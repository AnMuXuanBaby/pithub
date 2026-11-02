# 前端与独立部署

## 1. 结构

```
www/
  index.html                 # 单页入口
  manifest.webmanifest
  assets/
    app.css                  # Tailwind v3 编译产物（内嵌到 IPA）
    config.js                # 可选：独立部署时的 API 地址
    app.js                   # 登录、路由、控制台
    api.js                   # fetch 封装、状态、Token
    ui.js                    # 图标/Toast/Modal/主题/格式化
    shell.js                 # 侧边栏、移动端导航、顶栏
    filepit.js               # FilePit 面板
    photo.js                 # PhotoNode 面板
    clip.js                  # ClipHub 面板
    dash.js                  # DashLink 面板
    settings.js              # 设置面板
    logs.js                  # 日志面板
    favicon.png
frontend-src/
  package.json
  tailwind.config.js
  input.css                  # @tailwind + 自定义玻璃样式
```

- 全部是静态 HTML + Tailwind v3 + Vanilla JS，不使用 Vue/React/Angular。
- 图标是内联 SVG（`ui.js`），没有图标库依赖。
- 主题：`:root` 深色变量，`html[data-theme="light"]` 覆盖；默认跟随系统，可手动切换，存于 `localStorage`。
- 服务端把 `www` 作为 folder reference 嵌入 App，`PitHubWebAssets` 从 `Bundle.main/www` 读取；也支持 `Documents/PitHub/www` 覆盖（调试）和 `PITHUB_WWW` 环境变量。

## 2. 构建 CSS

```bash
cd frontend-src
npm install
npm run build
# 产物写入 ../www/assets/app.css
```

`npm run watch` 开发时监听。

> 仓库已提交编译后的 `app.css`，即使没有 Node 也能直接运行/打包。修改前端类名后请重新 build，否则新类不会出现在 CSS 中。

## 3. 独立部署

把 `www/` 放到任意静态服务器（Nginx、对象存储、Vercel 等），然后：

```js
// www/assets/config.js
window.PITHUB_CONFIG = { apiBase: 'https://pithub.example.com' };
```

注意：

- `apiBase` 末尾不要带 `/`；前端会拼成 `配置地址/api/...`。
- 跨域时需要使用 `Authorization: Bearer <token>`（登录接口返回 token）。前端已优先使用 localStorage 里的 token。
- 浏览器对第三方 Cookie（SameSite=Lax）限制较多，独立域名下 Cookie 可能不生效；Bearer 是主要方式。
- **图片/视频/PDF 的 `<img src>` / `<video src>` 无法带 Authorization 头**，独立部署时这些资源会被 401。解决方案：
  1. 把前端和 API 放在同一域名（推荐，例如 Nginx 同时代理静态和 PitHub）；
  2. 或在反向代理层把 Bearer/Token 转成 Cookie；
  3. 或使用 Relay/Cloudflare 让同源。
- 因此“独立前端源码包”主要用于同源/反代部署，或者只使用文本类 API。

### Nginx 同源示例

```nginx
server {
  listen 443 ssl;
  server_name pithub.example.com;
  root /var/www/pithub/www;

  location /api/ { proxy_pass http://127.0.0.1:8787; }  # Relay
  location /s/   { proxy_pass http://127.0.0.1:8787; }
  location /webdav/ { proxy_pass http://127.0.0.1:8787; }
  location / { try_files $uri $uri/ /index.html; }
}
```

## 4. 路由与相对地址

前端使用 Hash 路由：`#/dashboard`、`#/file`、`#/photo`、`#/clip`、`#/dash`、`#/logs`、`#/settings`。

API 地址默认是**相对路径**（`api/status` 而不是 `/api/status`），原因：

- 根路径部署时解析为 `/api/status`；
- Relay 的 `/t/<id>/` 子路径部署时解析为 `/t/<id>/api/status`；
- 单段页面 `/file` 直接打开时解析为 `/api/status`。

因此请保持入口页的 URL 以 `/` 结尾（Relay 已对 `/t/<id>` 做 302 到 `/t/<id>/`）。

## 5. 登录与 Token

- 登录成功后服务端同时下发 Cookie 与 JSON `token`。
- 前端把 token 存到 `localStorage('pithub_token')`，后续请求同时带 Cookie 与 Bearer。
- 401 会清空 token 并回到登录页。
- “记住会话”由服务端会话有效期与 Cookie Max-Age 控制。

## 6. 开发提示

- 没有 npm 也能运行；改样式才需要 Tailwind。
- `app.js` 负责路由，面板模块各自导出 `renderX()`；所有异步数据通过 `api.js`。
- 不要使用 `innerHTML` 拼接未转义的用户输入；现有代码统一用 `escapeHtml` / `escapeAttr`。
- 新增页面：在 `app.js` 的 `ROUTES` 注册，在 `shell.js` 的 `BASE_NAV` 加导航，写一个 `renderX()`。
