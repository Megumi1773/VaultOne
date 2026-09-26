# VaultOne

> **明文、主密码、Secret Key 永不离开你的设备。** 服务端只是一堆读不懂的密文块和版本号。
> 一个把「零知识」二字当真的密码保险库——Rust 密码学内核 + Flutter 多端 UI + 可自托管同步服务，全部开源。

[![CI](https://github.com/Megumi1773/VaultOne/actions/workflows/ci.yml/badge.svg)](https://github.com/Megumi1773/VaultOne/actions/workflows/ci.yml)
![Rust](https://img.shields.io/badge/rust-1.85%2B-orange)
![Flutter](https://img.shields.io/badge/flutter-3.47.5-blue)
![Tests](https://img.shields.io/badge/tests-79%20passed-success)
![License](https://img.shields.io/badge/license-AGPL--3.0--only-green)

## 凭什么值得一看

大多数「E2EE 密码管理器」只是把整条记录加密后丢给服务器，冲突了**整条后写覆盖**，你另一台设备上改的字段就这么悄无声息地没了。VaultOne 不干这事：

- **字段级三方合并，离线冲突不丢数据。** 为每个条目维护「最后一次与服务端一致的密文」作为 base，冲突时在客户端内存里解密 base / local / remote 三份，**逐字段**三方合并——双方都改的字段取 `updated_at` 较新者，被覆盖的旧密码自动进 `passwordHistory`。服务端连明文都看不到，却能做到通用同步服务才有的合并粒度。
- **越权填充？先过匹配策略这一关。** 公共后缀判定复用 `psl`，自研的是**安全决策**：https 条目拒绝在 http 页面匹配（抗 SSL strip）、IP/单标签主机禁止放宽、未收录公共后缀不放宽、punycode 比较抵御西里尔字母 `а` 之类同形异义字、Exact > Host > Domain 打分排序。这是密码管理器真正该较真、也最容易搞砸的地方。
- **每条消息一把一次性子密钥，把 IV 生日界问题从根上删掉。** 每次加密随机 32 字节盐 + 12 字节 IV，经 HKDF 派生一次性消息密钥，版本/套件/盐/IV 全部纳入 GCM 认证头。相比「一把长期密钥 + 随机 96-bit IV」的方案，直接消除了 2³² 条消息后 IV 碰撞的概率界。
- **主密码 × Secret Key 双因子派生（2SKD），服务端拿到数据库也撬不开。** Argon2id（默认 64 MiB / t=3 / p=4，且硬编码安全下限拒绝任何降级），密钥全程 `mlock`/`VirtualLock` 锁定在受保护内存页，防换页、防核心转储；用后 `zeroize` 清零。
- **SRP-6a 认证——认证过程网络从不出现口令或口令等价物。** RFC 5054 3072-bit 群 + SHA-256，还附带设备批准与离线恢复套件。
- **密码学全在 Rust 内核，UI 层零密钥逻辑。** Flutter 只通过 `flutter_rust_bridge` 2 调用类型安全的异步 API，四端（Windows / macOS / Android / iOS）共用一套 Dart 代码，改一处对四处生效。

## 它到底覆盖了什么

| 能力 | 实现 |
|---|---|
| 零知识 E2EE 增量同步 | 客户端逐字段 AES-256-GCM 密封，服务端仅存密文 + 版本号 + 时间戳 |
| 字段级三方合并 | `crates/vault-core/src/merge.rs`（6 个单元测试 + e2e 双设备并发编辑验证） |
| 防钓鱼自动填充 | `crates/vault-core/src/urlmatch.rs`（7 个测试：`github.io` 私有后缀、SSL strip、同形异义字、IP 端口等） |
| 双因子密钥派生 | Argon2id + 32 字节随机盐 + Secret Key，受保护内存 |
| 认证 / 设备批准 / 恢复 | SRP-6a（RFC 5054 3072-bit）、登录/注册/设备批准/恢复全套 19 个 API 路由 |
| 随机密码 / 口令短语 | `passwords`（strict 模式、排除易混字符）+ EFF 7776 词大词表 |
| TOTP | RFC 6238，SHA1/256/512，`otpauth://` URI 解析，常量时间校验 |
| 安全审计 | zxcvbn 强度评估 + HIBP k-匿名泄露检测（客户端算 SHA-1 前缀，服务端无从得知完整密码） |
| 自托管服务端 | axum + SQLite（内测单机）/ PostgreSQL 16（生产），SQL 一套两用 |

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
| `crates/vault-crypto` | 加密原语编排：AES-256-GCM 密封盒、Argon2id、SRP-6a、Secret Key 解析、受保护内存（26 个测试） |
| `crates/vault-proto` | 协议类型与稳定错误码（客户端/服务端共享） |
| `crates/vault-core` | 保险库逻辑：建号/解锁/条目 CRUD、SQLite 真相源、增量同步、三方合并、URL 匹配、TOTP、安全审计（41 个测试） |
| `crates/vault-server` | axum HTTP 服务端，SQLite / PostgreSQL 双后端（10 个测试，含端到端全生命周期） |
| `app/` | Flutter 客户端；`app/rust` 为 FFI 桥 `vaultone_bridge`，`app/lib/src/rust/**` 为生成代码 |
| `deploy/` | Docker Compose + Caddy 反代自动 HTTPS + 配置样例 |
| `docs/` | 模块拆分与依赖选型说明 |
| `legacy/` | 旧实现（Dart UI + 旧 Rust core + Go 服务端），**不在构建中，仅作参考** |

## 快速开始

### 环境要求

- Rust 1.85+（edition 2021）
- Flutter 3.47.5（仅在构建客户端时需要）

### 构建与测试

```bash
cargo test --workspace          # 全量 79 项测试（e2e 自启 SQLite 临时库，无需外部服务）
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
- KDF 参数硬编码安全下限（OWASP 2024 最低建议 19 MiB / t=2），任何降级都会被拒绝。
- 测试使用低成本 KDF（`allow_test_kdf=true`），勿在测试中使用 recommended 参数（Argon2id 会很慢）。
- 根 `Cargo.toml` 的 `[profile.dev.package."*"] opt-level = 3` 是必需的，勿删。

## 供应链安全

CI（`.github/workflows/ci.yml`）在 push / PR 时执行：`cargo fmt` + `clippy`（`-D warnings`）+ 单元/端到端测试 + PostgreSQL 冒烟、`cargo-deny` 依赖审计、SBOM（Syft，SPDX）、Trivy 漏洞扫描（High/Critical 阻断）、Flutter analyze/test + 多平台构建。发布 tag 时额外构建服务端镜像并以 cosign 无密钥签名。

## 文档

- [模块拆分与依赖选型](docs/01-模块拆分与依赖选型.md)
- [AGENTS.md](AGENTS.md) — 开发约定与不变量

## 许可证

[AGPL-3.0-only](https://www.gnu.org/licenses/agpl-3.0.html)
