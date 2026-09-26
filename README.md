# VaultOne

> 零知识、本地优先的密码保险库。明文、主密码、Secret Key 永不离开设备——服务端只接触不可解析的密文块。

[![CI](https://github.com/Megumi1773/VaultOne/actions/workflows/ci.yml/badge.svg)](https://github.com/Megumi1773/VaultOne/actions/workflows/ci.yml)
![Rust](https://img.shields.io/badge/rust-1.85%2B-orange)
![Flutter](https://img.shields.io/badge/flutter-3.47.5-blue)
![License](https://img.shields.io/badge/license-AGPL--3.0--only-green)

## 特性

- **零知识 E2EE 同步**：客户端逐字段 AES-256-GCM 密封，服务端仅存密文 + 版本号 + 时间戳，可自托管。
- **字段级三方合并**：两台设备离线并发编辑同一条目的不同字段，双方修改均保留，旧密码自动进入历史（`crates/vault-core/src/merge.rs`）。
- **双因子密钥派生**：主密码 × Secret Key（2SKD）经 Argon2id 派生；恢复套件可离线重建。
- **防钓鱼自动填充**：基于公共后缀列表的匹配策略，拒绝协议降级、punycode 同形异义字（`crates/vault-core/src/urlmatch.rs`）。
- **完整凭据工具**：随机密码 / 口令短语、TOTP（RFC 6238）、弱密码评估（zxcvbn）、HIBP 泄露检测。
- **一套 UI 覆盖 Windows / macOS / Android / iOS**，密码学全部在 Rust 内核，UI 层零密钥逻辑。

## 架构

```
┌──────────── 客户端（信任域：明文只在此存在） ────────────┐
│ Flutter UI  app/lib/src/{ui,state,core}                  │
│      │  flutter_rust_bridge 2（自动生成 app/lib/src/rust）│
│ vaultone_bridge  app/rust                                │
│      │                                                   │
│ vault-core ── 保险库 / SQLite 真相源 / 同步 / 三方合并    │
│ vault-crypto ── AES-256-GCM 密封盒 / Argon2id / SRP-6a   │
│ vault-proto ── 与服务端共享的线协议（仅密文与元数据）     │
└───────────────────────────┬──────────────────────────────┘
                            │ HTTPS（rustls）· 只传密文
┌───────────────────────────▼──────────────────────────────┐
│ vault-server（axum）：SRP-6a 认证 · 设备批准 · 增量同步   │
│ sqlx Any：SQLite（内测）或 PostgreSQL 16（生产）· Caddy   │
└──────────────────────────────────────────────────────────┘
```

## 目录结构

| 路径 | 说明 |
|---|---|
| `crates/vault-crypto` | 加密原语编排：AES-256-GCM 密封盒、Argon2id、SRP-6a、Secret Key 解析、受保护内存 |
| `crates/vault-proto` | 协议类型与稳定错误码（客户端/服务端共享） |
| `crates/vault-core` | 保险库逻辑：建号/解锁/条目 CRUD、SQLite 真相源、增量同步、三方合并、URL 匹配、TOTP、安全审计 |
| `crates/vault-server` | axum HTTP 服务端（SQLite / PostgreSQL） |
| `app/` | Flutter 客户端；`app/rust` 为 FFI 桥 `vaultone_bridge`，`app/lib/src/rust/**` 为生成代码 |
| `deploy/` | Docker Compose + Caddy 反代 + 配置样例 |
| `docs/` | 模块拆分与依赖选型说明 |
| `legacy/` | 旧实现（Dart UI + 旧 Rust core + Go 服务端），**不在构建中，仅作参考** |

## 快速开始

### 环境要求

- Rust 1.85+（edition 2021）
- Flutter 3.47.5（仅在构建客户端时需要）

### 构建与测试（Rust 工作区）

```bash
cargo test --workspace          # 全量测试（e2e 自启 SQLite 临时库，无需外部服务）
cargo test -p vault-core        # 单 crate
cargo test -p vault-core <name> # 单个测试
```

> 根 `cargo build` / `cargo test` 只构建 `default-members`（4 个 crate），不含 `app/rust`；要带桥用 `--workspace` 或 `-p vaultone_bridge`。

### 运行服务端

```bash
cargo run -p vault-server -- gen-secret   # 生成 server_secret（64 位十六进制）
export VAULTONE_SERVER_SECRET=<上一步输出>
cargo run -p vault-server                 # 启动
cargo run -p vault-server -- check        # 仅校验配置 + DB 后退出
```

配置分层加载：默认值 → `vaultone.toml`（或 `$VAULTONE_CONFIG`）→ 环境变量 `VAULTONE_*`（嵌套用 `__`）。详见 `deploy/vaultone.example.toml`。

### 构建 Flutter 客户端

```bash
cd app
flutter pub get
flutter run -d windows   # 或 macos / <android-device>
```

改动 Rust 侧 API 后，需在 `app/` 重新生成绑定：

```bash
flutter_rust_bridge_codegen generate   # 配置见 app/flutter_rust_bridge.yaml
```

> `app/lib/src/rust/**` 为生成代码，请勿手改。FRB 版本在两处精确锁定为 `=2.13.0`（`app/rust/Cargo.toml`、`app/pubspec.yaml`），必须一致。

## 安全不变量（勿破坏）

- 服务端绝不接触明文 / 主密码 / Secret Key。邮箱为 HMAC 索引 + AES-GCM 密文，条目为客户端密封盒。
- 每条消息使用随机盐 + 随机 IV 派生的一次性子密钥，头部纳入 GCM 认证，彻底规避 96-bit IV 生日界。
- 测试使用低成本 KDF（`allow_test_kdf=true`），勿在测试中使用 recommended 参数（Argon2id 会很慢）。
- 根 `Cargo.toml` 的 `[profile.dev.package."*"] opt-level = 3` 是必需的，勿删。

## 供应链安全

CI（`.github/workflows/ci.yml`）在 push / PR 时执行：`cargo fmt` + `clippy` + 单元/端到端测试 + PostgreSQL 冒烟、`cargo-deny` 审计、SBOM（Syft）、Trivy 漏洞扫描、Flutter analyze/test + 多平台构建。发布 tag 时额外构建服务端镜像并以 cosign 无密钥签名。

## 文档

- [模块拆分与依赖选型](docs/01-模块拆分与依赖选型.md)
- [AGENTS.md](AGENTS.md) — 开发约定与不变量

## 许可证

[AGPL-3.0-only](https://www.gnu.org/licenses/agpl-3.0.html)
