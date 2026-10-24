#!/usr/bin/env bash
# 在 WSL 的 Ubuntu 里跑完整构建（连环境一起准备）
#
# 用法（Windows 终端里执行；路径按你的实际位置改）：
#   wsl -d Ubuntu -- bash /mnt/c/Users/qiluo/WorkBuddy/开发/maayys-fnos/tools/build-in-wsl.sh
#
# 它做四件事：
#   1. 把工程从 /mnt/c 拷到 ~/ —— WSL 里跨盘 IO 很慢，docker build 在 /mnt 上也容易踩
#      权限与大小写问题，所以不在原位置构建
#   2. 没有 Docker 就装 docker.io，并在没有 systemd 的情况下手工拉起 dockerd
#   3. 把当前用户加进 docker 组，用 sg 直接生效（不用重新登录）
#   4. 调 deploy/build.sh，构建完把 fpk 拷回 Windows 侧
#
# 需要 sudo 权限安装软件；如果你的 sudo 要输密码，请先手工执行一次：
#   sudo apt-get update && sudo apt-get install -y docker.io rsync
# 再跑本脚本（它会跳过安装步骤）。

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HOME}/maayys-fnos-build"
NEED_GB=8

log()  { echo -e "\n=== $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

log "[0/4] 环境确认"
[ -f /etc/os-release ] || fail "这看起来不是 Linux。"
. /etc/os-release
echo "    发行版：${PRETTY_NAME:-unknown}"
case "${ID:-}" in
    ubuntu|debian) ;;
    *) echo "    WARN: 只在 Ubuntu/Debian 上验证过，继续但可能缺包。" ;;
esac
echo "    内核：$(uname -r)"

AVAIL_GB="$(df -Pk "${HOME}" | awk 'NR==2 {printf "%d", $4/1024/1024}')"
echo "    ${HOME} 可用空间：${AVAIL_GB}GB"
[ "${AVAIL_GB}" -ge "${NEED_GB}" ] || fail "空间不足，至少需要 ${NEED_GB}GB（镜像 + 导出包 + fpk）。"

log "[1/4] 拷贝工程到 WSL 文件系统"
rm -rf "${DEST}"
mkdir -p "${DEST}"
if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude build-work --exclude dist --exclude 'deploy/data' "${SRC}/" "${DEST}/"
else
    # 没有 rsync 就用 cp，再手工剔掉体积大的目录
    cp -a "${SRC}/." "${DEST}/"
    rm -rf "${DEST}/build-work" "${DEST}/dist" "${DEST}/deploy/data"
fi
echo "    ${DEST}"

log "[2/4] Docker"
if docker info >/dev/null 2>&1; then
    echo "    Docker 可用，跳过安装。"
else
    if ! command -v docker >/dev/null 2>&1; then
        echo "    安装 docker.io ..."
        sudo -n true 2>/dev/null || fail "sudo 需要密码。请先手工执行：
      sudo apt-get update && sudo apt-get install -y docker.io rsync
    然后重跑本脚本。"
        sudo apt-get update -qq
        sudo apt-get install -y -qq docker.io rsync
    fi

    if command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
        echo "    systemd 在跑，用 systemctl 启 docker ..."
        sudo systemctl enable --now docker
    else
        echo "    没有 systemd（WSL 常见），手工拉起 dockerd ..."
        sudo mkdir -p /etc/docker
        # WSL 里的 overlayfs 偶发不稳，直接用 vfs 稳但更占空间；这里优先 overlay2、失败再退
        sudo nohup dockerd > /tmp/dockerd.log 2>&1 &
        for i in $(seq 1 30); do
            sudo docker info >/dev/null 2>&1 && break
            sleep 1
        done
        sudo docker info >/dev/null 2>&1 || {
            echo "    dockerd 起不来，最后 20 行日志："
            tail -20 /tmp/dockerd.log | sed 's/^/      /'
            fail "dockerd 启动失败。"
        }
    fi

    sudo usermod -aG docker "${USER}" 2>/dev/null || true
    # usermod 要重新登录才生效，sg 可以立刻拿到组身份
    if ! docker info >/dev/null 2>&1; then
        echo "    切到 docker 组身份重新执行本脚本 ..."
        exec sg docker -c "bash '$0' $*"
    fi
fi

log "[3/4] 构建"
cd "${DEST}"
sg docker -c "bash deploy/build.sh $*" || fail "构建失败，日志见上。"

log "[4/4] 取回产物"
shopt -s nullglob
FPKS=("${DEST}/dist/"*.fpk)
shopt -u nullglob
if [ "${#FPKS[@]}" -eq 0 ]; then
    echo "    没有找到 .fpk（用了 --image-only？）"
    exit 0
fi
mkdir -p "${SRC}/dist"
cp -f "${FPKS[@]}" "${SRC}/dist/"
echo "    已拷回 Windows 侧："
for f in "${FPKS[@]}"; do
    echo "      ${SRC}/dist/$(basename "${f}")  ($(du -h "${f}" | cut -f1))"
done
