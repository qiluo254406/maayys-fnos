# MaaYYs on 飞牛 fnOS
#
# 组成：MaaYYs 官方 Linux 全量包（MaaFramework + MXU + Go agent + 资源）
#       + Xvfb（MXU 是 Tauri 桌面程序，没有显示就起不来）
#       + nginx（把 MXU 自带的 Web 控制台挂到飞牛网关的 unix socket 上）
#
# 为什么不需要 noVNC：MXU 内置了一个 axum Web 服务器，把前端产物 rust_embed 进
# 二进制，并提供完整 HTTP API + WebSocket（默认 127.0.0.1:12701）。浏览器拿到的
# 就是 MXU 原生网页界面，不是远程桌面。Xvfb 只是为了满足 Tauri 起窗口的需要。
#
# 基础镜像 ubuntu:24.04：MaaFramework 与 WebKitGTK 都要求较新的 glibc。

FROM ubuntu:24.04

# 构建期要装 200+ 个包，走官方 archive 在国内非常慢。
# 传空字符串（--build-arg APT_MIRROR=）则保持官方源。
ARG APT_MIRROR=http://mirrors.aliyun.com/ubuntu
RUN if [ -n "${APT_MIRROR}" ]; then \
        for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do \
            [ -f "$f" ] && sed -i \
                "s|http://archive.ubuntu.com/ubuntu|${APT_MIRROR}|g; \
                 s|http://security.ubuntu.com/ubuntu|${APT_MIRROR}|g; \
                 s|http://ports.ubuntu.com/ubuntu-ports|${APT_MIRROR}|g" "$f"; \
        done; \
    fi

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Asia/Shanghai \
    DISPLAY=:99 \
    GDK_BACKEND=x11 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    WEBKIT_DISABLE_COMPOSITING_MODE=1 \
    WEBKIT_DISABLE_DMABUF_RENDERER=1 \
    WEBKIT_FORCE_SANDBOX=0 \
    HOME=/data/home \
    XDG_CONFIG_HOME=/data/home/.config \
    XDG_DATA_HOME=/data/home/.local/share \
    XDG_CACHE_HOME=/data/home/.cache \
    PRISTINE_DIR=/opt/maayys-dist \
    APP_DIR=/data/app \
    GATEWAY_DIR=/gw

# 中文界面必须有 CJK 字体，否则 MXU 里全是方块。
# GTK3 / ALSA 在 24.04 走了 t64 改名，这里新名优先、旧名兜底，避免换个基础镜像就构建失败。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        xvfb x11vnc novnc websockify \
        nginx-light curl ca-certificates tzdata gettext-base procps \
        fonts-noto-cjk fontconfig dbus-x11 \
        libwebkit2gtk-4.1-0 libjavascriptcoregtk-4.1-0 \
        libayatana-appindicator3-1 libnss3 libsoup-3.0-0 \
        libgomp1 libgl1 libglib2.0-0 adb \
    && (apt-get install -y --no-install-recommends libgtk-3-0t64 \
        || apt-get install -y --no-install-recommends libgtk-3-0) \
    && (apt-get install -y --no-install-recommends libasound2t64 \
        || apt-get install -y --no-install-recommends libasound2) \
    # 必须和 install 在同一个 RUN 里收尾：Docker 的层是叠加的，
    # 这里清掉的空间才真正不进镜像。漏了 apt-get clean 会白占 343MB（实测）。
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
              /usr/share/doc /usr/share/man /usr/share/locale/*/LC_MESSAGES

# ---------- MaaYYs 全量包 ----------
# 由 build.sh 把 Release 里的 MaaYYs-linux-x86_64-*-MXU.tar.gz 放进构建上下文。
ARG MAAYYS_TARBALL=maayys-linux.tar.gz
# 上游版本号，仅用于「镜像升级后刷新程序文件」的判断
ARG MAAYYS_VERSION=unknown

WORKDIR /opt
# 用 BuildKit 的 bind mount 把上游包喂给 tar，而不是先 COPY 再解压。
#
# 为什么：COPY 进来的那份 tar.gz 会**永久留在那一层里**，后面 rm 只影响新层，
# 旧层的 254MB 照样进镜像和 fpk（gzip 压不动，等于白带一份）。bind mount 不落层。
#
# 解包与校验写在一起但没有 `|| true`：任何一步失败都要当场炸掉构建，
# 不能建出一个"能跑但里面没程序"的镜像。
RUN --mount=type=bind,source=${MAAYYS_TARBALL},target=/tmp/maayys.tar.gz \
    mkdir -p "${PRISTINE_DIR}" \
    && tar -xzf /tmp/maayys.tar.gz -C "${PRISTINE_DIR}" \
    && test -f "${PRISTINE_DIR}/mxu" \
    && test -f "${PRISTINE_DIR}/interface.json" \
    && chmod +x "${PRISTINE_DIR}/mxu" \
    && (chmod +x "${PRISTINE_DIR}/agent/agent" 2>/dev/null || true) \
    && printf '%s\n' "${MAAYYS_VERSION}" > "${PRISTINE_DIR}/.dist-version"

# ---------- 运行期外壳 ----------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY nginx.conf.template /etc/nginx/nginx.conf.template
RUN chmod +x /usr/local/bin/entrypoint.sh

# 运行期数据（配置、日志、截图）与网关 socket 目录都在挂载点上
VOLUME ["/data"]

# 刻意不 EXPOSE：正式部署走飞牛网关的 unix socket。
# 单机调试时用 docker-compose.yml 里的 18000 -> 18000 映射（nginx 会额外监听它）。

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
