# 重签名与侧载

> 只给自己的设备安装；不要分发你没权分发的证书/描述文件。

## 1. 三种常见方式

| 方式 | 适合 | 是否需要证书 | 有效期 |
| --- | --- | --- | --- |
| **TrollStore** | iOS 14.0–16.6.1（部分版本到 17.0，按官方兼容表） | 不需要 | 永久（依赖 CoreTrust 漏洞） |
| **AltStore / Sideloadly / Feather** | 任意 iOS，自签 | 需要 Apple ID（免费）或开发者账号 | 免费 7 天，开发者 1 年 |
| **Apple Developer / Ad Hoc** | 自己或少量登记设备 | 需要 | 1 年 |

你的设备是 **iPhone 13 / iOS 16.0.2**，在 TrollStore 的兼容区间内（以 [TrollStore 官方说明](https://github.com/opa334/TrollStore) 为准）。安装 TrollStore 通常需要通过 TrollHelper / TrollInstallerX（利用设备上的系统漏洞），这一步请自行评估安全风险。

---

## 2. 从 GitHub 安装

1. 在 iPhone Safari 打开仓库的 **Releases → PitHub-Latest**，下载 `PitHub.ipa`（Safari 会存到「文件」App）。
2. 如果使用 TrollStore：在「文件」里点 `PitHub.ipa` → 共享/打开方式 → TrollStore → Install。
3. 如果使用 AltStore/Sideloadly：把 IPA 传到电脑，用工具安装；或使用设备上的自签工具打开 IPA 并签名。
4. 安装后到「设置 → 通用 → VPN 与设备管理」信任对应证书/开发者（TrollStore 不需要）。

> GitHub 的 Release 资产是**未签名** IPA。AltStore/Sideloadly 会自动重签；TrollStore 直接安装未签名包（TrollStore 会处理）。

---

## 3. 手动重签名（开发者/Ad Hoc）

如果 CI 给的是未签名 IPA，而你有开发者证书与描述文件，可以手动签名：

```bash
# 0. 准备
IPA=PitHub.ipa
PROFILE=PitHub_AdHoc.mobileprovision
CERT="iPhone Distribution: Your Name (TEAMID)"
BUNDLE=com.yourname.pithub
WORK=$(mktemp -d)

unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/PitHub.app"

# 1. 取出描述文件里的 entitlements
security cms -D -i "$PROFILE" > "$WORK/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/entitlements.plist"

# 2. 放入描述文件
cp "$PROFILE" "$APP/embedded.mobileprovision"

# 3. 删除旧签名（未签名包通常没有）
rm -rf "$APP/_CodeSignature"

# 4. 先签 Frameworks 里的每个 framework
find "$APP/Frameworks" -name "*.framework" -maxdepth 1 -print0 | while IFS= read -r -d '' fw; do
  codesign --force --sign "$CERT" --timestamp=none "$fw"
done

# 5. 签主 App
codesign --force --sign "$CERT" --entitlements "$WORK/entitlements.plist" --timestamp=none "$APP"

# 6. 校验
codesign --verify --deep --strict --verbose=2 "$APP"

# 7. 重新打包
rm -f PitHub-signed.ipa
cd "$WORK" && zip -qry "$OLDPWD/PitHub-signed.ipa" Payload
```

注意事项：

- `BUNDLE` 必须与描述文件里的 App ID 匹配；如果描述文件是通配符，则任意后缀都可以。
- 描述文件里的 `Entitlements` 必须与 App 能力匹配；PitHub 没有特殊 entitlement。
- frameworks 必须先签，否则主 App 校验会失败。
- Apple 对 Ad Hoc 签名通常会要求 `--timestamp`；本地自用可省略。用 Xcode 导出最稳妥。
- 重签名后如果 App 打不开，先在 Console.app / Xcode Devices 看 `amfid` / `codesign` 报错。

---

## 4. AltStore / Sideloadly 简要步骤

### Sideloadly（Windows/macOS）

1. 安装 iTunes（Windows）或使用 macOS 自带驱动。
2. 打开 Sideloadly，连接 iPhone，选择 `PitHub.ipa`。
3. 填 Apple ID，选择 “Normal Install”。
4. 首次需要在 iPhone 设置里信任开发者证书；免费账号 7 天后过期，需要重新安装。
5. 如果提示 App 数量超限：免费账号最多 3 个自签 App，删除旧的。

### AltStore

1. 电脑安装 AltServer，iPhone 安装 AltStore。
2. AltStore 里 `+` → 选择 IPA。
3. 同样需要信任证书，7 天续签（AltStore 可在同一 Wi-Fi 下自动续签）。

---

## 5. 安装后检查

1. 打开 App，允许「本地网络」「相册」「通知」。
2. 看控制台是否显示“服务运行中”和内网地址。
3. 同一 Wi-Fi 下用电脑浏览器访问 `http://<iPhone IP>:8080`。
4. 默认密码 `pithub`，登录后马上去设置里改密码。
5. 如果网页打不开：检查系统设置 → PitHub → 本地网络；确认端口未被其他 App 占用。

---

## 6. 常见报错

| 报错 | 处理 |
| --- | --- |
| `The executable was signed with invalid entitlements` | 描述文件与 Bundle ID/entitlements 不匹配 |
| `Unable to Install "PitHub"` | 设备 UDID 不在 Ad Hoc 名单，或描述文件过期 |
| `The app cannot be installed because its integrity could not be verified` | 证书未信任，或重签名不完整 |
| `A valid provisioning profile for this executable was not found` | 没有把描述文件嵌进 App，或 Bundle ID 不匹配 |
| TrollStore 安装后闪退 | 系统版本不在兼容范围，或 IPA 架构/最低版本不对（本工程是 iOS 16.0+） |
