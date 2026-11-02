# HTTP API 参考

所有业务接口以 `/api` 开头，返回 JSON。统一鉴权，三种方式任选：

```http
Cookie: pithub_session=<token>
Authorization: Bearer <token>
Authorization: Basic base64(user:pass)      # WebDAV / curl 方便
```

角色：`guest` < `user` < `admin`。写操作需要 `user`，私密目录/设置/插件开关/日志导出需要 `admin`。

> 独立部署前端时，跨域请求使用 Bearer Token；Cookie 受浏览器 SameSite/CORS 限制。

---

## 1. 鉴权

### `POST /api/auth/login`

```json
{ "role": "admin", "password": "pithub", "remember": true }
```

返回：

```json
{
  "ok": true,
  "role": "admin",
  "token": "…",
  "expiresAt": "2026-11-02T...",
  "timeoutSeconds": 43200
}
```

同时下发 `Set-Cookie: pithub_session=…; Path=/; HttpOnly; SameSite=Lax`。

失败：`401`；尝试过多：`429`。

### `GET /api/auth/status`

公开。返回当前会话角色、访客开关、默认密码提示、隧道状态。

### `POST /api/auth/logout`

退出并清除 Cookie。

### `GET /api/health`

公开，供隧道连接器/Relay 检测。返回 `{"ok":true,"name":"PitHub"}`。

---

## 2. 全局状态

### `GET /api/status`

```json
{
  "online": true,
  "port": 8080,
  "localURL": "http://192.168.1.8:8080",
  "lanHost": "192.168.1.8",
  "bonjour": "_pithub._tcp",
  "tunnel": {
    "provider": "relay",
    "providerName": "PitHub Relay 自建隧道",
    "active": true,
    "publicURL": "https://relay.example.com/t/abc/",
    "message": "Relay 隧道已建立"
  },
  "connections": 2,
  "traffic": { "lanIn": 0, "lanOut": 0, "tunnelIn": 0, "tunnelOut": 0, "totalIn": 0, "totalOut": 0, "total": 0 },
  "trafficText": { "lan": "0 B", "tunnel": "0 B", "total": "0 B" },
  "plugins": [ { "id": "file", "name": "FilePit", "enabled": true, "prefix": "/api/file", ... } ],
  "role": "admin",
  "uptime": 123
}
```

### `GET /api/plugin/list`

返回全部插件描述与启用状态。

### `POST /api/plugin/enable` / `POST /api/plugin/disable`

管理员。Body：`{"id":"file"}`。

---

## 3. 设置 / 缓存 / 二维码 / 日志

### `GET /api/settings`

返回 `{"ok":true,"settings":{...}}`。密码哈希不会下发。

### `POST /api/settings`（管理员）

Body 为部分设置；支持嵌套：

```json
{
  "port": 8080,
  "guestEnabled": true,
  "tunnelEnabled": false,
  "tunnelProvider": "cloudflare",
  "tunnelPublicURL": "https://xxx.trycloudflare.com",
  "relayURL": "https://relay.example.com",
  "relayToken": "…",
  "wanRateLimitKBps": 0,
  "backgroundPolicy": "pauseOnLock",
  "preventAutoLock": true,
  "cacheLimitMB": 512,
  "newAccessPassword": "…",
  "newAdminPassword": "…",
  "filePit": {
    "maxUploadMB": 4096,
    "blockedExtensions": ["exe", "bat", "sh"],
    "shareExpiryMinutes": 60,
    "allowZipDownload": true,
    "allowPhotoMount": true,
    "chunkMB": 8
  },
  "photoNode": {
    "allowedAlbumIDs": [],
    "includeVideos": true,
    "includeHiddenAssets": false,
    "thumbnailQuality": 72
  },
  "clipHub": { "maxRecords": 200, "maxItemMB": 16, "retentionDays": 30 },
  "dashLink": { "cooldownSeconds": 10, "maxRuns": 300 }
}
```

修改端口会在响应后自动重启监听。

### `GET /api/tunnel/guide`

返回 Cloudflare 命令、frp 配置、Relay 部署步骤与 iOS 限制说明。

### `GET /api/qr?url=...`

返回 PNG。`url` 省略时使用当前分享基地址。

### `GET /api/cache/stats` / `POST /api/cache/clear`

缓存大小；清空需要管理员。

### `GET /api/logs?offset=0&limit=50&q=&method=&tunnel=1`

需要 user。`tunnel` 可传 `1`/`0`。

### `GET /api/logs/export?format=json|txt`

管理员。直接返回附件。

### `POST /api/logs/clear`

管理员。

---

## 4. FilePit

虚拟路径：`/shared`、`/uploads`、`/private`、`/data`、`/photos`。

### `GET /api/file/roots`

返回可用挂载根。

### `GET /api/file/list?path=/shared`

```json
{
  "ok": true,
  "path": "/shared",
  "parent": "/",
  "entries": [
    {
      "name": "photo.jpg",
      "path": "/shared/photo.jpg",
      "isDirectory": false,
      "size": 1234,
      "modified": 1760000000,
      "kind": "image",
      "mime": "image/jpeg",
      "isReadOnly": false,
      "rootID": "shared"
    }
  ],
  "total": 1,
  "roots": [...],
  "breadcrumb": [...]
}
```

### `GET /api/file/stat?path=...`

单个文件/目录信息。

### 写操作

```json
POST /api/file/mkdir    { "path": "/shared/NewFolder" }
POST /api/file/delete   { "path": "/shared/foo" }
POST /api/file/rename   { "path": "/shared/foo", "name": "bar" }
POST /api/file/move     { "path": "/shared/foo", "destination": "/shared/Archive" }
```

返回 `{"ok":true,"entry":{...}}`（delete 返回 `{"ok":true}`）。

### 上传（小文件）

```http
POST /api/file/upload?path=/uploads/a.txt&overwrite=1
Content-Type: application/octet-stream

<二进制>
```

服务器会按请求体流式写入临时文件，不需要 multipart。

### 分片上传 / 断点续传

1. 初始化：

```http
POST /api/file/upload/init
Content-Type: application/json

{ "path": "/uploads/big.mov", "size": 123456789 }
```

返回：

```json
{
  "ok": true,
  "uploadId": "…",
  "chunkSize": 8388608,
  "totalChunks": 15,
  "received": []
}
```

2. 逐片上传（索引从 0 开始，切片大小必须与 `chunkSize` 一致，最后一片为剩余大小）：

```http
PUT /api/file/upload/chunk?uploadId=…&index=0
Content-Type: application/octet-stream

<分片二进制>
```

3. 查询已收分片（用于断点续传）：

```http
GET /api/file/upload/status?uploadId=…
```

4. 完成：

```http
POST /api/file/upload/complete
{ "uploadId": "…" }
```

5. 取消：

```http
POST /api/file/upload/cancel?uploadId=…
```

### 下载 / 预览 / ZIP

```http
GET /api/file/download?path=/shared/a.jpg&inline=1
Range: bytes=0-1023
```

- `inline=1` 时 `Content-Disposition: inline`；否则 attachment。
- 支持 `Range`，返回 206 / 416。
- 相册文件加 `&live=video` 下载实况配对视频。

```http
GET /api/file/zip?path=/shared/Folder
```

返回 ZIP（STORE，无压缩，4GB 限制）。

### 临时分享

```http
POST /api/file/share
{ "path": "/shared/a.pdf", "expiresMinutes": 60, "password": "1234" }
```

返回 `share.url`。

```http
GET  /api/file/shares
POST /api/file/share/delete  { "token": "…" }
```

公开访问：`GET /s/<token>`；有密码时返回表单，POST 同 URL 提交 `password` 与可选 `download=1`。

---

## 5. PhotoNode

| 接口 | 说明 |
| --- | --- |
| `GET /api/photo/status` | 权限状态 |
| `GET /api/photo/albums` | 相册列表（遵守白名单） |
| `GET /api/photo/assets?album=&offset=&limit=&year=&month=` | 资源列表 |
| `GET /api/photo/timeline?album=` | 年月计数 |
| `GET /api/photo/thumb?id=&size=small|medium|large` | JPEG 缩略图 |
| `GET /api/photo/cover?album=&size=` | 相册封面 |
| `GET /api/photo/original?id=&live=video` | 原图/视频/实况配对视频（异步导出后流式返回） |
| `GET /api/photo/info?id=` | 单个资源元数据 |

`assets` 示例：

```json
{
  "ok": true,
  "items": [
    {
      "id": "…/L0/001",
      "filename": "IMG_0001.HEIC",
      "mediaType": "image",
      "isLivePhoto": false,
      "duration": 0,
      "createdAt": "2026-10-01T...",
      "pixelWidth": 4032,
      "pixelHeight": 3024,
      "thumbURL": "/api/photo/thumb?id=...&size=small",
      "originalURL": "/api/photo/original?id=..."
    }
  ],
  "total": 500
}
```

---

## 6. ClipHub

### 文本

```http
POST /api/clip/push
{ "kind": "text", "text": "hello", "tags": ["work"], "source": "shortcut" }
```

### 图片/文件（base64）

```http
POST /api/clip/push
{
  "kind": "image",
  "filename": "a.png",
  "mime": "image/png",
  "tags": ["截图"],
  "dataBase64": "<base64>"
}
```

### 图片/文件（原始二进制，推荐大文件）

```http
POST /api/clip/blob?filename=a.png&kind=image&tags=截图
Content-Type: application/octet-stream

<二进制>
```

### 读取 / 管理

```
GET  /api/clip/latest
GET  /api/clip/list?q=&tag=&offset=0&limit=50
GET  /api/clip/get?id=...
GET  /api/clip/blob?id=...        # 下载/预览
GET  /api/clip/tags
GET  /api/clip/status
POST /api/clip/delete { "id": "..." }
POST /api/clip/clear
```

写入需要 user。超过 `maxRecords` 或 `retentionDays` 会自动淘汰。

---

## 7. DashLink

```
GET  /api/dash/buttons
POST /api/dash/button/save      { id?, title, shortcutName, inputTemplate, color, icon, cooldownSeconds }
POST /api/dash/button/delete    { id }
POST /api/dash/run              { id, text }
GET  /api/dash/runs?limit=30
POST /api/dash/runs/clear
```

`/api/dash/run` 返回：

```json
{
  "ok": true,
  "run": { "id": "...", "status": "launched", ... },
  "callbackURL": "http://.../api/dash/callback?runId=...",
  "note": "iOS 不会把快捷指令结果直接回传..."
}
```

### 结果回调（公开，凭 runId）

```http
POST /api/dash/callback?runId=...
Content-Type: application/json

{ "result": "执行成功" }
```

也支持 `{"status":"failed"}` 与纯文本/query `result`。`runId` 每次随机、不可猜测。

---

## 8. WebDAV

路径前缀 `/webdav/`，方法与行为见 [WEBDAV.md](WEBDAV.md)。

---

## 9. 错误

| 状态 | 含义 |
| --- | --- |
| 400 | 参数/路径无效 |
| 401 | 未登录或密码错误 |
| 403 | 权限不足（访客写、非管理员进 Private、相册未共享） |
| 404 | 不存在 / 插件已禁用 / 分享过期 |
| 405 | 方法不支持 |
| 409 | 同名文件、上传分片缺失 |
| 412 | WebDAV Overwrite: F |
| 413 | 超过上传上限 / Relay 单次响应过大 |
| 415 | 后缀黑名单 |
| 416 | Range 无效 |
| 429 | 登录尝试过多 / DashLink 冷却中 |
| 500 | 服务端错误 |
| 503 | 插件未就绪 / 服务未启动 |

错误体：

```json
{ "ok": false, "error": "具体原因" }
```

---

## 10. curl 速查

```bash
BASE=http://192.168.1.8:8080
COOKIE=/tmp/pithub.cookies

# 登录
curl -s -c $COOKIE -X POST $BASE/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"role":"admin","password":"pithub","remember":true}'

# 状态
curl -s -b $COOKIE $BASE/api/status

# 文件列表
curl -s -b $COOKIE "$BASE/api/file/list?path=/shared"

# 上传
curl -b $COOKIE -X POST "$BASE/api/file/upload?path=/uploads/demo.txt" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @demo.txt

# 下载
curl -b $COOKIE -L "$BASE/api/file/download?path=/shared/demo.txt" -o demo.txt

# Range
curl -b $COOKIE -H 'Range: bytes=0-99' "$BASE/api/file/download?path=/shared/demo.txt" -o part.bin

# WebDAV
curl -u admin:pithub -X PROPFIND -H 'Depth: 1' $BASE/webdav/Shared/
```
