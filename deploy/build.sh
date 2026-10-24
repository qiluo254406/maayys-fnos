#!/usr/bin/env bash
# 一条命令构建 MaaYYs 的飞牛 fpk
#
#   bash deploy/build.sh                      # 默认：下载 v3.17.11 → 建镜像 → 冒烟 → 导出 → 打 fpk
#   bash deploy/build.sh --version v3.18.0    # 换上游版本
#   bash deploy/build.sh --offline            # 复用构建目录里已下好的包
#   bash deploy/build.sh --no-smoke           # 跳过冒烟测试
#   bash deploy/build.sh --image-only         # 只建镜像，不打 fpk
#
# 前置：Docker（构建机）、curl、gzip、tar。fnpack 会自动下载。
# 磁盘：约 8GB（上游包 254MB + 镜像 ~2.8GB + 导出包 1.3GB + fpk 1.3GB）
# 大头在 MaaYYs 自身：全量包解压后约 1.5GB（资源图多），再叠加 WebKitGTK/CJK 字体/LLVM。
#
# 不要在日用的飞牛上跑构建：吃 CPU/IO，且 docker build 期间镜像层会把存储撑满。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

UPSTREAM_REPO="TanyaShue/MaaYYs"
UPSTREAM_VERSION="v3.17.11"      # 本项目核对过的版本；换版本前先确认目录结构没变
WORK="${MAAYYS_BUILD_WORK:-${REPO_ROOT}/build-work}"
IMAGE_TAG="maayys-fnos:local"

FNPACK_URL="https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64"
FNPACK_BIN=""

DO_SMOKE=1
DO_FPK=1
OFFLINE=0
# 构建期装包走的 APT 源。国内默认阿里云；传 --apt-mirror "" 用官方源
APT_MIRROR="http://mirrors.aliyun.com/ubuntu"

# ---------------------------------------------------------------- 参数
while [ $# -gt 0 ]; do
    case "$1" in
        --version)    UPSTREAM_VERSION="${2:?--version 需要一个值}"; shift 2 ;;
        --work)       WORK="${2:?--work 需要一个值}"; shift 2 ;;
        # 用 ${2?} 而不是 ${2:?}：后者把空字符串也当成"没给值"，
        # 而国内镜像源在 CI（国外 runner）上是反效果，需要显式传空切回官方源。
        --apt-mirror) APT_MIRROR="${2?--apt-mirror 需要一个值；传空字符串表示用官方源}"; shift 2 ;;
        --image-only) DO_FPK=0; shift ;;
        --no-smoke)   DO_SMOKE=0; shift ;;
        --offline)    OFFLINE=1; shift ;;
        -h|--help)    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1（用 --help 看用法）" >&2; exit 2 ;;
    esac
done

case "$WORK" in
    /*) ;;
    *) echo "ERROR: --work 必须是绝对路径：$WORK" >&2; exit 1 ;;
esac

# --version latest：查 GitHub 取最新 release 的 tag。
# 国内直连 api.github.com 通常不通，走代理：export https_proxy=http://127.0.0.1:7890
if [ "${UPSTREAM_VERSION}" = "latest" ]; then
    echo "=== 查询上游最新版本 ==="
    LATEST="$(curl -fsSL --retry 2 --retry-delay 2 --max-time 25 \
        "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "${LATEST}" ] || {
        echo "ERROR: 取不到最新版本。可能是网络问题，试试：" >&2
        echo "       export https_proxy=http://<你的代理>:<端口>" >&2
        exit 1
    }
    UPSTREAM_VERSION="${LATEST}"
    echo "    上游最新：${UPSTREAM_VERSION}"
fi

TARBALL="${WORK}/MaaYYs-linux-x86_64-${UPSTREAM_VERSION}-MXU.tar.gz"
IMAGE_TGZ="${WORK}/maayys-image.tar.gz"

log()  { echo "=== $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. 前置检查
log "[1/6] 检查前置条件"

command -v docker >/dev/null 2>&1 || fail "没有 docker。构建机需要 Docker。"
docker info >/dev/null 2>&1 || fail "Docker 守护进程没在跑（或当前用户无权限，试试 sudo）。"
command -v curl >/dev/null 2>&1 || fail "没有 curl。"
command -v gzip >/dev/null 2>&1 || fail "没有 gzip。"
command -v tar  >/dev/null 2>&1 || fail "没有 tar。"

mkdir -p "${WORK}" "${REPO_ROOT}/dist"
echo "    构建目录：${WORK}"

# 基础镜像：docker pull 是 daemon 发起的，shell 里设代理对它无效。
# 拉不到时给出可执行的替代方案，别让人对着 "pull access denied" 猜。
if ! docker image inspect ubuntu:24.04 >/dev/null 2>&1; then
    echo "    本地没有 ubuntu:24.04，尝试拉取 ..."
    if ! docker pull ubuntu:24.04 >/dev/null 2>&1; then
        fail "拉不到 ubuntu:24.04（daemon 没有外网/代理）。
    替代方案（不需要 sudo）：
      bash deploy/prepare-base-image.sh
    它用官方 rootfs 导入一份等价的本地镜像。"
    fi
    echo "    拉取完成。"
fi

# ---------------------------------------------------------------- 2. 上游全量包
log "[2/6] 准备 MaaYYs 上游全量包"

if [ -s "${TARBALL}" ] && gzip -t "${TARBALL}" 2>/dev/null; then
    echo "    已存在且完好：$(du -h "${TARBALL}" | cut -f1)"
elif [ "${OFFLINE}" = "1" ]; then
    fail "--offline 要求 ${TARBALL} 已就绪，但它不存在或已损坏。"
else
    URL="https://github.com/${UPSTREAM_REPO}/releases/download/${UPSTREAM_VERSION}/MaaYYs-linux-x86_64-${UPSTREAM_VERSION}-MXU.tar.gz"
    echo "    下载：${URL}"
    curl -fL --retry 3 --retry-delay 2 -o "${TARBALL}.part" "${URL}" \
        || fail "下载失败。可手动下载后放到 ${TARBALL} 再用 --offline 重跑。"
    mv -f "${TARBALL}.part" "${TARBALL}"
    gzip -t "${TARBALL}" || fail "下载的包不完整（gzip 校验失败），请重下。"
    echo "    完成：$(du -h "${TARBALL}" | cut -f1)"
fi

# 结构校验：这几个缺一个镜像就跑不起来。包内路径可能带 ./ 前缀，两种都认。
#
# 注意：这里必须先把清单落盘再 grep。写成 `printf ... | grep -q` 会踩一个经典坑 ——
# grep -q 一命中就退出，写端收到 SIGPIPE 返回 141，pipefail 会把整条管道判成失败，
# 于是"明明找到了"却报"找不到"（条目越靠前越容易触发）。
LIST_FILE="$(mktemp)"
trap 'rm -f "${LIST_FILE}"' EXIT
tar -tzf "${TARBALL}" > "${LIST_FILE}" || fail "读不了上游包：${TARBALL}"

for must in mxu agent/agent interface.json maafw; do
    grep -qE "^\.?/?${must}(/|$)" "${LIST_FILE}" \
        || fail "上游包里找不到 ${must}，目录结构与预期不符（版本 ${UPSTREAM_VERSION}）。"
done
rm -f "${LIST_FILE}"
trap - EXIT
echo "    结构校验通过"

# ---------------------------------------------------------------- 3. 构建上下文
log "[3/6] 准备构建上下文"

# 上下文就是 WORK：上游包已在里面，再把 Dockerfile / entrypoint / nginx 模板拷平进去。
cp -f "${REPO_ROOT}/deploy/Dockerfile"           "${WORK}/Dockerfile"
cp -f "${REPO_ROOT}/deploy/entrypoint.sh"        "${WORK}/entrypoint.sh"
cp -f "${REPO_ROOT}/deploy/nginx.conf.template"  "${WORK}/nginx.conf.template"

# 上次导出的镜像包（1.3GB）和 fnpack 不该进上下文，否则每次构建都白传一遍
cat > "${WORK}/.dockerignore" <<'EOF'
maayys-image.tar.gz
maayys-image.tar
fnpack
*.part
EOF

# ---------------------------------------------------------------- 4. 构建镜像
log "[4/6] docker build（首次约 5-10 分钟，取决于网速）"

docker build \
    -f "${WORK}/Dockerfile" \
    -t "${IMAGE_TAG}" \
    --build-arg "MAAYYS_TARBALL=$(basename "${TARBALL}")" \
    --build-arg "MAAYYS_VERSION=${UPSTREAM_VERSION}" \
    --build-arg "APT_MIRROR=${APT_MIRROR}" \
    "${WORK}"

docker image inspect "${IMAGE_TAG}" --format '    镜像就绪：{{.Id}} ({{.Size}} bytes)' || fail "镜像没建出来。"

# ---------------------------------------------------------------- 5. 冒烟
if [ "${DO_SMOKE}" = "1" ]; then
    log "[5/6] 冒烟测试"

    docker rm -f maayys-smoke >/dev/null 2>&1 || true
    # 用 18000（nginx 的调试端口）验证整条链路：Xvfb → mxu → 内置 Web → nginx
    docker run -d --name maayys-smoke --init --shm-size 512m \
        -p 127.0.0.1:18000:18000 "${IMAGE_TAG}" >/dev/null \
        || fail "冒烟容器起不来。"

    ok=0
    for i in $(seq 1 90); do
        if curl -sf --max-time 2 http://127.0.0.1:18000/api/heartbeat >/dev/null 2>&1; then
            ok=1
            break
        fi
        # 不用 `docker ps | grep -q`：同上，pipefail 下会因 SIGPIPE 误判
        if [ -z "$(docker ps --filter 'name=^maayys-smoke$' --format '{{.Names}}')" ]; then
            echo "    容器提前退出，日志："
            docker logs --tail 40 maayys-smoke 2>&1 | sed 's/^/    /'
            docker rm -f maayys-smoke >/dev/null 2>&1 || true
            fail "冒烟失败：容器启动后退出。"
        fi
        sleep 2
    done

    if [ "${ok}" != "1" ]; then
        echo "    等待 180s 仍未就绪，容器日志："
        docker logs --tail 60 maayys-smoke 2>&1 | sed 's/^/    /'
        docker rm -f maayys-smoke >/dev/null 2>&1 || true
        fail "冒烟失败：MXU 的 Web 服务没起来。用 --no-smoke 可跳过，但打出来的包大概率也是坏的。"
    fi

    echo "    /api/heartbeat 正常响应"
    # 深度冒烟。教训：这几次事故里两次是「heartbeat 正常但页面/WS 是坏的」——
    # 白屏 = 首页 200 但 assets 404；断连 = WS 握手 403。只测 heartbeat 一次都拦不住。
    #
    # 另一个教训（run #4）：MXU 刚启动的几秒里连接可能被重置，heartbeat 通了 1 秒后
    # GET / 直接 000。所以每项带重试（5 次、间隔 3s），并用 -sS 留下 curl 的错误原文，
    # 失败时能分清是超时、拒绝连接还是状态码不对。
    base="http://127.0.0.1:18000"

    # 失败时必须能看到容器内部发生了什么（mxu 崩溃、重启计数、entrypoint 决策都在这里）
    smoke_diag() {
        echo "    ---- 冒烟容器状态 ----"
        docker ps -a --filter 'name=^maayys-smoke$' --format '  {{.Status}}  {{.Image}}' | sed 's/^/    /'
        echo "    ---- 容器日志（尾部 60 行）----"
        docker logs --tail 60 maayys-smoke 2>&1 | sed 's/^/    /'
    }


    smoke_200() {
        local url="$1" name="$2" i code=000 err
        err="$(mktemp)"
        for i in 1 2 3 4 5; do
            code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>"$err" || true)"
            if [ "${code}" = "200" ]; then
                rm -f "$err"
                echo "    ${name} -> 200"
                return 0
            fi
            sleep 3
        done
        echo "    curl 报错：$(tail -1 "$err" 2>/dev/null)"
        rm -f "$err"
        smoke_diag
        fail "冒烟失败：${name} 最后返回 ${code}（期望 200），已重试 5 次"
    }

    smoke_ws() {
        local i hs="(空)"
        for i in 1 2 3 4 5; do
            hs="$(curl -s -i --max-time 5 \
                -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
                -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
                -H "Origin: ${base}" \
                "${base}/api/ws" 2>/dev/null | head -1 || true)"
            case "${hs}" in
                *101*) echo "    WS 握手 -> 101"; return 0 ;;
            esac
            sleep 3
        done
        smoke_diag
        fail "冒烟失败：WS 握手返回「${hs}」（期望 101），已重试 5 次"
    }

    smoke_ws

    if ! docker ps --filter 'name=^maayys-smoke$' --format '{{.Names}}' | grep -q .; then
        echo "    容器已退出，日志："
        docker logs --tail 60 maayys-smoke 2>&1 | sed 's/^/    /'
        fail "冒烟失败：容器在冒烟过程中退出。"
    fi

    smoke_200 "${base}/" "GET /"

    js="$(curl -s --max-time 5 "${base}/" 2>/dev/null | grep -oE '/assets/index-[^"]+\.js' | head -1 || true)"
    [ -n "${js}" ] || fail "冒烟失败：首页里找不到前端入口（/assets/index-*.js）"
    smoke_200 "${base}${js}" "前端资源"

    smoke_200 "${base}/api/interface" "接口"

    smoke_ws

    echo "    冒烟通过"
    docker rm -f maayys-smoke >/dev/null 2>&1 || true
else
    log "[5/6] 跳过冒烟测试（--no-smoke）"
fi

# ---------------------------------------------------------------- 6. 导出 + 打 fpk
log "[6/6] 导出镜像并打包 fpk"

echo "    导出镜像（几分钟）..."
docker save "${IMAGE_TAG}" | gzip -6 > "${IMAGE_TGZ}"
[ -s "${IMAGE_TGZ}" ] || fail "镜像导出失败。"
echo "    导出完成：$(du -h "${IMAGE_TGZ}" | cut -f1)"

if [ "${DO_FPK}" = "0" ]; then
    echo
    echo "已完成（--image-only）：镜像 ${IMAGE_TAG}，导出包 ${IMAGE_TGZ}"
    exit 0
fi

# fnpack：飞牛官方打包工具，没有就下到构建目录里，不污染系统
if command -v fnpack >/dev/null 2>&1; then
    FNPACK_BIN="$(command -v fnpack)"
elif [ -x "${WORK}/fnpack" ]; then
    FNPACK_BIN="${WORK}/fnpack"
else
    echo "    下载 fnpack ..."
    curl -fL --retry 3 -o "${WORK}/fnpack" "${FNPACK_URL}" || fail "fnpack 下载失败。"
    chmod +x "${WORK}/fnpack"
    FNPACK_BIN="${WORK}/fnpack"
fi
echo "    fnpack: ${FNPACK_BIN}"

cp -f "${IMAGE_TGZ}" "${REPO_ROOT}/fnos-app/app/maayys-image.tar.gz"
echo "    离线镜像已放入 fnos-app/app/ ($(du -h "${REPO_ROOT}/fnos-app/app/maayys-image.tar.gz" | cut -f1))"

rm -f "${REPO_ROOT}/fnos-app/"*.fpk
( cd "${REPO_ROOT}/fnos-app" && "${FNPACK_BIN}" build )

FPK_SRC="$(ls -1 "${REPO_ROOT}/fnos-app/"*.fpk 2>/dev/null | head -1 || true)"
[ -n "${FPK_SRC}" ] || fail "fnpack 没有产出 .fpk，检查上面的报错。"

# fnpack 按 appname 命名（maayys-fnos.fpk），不带版本号 ——
# 直接堆在 dist/ 里根本分不清哪个是哪个版本，这里补上应用版本与上游版本
APP_VER="$(grep -E '^version[[:space:]]*=' "${REPO_ROOT}/fnos-app/manifest" | awk -F'=' '{gsub(/[[:space:]]/,"",$2); print $2}')"
FPK_OUT="${REPO_ROOT}/dist/maayys-fnos_${APP_VER:-unknown}_${UPSTREAM_VERSION}.fpk"
mv -f "${FPK_SRC}" "${FPK_OUT}"

echo
echo "================ 构建完成 ================"
echo "上游版本 : ${UPSTREAM_VERSION}"
echo "镜像     : ${IMAGE_TAG}"
echo "fpk      : ${FPK_OUT}  ($(du -h "${FPK_OUT}" | cut -f1))"
FPK_SHA=""
if command -v sha256sum >/dev/null 2>&1; then
    FPK_SHA="$(sha256sum "${FPK_OUT}" | cut -d' ' -f1)"
    echo "sha256   : ${FPK_SHA}"
fi

# 记录本次构建的版本与指纹：tools/check-update.sh 靠它判断"我手上是哪一版"
mkdir -p "${REPO_ROOT}/dist"
cat > "${REPO_ROOT}/dist/.last-build.json" <<EOF
{
  "app_version": "${APP_VER:-unknown}",
  "upstream_version": "${UPSTREAM_VERSION}",
  "fpk": "$(basename "${FPK_OUT}")",
  "size_bytes": $(stat -c '%s' "${FPK_OUT}" 2>/dev/null || echo 0),
  "sha256": "${FPK_SHA}",
  "built_at": "$(date -Iseconds)"
}
EOF

echo
echo "安装到飞牛："
echo "  rsync -avP --partial --inplace '${FPK_OUT}' <user>@<NAS_IP>:/home/<user>/"
echo "  sudo appcenter-cli install-fpk --volume 1 /home/<user>/$(basename "${FPK_OUT}")"
echo "  sudo appcenter-cli start maayys-fnos"
echo "  sudo appcenter-cli status maayys-fnos     # 返回 0 = running"
