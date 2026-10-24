# MaaYYs on 飞牛 fnOS

把 [MaaYYs](https://github.com/TanyaShue/MaaYYs)（阴阳师自动化，MaaFramework + MXU）搬进飞牛 NAS，
做成可以直接在应用中心安装的 fpk。装完桌面多一个 **MaaYYs** 图标，点开就是完整控制台：
配任务、看实时日志、看截图，手机浏览器也能用。

## 为什么不是照抄 MAA-FnOS 的构建指南

那份指南的骨架很好用（本项目的 `fnos-app/` 就是照它的约定写的），但**应用层不能套**，两者的形态根本不同：

| | MAA-FnOS | MaaYYs（本项目） |
|---|---|---|
| 引擎 | MAA 官方 Linux 包 + Python 绑定 | MaaFramework Linux 包 + Go agent |
| 界面 | MAA-WEB-CONTROL，独立 Web 项目 | **MXU 自带 axum Web 服务器**，前端 `rust_embed` 进二进制 |
| 指南 1.2 步「换 Web 前端源码」 | 必须，要自建 `serve_socket.py` | **不需要**，MXU 自己会 serve |
| 指南 2 步「镜像里 listen socket」 | uvicorn 接网关 | nginx 只用于判活；业务走直连端口 |
| 入口方式 | 飞牛网关 `/app/maa-fnos/`（iframe） | **直连 `http://<NAS>:12701/`**，见下 |
| 进程形态 | 纯服务端，无 GUI | Tauri 桌面程序，**必须有一块显示** |

三个关键结论：

1. **MXU 自带 Web 控制台**。内置 axum 服务器（`127.0.0.1:12701`）提供完整 HTTP API + WebSocket，
   浏览器里看到的是 MXU 原生网页界面，不是远程桌面。
2. **MXU 是 Tauri 桌面程序，没有 DISPLAY 起不来**。容器里跑 Xvfb 喂它虚拟显示，
   界面本身不经过 Xvfb —— 那是给二进制"能启动"用的，不是给人看的。
3. **它进不了网关前缀**（1.0.3 的结论）。前端把 API/WS 地址硬编码成
   `hostname:webServerPort`（默认 12701），页面自己不知道"我是被哪个端口访问的"。
   挂在 `/app/maayys-fnos/` 下时，页面会去 `host:12701` 找后端 → 同源失败 → WS 连不上。
   所以只能让**页面端口 = 前端以为的端口**：宿主机用 12701。

```
浏览器 ──HTTP──> <NAS>:12701 ──docker publish──> 容器 18000 (nginx) ──> 127.0.0.1:12701 (MXU Web)
                        同源，前端自己拼的 hostname:12701 正好命中         ▲
                                                                      mxu（跑在 Xvfb :99 上）
                                                                           │ adb 5555
                                                                           ▼
                                                                     redroid / 模拟器
```

## 安装

1. 在**有 Docker 的 Linux 机器**上构建（见 [`docs/构建指南.md`](docs/构建指南.md)）：
   ```bash
   git clone <this-repo> && cd maayys-fnos
   bash deploy/build.sh
   ```
   产物在 `dist/maayys-fnos_1.0.3_v3.17.11.fpk`（**1.3GB**，内置离线镜像，安装时不用联网）。
2. 飞牛 **应用中心 → 左下角手动安装 → 从电脑上传**，选这个 fpk。
3. 装完在应用中心启动，点桌面 **MAAYYs** 图标 —— 会在浏览器里打开 `http://<NAS>:12701/`。

> **端口 12701 是固定的，不能改**。前端把后端地址硬编码成 `hostname:webServerPort`，
> 换了端口页面就找不到后端。真被占用时应用中心会直接报"端口已占用"，不会静默失败。

数据都在 `/volN/@appdata/maayys-fnos/maayys-data`（N 是你安装时选的存储空间，实测常见 `/vol2`），
重装不动它；想清空就删这个目录。

> **安全提示**：直连模式不走飞牛网关鉴权，局域网内知道地址的人都能打开这个控制台
> （能操作你的安卓端）。如果你在意，就把 NAS 的 12701 端口限制在内网，别做端口转发。

### 装之前要有什么

- 飞牛 fnOS 1.1.3100 以上，Docker 已装好
- **x86_64** 机器（MXU 只出 linux-x86_64 包）
- 一个能被 `adb connect` 连上的安卓环境：redroid 容器，或局域网里的模拟器/真机
- 约 5GB 硬盘（**安装包 1.3GB + 镜像约 2.8GB** + 运行数据）。
  大头是 MaaYYs 自己：全量包解压后约 1.5GB（资源图多），再叠加 WebKitGTK / CJK 字体 / LLVM

### 体积是怎么构成的（想再瘦看这里）

镜像 3.0GB / 安装包 1.3GB。1.0.3 之后做过一轮清理，去掉了两块纯浪费：

| 项 | 之前 | 处理 |
|---|---|---|
| `apt` 的 .deb 缓存 | **343MB** | `apt-get clean` 与 install 写在同一个 `RUN` 里（分层机制决定：跨层删等于没删） |
| 上游 tar.gz 被 COPY 进层 | **265MB** | 改用 `RUN --mount=type=bind`，包只喂给 `tar`，不落层 |

剩下的大头是 `/opt/maayys-dist` 约 785MB —— **MaaYYs 自己的资源图**，PNG 已经压过，
再压就是有损的（会掉模板匹配准确率，不建议）。所以这块基本是地板。

还想更小有两个可选项，各有代价：

- 换掉 `fonts-noto-cjk`（约 93MB）用更小的中文字体，能省 ~70MB，但生僻字/多语言覆盖会变差
- 去掉 noVNC / x11vnc / websockify（逃生通道，约 30MB），省不了多少还少了条后路

## 用起来

1. **连安卓端**：进 MXU 界面 → 设备 → 手动填 ADB 地址，例如 `<NAS_IP>:5555`（redroid 要把 5555 映射到宿主）。
   容器里的 adb 能连局域网，不需要 USB 透传。
2. **选区服**：脚本右上角按自己区服改（官服 / B 站服 / 各渠道服）。分辨率 16:9、建议 1280×720，模拟器常态横屏。
3. **配任务**：日常奖励、御魂、结界突破、寮三十……按需勾。
4. **点运行**，回浏览器主页看日志和截图。

> 停用应用时容器会收到 SIGTERM 并转给 mxu，留 10 秒存配置。**正在跑的任务链会被中断** ——
> MaaFramework 没有「暂停到安全点」的接口，这是 MXU 的限制，不是这里偷懒。

## 更新

分两种情况，别混：

### 上游 MaaYYs 出了新版

```bash
# 1. 先看有没有新版（国内要带代理查 GitHub）
https_proxy=http://127.0.0.1:7890 bash tools/check-update.sh

# 2. 直接按最新版重打
bash deploy/build.sh --version latest
```

产物落在 `dist/`，文件名自带版本（`maayys-fnos_1.0.4_v3.18.0.fpk`），不会覆盖旧的。

装到 NAS：应用中心 → 手动安装 → 选新 fpk，**覆盖安装**即可。容器首次启动时
`seed_app()` 会比对 `/opt/maayys-dist/.dist-version`：变了就刷新程序文件
（`mxu` / `agent` / `maafw` / `resource_pack` / `tasks` / `interface.json`），
而 `config/`（你的任务配置）、`debug/`（截图）、`cache/` 一律不动。

### 改了本项目自己的东西

比如改了 nginx 配置、cmd/main、端口号：

1. **必须**升 `fnos-app/manifest` 里的 `version`（例如 1.0.4），并在 `changelog` 加一句。
   否则 fnOS 认为版本没变，不给覆盖安装。
2. 重打：`bash deploy/build.sh --version v3.17.11`（复用已下好的上游包）。

> 一个坑记在这：如果本次只改了**运行参数**（端口映射、挂载、env）而镜像内容没变，
> 镜像 ID 会和上一版一模一样。`cmd/main` 现在除了比对镜像 ID，还会比对端口映射
> （`container_port_matches`），对不上就重建容器 —— 否则会出现"装完了但没生效"。

## 不想在本地构建？（云端构建 + 自动更新）

按"要多自动"分三层，建议先只用 A。

### A. 云端构建，本机不用装 Docker

把本仓库推到 GitHub，`.github/workflows/build-fpk.yml` 会：

- **每天 03:00** 查一次上游 MaaYYs 有没有新 release，有就构建
- 也能手动触发：Actions → build-fpk → Run workflow（可指定上游版本）
- 构建完发到 **Release**（tag = 上游版本），带三个文件：
  `maayys-fnos_<应用版本>_<上游版本>.fpk`、固定名 `maayys-fnos.fpk`、`latest.json`
- 同一上游版本不会重复构建（Release 已存在就直接跳过，日常跑一次只要几十秒）

之后你只需要在应用中心上传新 fpk。**仓库必须是 public** —— 私有仓库的 Release 资源下载要鉴权，
下面 B 的自动更新会失败。

> CI 里有个坑我提前处理了：fnOS 不接受同版本号覆盖安装，所以工作流会在每次发布前
> **自动把 patch 位 +1**（人力只维护 major.minor）。

### B. 连安装也自动（NAS 上的 systemd timer）

一次性配置，SSH 到 NAS 用 root：

```bash
# 1. 脚本与 unit 就位
mkdir -p /vol2/@appdata/maayys-fnos
cp tools/nas-auto-update.sh /vol2/@appdata/maayys-fnos/
chmod +x /vol2/@appdata/maayys-fnos/nas-auto-update.sh
cp tools/maayys-auto-update.{service,timer} /etc/systemd/system/

# 2. 改三处：仓库名、卷号、代理（你这台 NAS 自己有 Clash，代理写 http://127.0.0.1:7890）
vi /etc/systemd/system/maayys-auto-update.service

# 3. 启用
systemctl daemon-reload && systemctl enable --now maayys-auto-update.timer

# 4. 立刻试跑一次，看日志
systemctl start maayys-auto-update.service
tail -20 /vol2/@appdata/maayys-fnos/auto-update.log
```

脚本流程：读 `latest.json` → 比版本（**只升不降**）→ 下载 → **校验 sha256** → `appcenter-cli install-fpk`
→ `start`。校验不过或安装失败就保持旧版本不动，日志在 `/vol2/@appdata/maayys-fnos/auto-update.log`。

> ⚠️ 这是 root 权限、自动安装从网上下载的包。虽然做了 sha256 校验（防传输损坏），
> 但**信任根是那个 GitHub 仓库** —— 仓库被改就等于把机器交出去。
> 所以别把仓库写权限给不信任的人；介意的话就只用 A，手动点安装。

### C. 只更新 MaaYYs 本体、不换 fpk（没做，也不建议）

理论上可以让容器自己去拉新的 MaaYYs 全量包、替换 `/data/app` 里的程序文件
（`seed_app()` 已经是这个思路）。没做的原因：

- 容器内要能直达 GitHub（你这台 NAS 有代理，技术上可行）
- 需要额外的原子切换与失败回滚，否则一次下载中断就把程序文件搞坏
- 会和 `seed_app()` 的版本标记互相覆盖，得先重构

收益只是"省掉发新 fpk"，风险比 A+B 都高，所以留作以后可选项。

## 出问题了

| 现象 | 去哪看 |
|---|---|
| 应用中心显示"异常" | `/vol{N}/@appdata/maayys-fnos/info.log`（容器启停）、`maayys-data/logs/mxu.log`（程序自己） |
| 打开图标是空白页 | 先看 `maayys-data/logs/nginx-error.log`，再看 mxu.log |
| 页面能开但提示"与后端连接断开" | 页面端口和前端认知的 `webServerPort` 不一致。别加反代、别改端口，必须用 `:12701` |
| 应用中心报"端口已被占用" | 宿主机 12701 被占了。前端硬编码这个端口，只能腾出来，不能换 |
| 连不上安卓 | `sudo docker exec -it maayys-fnos adb connect <IP>:5555`，看容器内网络是否通 |

**逃生通道**：如果 MXU 的 Web 界面彻底打不开（比如你把它关掉了），可以开一个 noVNC 桌面进去救：

```bash
# 编辑 /vol{N}/@appcenter/maayys-fnos/cmd/main，把 MAAYYS_VNC 默认值改成 1，然后重启应用
# 浏览器访问 http://<NAS>:12701/vnc/vnc.html?autoconnect=1
```

## 路径对照（排查时用）

| 路径 | 内容 |
|---|---|
| `/var/apps/maayys-fnos/` | `manifest`、`cmd/`、`config/`、`ICON*.PNG` |
| `/var/apps/maayys-fnos/target` | 软链 → `/vol{N}/@appcenter/maayys-fnos`（`app/` 的内容） |
| `/vol{N}/@appdata/maayys-fnos/` | 运行期：`info.log`、`gateway/app.sock`（仅供判活）、`maayys-data/` |
| `…/maayys-data/app/` | MXU 程序 + `config/`（任务配置）+ `debug/`（日志截图） |
| `…/maayys-data/logs/` | 容器内各服务的日志（xvfb / mxu / nginx） |

> `{N}` 是安装时选的存储空间序号，实测是 `2`（即 `/vol2`）。

MXU 在 Linux 上是便携式布局，配置写在可执行文件同目录。所以 `app/` 整个放在数据卷里，
镜像升级时只刷新程序文件，`config/` `debug/` `cache/` 一律保留。

## 免责声明

自动化工具可能违反游戏用户协议，风险自负。本项目只是打包脚本，不含游戏内容，
不用于代练或账号交易。MaaYYs、MaaFramework、MXU 各自遵循其原始许可证；本仓库的自制部分同样以其作者意愿为准。
