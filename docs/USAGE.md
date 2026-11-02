# 使用文档

## 1. 首次启动

1. 安装并打开 PitHub（安装方式见 [侧载](SIDELOAD.md)）。
2. 系统会依次弹出：
   - **本地网络**：必须允许，否则局域网内的设备找不到服务。
   - **照片**：PhotoNode 与 `/photos` 需要；拒绝后可在系统设置里重新开启。
   - **通知**：上传完成、隧道断开时提醒；可选。
3. 服务默认自动启动，端口 `8080`。控制台会显示当前局域网 IP 与二维码。
4. 浏览器打开 `http://<iPhone IP>:8080`。
5. 默认密码 `pithub`。进入「设置 → 访问密码」修改普通用户密码与管理员密码，修改后重新登录。

> 建议：插电、保持 App 在前台或屏幕常亮。iOS 会挂起后台 App，服务会随之中断。这不是 PitHub 的 bug，也无法用公开 API 绕过。

---

## 2. 角色与权限

| 角色 | 登录方式 | 权限 |
| --- | --- | --- |
| 访客 guest | 无密码（可在设置关闭） | 只读：浏览、下载、PhotoNode、查看日志？否（日志需 user） |
| 用户 user | 访问密码 | 读写文件、上传、分享、ClipHub 写入、DashLink 调用、查看日志 |
| 管理员 admin | 管理员密码（默认同访问密码） | 以上全部 + `Private`/`Data` 目录、设置、插件开关、日志导出/清空、缓存清空 |

WebDAV 使用 HTTP Basic：

- 用户名 `admin` + 管理员密码 → 管理员
- 其他用户名 + 访问密码 → 普通用户
- 访客无法通过 WebDAV Basic 登录（Basic 需要非空密码）；如需只读挂载，请创建一个普通用户并只读使用。

---

## 3. 局域网访问与 Bonjour

- 内网地址：`http://<iPhone 局域网 IP>:<端口>`（默认 8080）。
- QR 码：控制台「扫码访问」选择局域网/公网，直接扫码。
- Bonjour：服务启动后通过 `NWListener.service` 广播 `_pithub._tcp`，服务名默认 `PitHub`（可在设置改）。
  - Mac：使用「发现」类 App / `dns-sd -B _pithub._tcp` 可以看到。
  - iOS/第三方工具：支持 Bonjour 浏览器的 App 可以解析到 IP 与端口。
  - 浏览器本身不会自动发现 Bonjour，首次仍需输入一次 IP；扫二维码更快。
- 如果你改了端口，Bonjour 会自动广播新端口。

---

## 4. App 本机界面

- **控制台**：服务开关、内网/公网地址、二维码、连接数、流量、隧道状态、权限引导、后台说明。
- **插件**：每个插件的开关与本机预览。
  - FilePit：本机目录浏览 + QuickLook 预览。
  - PhotoNode：相册分组 + 缩略图网格 + 大图。
  - ClipHub：新增文本、复制、删除。
  - DashLink：按钮列表、运行、执行记录。
- **日志**：本机查看访问记录，可导出。
- **设置**：与网页设置同一份数据；端口、密码、隧道、后台、插件参数、缓存。

关闭 App 或系统挂起后，网页/WebDAV 会断开。重新打开 App 会自动恢复服务。

---

## 5. 网页控制台

浏览器访问首页 → 登录 → 控制台：

- 全局状态：在线指示灯、内网地址、公网地址、二维码、连接数、流量。
- 插件卡片：开关（管理员）、状态、打开入口。
- 快速入口：设置、日志。
- 主题：右上角切换「跟随系统 / 深色 / 浅色」，记录在浏览器 localStorage。

页面对手机与电脑都做了适配；手机端使用顶部菜单 + 底部导航。

---

## 6. FilePit

### 6.1 目录

| 虚拟路径 | 实际位置 | 权限 |
| --- | --- | --- |
| `/shared` | `Documents/PitHub/Shared` | user 读写，guest 只读 |
| `/uploads` | `Documents/PitHub/Uploads` | user 读写，guest 只读 |
| `/private` | `Application Support/PitHub/Private` | admin 读写 |
| `/data` | `Application Support/PitHub/PluginData/FilePit` | admin 读写 |
| `/photos` | 系统相册（只读） | 所有已登录角色，遵守相册白名单 |

`Documents/PitHub` 在「文件」App 中可见（`UIFileSharingEnabled`），可以直接用数据线/AirDrop 拷文件进去。`/private` 不出现在「文件」App。

### 6.2 上传

- 网页：点击「上传」或多选文件；也可以把文件拖到文件区域。
- 小文件直接 `POST`；大于 4MB 自动走分片（默认 8MB/片）。
- 分片失败/断网后重新上传，会先查服务端已收到哪些分片，只补缺失部分（断点续传）。
- 上限、分片大小、禁止后缀在设置里修改。默认禁止 `exe/bat/cmd/msi/sh/js/jar/...`。

### 6.3 操作

- 新建文件夹、重命名、移动、删除（支持多选）。
- 单击文件直接预览图片/视频/PDF/文本/音频；其他类型下载。
- 右键（桌面）或「…」菜单：下载、分享、移动、重命名、删除、ZIP。
- 文件夹操作栏「ZIP」把当前目录打包下载（STORE 无压缩，4GB 限制）。

### 6.4 临时分享

- 文件菜单 →「生成临时分享」。
- 设置有效期（默认 60 分钟，可改）与可选密码。
- 得到的链接形如 `http://<地址>/s/<token>`；密码页面只针对该文件，不会暴露其他目录。
- 分享可随时在网页/接口删除；到期自动失效。
- 注意：分享链接使用的是**生成时**的基地址（隧道优先，其次局域网）。如果之后隧道地址变化，请重新生成。

### 6.5 预览

- 网页内置：图片、视频（Range）、PDF（浏览器/系统能力）、纯文本（截取前 256KB）。
- App 本机：QuickLook 直接预览本地文件。

---

## 7. PhotoNode

- 左侧相册（系统用户相册 + 常用智能相册），中间网格；顶部按年份/月筛选。
- 实况照片有 `LIVE` 标记；视频显示时长，点开直接播放。
- 缩略图由系统 `PHImageManager` 生成并缓存在统一 LRU 缓存。
- 原图/视频下载：`/api/photo/original?id=...`，实况配对视频加 `?live=video`。
- 相册白名单：设置 → PhotoNode → 允许共享的相册；同时作用于 FilePit 的 `/photos`。
- 首次访问 iCloud 中的照片可能较慢，因为要把资源从 iCloud 下载到本机临时目录。

---

## 8. ClipHub

### 8.1 网页

- 顶部输入文本 + 标签（逗号分隔）→ 保存。
- 搜索、标签筛选、复制、删除、批量删除、清空。
- 图片/文件剪贴记录会显示缩略图/文件名，可下载。

### 8.2 API 推送

```bash
# 登录拿到 token
TOKEN=$(curl -s -X POST http://<ip>:8080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"role":"user","password":"pithub","remember":false}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# 推送文本
curl -X POST http://<ip>:8080/api/clip/push \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"kind":"text","text":"来自快捷指令的剪贴","tags":["work"]}'

# 取最新
curl "http://<ip>:8080/api/clip/latest" -H "Authorization: Bearer $TOKEN"
```

图片/文件可以用 `POST /api/clip/blob?filename=xxx&tags=...&kind=image` 直接上传二进制（`Content-Type: application/octet-stream`）。

- 最大保留条数与保留天数在设置里配置；超过会自动淘汰最旧记录并删除对应文件。
- 单条上限默认 16MB。

---

## 9. DashLink

### 9.1 添加按钮

1. 网页 → DashLink →「新增按钮」。
2. 填写按钮名称与**快捷指令名称**（必须与「快捷指令」App 里完全一致）。
3. 可选：输入模板（`{{text}}` 会被运行时文本替换）、颜色、单独冷却。
4. 保存后，网页或 App 都能点击运行。

### 9.2 调用机制

- 运行时会打开 `shortcuts://run-shortcut?name=<名称>&input=text&text=<参数>`。
- iOS 不允许 App 枚举快捷指令，也不把执行结果回传给调用方。
- 结果回传：在快捷指令末尾加一个「获取 URL 内容」动作：
  - URL 用每次运行返回的 `callbackURL`（形如 `http://.../api/dash/callback?runId=xxx`）
  - 方法 `POST`
  - 请求体 JSON：`{"result":"执行成功"}`（也支持 `status: "failed"`）
  - 该接口只凭 `runId` 授权，`runId` 每次随机生成、不可猜测；不要把它写到公开网页。
- 冷却时间默认 10 秒；每个按钮可覆盖。

---

## 10. 通知与后台

- 本地通知：上传完成、隧道断开、服务启动失败、DashLink 触发。
- 通知权限在首次启动时请求；可在系统设置关闭。
- 锁屏策略：
  - **锁屏暂停服务**：检测到设备锁定（受保护数据不可用）时停止服务，解锁后自动恢复。
  - **锁屏尽量保活**：不主动停止；同时可开启「屏幕常亮」（`isIdleTimerDisabled`），适合插电常驻。
- **不要**使用静默音频等私有/灰产保活；工程默认不启用 `audio` 后台模式，避免 TestFlight 审核风险。需要时可在 `project.yml` 里自行添加并承担风险（见 [限制](LIMITATIONS.md)）。

---

## 11. 排障

| 问题 | 检查 |
| --- | --- |
| 网页打不开 | 同一 Wi-Fi？App 显示在线？端口对不对？本地网络权限？ |
| 登录 401 | 密码错误、角色不可用（访客被关闭）、会话超时 |
| 上传 413 | 超过设置里的上传上限；改设置或分片 |
| 上传 415 | 后缀在黑名单里；改设置 |
| WebDAV 连不上 | 地址是否带 `/webdav`；用户名/密码；Windows 的 BasicAuthLevel |
| 照片空白 | 相册权限；iCloud 下载；缩略图缓存清空后重试 |
| 隧道一直“检测中” | Cloudflare 外部连接器没运行/公网地址填错；Relay Token/地址错误 |
| 修改端口后失联 | 浏览器换成新端口；App 已自动重启监听 |
| 通知不弹 | 系统通知权限、App 在前台时横幅设置 |
| 相册下载很慢 | PhotoKit 需要先导出，视频/iCloud 原图尤其慢 |
