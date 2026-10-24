#!/usr/bin/env bash
# 检查上游 MaaYYs 有没有新版本，并给出升级命令。
#
#   bash tools/check-update.sh
#
# 国内直连 api.github.com 通常不通，需要代理：
#   https_proxy=http://<代理>:<端口> bash tools/check-update.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST="${ROOT}/dist/.last-build.json"
REPO="TanyaShue/MaaYYs"

cur_app="unknown"
cur_up="unknown"
if [ -f "${LAST}" ]; then
    cur_app="$(sed -n 's/.*"app_version":[[:space:]]*"\([^"]*\)".*/\1/p' "${LAST}" | head -1)"
    cur_up="$(sed -n 's/.*"upstream_version":[[:space:]]*"\([^"]*\)".*/\1/p' "${LAST}" | head -1)"
fi

echo "本仓库已构建：应用 ${cur_app}  上游 ${cur_up}"
[ -f "${LAST}" ] || echo "  （还没有构建记录，先跑一次 bash deploy/build.sh）"

printf "查询上游最新版本 ... "
latest="$(curl -fsSL --retry 2 --retry-delay 2 --max-time 25 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
if [ -z "${latest}" ]; then
    echo "失败"
    echo
    echo "取不到 GitHub release。国内网络请带代理："
    echo "  https_proxy=http://127.0.0.1:7890 bash tools/check-update.sh"
    exit 1
fi
echo "${latest}"

echo
if [ "${latest}" = "${cur_up}" ]; then
    echo "上游已是最新。"
else
    echo "上游有更新：${cur_up} -> ${latest}"
    echo
    echo "升级步骤："
    echo "  1) bash deploy/build.sh --version ${latest}"
    echo "  2) 应用中心手动安装新的 fpk（覆盖安装，数据不动）"
    echo
    echo "  注意：MaaYYs 的资源图/任务定义会随之更新，容器首次启动时会同步程序文件、"
    echo "        保留 config/ 与 debug/（见 deploy/entrypoint.sh 的 seed_app）。"
fi

echo
echo "你自己的改动（源码/配置）需要手动升 fnos-app/manifest 的 version，"
echo "并在 changelog 里写一句，否则 fnOS 会认为版本没变、不给覆盖安装。"
