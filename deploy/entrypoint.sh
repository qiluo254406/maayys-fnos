#!/bin/bash
# MaaYYs 容器入口
#
# 启动顺序：铺开应用文件 → Xvfb → mxu → 等 MXU 自带的 Web 服务就绪 → nginx 接网关
# 退出语义：mxu 反复退出就退出容器（让飞牛看到"异常"，而不是一个假运行的空壳）
#
# 刻意不用 set -e：每个子进程的失败要有自己的处理，不能让某一步静默带走整个容器。

PRISTINE_DIR="${PRISTINE_DIR:-/opt/maayys-dist}"
APP_DIR="${APP_DIR:-/data/app}"
GATEWAY_DIR="${GATEWAY_DIR:-/gw}"
GATEWAY_SOCKET="${GATEWAY_DIR}/app.sock"
LOG_DIR="${LOG_DIR:-/data/logs}"

# MXU 的 Web 服务默认端口 12701；端口被占时它会向后试 10 个（见上游 MAX_PORT_ATTEMPTS）
WEB_PORT_BASE=12701
WEB_PORT_SPAN=10

# 可选逃生通道：MAAYYS_VNC=1 时额外起 x11vnc + noVNC，走网关的 /vnc/ 路径
VNC_ENABLED="${MAAYYS_VNC:-0}"
VNC_PORT=6080

SCREEN_GEOMETRY="${SCREEN_GEOMETRY:-1280x800x24}"
DEBUG_TCP_PORT="${DEBUG_TCP_PORT:-18000}"
# 飞牛网关前缀，必须与 fnos-app/app/ui/config 里的 gatewayPrefix 一致
APP_PREFIX="${APP_PREFIX:-/app/maayys-fnos}"

XVFB_PID=""
MXU_PID=""
X11VNC_PID=""
WEBSOCKIFY_PID=""
SHUTTING_DOWN=0
WEB_PORT=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [entrypoint] $*"; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- 应用文件
# MXU 在 Linux 上是便携式布局：配置、截图、日志全部写在 exe 同目录（get_app_data_dir
# 在非 macOS 上直接返回 exe 目录）。所以程序目录必须是可写的持久化卷，不能只读挂镜像。
# 这里把「程序文件」和「用户数据」分开处理：
#   首次安装  → 全量铺开
#   镜像升级  → 只刷新程序文件，config/ config_backup/ cache/ debug/ dist/ 一律保留
seed_app() {
    local dist_ver have item
    dist_ver="$(cat "${PRISTINE_DIR}/.dist-version" 2>/dev/null || echo unknown)"

    mkdir -p "${APP_DIR}" || die "无法创建 ${APP_DIR}"

    # 用「文件在不在」判断有没有铺开过，不要用 -x：cp/tar 在某些挂载上会丢 mode，
    # 一旦丢了就会被误判成首次安装，把用户配置又盖一遍。
    if [ ! -f "${APP_DIR}/mxu" ]; then
        log "首次启动，铺开应用文件 -> ${APP_DIR}"
        cp -a "${PRISTINE_DIR}/." "${APP_DIR}/" || die "复制应用文件失败"
        chmod +x "${APP_DIR}/mxu" 2>/dev/null || true
        printf '%s\n' "${dist_ver}" > "${APP_DIR}/.maayys-version"
        return 0
    fi

    have="$(cat "${APP_DIR}/.maayys-version" 2>/dev/null || echo unknown)"
    if [ "${have}" = "${dist_ver}" ]; then
        return 0
    fi

    log "程序版本变化（${have} -> ${dist_ver}），刷新程序文件，保留用户数据"
    for item in mxu agent maafw resource_pack tasks assets preset doc interface.json LICENSE; do
        [ -e "${PRISTINE_DIR}/${item}" ] || continue
        rm -rf "${APP_DIR:?}/${item}"
        cp -a "${PRISTINE_DIR}/${item}" "${APP_DIR}/${item}" || die "刷新 ${item} 失败"
    done
    printf '%s\n' "${dist_ver}" > "${APP_DIR}/.maayys-version"
    chmod +x "${APP_DIR}/mxu" 2>/dev/null || true
    log "程序文件已更新；配置与截图目录未动"
}

# ---------------------------------------------------------------- 虚拟显示
start_xvfb() {
    rm -f /tmp/.X99-lock
    Xvfb :99 -screen 0 "${SCREEN_GEOMETRY}" -nolisten tcp -ac \
        > "${LOG_DIR}/xvfb.log" 2>&1 &
    XVFB_PID=$!

    local i
    for i in $(seq 1 50); do
        [ -S /tmp/.X11-unix/X99 ] && { log "Xvfb 就绪（${SCREEN_GEOMETRY}）"; return 0; }
        kill -0 "${XVFB_PID}" 2>/dev/null || break
        sleep 0.2
    done
    die "Xvfb 启动失败，详见 ${LOG_DIR}/xvfb.log"
}

# ---------------------------------------------------------------- MXU
start_mxu() {
    cd "${APP_DIR}" || die "无法进入 ${APP_DIR}"
    ./mxu >> "${LOG_DIR}/mxu.log" 2>&1 &
    MXU_PID=$!
    log "mxu 已启动（pid=${MXU_PID}）"
}

# 等 MXU 的 Web 服务就绪。它绑 127.0.0.1（allowLanAccess 默认 false），
# 所以这里探本机回环即可；端口被占时上游会自增，故扫一段。
wait_web() {
    local i port
    for i in $(seq 1 180); do
        for port in $(seq "${WEB_PORT_BASE}" "$((WEB_PORT_BASE + WEB_PORT_SPAN))"); do
            if curl -sf --max-time 1 "http://127.0.0.1:${port}/api/heartbeat" >/dev/null 2>&1; then
                WEB_PORT="${port}"
                log "MXU Web 服务就绪：127.0.0.1:${port}"
                return 0
            fi
        done
        kill -0 "${MXU_PID}" 2>/dev/null || return 1
        sleep 0.5
    done
    return 1
}

# ---------------------------------------------------------------- ADB 预连接
# MXU 的设备列表来自 MaaFramework 的 Toolkit::find_adb_devices()，它**只列已连接的设备**，
# 不会主动扫描网段。容器里没有 USB、也没有预连，所以界面点"刷新"永远是空的。
# 解决方式：容器启动时先把目标 adb connect 上，并保持重连（redroid 重启会掉线）。
#
# 目标地址来源，优先级从高到低：
#   1. 环境变量 MAAYYS_ADB_TARGETS（逗号或空格分隔，如 "192.168.1.15:5555"）
#   2. 数据文件 /data/adb-targets.txt（一行一个，# 开头为注释）
#   3. 默认：本容器所在网桥的网关 + :5555 —— 对应"redroid 把 5555 发布到宿主机"的常见接法
adb_targets() {
    if [ -n "${MAAYYS_ADB_TARGETS:-}" ]; then
        printf '%s' "${MAAYYS_ADB_TARGETS}" | tr ', ' '\n\n' | grep -v '^$'
        return 0
    fi
    if [ -f /data/adb-targets.txt ]; then
        grep -vE '^[[:space:]]*(#|$)' /data/adb-targets.txt
        return 0
    fi
    local gw
    gw="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
    [ -n "${gw}" ] && echo "${gw}:5555"
}

adb_keepalive() {
    local target
    # 等 MXU 起来再动 adb，避免两边同时拉起 adb server 抢 5037
    sleep 20
    while true; do
        for target in $(adb_targets); do
            if ! adb devices 2>/dev/null | grep -q "^${target}[[:space:]]"; then
                if adb connect "${target}" 2>&1 | grep -qi "connected"; then
                    log "adb 已连接：${target}"
                fi
            fi
        done
        sleep 45
    done
}

# ---------------------------------------------------------------- 可选 VNC
start_vnc() {
    [ "${VNC_ENABLED}" = "1" ] || return 0
    command -v x11vnc >/dev/null 2>&1 || { log "WARN: MAAYYS_VNC=1 但镜像里没有 x11vnc"; return 0; }

    x11vnc -display :99 -forever -shared -nopw -localhost -noxdamage -rfbport 5900 \
        > "${LOG_DIR}/x11vnc.log" 2>&1 &
    X11VNC_PID=$!

    websockify --web=/usr/share/novnc "127.0.0.1:${VNC_PORT}" 127.0.0.1:5900 \
        > "${LOG_DIR}/websockify.log" 2>&1 &
    WEBSOCKIFY_PID=$!
    log "VNC 逃生通道已开启：<网关地址>/vnc/vnc.html"
}

# ---------------------------------------------------------------- nginx
NGINX_RUNNING=0

# socket 由 nginx master（容器内 root）创建，属主必须改成飞牛的应用用户，
# 否则宿主侧以 package 身份跑的探活会被 0600 挡在门外。
fix_socket_perms() {
    local i
    for i in $(seq 1 50); do
        [ -S "${GATEWAY_SOCKET}" ] && break
        sleep 0.2
    done
    [ -S "${GATEWAY_SOCKET}" ] || return 1
    if [ -n "${GATEWAY_OWNER:-}" ]; then
        chown "${GATEWAY_OWNER}" "${GATEWAY_SOCKET}" 2>/dev/null \
            || log "WARN: chown ${GATEWAY_SOCKET} -> ${GATEWAY_OWNER} 失败"
        chmod 600 "${GATEWAY_SOCKET}" 2>/dev/null || true
    fi
    return 0
}

start_nginx() {
    mkdir -p /run/nginx-tmp

    GATEWAY_SOCKET="${GATEWAY_SOCKET}" \
    WEB_PORT="${WEB_PORT}" \
    VNC_PORT="${VNC_PORT}" \
    DEBUG_TCP_PORT="${DEBUG_TCP_PORT}" \
    APP_PREFIX="${APP_PREFIX}" \
    envsubst '${GATEWAY_SOCKET} ${WEB_PORT} ${VNC_PORT} ${DEBUG_TCP_PORT} ${APP_PREFIX}' \
        < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf \
        || die "生成 nginx 配置失败"

    if [ "${NGINX_RUNNING}" = "1" ]; then
        # 重启 mxu 后端口可能变了：只重载配置，不要碰已存在的 socket
        nginx -s reload >/dev/null 2>&1 || log "WARN: nginx reload 失败"
        log "nginx 配置已重载（上游 127.0.0.1:${WEB_PORT}）"
        fix_socket_perms || true
        return 0
    fi

    rm -f "${GATEWAY_SOCKET}"
    nginx -c /etc/nginx/nginx.conf || die "nginx 启动失败"
    NGINX_RUNNING=1

    if fix_socket_perms; then
        log "网关 socket 就绪：${GATEWAY_SOCKET}（属主 ${GATEWAY_OWNER:-未指定}）"
    else
        die "nginx 没有创建 ${GATEWAY_SOCKET}"
    fi
}

# ---------------------------------------------------------------- 退出
shutdown() {
    [ "${SHUTTING_DOWN}" = "1" ] && return 0
    SHUTTING_DOWN=1
    trap - TERM INT

    log "收到停止信号，开始收尾"
    if [ -n "${MXU_PID}" ] && kill -0 "${MXU_PID}" 2>/dev/null; then
        # 先礼后兵：SIGTERM 让 MXU 有机会保存配置；MaaFramework 的任务链没有
        # 「暂停到安全点」的接口，正在跑的任务只能中断，这一点在文档里写明。
        kill -TERM "${MXU_PID}" 2>/dev/null
        local i
        for i in $(seq 1 20); do
            kill -0 "${MXU_PID}" 2>/dev/null || break
            sleep 0.5
        done
        kill -KILL "${MXU_PID}" 2>/dev/null || true
    fi

    nginx -s quit >/dev/null 2>&1 || true
    [ -n "${WEBSOCKIFY_PID}" ] && kill "${WEBSOCKIFY_PID}" 2>/dev/null
    [ -n "${X11VNC_PID}" ] && kill "${X11VNC_PID}" 2>/dev/null
    [ -n "${XVFB_PID}" ] && kill "${XVFB_PID}" 2>/dev/null
    wait 2>/dev/null
    log "已停止"
    exit 0
}
trap shutdown TERM INT

# ---------------------------------------------------------------- main
main() {
    mkdir -p "${LOG_DIR}" "${HOME}" "${GATEWAY_DIR}" "${APP_DIR}"

    seed_app
    start_xvfb

    # Tauri 的若干插件（快捷键/托盘）走 dbus，没有会话总线只会刷警告；
    # 起一条最省事，起不来也不影响主功能。
    if command -v dbus-launch >/dev/null 2>&1; then
        eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
    fi

    start_mxu

    if ! wait_web; then
        log "ERROR: MXU 的 Web 服务没有起来。可能原因："
        log "       1) 在 MXU 设置里关闭了「Web 服务器」或改了端口"
        log "       2) mxu 进程启动失败（见 ${LOG_DIR}/mxu.log）"
        log "       MAAYYS_VNC=1 可临时走 /vnc/ 桌面通道排查"
        exit 1
    fi

    start_vnc
    start_nginx

    # 后台把 adb 目标连上并保持。MXU 只列已连接设备，没有这一步界面永远空白。
    adb_keepalive &
    ADB_KEEPALIVE_PID=$!
    log "ADB 预连接已启动（目标：$(adb_targets | tr '\n' ' ')）"

    # 守护：mxu 挂了先重启，连续退出就交出容器
    local restarts=0 code
    while :; do
        wait "${MXU_PID}"
        code=$?
        [ "${SHUTTING_DOWN}" = "1" ] && break

        restarts=$((restarts + 1))
        if [ "${restarts}" -gt 3 ]; then
            log "ERROR: mxu 连续退出 ${restarts} 次（最后一次 code=${code}），容器退出"
            exit 1
        fi

        log "mxu 退出（code=${code}），第 ${restarts} 次重启"
        sleep 3
        start_mxu
        if wait_web; then
            # 端口可能变了，重新生成 nginx 配置并热加载
            start_nginx
        else
            log "WARN: 重启后 Web 服务仍未就绪"
        fi
    done
}

main "$@"
