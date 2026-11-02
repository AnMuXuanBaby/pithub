# WebDAV 挂载

PitHub 的 WebDAV 与网页/HTTP API 使用同一套会话与角色，不会绕过权限。

## 1. 地址与账号

- 局域网：`http://<iPhone 局域网 IP>:<端口>/webdav/`
- 隧道/公网：`https://<公网地址>/webdav/`（Relay 会自动带上 `/t/<id>/` 前缀）
- 用户名：
  - `admin` + 管理员密码 → 管理员（可进 `/Private`、`/Data`）
  - 任意其他用户名 + 访问密码 → 普通用户
- 访客（guest）无法用 Basic 登录；如果要只读挂载，请使用普通用户并不要写入。

> 地址末尾的 `/` 很重要。缺少时会由客户端自行处理，但部分 Windows 版本会出现兼容问题。

## 2. macOS 访达

1. 访达 → 顶部菜单「前往」→「连接服务器」（⌘K）。
2. 输入 `http://<iPhone IP>:8080/webdav/`。
3. 选择「注册用户」，用户名 `admin`（或任意用户名），密码为对应密码。
4. 挂载后会出现 `Shared`、`Uploads`、`Private`（管理员）、`Data`（管理员）、`Photos`（只读）。

## 3. iOS / iPadOS「文件」App

1. 文件 → 浏览 → 右上角「…」→「连接服务器」。
2. 服务器：`http://<iPhone IP>:8080/webdav/`
3. 选择「注册用户」，输入账号密码。
4. 连接后可浏览、下载；`Photos` 为只读。

## 4. Windows

### 4.1 资源管理器「映射网络驱动器」

1. 右键「此电脑」→「映射网络驱动器」。
2. 文件夹：`http://<iPhone IP>:8080/webdav/`
3. 勾选「使用其他凭据」，输入用户名/密码。

如果提示「无法访问网络位置」：

- Windows WebClient 默认禁止 HTTP 上的 Basic 认证。以管理员运行：

```powershell
reg add HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters /v BasicAuthLevel /t REG_DWORD /d 2 /f
reg add HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters /v FileSizeLimitInBytes /t REG_DWORD /d 4294967295 /f
net stop webclient
net start webclient
```

- 确认 iPhone 与电脑同一 Wi-Fi，防火墙没有拦截。
- 28800 端口冲突 / WebClient 服务异常：重启 `webclient` 服务。
- Windows 默认对大文件有 50MB 限制，`FileSizeLimitInBytes` 调整后重启服务生效。

### 4.2 第三方客户端

- WinSCP（WebDAV 协议）、RaiDrive、Cyberduck 都可以；地址同上，Basic 认证。

## 5. Android

- **Solid Explorer**：添加存储 → WebDAV → 地址、用户名、密码。
- **CX File Explorer**：网络 → WebDAV。
- **FolderSync** 等同步工具也支持 WebDAV。

## 6. 权限模型

| 路径 | 读 | 写 |
| --- | --- | --- |
| `/webdav/Shared/...` | guest/user/admin | user/admin |
| `/webdav/Uploads/...` | guest/user/admin | user/admin |
| `/webdav/Private/...` | admin | admin |
| `/webdav/Data/...` | admin | admin |
| `/webdav/Photos/...` | guest/user/admin | 禁止（只读） |

WebDAV 的写操作在内部会再次调用与网页相同的权限函数；不存在“绕过网页权限”的接口。

## 7. 支持的方法

| 方法 | 说明 |
| --- | --- |
| `OPTIONS` | 返回 `DAV: 1, 2`、`MS-Author-Via` |
| `PROPFIND` | Depth 0/1（infinity 按 1 处理），返回 207 XML |
| `GET` / `HEAD` | 文件下载，支持 Range；目录返回 405 |
| `PUT` | 上传（原始二进制），自动遵守大小/后缀限制 |
| `MKCOL` | 新建目录 |
| `DELETE` | 删除文件/目录 |
| `MOVE` | 重命名/移动；`Destination` 支持绝对 URL |
| `PROPPATCH` | 返回 207（属性不实际保存） |
| `LOCK` / `UNLOCK` | 返回形式化锁令牌，不做真正并发互斥 |
| `COPY` | 暂未实现（501），请下载后上传 |

## 8. 已知限制

- 相册目录只读，`PROPFIND` 的 `getcontentlength` 为 0；下载时会先导出原图，可能较慢。
- 大目录首次 `PROPFIND Depth: 1` 可能较慢；目录列表有增量缓存，后续会快很多。
- 相册白名单对 WebDAV 同样生效；未共享的相册不会出现。
- 单个文件最大受设置里的“上传上限”限制；ZIP 不支持 ZIP64（4GB 上限）。
- WebDAV 没有 HTTPS（局域网 HTTP）；外网请通过 Cloudflare/Relay 的 HTTPS。
