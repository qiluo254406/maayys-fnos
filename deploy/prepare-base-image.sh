#!/usr/bin/env bash
# 在没有 Docker Hub 访问的环境里，用 Ubuntu 官方 rootfs 导入一个等价的 ubuntu:24.04。
#
# 为什么需要它：`docker pull` 是 **daemon** 发起的请求，你给 shell 设 http_proxy 没用，
# 得改 /etc/systemd/system/docker.service.d/ 或 daemon.json 再重启 docker（要 root）。
# 而 `docker import` 只走 docker CLI，普通用户在 docker 组里就能做 —— 不需要 sudo。
#
# 用法：
#   bash deploy/prepare-base-image.sh              # 默认阿里云 + 官方 cdimage
#   BASE_URL=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-base/releases/24.04/release \
#     bash deploy/prepare-base-image.sh
#
# 完成后 `docker images ubuntu` 里会有 24.04，`docker build` 的 FROM 直接用本地这份。

set -euo pipefail

BASE_URL="${BASE_URL:-http://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release}"
CACHE="${CACHE:-${HOME}/.cache/maayys-base}"
TAG="${TAG:-ubuntu:24.04}"

log()  { echo "=== $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

log "[1/4] 检查已有镜像"
if docker image inspect "${TAG}" >/dev/null 2>&1; then
    echo "    ${TAG} 已存在，跳过："
    docker image inspect "${TAG}" --format '    {{.Id}} ({{.Size}} bytes)'
    exit 0
fi
echo "    没有 ${TAG}，准备导入"

log "[2/4] 定位 rootfs 包"
mkdir -p "${CACHE}"
if ! curl -fsSL --max-time 30 "${BASE_URL}/" -o "${CACHE}/index.html"; then
    fail "无法访问 ${BASE_URL}，换一个镜像源再试。"
fi
FILE="$(grep -oE 'ubuntu-base-24\.04[^"]*amd64\.tar\.gz' "${CACHE}/index.html" | sort -uV | tail -1 || true)"
[ -n "${FILE}" ] || fail "${BASE_URL} 里找不到 ubuntu-base-24.04 的 amd64 包。"
echo "    选定：${FILE}"

log "[3/4] 下载（约 30MB）"
TARBALL="${CACHE}/${FILE}"
if [ -s "${TARBALL}" ] && tar -tzf "${TARBALL}" >/dev/null 2>&1; then
    echo "    已缓存：$(du -h "${TARBALL}" | cut -f1)"
else
    curl -fL --retry 3 --retry-delay 2 -o "${TARBALL}.part" "${BASE_URL}/${FILE}" \
        || fail "下载失败：${BASE_URL}/${FILE}"
    mv -f "${TARBALL}.part" "${TARBALL}"
    tar -tzf "${TARBALL}" >/dev/null || fail "下载的 rootfs 不完整。"
    echo "    完成：$(du -h "${TARBALL}" | cut -f1)"
fi

log "[4/4] docker import"
# 官方 rootfs 是空壳，没有 ENV/CMD；这里补上 Docker 官方 ubuntu 镜像的默认值，
# 否则构建阶段 PATH 之类可能不是预期的
docker import \
    --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    --change 'CMD ["/bin/bash"]' \
    "${TARBALL}" "${TAG}" >/dev/null || fail "docker import 失败。"

docker image inspect "${TAG}" --format '    {{.Id}} ({{.Size}} bytes)'
echo
echo "    自检："
docker run --rm "${TAG}" sh -c 'cat /etc/os-release | head -2; command -v apt-get && echo "apt 可用"' \
    || fail "导入的镜像跑不起来。"
