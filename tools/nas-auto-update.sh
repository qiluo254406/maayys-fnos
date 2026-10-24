#!/bin/bash
# 在飞牛 NAS 上运行的自动更新脚本：检查 GitHub Release，有新版就装。
#
# 必须 root 跑（要调 appcenter-cli）。由 systemd timer 或 cron 定时触发。
# 安装位置见同目录的 maayys-auto-update.service / .timer。
#
#   bash nas-auto-update.sh            # 正常执行
#   bash nas-auto-update.sh --check    # 只查不装（dry run）
#
# ============ 配置 ============
REPO="${MAAYYS_REPO:-qiluo/maayys-fnos}"        # 改成你自己的 GitHub 仓库
VOLUME="${MAAYYS_VOLUME:-2}"                    # 装到哪个存储空间，与首次安装保持一致
PROXY="${MAAYYS_UPDATE_PROXY:-}"                # 例：http://127.0.0.1:7890（NAS 本机跑代理时）
APP="maayys-fnos"
MANIFEST="/var/apps/${APP}/manifest"
LOG="/vol${VOLUME}/@appdata/${APP}/auto-update.log"
# ==============================

set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

mkdir -p "$(dirname "${LOG}")" 2>/dev/null || true
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG}"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root 权限（要调 appcenter-cli）"
[ -f "${MANIFEST}" ] || die "找不到 ${MANIFEST}，应用没装？"

# 并发保护：定时任务和手动执行撞上时不要同时装
exec 9>"/var/run/maayys-auto-update.lock" 2>/dev/null || exec 9>/tmp/maayys-auto-update.lock
flock -n 9 || die "已有另一个更新进程在跑"

CURL=(curl -fsSL --retry 3 --retry-delay 2 --max-time 600)
[ -n "${PROXY}" ] && CURL+=(-x "${PROXY}")

BASE="https://github.com/${REPO}/releases/latest/download"
current="$(awk -F= '/^version/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${MANIFEST}")"
log "当前应用版本：${current}"

# 1. 取最新元信息
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
"${CURL[@]}" -o "${tmp}/latest.json" "${BASE}/latest.json" \
    || die "拉不到 latest.json（检查 REPO / 网络 / 代理）。仓库若是私有的，这里必须换成带 token 的下载方式"

latest="$(sed -n 's/.*"app_version":[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp}/latest.json" | head -1)"
sha_want="$(sed -n 's/.*"sha256":[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp}/latest.json" | head -1)"
upstream="$(sed -n 's/.*"upstream_version":[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp}/latest.json" | head -1)"
[ -n "${latest}" ] || die "latest.json 里没有 app_version，格式不对？"
log "上游最新：${latest}（MaaYYs ${upstream}）"

if [ "${latest}" = "${current}" ]; then
    log "已是最新，退出"
    exit 0
fi

# 2. 只允许升级，不允许降级（避免 release 被回滚时把应用降回去）
if [ "$(printf '%s\n%s\n' "${current}" "${latest}" | sort -V | tail -1)" != "${latest}" ]; then
    log "远端版本 ${latest} 不高于当前 ${current}，跳过（不降级）"
    exit 0
fi

if [ "${CHECK_ONLY}" = "1" ]; then
    log "--check：有新版本 ${current} -> ${latest}，未安装"
    exit 0
fi

# 3. 下载并校验
log "下载 fpk ..."
"${CURL[@]}" --max-time 3600 -o "${tmp}/new.fpk" "${BASE}/maayys-fnos.fpk" || die "下载失败"
sha_have="$(sha256sum "${tmp}/new.fpk" | cut -d' ' -f1)"
if [ -n "${sha_want}" ] && [ "${sha_have}" != "${sha_want}" ]; then
    die "sha256 不匹配（期望 ${sha_want}，实际 ${sha_have}），拒绝安装"
fi
log "校验通过（$(du -h "${tmp}/new.fpk" | cut -f1)）"

# 4. 安装。install-fpk 会覆盖同 appname 的旧版本，用户数据在 @appdata 不受影响
log "安装 ${latest} ..."
if ! appcenter-cli install-fpk --volume "${VOLUME}" "${tmp}/new.fpk" >>"${LOG}" 2>&1; then
    die "install-fpk 失败，日志见 ${LOG}；旧版本仍在，应用可能处于停止状态，请到应用中心检查"
fi

# 5. 启动并确认
appcenter-cli start "${APP}" >>"${LOG}" 2>&1 || log "WARN: start 返回非 0，稍后确认状态"
sleep 5
now="$(awk -F= '/^version/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${MANIFEST}" 2>/dev/null)"
if [ "${now}" = "${latest}" ]; then
    log "更新完成：${current} -> ${now}"
else
    log "WARN: 装完读到的版本是 '${now}'，与期望 ${latest} 不一致，请手动确认"
fi
