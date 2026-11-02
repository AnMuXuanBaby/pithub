# iOS 限制与替代方案

PitHub 不尝试绕过沙盒，也不使用私有 API。下面列出硬限制、当前实现与替代方案。

## 1. 最低系统版本

- 需求写的是 iOS 17，但设备是 **iPhone 13 / iOS 16.0.2**。为了能安装，工程最低部署目标是 **iOS 16.0**。
- 代码只使用 iOS 16 可用 API，没有 iOS 17-only 调用。若以后要全量升级到 iOS 17，改 `project.yml` 的 `deploymentTarget` 与 `IPHONEOS_DEPLOYMENT_TARGET` 即可。
- 如果 CI 在更新的 Xcode 上以 iOS 17 SDK 构建，部署目标仍然保持 16.0，生成的 IPA 可装在 iOS 16.0.2 上（TrollStore 安装未签名 IPA 时尤其需要注意架构与最低版本）。

## 2. 后台与锁屏

- iOS 会在锁屏/切后台后挂起普通 App，`NWListener` 随之暂停。没有公开 API 可以让 HTTP 服务真正常驻。
- 当前实现：
  - 服务运行时可开启「屏幕常亮」（`UIApplication.isIdleTimerDisabled`），防止自动锁屏；
  - 可检测 `protectedDataDidBecomeUnavailable`（设备锁定）按策略停止/恢复；
  - 不启用静默音频保活（有 App Store 审核风险）。
- 替代方案：
  - 插电常驻，保持 App 前台/屏幕常亮；
  - 使用支持后台音频的 App 会违反“静默音频”规则，不建议；
  - 需要长时间无人值守时，把文件放在 Mac/NAS 上跑同等服务，或接受系统随时可能挂起。

## 3. 隧道

- **cloudflared / frpc 不能在 App 内运行**：iOS 沙盒禁止 `fork/exec`、禁止加载外部可执行文件；没有公开的 tunnel 客户端 API。
- 当前实现：
  1. Cloudflare：外部连接器（Mac/路由器/NAS）把公网请求转到 iPhone 的 HTTP 端口；App 内填写公网地址并检测。
  2. Relay：自建 Node 服务；App 主动 WebSocket 连出，真正“一键”。
  3. frp：外部 frpc。
- 因此“内置 Cloudflare Tunnel 客户端”在这里是**连接器封装 + 地址检测 + 状态/二维码**，而不是把 cloudflared 编译进 App。文档与设置里都明确标注。
- Relay 单次响应体上限 24MB；大文件依赖 Range/分片。Relay 限速建议在 Relay 服务器侧配置。

## 4. 相册

- PhotoKit 不暴露照片的真实文件 URL；原图/视频必须先通过 `PHAssetResourceManager` 导出到临时目录，再流式发送。
- iCloud 中的照片/视频需要先下载到本机，首次访问可能很慢，且失败时没有细粒度进度。
- 相册目录（`/photos`）在 WebDAV 里大小显示为 0；列出上限 5000 条/相册（防止一次性扫描过大）。
- 实况照片的原图与配对视频是两个资源，需要分别下载。
- 相册白名单同时作用于 PhotoNode 与 FilePit 的 `/photos`；设置为空表示全部。

## 5. HTTP 服务

- 自研 HTTP/1.1，不支持 HTTP/2、HTTP/3、WebSocket 服务端（Relay 是客户端 WebSocket）。
- 一个连接处理一个请求后关闭（`Connection: close`），没有 keep-alive 复用；大目录/小请求频繁时开销略高，但兼容性更好。
- 没有内置 TLS；局域网是明文 HTTP。外网 HTTPS 由 Cloudflare/Relay/反向代理提供。
- 不支持 multipart 表单上传；网页使用原始二进制/分片。第三方表单客户端请改用 WebDAV PUT。
- 请求头最大 64KB；单请求体默认受“上传上限”限制（可配置到 64GB，但受设备存储限制）。
- 服务器是单进程 App，性能受 iPhone 与系统调度影响；并发很高时不适合做公网热点。

## 6. WebDAV

- `LOCK/UNLOCK` 只返回形式化锁令牌，不做真正互斥（家用场景足够；多客户端同时写同一文件需自行避免）。
- `COPY` 未实现（501）。
- `PROPPATCH` 返回 207 但不真正保存自定义属性。
- Windows WebClient 默认限制 HTTP Basic 与大文件，需要改注册表（见 [WEBDAV.md](WEBDAV.md)）。
- 相册目录只读，且 `getcontentlength` 为 0。
- WebDAV 访客不可用（Basic 需要非空密码）；请用普通用户只读挂载。

## 7. ZIP

- 自研 STORE（无压缩）ZIP 写入器，不引入第三方库。
- 未实现 ZIP64：单文件/总大小需小于 4GB。
- 目录条目上限 20000；空目录不会写入包内。
- 不跟随符号链接。
- 打包在后台队列进行；非常大的目录会占用临时磁盘与时间。

## 8. 文件与预览

- 网页文本预览最多读取前 256KB（Range）；完整内容请下载。
- PDF 预览依赖浏览器/系统能力；部分 iOS 浏览器可能直接下载。
- 网页视频依赖 Range；Relay 模式下受 24MB 单次响应限制，但播放器通常按 Range 分片请求。
- App 内 QuickLook 无法预览相册挂载中的 PHAsset（没有本地文件 URL）；相册请在 PhotoNode 本机预览中查看。

## 9. Core ML / 其它

- Core ML 只预留了接口方向，当前没有模型推理功能；不引入第三方模型或云端推理。
- 没有实现真正的 Bonjour 浏览器 UI；Bonjour 只是服务广播，浏览器本身不会自动发现。可用专用 App 或 `dns-sd` 查看。
- 本地通知使用 `UNUserNotificationCenter`，不是远程推送；App 被系统杀死后不会收到通知。

## 10. TestFlight / App Store 注意事项

- 本工程没有使用私有 API；但“长期后台 HTTP 服务”本身与 App Store 的能耗/后台规则存在张力。上架前建议：
  - 不启用静默音频后台模式（当前默认关闭）；
  - 在 App 内清楚说明服务会随系统挂起；
  - 隐私清单 `PrivacyInfo.xcprivacy` 已声明 UserDefaults、文件时间戳、磁盘空间用途；
  - 相册、本地网络用途描述已写入 Info.plist；
  - 不上传用户数据到第三方。
- TestFlight 对“服务器类 App”可能人工审核；主要交付目标是自签/侧载 IPA。

## 11. 安全限制（有意为之）

- 局域网 HTTP 明文；Cookie 没有 `Secure`（否则局域网 HTTP 无法登录）。外网请务必 HTTPS。
- CORS 会反射请求 Origin 以支持独立前端；这降低了跨站限制，但服务本身是局域网私有的，且鉴权仍需要 Cookie/Bearer。不要把端口暴露给不可信网络。
- 分享链接与 DashLink 回调使用不可猜测 token；token 会出现在访问日志与浏览器历史中，注意不要公开日志。
- 密码哈希使用迭代 SHA-256（CryptoKit 没有直接 PBKDF2 封装），不是 Argon2；对家用强度足够，但不建议用于高风险公网服务。
