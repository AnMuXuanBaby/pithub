# 打包 IPA

目标：产出可安装的 `PitHub.ipa`。分三种情况：

1. **未签名 IPA**：TrollStore / 自行重签名使用（CI 默认产出）。
2. **Developer 签名 IPA**：装到你自己的设备，用于调试/自用。
3. **Ad Hoc 签名 IPA**：装到已登记 UDID 的有限设备。

> 工程最低部署目标为 **iOS 16.0**，以适配 iPhone 13 / iOS 16.0.2。  
> 如果改成 iOS 17，iOS 16 设备将无法安装。

---

## 1. 环境

- macOS 13+（推荐 macOS 14/15）
- Xcode 15 或更新（含 iOS 16 SDK 与 iOS 17 SDK）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- 可选：Apple Developer 账号（Developer / Ad Hoc 需要）
- 可选：已注册的设备 UDID（Ad Hoc 需要）

```bash
git clone <你的仓库地址> pithub
cd pithub
brew install xcodegen
xcodegen generate
open PitHub.xcodeproj
```

`xcodegen generate` 会读取 `project.yml` 并生成 `PitHub.xcodeproj`。`www` 以 folder reference 形式嵌入 App；`PitHub`、`Modules/*`、`PrivacyInfo.xcprivacy` 都会进入对应 target。

---

## 2. 在 Xcode 里配置签名

1. 选中 **PitHub** target → **Signing & Capabilities**。
2. 勾选 **Automatically manage signing**，选择你的 **Team**。
3. 把 **Bundle Identifier** 从 `com.pithub.app` 改成全局唯一的，例如 `com.yourname.pithub`。
4. 如果提示需要注册设备：连接 iPhone，Xcode 会自动注册（Developer 账号）。
5. 选中真机，点击 Run，首次运行需要在 iPhone「设置 → 通用 → VPN 与设备管理」里信任开发者证书。

本地运行时，Xcode 会自动把 5 个 framework 嵌入 App（`Frameworks/`），无需手动操作。

### 2.1 用命令行注入 Team ID（可选）

把 `project.yml` 里的 `DEVELOPMENT_LANGUAGE` 下面补一行：

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: "ABCDE12345"
```

或直接改生成后的 Xcode 工程（不推荐，因为下次 `xcodegen` 会覆盖）。

---

## 3. 未签名 IPA（CI 与本地）

### 3.1 GitHub Actions（推荐）

推到 GitHub 的 `main` 分支后，Actions 自动执行：

```
.github/workflows/build-ipa.yml
```

步骤：安装 XcodeGen → 生成工程 → `xcodebuild`（关闭签名）→ 校验 `www` 与 `Frameworks` → 打包 `Payload/PitHub.app` → 上传 Artifact → 发布 Release `PitHub-Latest`。

在 GitHub 页面：

- **Actions** → 最近一次 *Build IPA* → Artifacts → `PitHub-unsigned-ipa`
- 或 **Releases** → `PitHub-Latest` → 下载 `PitHub.ipa`

### 3.2 本地命令行

```bash
xcodegen generate
xcodebuild \
  -project PitHub.xcodeproj \
  -scheme PitHub \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP=".build/Build/Products/Release-iphoneos/PitHub.app"
mkdir -p Payload
cp -R "$APP" Payload/
zip -qry PitHub.ipa Payload
```

检查：

```bash
ls -la "$APP"
ls -la "$APP/Frameworks"
ls -la "$APP/www"
/usr/libexec/PlistBuddy -c "Print :NSBonjourServices" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$APP/Info.plist"
```

---

## 4. Developer 签名 IPA

### 4.1 Xcode GUI

1. 连接 iPhone，选择真机。
2. `Product → Archive`。
3. Organizer 里选中刚生成的 archive → **Distribute App**。
4. 选择 **Development** → **Automatically manage signing** → 选择 Team。
5. 导出到文件夹，得到 `PitHub.ipa`。

### 4.2 命令行 Archive + Export

```bash
xcodebuild \
  -project PitHub.xcodeproj \
  -scheme PitHub \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/PitHub.xcarchive \
  -allowProvisioningUpdates \
  archive

xcodebuild -exportArchive \
  -archivePath build/PitHub.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist docs/templates/ExportOptions-development.plist \
  -allowProvisioningUpdates
```

模板见 [`docs/templates/ExportOptions-development.plist`](templates/ExportOptions-development.plist)。把 `YOUR_TEAM_ID`、`com.yourname.pithub`、描述文件名替换成你自己的。

---

## 5. Ad Hoc 签名 IPA

前提：目标设备 UDID 已加入 Apple Developer 后台（Devices），并生成了 Ad Hoc 描述文件。

GUI：Archive → Distribute App → **Ad Hoc** → 选择描述文件 → Export。

CLI：

```bash
xcodebuild -exportArchive \
  -archivePath build/PitHub.xcarchive \
  -exportPath build/export-adhoc \
  -exportOptionsPlist docs/templates/ExportOptions-ad-hoc.plist
```

导出后 `build/export-adhoc/PitHub.ipa` 可以：

- 用 Apple Configurator / Xcode Devices 安装；
- 用 AirDrop / 上传到网页后通过 Safari 安装（需要 itms-services + manifest，或第三方分发平台）；
- 用 Sideloadly / AltStore 安装。

Ad Hoc 不是无限分发：只能装到 UDID 白名单里的设备，且证书有效期通常一年。

---

## 6. 常见问题

| 现象 | 原因/解决 |
| --- | --- |
| `No signing certificate "iOS Development" found` | Xcode 未登录 Apple ID，或 Team 未选择 |
| `Bundle Identifier ... is not available` | 换一个唯一 Bundle ID |
| 安装后打不开/闪退 | 证书/描述文件与 Bundle ID 不匹配；或设备未信任证书 |
| 网页打不开、App 显示在线 | 首次启动没有允许「本地网络」；到系统设置 → PitHub → 本地网络 打开 |
| `www` 404 | 检查 App 包里是否有 `www/index.html`；`project.yml` 里 `www` folder reference 是否保留 |
| 找不到框架 | 确认 `PitHub` target 的 Embed Frameworks 包含 5 个 framework；`xcodegen` 会处理 |
| CI 构建失败 | 查看 Actions 的 `build.log`；常见原因是 Xcode/Swift 版本或 XcodeGen 语法 |
| 端口修改后网页失联 | 新端口生效，请用新地址访问；App 内会显示新端口 |
| iOS 16 安装失败 | 确认部署目标没有被改成 iOS 17 |

日志位置：

- Xcode：Window → Devices and Simulators → View Device Logs
- App 内：日志 Tab
- 网页：设置 → 访问日志

---

## 7. 产物说明

| 文件 | 内容 |
| --- | --- |
| `PitHub.ipa` | 未签名或已签名（取决于构建方式）；内含 App、5 个 Frameworks、`www` |
| `PitHub-frontend.zip` | `www` + `frontend-src`（不含 node_modules），可独立部署 |
| `PitHub.app` | Payload 中的主体；可用于检查资源与 Info.plist |

签名 IPA 里 `Payload/PitHub.app/_CodeSignature/`、`embedded.mobileprovision` 存在；未签名 IPA 没有这些文件。
