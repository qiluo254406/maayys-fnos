#!/usr/bin/env bash
# 打包前的静态自检：不需要 Docker，几秒钟跑完。
# 把 fnpack / 飞牛安装阶段才会暴露的错误提前抓出来。
#
#   bash tools/check-project.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/fnos-app"
FAILED=0

ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; FAILED=$((FAILED + 1)); }
warn() { echo "  warn $*"; }

echo "[1] shell 语法"
for f in "${ROOT}"/deploy/*.sh "${APP}"/cmd/*; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then
        ok "$(basename "$f")"
    else
        bad "$(basename "$f") 语法错误"
        bash -n "$f" 2>&1 | sed 's/^/       /'
    fi
done

echo "[2] manifest 必填字段"
for key in appname version display_name platform source maintainer distributor \
           desktop_uidir desktop_applaunchname ctl_stop os_min_version; do
    if grep -qE "^${key}[[:space:]]*=" "${APP}/manifest"; then
        ok "${key}"
    else
        bad "manifest 缺 ${key}"
    fi
done

echo "[3] 图标（fnpack 强制校验）"
for f in ICON.PNG ICON_256.PNG; do
    [ -s "${APP}/${f}" ] && ok "${f}" || bad "缺 ${f}"
done
[ -s "${APP}/app/ui/images/icon_256.png" ] && ok "ui/images/icon_256.png" || bad "缺 ui 图标"

echo "[4] manifest 与 ui 配置一致性"
UIDIR="$(grep -E '^desktop_uidir' "${APP}/manifest" | awk -F'=' '{gsub(/[[:space:]]/,"",$2); print $2}')"
# 安装后 app/ 的内容落到 TRIM_APPDEST，所以 ui 目录是 app/ui
[ -d "${APP}/app/${UIDIR}" ] && ok "desktop_uidir=${UIDIR} → app/${UIDIR} 存在" || bad "app/${UIDIR} 不存在"

LAUNCH="$(grep -E '^desktop_applaunchname' "${APP}/manifest" | awk -F'=' '{gsub(/[[:space:]]/,"",$2); print $2}')"
if grep -q "\"${LAUNCH}\"" "${APP}/app/ui/config"; then
    ok "ui/config 里有 ${LAUNCH}"
else
    bad "ui/config 里没有桌面入口 ${LAUNCH}"
fi

# 1.0.3 起走直连模式：入口必须是 type=url + port=12701，
# 且端口要和 cmd/main 的 HOST_PORT 一致（前端把后端地址硬编码成 hostname:webServerPort，
# 端口对不上就"与后端连接断开"，见 docs/构建指南.md 2.6）
UI_PORT="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "${APP}/app/ui/config" | head -1)"
MAIN_PORT="$(sed -n 's/^HOST_PORT="\([0-9]*\)".*/\1/p' "${APP}/cmd/main" | head -1)"

if grep -q '"type"[[:space:]]*:[[:space:]]*"url"' "${APP}/app/ui/config"; then
    ok "ui/config type = url（直连模式）"
else
    bad "ui/config 不是直连模式（type 应为 url）"
fi

if [ -n "${UI_PORT}" ] && [ "${UI_PORT}" = "${MAIN_PORT}" ]; then
    ok "ui/config port = cmd/main HOST_PORT = ${UI_PORT}"
else
    bad "端口不一致：ui/config='${UI_PORT}' cmd/main='${MAIN_PORT}'（前端硬编码，必须相同）"
fi

if grep -q "service_port[[:space:]]*=[[:space:]]*${UI_PORT:-x}" "${APP}/manifest"; then
    ok "manifest service_port 与入口端口一致"
else
    bad "manifest 的 service_port 应等于 ${UI_PORT}"
fi

echo "[5] JSON 合法性"
for f in "${APP}/app/ui/config" "${APP}/config/privilege" "${APP}/config/resource"; do
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null \
            && ok "$(basename "$f")" || bad "$(basename "$f") 不是合法 JSON"
    else
        warn "没有 python3，跳过 $(basename "$f")"
    fi
done

echo "[6] 离线镜像包"
if [ -s "${APP}/app/maayys-image.tar.gz" ]; then
    ok "maayys-image.tar.gz ($(du -h "${APP}/app/maayys-image.tar.gz" | cut -f1))"
else
    warn "app/maayys-image.tar.gz 还没有（跑完 deploy/build.sh 才会生成）"
fi

echo
if [ "${FAILED}" -eq 0 ]; then
    echo "全部通过"
    exit 0
fi
echo "有 ${FAILED} 项未通过"
exit 1
