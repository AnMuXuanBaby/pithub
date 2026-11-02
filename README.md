# PitHub

把一台插电常驻的 iPhone 变成家庭私有微型服务器：内置 HTTP / WebDAV / 鉴权 / 隧道 / 缓存 / 日志，插件式扩展。

> 目标设备：iPhone 13 / iOS 16.0.2  
> 需求书写的是 iOS 17，但为了让这台手机能实际安装，工程最低部署目标设为 **iOS 16.0**（见 `project.yml`）。代码只使用 iOS 16 可用 API；若以后全量升级到 iOS 17，改这一个配置即可。

---

## 1. 功能一览

| 模块 | 能力 |
| --- | --- |
| **PitHubCore** | NWListener 原生 HTTP/1.1、Range、流式收发、会话 Cookie + Bearer + Basic、插件管理、LRU 缓存、访问日志、流量统计、二维码、Bonjour、Cloudflare/frp 引导、Relay 隧道客户端 |
| **FilePit** | 公共/上传/私密/插件数据/相册挂载目录；新建、重命名、移动、删除、多选；分片上传与断点续传；WebDAV；图片/视频/PDF/文本预览；带时效与密码的分享；ZIP 打包；后缀黑名单与大小上限 |
| **PhotoNode** | 相册分组、时间线、缩略图、实况照片标记、视频、原图/视频下载、相册白名单 |
| **ClipHub** | 文本/图片/文件剪贴记录、标签、搜索、保留上限、HTTP API、网页面板 |
| **DashLink** | 自定义按钮、调用 `shortcuts://`、冷却、执行记录、结果回调接口 |
| **App 本机 UI** | 服务开关、内网/公网地址、二维码、插件开关与本机预览、设置、日志、权限引导 |
| **网页** | 登录、控制台、FilePit、PhotoNode、ClipHub、DashLink、设置、日志；深色磨砂玻璃、跟随系统明暗 |

所有数据保存在 iPhone 本机。隧道只转发流量，不存储内容。

---

## 2. 工程结构

```
PitHub/                     App target + SwiftUI 本机 UI + Info.plist + 资源
Modules/
  PitHubCore/               公共底层（HTTP、鉴权、隧道、缓存、日志、插件协议、PhotoKit）
  PitHubFilePit/            FilePit 插件（含 WebDAV）
  PitHubPhotoNode/          PhotoNode 插件
  PitHubClipHub/            ClipHub 插件
  PitHubDashLink/           DashLink 插件
www/                        内嵌到 App 的静态前端（HTML + Tailwind v3 产物 + Vanilla JS）
frontend-src/               Tailwind 源码与构建脚本（独立前端源码包）
relay/                      自建 Relay 隧道服务（Node.js）
docs/                       打包、签名、侧载、使用、WebDAV、隧道、测试、限制、API
.github/workflows/          GitHub Actions：构建未签名 IPA 并发布 Release
project.yml                 XcodeGen 工程定义（5 个 target）
```

插件是独立 framework target，主程序只是骨架。启用插件后会自动挂载：

- `/api/file`、`/webdav`、`/s/<token>` → FilePit
- `/api/photo` → PhotoNode
- `/api/clip` → ClipHub
- `/api/dash` → DashLink

---

## 3. 快速开始

### 3.1 用 GitHub Actions 拿到 IPA

1. 把本仓库推到 GitHub（`main` 分支）。
2. Actions 会自动运行 `.github/workflows/build-ipa.yml`。
3. 在 Actions → Build IPA → Artifacts 下载 `PitHub-unsigned-ipa`；同时 Release `PitHub-Latest` 里会有 `PitHub.ipa` 与 `PitHub-frontend.zip`。

如果本地没有安装 Git，也可以用仓库里的 `scripts/upload-github.mjs` 通过 GitHub REST API 上传（需要 `GITHUB_TOKEN` 与 `GITHUB_REPO`，Token 需 Contents + Workflows 写权限）。

未签名 IPA 可直接用 TrollStore 安装（iOS 16.0.2 在兼容范围内，以 TrollStore 官方列表为准）；也可以自行重签名后侧载。详见 [打包 IPA](docs/BUILD_IPA.md) 与 [侧载](docs/SIDELOAD.md)。

### 3.2 本地用 Xcode 构建

```bash
brew install xcodegen
xcodegen generate
open PitHub.xcodeproj
```

在 Xcode 的 Signing & Capabilities 里选择自己的 Team，把 Bundle Identifier 改成自己的（例如 `com.yourname.pithub`），然后 Run / Archive。详见 [打包 IPA](docs/BUILD_IPA.md)。

### 3.3 首次使用

1. 打开 PitHub，允许「本地网络」与「相册」权限。
2. 服务默认自动启动，端口 `8080`。
3. 手机或电脑浏览器打开 `http://<iPhone 局域网 IP>:8080`。
4. 默认密码：`pithub`（管理员/用户通用；首次登录后请立刻在「设置」里修改）。
5. 访客角色只读，无需密码（可在设置里关闭访客登录）。

后台限制、锁屏策略、保活建议见 [使用文档](docs/USAGE.md#后台与锁屏) 与 [限制清单](docs/LIMITATIONS.md)。

---

## 4. 关键设计

### 4.1 原生 HTTP

- `Network.NWListener` + 自研 HTTP/1.1 解析，不引入第三方 Web 服务器或 WebDAV 库。
- 请求头/体分流：小请求进内存，大请求直接落盘；上传/下载都按 256KB～1MB 分块，避免整文件进内存。
- Range 在连接层统一处理（206 / 416），FilePit、PhotoNode、分享、WebDAV 都自动支持。
- 每个连接独立串行队列；一个视频下载不会阻塞其他请求。
- 一个连接处理一个请求后 `Connection: close`，兼容 Finder、Windows、Android 文件管理器。

### 4.2 统一鉴权

- 会话 Cookie `pithub_session`，也支持 `Authorization: Bearer <token>` 与 WebDAV 的 HTTP Basic。
- 角色：`guest`（只读）、`user`（读写）、`admin`（含私密目录、设置、插件开关、日志导出）。
- 网页、`/api/*`、`/webdav` 全部经过同一个 `PitHubRuntime.handle`，没有权限旁路。
- 例外：`/s/<token>` 临时分享与 `/api/dash/callback?runId=`，它们各自凭不可猜测的 token 限定到单个文件/单次执行。

### 4.3 隧道

iOS 沙盒不允许 App `fork/exec` 外部二进制，因此 **不能在 App 内直接运行 cloudflared / frpc**。提供三条路径：

1. **Cloudflare Tunnel（外部连接器）**：在 Mac/路由器/NAS 上运行 `cloudflared tunnel --url http://<iPhone-IP>:8080`，把得到的公网地址填进设置；App 负责状态检测、二维码、外网流量统计。
2. **PitHub Relay（App 内一键）**：部署 `relay/server.mjs` 后，iPhone 主动用 WebSocket 连出去，App 自动拿到 `https://relay/t/<id>/` 公网地址，无需公网 IP。
3. **frp**：外部运行 frpc，App 生成配置模板并填写公网地址。

详见 [隧道配置](docs/TUNNEL.md)。

### 4.4 文件与相册

- `Documents/PitHub/Shared`、`Documents/PitHub/Uploads` 可在系统「文件」App 中看到（`UIFileSharingEnabled`）。
- `Application Support/PitHub/Private` 仅管理员可访问，不出现在「文件」App。
- PhotoKit 没有公开的相片文件 URL，原图下载会先由 `PHAssetResourceManager` 导出到临时目录，再流式下发；首次访问 iCloud 照片可能较慢。
- 相册白名单同时作用于 PhotoNode 与 FilePit 的 `/photos`。

---

## 5. 安全与隐私

- 所有文件、照片、剪贴内容只在本机；没有第三方统计/SDK。
- 隧道只转发请求，不保存内容；Relay 是你可以自己掌控的服务器。
- 局域网默认 HTTP，明文传输；不要把端口直接映射到公网后长期暴露。外网请使用 HTTPS 隧道（Cloudflare 或 Relay 的 TLS/反代）。
- 默认密码 `pithub` 只用于首次进入；上线前必须修改访问密码与管理员密码。
- 日志会记录来源 IP、路径、操作、状态码与流量大小；日志可在网页导出/清空。
- 分享链接到期自动失效，可加密码；密码只以加盐慢哈希保存。
- 详细威胁模型与限制见 [限制清单](docs/LIMITATIONS.md)。

---

## 6. 文档

- [架构说明](docs/ARCHITECTURE.md)
- [打包 IPA（Developer / Ad Hoc / 未签名）](docs/BUILD_IPA.md)
- [重签名与侧载](docs/SIDELOAD.md)
- [使用文档（局域网、角色、各插件、通知、排障）](docs/USAGE.md)
- [WebDAV 挂载（Mac / Windows / Android / iOS）](docs/WEBDAV.md)
- [外网隧道（Cloudflare / Relay / frp）](docs/TUNNEL.md)
- [HTTP API 参考](docs/API.md)
- [前端与独立部署](docs/FRONTEND.md)
- [测试用例](docs/TEST_CASES.md)
- [iOS 限制与替代方案](docs/LIMITATIONS.md)
- [Relay 服务](relay/README.md)

---

## 7. 构建状态

本项目按 XcodeGen + GitHub Actions 构建。CI 产物是**未签名** IPA；签名 IPA 需要你自己的 Apple Developer 证书与描述文件，步骤见文档。

> Windows 开发环境无法运行 Xcode，本仓库的所有构建验证依赖 macOS 上的 Xcode / GitHub Actions。若第一次构建出现编译错误，请提交 Actions 日志。

---

## 8. 许可

仅用于个人家庭场景。使用第三方服务（Cloudflare、你自己的 VPS、Apple 签名服务）时请遵守对应条款。不要在未经授权的情况下把他人照片/文件暴露到公网。
