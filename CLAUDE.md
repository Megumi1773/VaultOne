# CLAUDE.md

VaultOne：零知识、本地优先的密码保险库。Rust 工作区（加密内核 + 同步服务端）+ Flutter 壳（flutter_rust_bridge）。全仓库注释/文档用中文，沿用该风格。

## 目录边界

- `crates/` — 新实现，参与根工作区构建：
  - `vault-crypto` 加密原语（Argon2id / AES-256-GCM 密封盒 / SRP-6a / Secret Key 解析）
  - `vault-proto` 协议类型与稳定错误码
  - `vault-core` 保险库逻辑：建号/解锁/条目 CRUD、SQLite 真相源、增量同步、三方合并、URL 匹配、TOTP、安全审计
  - `vault-server` axum HTTP 服务端
- `app/` — Flutter 客户端。`app/rust`（crate `vaultone_bridge`）是 FFI 桥；`app/lib/src/rust/**` 全是生成代码。
- `legacy/` — 旧实现（Dart UI + 旧 Rust core + Go 服务端），**不在构建中、无引用，勿改**。新的 Flutter UI 正从 `legacy/zeroone-app-ui/lib/src` 移植过来，可作参考来源。

## 参考文档（早于当前实现，勿照搬方案）

- `App功能总览-重构基线.md` — 整体功能清单（66 路由）。**只对照「要做哪些功能」，不采用其任何实现思路/方案**（它描述旧 passmgr 的 SECP256K1 / AES-CBC 等，与本仓库无关）。
- `VaultOne-MVP开发计划书.md` — MVP 方向参考；开发大体按其走但**不完全依照**（实际技术栈为 Flutter + Rust，而非计划书里的 Tauri / Go / 原生移动端）。
- 文档与代码冲突时**以代码为准**。

## 命令

- 全量测试：`cargo test --workspace`（约 79 项；e2e 自启 SQLite 临时库，无需外部服务）
- 单 crate / 单测试：`cargo test -p vault-core` / `cargo test -p vault-core <name>`
- 根 `cargo build`/`cargo test` 只构建 `default-members`（4 个 crate），**不含 `app/rust`**；要带桥用 `--workspace` 或 `-p vaultone_bridge`。
- 服务端：`cargo run -p vault-server -- gen-secret` → 设 `VAULTONE_SERVER_SECRET` → `cargo run -p vault-server`；`-- check` 仅校验配置+DB 后退出。
- Flutter 命令必须在 `app/` 目录下执行。

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

## 当前状态（勿误判）

- **Flutter UI 移植中，当前无法编译**：`app/lib/src/{core,state,ui}` 已从 `legacy/zeroone-app-ui` 拷入（约 5200 行），但接缝未打通——`core/ffi.dart` 缺失（被 `core/api.dart`、`state/app_state.dart` 引用）；`core/api.dart` 仍走旧 FFI 协议（`Core.call('open', …)`），**尚未改接新 FRB 绑定**；`pubspec.yaml` 缺 `file_selector` / `flutter_secure_storage` / `http` / `url_launcher`；`main.dart` 仍是模板，引用不存在的 `api/simple.dart`。
- `app/rust/src/api/**`（新 FRB 接口：`open_vault` / `create_account` / `list_items` …）与旧 UI 的 `Core.call` 方法名不同，两侧尚未对齐。
- 无 CI；无 `docs/`（`Cargo.toml:24` 注释引用的 `docs/01-模块拆分与依赖选型.md` 不存在）。
