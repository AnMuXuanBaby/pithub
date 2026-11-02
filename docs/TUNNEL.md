# 外网隧道

隧道是**全局模块**，独立于插件：开启后，把本机 HTTP 端口暴露到公网，并显示状态、公网地址与二维码。

> **iOS 沙盒限制**：App 不能 `fork/exec` 外部二进制，因此无法在 iPhone 内直接运行 `cloudflared` 或 `frpc`。PitHub 提供三种合规路径：外部 Cloudflare 连接器、自建 Relay（App 内一键）、外部 frp。详见 [限制清单](LIMITATIONS.md#隧道)。

## 1. 模式总览

| 模式 | 是否需要公网 IP | 是否 App 内一键 | 说明 |
| --- | --- | --- | --- |
| 仅局域网 | 否 | — | 默认；只在同一 Wi-Fi 可用 |
| Cloudflare Tunnel | 否 | 否（外部连接器） | 在 Mac/路由器/NAS 运行 cloudflared 指向 iPhone 端口 |
| PitHub Relay | 否 | 是 | 部署 `relay/server.mjs` 后，iPhone 主动连出，自动拿到公网地址 |
| frp | 否 | 否（外部 frpc） | 适合已有 frps 的用户 |

在 App 或网页「设置 → 外网隧道」切换。切换后保存即生效，不影响插件启停。

## 2. Cloudflare Tunnel（推荐给已有 Cloudflare 的用户）

### 2.1 快速隧道（临时域名）

在 iPhone 同一 Wi-Fi 的 Mac / Linux / NAS 上：

```bash
brew install cloudflared              # macOS
# 或按官方文档安装：https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/
cloudflared tunnel --url http://<iPhone 局域网 IP>:8080
```

终端会输出：

```
https://<随机>.trycloudflare.com
```

把这个地址填到 PitHub 设置里的「公网地址」，开启隧道。App 会立即检测 `/api/health`，成功后显示“公网隧道可用”，并生成二维码。

快速隧道的域名是临时的，重启 cloudflared 可能变化；变化后需要重新填写地址/重新生成分享链接。

### 2.2 固定域名（Named Tunnel）

```bash
cloudflared tunnel login
cloudflared tunnel create pithub
cloudflared tunnel route dns pithub pithub.example.com
cloudflared tunnel run --url http://<iPhone IP>:8080 pithub
```

把 `https://pithub.example.com` 填到 PitHub。域名固定后，分享链接也更稳定。

> cloudflared 必须运行在**能访问到 iPhone 的局域网设备**上（Mac、树莓派、路由器、NAS）。它只做转发，不存储文件。

## 3. PitHub Relay（App 内一键，自建）

如果你有一台 VPS（或有公网 IP 的服务器），部署仓库里的 Relay：

```bash
cd relay
npm install
RELAY_TOKEN="$(openssl rand -hex 24)" \
PUBLIC_BASE_URL="https://relay.example.com" \
PORT=8787 \
npm start
```

Nginx/Caddy 需要支持 WebSocket，配置见 [relay/README.md](../relay/README.md)。

然后在 PitHub 设置：

- 隧道方案：**PitHub Relay**
- Relay 地址：`https://relay.example.com`
- Relay Token：与 `RELAY_TOKEN` 相同
- 开启隧道 → 保存

几秒后 App 会显示 `https://relay.example.com/t/<id>/`，二维码也同步更新。这个地址可以用于：
网页、WebDAV、API、分享链接（分享链接会自动带 `/t/<id>/` 前缀）。

限制：单次响应体上限 24MB（大文件靠 Range 分片）；Relay 只做请求-响应转发，不保存内容。

## 4. frp

在路由器/电脑上运行 `frpc`，PitHub 设置里填写公网地址。设置页可一键复制配置模板：

```toml
serverAddr = "frp.example.com"
serverPort = 7000
auth.token = "your-token"

[[proxies]]
name = "pithub"
type = "http"
localIP = "<iPhone IP>"
localPort = 8080
customDomains = ["pithub.yourdomain.com"]
```

需要 HTTPS 时，在 frps 侧配置 TLS 或使用带 HTTPS 的反向代理。

## 5. 外网限速与流量统计

- 设置里可填「外网限速 KB/s」，0 表示不限速。直连/Cloudflare 打到本机 HTTP 的请求会在连接层节流。
- Relay 模式的限速目前建议在 Relay 服务器（Nginx/网关）侧配置；App 内会对通过 Relay 的流量单独计数，但不在客户端节流。
- 控制台区分：
  - 局域网流量
  - 隧道流量
  - 总流量
- 来源 IP：Cloudflare 请求会使用 `CF-Connecting-IP`；Relay 会带 `X-Forwarded-For`。

## 6. 安全建议

1. 修改默认密码，使用强密码。
2. 公网暴露前开启隧道，不要把 `8080` 直接端口映射到公网。
3. Cloudflare/Relay 都会给 HTTPS；局域网仍是明文 HTTP。
4. 分享链接带 token，等同于临时权限，不要发到公开群。
5. 不需要外网时关闭隧道；关闭后二维码与分享基地址会回到局域网。
6. Relay 的 `RELAY_TOKEN` 必须设置，并定期更换。
7. 不要用静默音频等灰产保活；见 [限制](LIMITATIONS.md)。

## 7. 排障

| 现象 | 排查 |
| --- | --- |
| Cloudflare 模式一直“暂不可达” | cloudflared 是否在运行？公网地址是否带 https？iPhone 与连接器是否同一 Wi-Fi？ |
| Relay 显示“正在连接” | 地址是否 `https://` 或 `wss://`；Token 是否正确；反向代理是否支持 WebSocket；443 是否放行 |
| Relay 连接后网页 502 | iPhone App 是否被系统挂起；重新打开 App |
| 公网能打开但登录后 401 | Cookie 被浏览器限制；用同一域名访问，不要混用 http/https |
| 分享链接指向局域网 | 生成分享时隧道未启用；重新生成 |
| 外网播放视频失败 | Relay 模式 24MB 限制；播放器应使用 Range；仍失败时改用 Cloudflare 或局域网 |
