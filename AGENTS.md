# AGENTS.md

VaultOne：零知识、本地优先的密码保险库。Rust 工作区（加密内核 + 同步服务端）+ Flutter 壳（flutter_rust_bridge）。全仓库注释/文档用中文，沿用该风格。

## 目录边界

- `crates/` — 新实现，参与根工作区构建：
  - `vault-crypto` 加密原语（Argon2id / AES-256-GCM 密封盒 / SRP-6a / Secret Key 解析）
  - `vault-proto` 协议类型与稳定错误码
  - `vault-core` 保险库逻辑：建号/解锁/条目 CRUD、SQLite 真相源、增量同步、三方合并、URL 匹配、TOTP、安全审计
  - `vault-server` axum HTTP 服务端
  - `vault-nmhost` 浏览器扩展的 Native Messaging 宿主（只做 stdin/stdout ⇄ 本地套接字转发）
- `app/` — Flutter 客户端。`app/rust`（crate `vaultone_bridge`）是 FFI 桥；`app/lib/src/rust/**` 全是生成代码。Android 自动填充的原生部分在 `app/android/app/src/main/kotlin/com/vaultone/app/autofill/`，其 Flutter 界面是独立 Dart 入口 `autofillMain`（`lib/main.dart` → `lib/src/autofill/`）。
- `extension/` — Chrome / Edge MV3 扩展（纯 JS，无构建步骤）。协议在 `vault-core/src/browser.rs`，两端靠交叉向量测试对齐。
- `fuzz/` — cargo-fuzz 目标，**独立工作区**（需 nightly），不在根工作区内。
- `legacy/` — 旧实现（Dart UI + 旧 Rust core + Go 服务端），**不在构建中、无引用，勿改**。仅作 UI 参考来源，新 UI 已不再从它移植。

## 参考文档

- `docs/01-模块拆分与依赖选型.md` — **唯一与当前实现同步的架构文档**：模块划分、每个依赖的选型理由、自研代码的不可替代性。改依赖或模块边界时同步更新。
- `docs/09-passmgr功能对照与新版开发计划.md` — 功能对照与开发排期；`docs/11-计划执行与验收记录.md` 是实际执行与验收口径；`docs/10-服务端迁移契约基线.md` 是 Rust → Java 迁移的字节级契约。
- `docs/archive/` — 历史参考，**勿照搬方案**：
  - `App功能总览-重构基线.md` — 旧 passmgr 功能清单，只对照「要做哪些功能」；其 SECP256K1 / AES-CBC 等实现与本仓库无关。
  - `VaultOne-MVP开发计划书.md` — 立项计划书；Tauri / Go / 原生移动端选型与现状不符，不依照。
- 文档与代码冲突时**以代码为准**。

## 命令

- 全量测试：`cargo test --workspace`（156 项通过 / 3 ignored；e2e 自启 SQLite 临时库，无需外部服务；ignored 为需真实 PG/Redis 的迁移与并发用例）。若 `target/debug` 下的服务端 exe 正被占用，加 `--target-dir target/xxx` 换输出目录。
- 单 crate / 单测试：`cargo test -p vault-core` / `cargo test -p vault-core <name>`
- 根 `cargo build`/`cargo test` 只构建 `default-members`（5 个 crate），**不含 `app/rust`**；要带桥用 `--workspace` 或 `-p vaultone_bridge`。桥的套接字端到端测试会调用 `target/debug/vaultone-nmhost(.exe)`，未构建时跳过这一段。
- 覆盖率：`cargo llvm-cov -p vault-crypto --fail-under-lines 90`（CI 门禁）。
- Fuzz：`cargo +nightly fuzz run <target>`（`cargo +nightly fuzz list` 列出 6 个目标）。本机 `cargo` 若不是 rustup 代理，改用 `RUSTC=$(rustup which rustc --toolchain nightly) $(rustup which cargo --toolchain nightly) fuzz run …`；Windows 还需把 MSVC 的 `clang_rt.asan_dynamic-x86_64.dll` 所在目录加入 PATH。
- 扩展：`node --test extension/test/protocol.test.mjs`；加载方式见 `extension/README.md`。
- 服务端：`cargo run -p vault-server -- gen-secret` → 设 `VAULTONE_SERVER_SECRET` → `cargo run -p vault-server`；`-- check` 仅校验配置+DB 后退出。
- Flutter 命令必须在 `app/` 目录下执行。
- Flutter 静态检查用 **`dart analyze`**（`flutter analyze` 在含非 ASCII 的路径下会因 LSP JSON 编码崩溃，属工具缺陷，非代码问题）。
- 集成测试（真实 Rust 内核，需桌面设备）：`flutter test integration_test -d windows`；应用商店截图生成见 `integration_test/screenshots_test.dart` 顶部注释。
- Android 构建：Gradle 拒绝含非 ASCII 字符的路径，本仓库路径含中文 → 先 `subst V: <仓库路径>`，再在 `V:/app` 下 `flutter build apk`。cargokit 会为全部 ABI 编译 Rust，需 `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android`。
- Windows 构建会经 CMake 调 `cargo build --release -p vault-nmhost` 并把宿主放到 exe 旁；桌面端启动时自动在 HKCU 登记 Native Messaging 宿主（指向当前构建目录）。

## 代码生成（易踩）

- `app/lib/src/rust/**`（`frb_generated*.dart`、`api/*.dart`）由 flutter_rust_bridge 从 `app/rust/src/api/**` 生成，**不要手改**。改 Rust API 后在 `app/` 运行 `flutter_rust_bridge_codegen generate`（配置见 `app/flutter_rust_bridge.yaml`）。
- FRB 版本在两处精确锁定为 `=2.13.0`（`app/rust/Cargo.toml`、`app/pubspec.yaml`），必须保持一致。

## 服务端配置

- 分层加载：默认值 → `vaultone.toml`（或 `$VAULTONE_CONFIG`）→ 环境变量 `VAULTONE_*`（嵌套用 `__`）。
- `server_secret` **无默认值**，缺失即拒绝启动；用 `gen-secret` 生成 64 位十六进制。
- DB 用 `sqlx` Any 驱动（`sqlite:` 或 `postgres://`），迁移在启动时自动执行（`migrations/{sqlite,postgres}`）。代码用运行时 `sqlx::query`，**无编译期宏**，构建不需要 `DATABASE_URL`。
- 开发期邮件 `mail.mode=log` 写日志；`smtp` 走真实投递。

## 约定与不变量

- 零知识红线：服务端绝不接触明文 / 主密码 / Secret Key。邮箱为 HMAC 索引 + AES-GCM 密文，条目为客户端密封盒——改服务端时勿破坏。
- 测试用低成本 KDF：`AppState::new(..., allow_test_kdf=true)` 与测试专用 `KdfParams`；勿在测试里用 recommended 参数（Argon2id 会很慢）。
- 根 `Cargo.toml` 的 `[profile.dev.package."*"] opt-level = 3` 是必需的（否则 Argon2id 慢到不可用），勿删。
- rust-version 1.85 / edition 2021。
- 桌面外壳（托盘 / 全局快捷键 / 浏览器扩展通道）只在 `main.dart` 正式启动路径创建（`VaultOneApp(desktopShell: true)`）；集成测试不创建，避免抢占系统快捷键与命名管道。
- 同一进程可能有多个 Flutter 引擎（Android 自动填充界面），`open_vault` 对同一路径幂等、共用一个保险库实例。
- 浏览器扩展的开发期 ID 由 `extension/manifest.json` 的 `key` 固定为 `pginfajjjgcjmijmddppkbhejjjcealc`；商店 ID 要追加到 `vault_proto::browser_ipc::EXTENSION_IDS`。

## 当前状态（2026-09-30 核对）

- **Flutter UI 已接通并可构建**：`app/lib/src/{core,state,ui,autofill}` 约 8900 行（不含生成代码）。12 个页面：home / item_list / item_detail / item_editor / generator / security / settings / sign_in / unlock / onboarding / qr_scan / conflicts；另有 Android 自动填充界面。
- **验证命令（本机 2026-09-30 实测）**：`cargo test --workspace` 156 项通过、3 ignored；`cargo clippy --workspace --all-targets -D warnings` 无警告；`cargo fmt --all --check` 通过。`dart analyze`、`flutter test`、集成测试与 `node --test extension/test/protocol.test.mjs` 的最近结果见 [docs/11](docs/11-计划执行与验收记录.md)；`server/` 的 `mvnw verify` 需 Docker 跑 Testcontainers，本机无 Docker 时会失败。
- `app/rust/src/api/**` 暴露约 62 个 FRB 函数（vault / sync / tools / clipboard / logging / browser / conflicts），与 UI 侧 `core/api.dart` 已对齐。
- 服务端（Rust axum）19 个路由：auth（register / login start+finish / logout）、devices（self / verify / list / approve / revoke）、recovery（start / fetch / complete）、account（get / delete / credentials）、audit、sync（pull / push），另有 `healthz` / `readyz`。另有 `server/`：Java 21 + Spring Boot 4 的 S1 基础设施底座（**无协议业务**）。
- 已实现：E1 导出闭环（`.wljbak` 加密备份 + CSV + 导入，UI / 桥 / 内核全通）；E4 本机加密冲突记录与裁决（候选快照、完整行 CAS、推送屏障 + 比较/裁决页面 + FRB）；P1 导入（Chrome / Edge / Firefox / Bitwarden / LastPass / 1Password CSV + 1PIF，幂等去重）；桌面托盘 + 全局快捷键 Ctrl+Shift+Space；F-05 浏览器扩展（配对 + HMAC 认证 + 按页面严格匹配释放凭据 + 保存/更新提示 + TOTP）；F-05 Android AutofillService（填充 + 保存）。
- 有 CI（`ci.yml`：fmt + clippy + 测试 + 覆盖率门禁 + fuzz 冒烟 + 扩展测试与打包 + PG 冒烟 + cargo-deny + SBOM + Trivy + Flutter + 多平台构建，tag 时 cosign 签名镜像；`fuzz.yml`：每晚每目标 5 h，语料库跨次累积）；有 `docs/01`、`03`、`04`、`05`、`07`、`09`、`10`、`11`（`08` 已移除；历史文档在 `docs/archive/`）；有 `deploy/`；有 `store/screenshots`；有根 `LICENSE`（AGPL-3.0 全文）。
- **未完成**：iOS AutoFill Credential Provider 扩展（需在 Xcode 新增 App Extension target、App Group 共享保险库文件与钥匙串，无法在 Windows 上构建验证）；浏览器扩展与 Android 自动填充只做了构建 / 协议级验证，尚未在真实浏览器与真机上跑通；macOS 沙盒版无法写入浏览器的宿主清单目录（需 Developer ID 分发或额外 entitlement）；Java 服务端 S0（字节级契约与黄金向量已就绪）尚未全协议互通，S2–S5 迁移 / 切流未开始。

## 功能进度（对照 `docs/archive/App功能总览-重构基线.md`）

**进度标签：MVP 核心完成；SaaS 外围（通知 / 组织协作 / 积分社区）未开工。** 核对日期 2026-09-30。

已实现（按基线功能域）：

- §1 启动/登录/身份：注册、SRP 登录、设备验证（轮询批准）、账户解锁、私钥导入 / 本机与服务端恢复、引导、隐私同意、解锁页。
- §2–3 保险库核心：条目 CRUD、详情、编辑、生成器、收藏、回收站、搜索、TOTP（扫码 + 解析）、导入、本地安全审计、同步状态。主框架为侧栏分区（全部 / 收藏 / 登录 / 支付卡 / 笔记 / 身份 / 回收站 / 设置），**非基线的 4 Tab**。
- §4 密钥与备份：Secret Key 查看 / 显示、改主密码、恢复套件、导出（`.wljbak` / CSV）。备份卡图、二次确认未落地。
- §5 安全中心：安全评分、泄露检测（HIBP k-匿名）、弱密码 / 强度、生物识别、自动锁定、设备管理、自动填充引导、审计日志、改密、注销。
- §11 平台集成：浏览器扩展（MV3 + Native Messaging 宿主 + 配对）、Android AutofillService、托盘 + 全局快捷键、生物识别、扫码、安全剪贴板、隐私遮罩。

未实现（基线有、代码无）：

- §6 通知系统、§7 组织 / 协作 / 工作区、§9 积分 / 签到 / 邀请 / 商城、§8.5 意见反馈、§8.7 应用内更新：相关关键字全仓 0 命中，**服务端连路由都没有**。
- §3.3 条目模板、§3.6 分组 / 分类 / 标签及子列表。
- §12 的 66 路由未逐页实现：当前为 phase 路由（loading / onboarding / locked / unlocked / error）+ 12 个 Screen。

建议优先级：

- **P0 收口**：iOS AutoFill 扩展；浏览器扩展与 Android 填充的真实环境验证；E1 / E4 的真实跨端与 PG 综合验收。
- **P1 核心体验**：条目模板、分组 / 分类 / 标签、备份卡图 + PDF 与二次确认。
- **P2 SaaS 外围**：通知、组织协作、积分社区、意见反馈、应用内更新（需先补服务端路由）。
