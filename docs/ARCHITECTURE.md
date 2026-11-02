# 架构说明

## 1. Target 与依赖

```
PitHub (App)
 ├─ PitHubCore.framework          公共底层
 ├─ PitHubFilePit.framework       └─ PitHubCore
 ├─ PitHubPhotoNode.framework     └─ PitHubCore
 ├─ PitHubClipHub.framework       └─ PitHubCore
 └─ PitHubDashLink.framework      └─ PitHubCore
```

- App 负责创建 5 个插件实例，交给 `PitHubRuntime`；Runtime 负责服务生命周期、鉴权、路由、隧道、日志等。
- 插件之间不直接依赖，只依赖 `PitHubCore` 的协议与模型。
- 新增插件：新建 framework target → 实现 `PitHubPlugin` → 在 `AppServices` 中实例化 → 在网页/App 增加面板。默认启用状态由 `defaultEnabled` 与设置里的 `pluginEnabled` 决定。

`PitHubPlugin` 协议：

```swift
var id, displayName, summary, systemImage: String
var apiPrefix: String          // /api/file
var extraPrefixes: [String]    // ["/webdav", "/s"]
var defaultEnabled: Bool
func attach(host: PitHubPluginHost, dataDirectory: URL)
func handle(_ request: HTTPRequest, subPath: String,
            context: PitHubPluginRequestContext,
            respond: @escaping (HTTPResponse) -> Void)
```

## 2. 请求流水线

```
Browser / WebDAV / Relay
        │
        ▼
PitHubHTTPServer (NWListener)
        │  解析 HTTP/1.1、Body 落盘、Range
        ▼
PitHubHTTPConnection
        │  HTTPRequest
        ▼
PitHubRuntime.handle
        ├─ /api/health（公开）
        ├─ /s/<token>（公开、share token 限定）
        ├─ /api/dash/callback（公开、runId 限定）
        ├─ 鉴权：Cookie / Bearer / Basic → Role
        ├─ 内置 API（状态、设置、日志、二维码…）
        ├─ 插件匹配（最长前缀）→ Plugin.handle
        └─ 静态 www / SPA 回退
        │
        ▼
HTTPResponse → 连接层写响应（Range/流式/限速）→ 关闭连接
        │
        ├─ 访问日志
        ├─ 流量统计
        └─ 本地通知（由插件/运行时触发）
```

关键点：

- **一个入口**：所有角色校验、CORS、日志、流量统计都在 Runtime 完成；插件不会绕过。
- **流式**：请求体大于 1MB 直接写临时文件；响应文件按 256KB 读取发送；不在内存里拼大文件。
- **Range**：连接层统一处理，FilePit/分享/PhotoNode/WebDAV 都自动生效。
- **Per-connection queue**：每个 NWConnection 一个串行队列，下载不阻塞其他连接。
- **Connection: close**：每个连接处理一个请求，降低状态机复杂度，兼容常见 WebDAV 客户端。

## 3. 鉴权模型

```
Login(role, password) → Session(token, role, expiresAt)
Cookie: pithub_session=token
Authorization: Bearer token
Authorization: Basic base64(user:pass)
```

- 密码用「加盐 + 迭代 SHA-256」慢哈希保存；不存明文。
- 会话空闲超时可配置（默认 720 分钟），`remember` 会话落盘。
- WebDAV Basic：用户名 `admin` → 管理员；其他 → 普通用户。
- 未登录只能访问登录页、静态资源、`/api/health`、`/s/*`、`/api/dash/callback`。
- 临时分享与 DashLink 回调各自用不可猜测 token 限定能力范围，不共享全局会话。

## 4. 存储布局

```
Documents/PitHub/
  Shared/                 # /shared
  Uploads/                # /uploads
  www/                    # 可选：覆盖内嵌前端（调试用）

Library/Application Support/PitHub/
  config/settings.json    # 全部设置（不含明文密码）
  config/sessions.json    # remember 会话
  config/traffic.json     # 流量累计
  logs/access.jsonl       # 访问日志（JSONL）
  cache/
    shared/               # 统一 LRU 缓存（ZIP 等）
    thumbnails/           # 缩略图缓存
  shares/shares.json      # 临时分享
  Private/                # /private
  PluginData/<plugin-id>/ # 每个插件的独立数据目录
    file/upload-sessions/ # 分片上传临时目录
    clip/blobs/           # 剪贴图片/文件
    dash/buttons.json     # 按钮
    dash/runs.json        # 执行记录
  tmp/
    uploads/              # 请求体临时文件
    photo-exports/        # 相册导出临时文件
```

- 目录全部由 `PitHubPaths` 统一提供，插件不自行拼路径。
- 统一缓存目录与 `cacheLimitMB`，可一键清空。
- `Private` 不在 `Documents`，不会出现在「文件」App。

## 5. 线程模型

- `NWListener` 在独立队列；每个连接一个串行队列。
- `PitHubRuntime` 的 `@Published` 状态只在主线程更新（回调里 `DispatchQueue.main.async`）。
- 设置通过 `PitHubSettingsStore` 的锁 + 快照读取，HTTP 线程安全；写入落盘在 utility 队列。
- FilePit 的目录缓存、上传会话、分享都有各自的锁；PhotoKit 回调在系统队列，完成后回到调用方。
- 文件流、ZIP 组装、相册导出都在后台队列，避免卡主线程。

## 6. 插件路由隔离

- `PitHubPluginManager.match(path:)` 取最长前缀。
- 插件禁用时仍可匹配，但 Runtime 返回 404（“插件已禁用”），不会误落到其他插件。
- FilePit 额外挂载 `/webdav` 与 `/s`；`/s` 在鉴权前由 Runtime 特判为公开，但仍由 FilePit 校验 token/密码/到期时间。
- 每个插件的写操作都在自己的 store 内再次校验角色与路径，保证 WebDAV 与 API 权限一致。

## 7. 隧道

- `PitHubTunnelManager` 独立于插件。
- Cloudflare/frp：外部连接器 + 公网地址 + `/api/health` 检测 + 60s 心跳。
- Relay：App 主动 WebSocket 连出，服务端分配 `/t/<id>/`；请求以 JSON（base64 body）下发，响应原路返回；支持 Range 截取，超过 24MB 直接 413。
- WAN 流量通过请求标记（`CF-Connecting-IP`、`x-pithub-transport`）区分；直连隧道由 HTTP 连接层统计，Relay 由 Runtime 统计。

## 8. 安全边界

- 没有私有 API、没有越狱依赖、没有第三方服务器。
- 隧道只是转发；Relay 自建，建议 HTTPS + Token。
- 局域网默认 HTTP，明文；Public 暴露前必须改密码。
- WebDAV LOCK 是形式化令牌（家用场景不做并发互斥）；COPY 未实现。
- 详细限制见 [LIMITATIONS.md](LIMITATIONS.md)。
