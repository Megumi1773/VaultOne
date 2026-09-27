# VaultOne 浏览器扩展（Chrome / Edge，MV3）

扩展本身不存任何保险库数据，也不做解密。它经 Native Messaging 连到本机的 VaultOne 桌面端，
由桌面端按页面地址严格匹配后，只返回当前网站那一条凭据。

```text
content.js ─┐                     Native Messaging            本地套接字（命名管道 / Unix socket）
popup.js ───┼─> background.js ──> vaultone-nmhost（只转发） ──> 桌面端 vault_core::browser
            └── 页面地址取自 sender.url，不采信页面脚本自报
```

## 开发期加载

1. 构建并运行桌面端（`app/` 下 `flutter run -d windows`）。Windows 构建会顺带编译 `vaultone-nmhost.exe`，
   应用启动时自动登记到 Chrome / Edge / Chromium / Brave（`HKCU\Software\<浏览器>\NativeMessagingHosts`）。
2. 浏览器打开 `chrome://extensions`，开启「开发者模式」，选择「加载已解压的扩展程序」，指向本目录。
   `manifest.json` 中的 `key` 把扩展 ID 固定为 `pginfajjjgcjmijmddppkbhejjjcealc`，与宿主清单 `allowed_origins` 一致。
3. 在桌面端解锁，点击扩展图标 →「配对」，核对两边配对码一致后在桌面端批准。

上架后商店会分配新的扩展 ID：把它追加到 `crates/vault-proto/src/lib.rs` 的 `EXTENSION_IDS`，重新发布桌面端。

## 功能

| 功能 | 触发 | 说明 |
|---|---|---|
| 站点匹配 | 打开弹窗 | 与条目网址同一注册域名（eTLD+1）的登录条目；https 条目不匹配 http 页面 |
| 一键填充 | 弹窗「填充」/ `Ctrl+Shift+L`（macOS `⌘⇧L`） | DOM 直接赋值并派发 input/change 事件，不模拟键盘；各框架以自身地址分别申请凭据 |
| 保存 / 更新提示 | 提交登录表单 | 新凭据提示保存，同用户名不同密码提示更新；密码只暂存在 `chrome.storage.session`（内存） |
| 两步验证码 | 填充时自动 / 弹窗「验证码」 | 页面有验证码输入框时直接填入，否则复制到剪贴板 |

## 权限说明（上架审核用）

| 权限 | 用途 |
|---|---|
| `nativeMessaging` | 与本机 VaultOne 桌面端通信 |
| `storage` | 保存配对密钥（local）与待确认的保存提示（session，内存） |
| `activeTab` / `http(s)://*/*` 主机权限 | 在网页中识别登录表单并填充 |
| `clipboardWrite` | 复制两步验证码 |

## 测试

```sh
node --test extension/test/protocol.test.mjs   # 配对码 / MAC 与 Rust 实现的交叉向量
```

协议实现的单元测试在 `crates/vault-core/src/browser.rs`，真实套接字 + 宿主转发的端到端测试在 `app/rust/src/api/browser.rs`。
