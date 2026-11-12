# AGENTS.md — 改这个仓库之前先读

给 AI / 自动化助手看的操作手册。人类读也有用，但第 3 节（铁律）和第 7 节（特别提醒）
是专门写给模型的：这个仓库出过的每一类事故，都能在第 3 节找到对应条目。

---

## 1. 这个仓库是什么

把 [MaaYYs](https://github.com/TanyaShue/MaaYYs) 打包成飞牛 fnOS 可安装的 `.fpk`。

本质是 **Docker 套壳**：

- 镜像里装 MaaYYs 的 Linux 全量包（MaaFramework + MXU + Go agent + 资源图）+ Xvfb + nginx
- MXU 是 Tauri 桌面程序，必须有 DISPLAY 才能启动 → 容器里跑 Xvfb
- MXU 同时内置了一个 axum Web 控制台（默认 `127.0.0.1:12701`），**用户看到的是这个网页，不是远程桌面**
- nginx 把该控制台暴露到宿主机 `12701`（直连模式），同时另监听 18000 仅供调试

仓库**不包含**：MaaYYs 二进制、Docker 镜像、`.fpk` 产物。它们都在构建时产生，已被 `.gitignore` 排除。

## 2. 目录与职责

| 路径 | 职责 | 改它的频率 |
|---|---|---|
| `deploy/build.sh` | 一条命令构建：下载上游包 → 建镜像 → 冒烟 → 导出 → 打 fpk | 低，但每次改都要跑一遍 |
| `deploy/Dockerfile` | 镜像定义。体积敏感，注释里写了每处瘦身的理由 | 低 |
| `deploy/entrypoint.sh` | 容器 1 号进程：铺程序文件 → Xvfb → mxu → 等 Web → nginx → adb 保活 → 守护 | 中，最容易踩坑的文件 |
| `deploy/nginx.conf.template` | envsubst 渲染的 nginx 配置，含 `sub_filter` 路径补丁 | 中，最需要小心 |
| `fnos-app/manifest` | fpk 元信息（INI 格式，空格对齐） | 每次发版都改 |
| `fnos-app/app/ui/config` | 桌面入口 JSON（图标、type、port、url） | 端口/入口变化时 |
| `fnos-app/cmd/main` | 应用生命周期：start/stop/status/image-ids。管 docker 容器 | 高 |
| `fnos-app/cmd/install_callback` | 安装/升级后导入离线镜像（按镜像 ID 判定，不看名字） | 中 |
| `fnos-app/cmd/uninstall_init` | 卸载前删容器 | 低 |
| `fnos-app/config/{privilege,resource}` | 运行身份 / 数据共享声明 | 低 |
| `tools/check-project.sh` | 打包前静态自检，几秒跑完，CI 第一步 | 改检查项时 |
| `tools/nas-auto-update.sh` | NAS 上的自动更新脚本（root + systemd timer） | 低 |
| `.github/workflows/build-fpk.yml` | 每日 03:00 跟随上游构建 + 发 Release | 低 |

## 3. 铁律

> 违反任意一条，症状通常**不是报错**，而是"看起来正常但行为错"。每条都附了自检方式。

1. **端口 12701 必须在三处一致。**
   `fnos-app/app/ui/config` 的 `port`、`fnos-app/cmd/main` 的 `HOST_PORT`、`fnos-app/manifest` 的 `service_port`。
   原因：MXU 前端把后端地址硬编码成 `hostname:webServerPort`，端口对不上就是红条「与后端连接断开」。
   自检：`bash tools/check-project.sh` 的 `[4]` 段。

2. **`\` 续行中间不许夹注释。**
   shell 到注释处就断了，后面的参数（包括镜像名）会变成一条新命令。1.0.6 就是这么挂的：`docker run` 从来没真正执行。
   自检：`check-project.sh` 的 `[1b]` 段。

3. **`set -o pipefail` 下不要用 `... | grep -q`。**
   `grep -q` 一命中就退出，写端收到 SIGPIPE 返回 141，整条管道被判失败。
   解法：先落盘再 grep（见 `build.sh` 第 129 行的 `LIST_FILE`），或改 `[ -z "$(...)" ]`。
   这条已经踩过两次，改动时别写回去。

4. **不要给脚本加 `set -e`。**
   `entrypoint.sh` 和 `cmd/main` 是刻意不用的：每个子进程的失败要有自己的处理，不能让某一步静默带走整个容器。

5. **改 `nginx` 的 `sub_filter` 段必须验证补丁还生效。**
   补丁靠字符串匹配 `if(xs>0){` / `if(Na&&Na>0){`，上游 MXU 改版后**会静默失效**（不报错，用户只看到红条）。
   自检：
   ```bash
   curl -s http://127.0.0.1:18000/assets/index-*.js | grep -c 'window.location.port===String'
   # 期望 2
   ```
   另外：`sub_filter` 只能改明文，所以转发时必须 `proxy_set_header Accept-Encoding ""`，
   少了这句上游一压缩就整段失效。

6. **WS 的 `Host` 必须带端口，`Origin` 必须与它同源。**
   MXU 的握手会校验（`is_same_origin_ws_request()`），nginx 的 `$host` 会丢端口，所以用
   `map $http_host $fwd_host`。改这段之后必须验一遍 WS 握手返回 101。

7. **版本号必须严格递增，`changelog` 必须同步。**
   fnOS 拒绝同版本覆盖安装。CI 每次发布把 patch +1，并在**发布成功后把 manifest 提交回 main**
   （提交信息带 `[skip ci]`；GITHUB_TOKEN 的 push 本身也不会触发新工作流），所以版本号是持久的。
   本地手改 manifest 时仍要自己升版本号，否则推上去会白装一次。
   `changelog` 是单行、按 `新版本号: 说明。 旧内容` 拼接；CI 只保留最近 3 条，与手写条目撞号时合并而非覆盖。

8. **判断"镜像要不要导入"只能比镜像 ID，不能看"同名镜像在不在"。**
   升级包里的镜像换了 ID、但 tag 还是 `maayys-fnos:local`，只看名字会跳过导入，装完跑的还是旧代码。
   推导逻辑在 `cmd/main image-ids` 与 `install_callback` 两处，**必须保持同一套**。

9. **`docker rmi -f` 在容器还在运行时是无效的**（只能摘 tag，镜像因被引用而删不掉，返回非 0）。
   所以"删除旧镜像"的动作只能放在容器重建之后，并且要先确认没有容器在引用。

10. **`seed_app` 用"文件在不在"（`[ -f .../mxu ]`）判断是否首次铺开，不要用 `-x`。**
    fnOS 的存储卷不兑现 `open(O_CREAT, mode)` 的模式位，`cp` 过来的文件可能没有 x 位；
    用 `-x` 判断会把"已铺开"误判成"首次安装"，把用户配置又盖一遍。

11. **写文件/复制/上传之后要显式 `chmod`。**
    同上，存储卷上新建的文件容易落成 `0000`。

12. **`manifest` 是 INI 不是 JSON**，且全文件用空格对齐（`version               = 1.0.8`）。
    改的时候保持对齐风格，不要重排、不要加引号。

13. **`app/ui/config` 的入口键名必须以 `appname` 为前缀**（`maayys-fnos.xxx`），
    且 `desktop_applaunchname` 指向的那个入口必须存在。

14. **`gunzip` 对"流完好、尾部多几个字节"的包返回 2，但产物可用。**
    所以解压判断要看产物（`tar -tf` 能不能读到 `manifest.json`），不要只看返回码。

15. **统计"出现次数"用 `grep -o ... | wc -l`，不要用 `grep -c`。**
    `grep -c` 数的是**行**：minified 的 JS 会把多处压在同一行，"两处补丁"会被数成 1。
    冒烟里断言 `sub_filter` 锚点就吃过这个亏（见 `deploy/build.sh` 的 `smoke_sub_filter`）。

## 4. 改代码的流程

```bash
bash tools/check-project.sh          # 1. 改之前先跑一遍，确认基线是绿的
# ... 改 ...
bash tools/check-project.sh          # 2. 改完再跑

bash deploy/build.sh --image-only    # 3. 只建镜像（不打包，几分钟）
docker compose -f deploy/docker-compose.yml up -d   # 需要 MAAYYS_BUILD_WORK 指向构建目录
```

手测清单（页面能打开 ≠ 好的）：

- `http://<host>:18000/` 首页 200 且**不是白屏**
- 页面顶部没有红条「与后端连接断开」（有红条 = WS 挂了）
- 调试面板不显示「MaaFramework 未初始化」
- 「设备」页能刷出 adb 设备
- 截图能刷新、日志能滚动

要发版时：改 `fnos-app/manifest` 的 `version` + `changelog`，再 `bash deploy/build.sh`。
CI 会在 push 后自动跑同一套（`check-project.sh` → build → 冒烟）。

## 5. 常用命令

```bash
# 容器日志（entrypoint 的决策都在这里）
docker logs --tail 60 maayys-fnos
# 容器内看 adb
sudo docker exec -it maayys-fnos adb devices -l
# MXU 自己的日志（在持久化卷里）
tail -f /vol{N}/@appdata/maayys-fnos/maayys-data/logs/mxu.log
# 宿主机侧的应用日志
tail -f /vol{N}/@appdata/maayys-fnos/info.log
# 申请临时进容器里看
sudo docker exec -it maayys-fnos bash
```

## 6. 已知未解问题（别以为是你改坏的）

- **程序文件存两份**：镜像里 `/opt/maayys-dist` 一份，`/data/app` 一份（`seed_app` 复制，各约 785MB）。
  想省这一份，得先确认 MXU 真正会写哪些目录（`--read-only` 跑一次看哪里报 EROFS），不要凭猜。
- **`adb connect` 没有超时**：目标不可达时单次可能挂十几秒，多目标会累积；保活循环是 45 秒一轮。
- **基础镜像没按 digest 固定、apt 也没 pin 版本**：上游一旦撤包，重跑构建可能拿到不同的层。
- **`DOCKER_BUILDKIT=1` 没有显式设置**：Dockerfile 用了 `RUN --mount=type=bind`，在关掉 BuildKit
  的机器上会直接失败（`the --mount option requires BuildKit`）。
- **`config/privilege` 把 `docker` 组给了应用用户**：等价于 root 权限面，只适合本机自用。
- **MXU 无登录验证**：直连模式下局域网内谁知道地址谁就能操作安卓端。
- **统一网关模式没有实现**（当前是直连 12701）；VNC 桌面入口也没做（讨论过，未落地）。
  相关约束见 `nginx.conf.template` 里 `gatewayPrefix` 与 `webServerPort` 的注释。

### 已修的（改代码时别再当成现状）

升级后回收旧镜像 / 安装时直载 gzip（省 1.3GB 临时解压）/ 容器内存上限与 256m shm /
卸载时清镜像 / `install_init` 预检 Docker 与空间 / restart 按"连续快速退出"计数 /
`changelog` 只保留最近 3 条 / 冒烟断言 `sub_filter` 锚点。

## 7. 给 AI 的特别提醒

- **最小 diff。**只改与任务相关的行。不要重排 `manifest` 的空格、不要统一引号、不要格式化 shell、
  不要把 `${VAR}` 改成 `"$VAR"`、不要"顺手"删注释。这个仓库的注释承载了约束，删掉比留着危险。
- **注释是规格。**写"为什么"而不是"做什么"，与现有风格一致（中文、解释踩过的坑）。新增的坑要写进注释。
- **不确定就问，不要编。**尤其是 MXU 的内部行为（它写入哪些目录、端口自增规则），
  代码里读不到就明说"未验证"，别假设。
- **一次只做一件事。**改动跨多个文件时，按"能独立验证"的最小单元拆开，每步都跑 `check-project.sh`。
- **不要碰 `/data`**（用户配置、截图、日志）。任何"清理"逻辑都必须有明确的时间/大小阈值。
- 提交信息用 Conventional Commits，中文描述，例如 `fix: 升级后回收旧镜像，避免悬挂镜像堆积`。
