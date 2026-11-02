# PitHub Relay

把 iPhone 上的 PitHub HTTP 服务映射成公网地址，不需要公网 IP。iPhone 主动连出去，Relay 只转发请求，不保存任何文件。

## 快速开始

```bash
cd relay
npm install
RELAY_TOKEN="$(openssl rand -hex 24)" \
PUBLIC_BASE_URL="https://relay.example.com" \
PORT=8787 \
npm start
```

然后：

1. 在 PitHub App / 网页设置里把隧道方案切到 **PitHub Relay**。
2. 填写 Relay 地址：`https://relay.example.com`（或 `wss://relay.example.com`）。
3. 填写同一个 `RELAY_TOKEN`。
4. 保存后 iPhone 会连出去，几秒后显示形如 `https://relay.example.com/t/<id>/` 的公网地址。

## 反向代理（Nginx）

```nginx
location / {
    proxy_pass http://127.0.0.1:8787;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 3600s;
    client_max_body_size 32m;
}
```

也可以把 Nginx 换成 Caddy；**必须支持 WebSocket**。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `RELAY_TOKEN` | 空 | 必填。与 App 设置里的 Token 一致；为空时任何客户端都能连。 |
| `PUBLIC_BASE_URL` | 自动 | 公网地址，例如 `https://relay.example.com`。不填则用请求 Host 推断。 |
| `PORT` | 8787 | Relay 监听端口。 |
| `MAX_BODY_BYTES` | 24MB | 单次请求体上限（base64 前）。大文件请用分片上传。 |
| `REQUEST_TIMEOUT_MS` | 90000 | 等待 iPhone 响应的超时。 |

## 已知限制

- 单个响应体超过 24MB 会被 iPhone 端拒绝；视频/大文件请使用 Range（播放器会自动）或分片下载。
- Relay 是“请求-响应”转发，不做长连接流式；大文件下载体验不如局域网直连。
- 生产环境请务必设置 `RELAY_TOKEN`，并在 HTTPS 后面运行。
- Relay 不存储请求内容；建议在 VPS 上关闭 access log 中的 body 记录（默认 Nginx 不记录 body）。

## systemd 示例

```ini
[Unit]
Description=PitHub Relay
After=network.target

[Service]
WorkingDirectory=/opt/pithub-relay
Environment=RELAY_TOKEN=change-me
Environment=PUBLIC_BASE_URL=https://relay.example.com
ExecStart=/usr/bin/node server.mjs
Restart=always

[Install]
WantedBy=multi-user.target
```
