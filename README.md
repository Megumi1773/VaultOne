# VaultOne

一个本地优先的密码管理器。加解密全在 Rust 内核里做,服务端只存密文,自托管也行。

多端 UI 用 Flutter 写一套,Windows / macOS / Android / iOS 都跑同一份 Dart 代码。密码学相关的逻辑一行都不在 Dart 里,全走 flutter_rust_bridge 调 Rust。

## 为什么自己做

现成的 E2EE 同步方案基本是整条记录加密后扔给服务器,冲突了整条覆盖。两台设备离线各改同一条记录的不同字段,总有一边的改动会被悄悄吃掉。这个事我们不接受,所以自己写了字段级的合并:每个条目存一份「上次和服务端一致的密文」当 base,冲突时本地把 base / local / remote 三份解密出来逐字段合,两边都改的字段取时间新的那个,被顶掉的旧密码进历史记录。服务端全程看不到明文。

另一个是自动填充的匹配。光知道域名注册域不够,得判断「这个页面到底能不能安全填这条凭据」。所以协议降级直接拒绝(https 的条目不会填到 http 页面上)、IP 和单标签主机不放宽匹配、west 里没收录的后缀也不放宽、punycode 比一遍防同形异义字。这块逻辑单独一个模块,有测试覆盖各种钓鱼场景。

## 加密这边

- 统一用 AES-256-GCM,每条消息随机 32 字节盐 + 12 字节 IV,过一遍 HKDF 派生出一次性的消息密钥。版本、套件、盐、IV 这些头信息都进 GCM 的认证范围。这样就没有「一把长期密钥配随机 96-bit IV」那个生日界问题了。
- 主密码要配合 Secret Key 一起派生密钥(2SKD),少一个都解不开。Argon2id 默认 64MiB / t=3 / p=4。
- 密钥放在 mlock / VirtualLock 锁住的内存页里,不进 swap;用完 zeroize 清掉。
- 认证走 SRP-6a(RFC 5054 3072-bit 群),口令不经过网络。设备批准和恢复套件也都有。

## 目录

```
crates/vault-crypto   加密原语编排:AES-256-GCM 密封盒、Argon2id、SRP-6a、Secret Key、受保护内存
crates/vault-proto    传输协议类型和错误码,客户端服务端共用
crates/vault-core     保险库逻辑:条目增删改查、SQLite、增量同步、三方合并、URL 匹配、TOTP、安全审计
crates/vault-server   axum 服务端,SQLite 或 PostgreSQL 都行
app/                  Flutter 客户端,app/rust 是 FFI 桥,app/lib/src/rust 是生成的绑定
deploy/               docker compose + Caddy + 配置样例
docs/                 模块和依赖选型的说明
legacy/               老实现,已经不参与构建了,留着参考
```

## 怎么跑

Rust 需要 1.85 以上,Flutter 用 3.47.5。

跑测试:

```bash
cargo test --workspace           # 全部,79 个;e2e 会自己起临时 SQLite,不用外部依赖
cargo test -p vault-core         # 只测某个 crate
cargo test -p vault-core <名字>  # 单个测试
```

注意根目录 `cargo build` / `cargo test` 只会构建 `default-members` 那四个 crate,不含 `app/rust`。要带上桥就加 `--workspace`,或者 `-p vaultone_bridge`。

起服务端:

```bash
cargo run -p vault-server -- gen-secret   # 生成 server_secret
export VAULTONE_SERVER_SECRET=<上面那串>
cargo run -p vault-server                 # 启动
cargo run -p vault-server -- check        # 只想验证配置和数据库,跑完就退
```

配置是分层的:默认值 → `vaultone.toml` → 环境变量 `VAULTONE_*`(嵌套用 `__`)。`deploy/vaultone.example.toml` 有完整例子。`server_secret` 没默认值,不给就起不来。

跑客户端:

```bash
cd app
flutter pub get
flutter run -d windows   # macos 或接个安卓机也行
```

改完 `app/rust` 里的 API,得重新生成绑定:

```bash
flutter_rust_bridge_codegen generate
```

`app/lib/src/rust/**` 都是生成出来的,别手改。FRB 版本在 `app/rust/Cargo.toml` 和 `app/pubspec.yaml` 里都锁死在 `=2.13.0`,改要一起改。

## 几个别踩的坑

- 服务端永远不碰明文、主密码、Secret Key。邮箱存的是 HMAC 索引加密文,条目是客户端那边封好的。
- KDF 参数写了安全下限,参数被改低了直接报错,别想着省事调小。
- 测试用低成本的 KDF 参数,别在测试里用 recommended,Argon2id 会慢到没法用。
- 根 `Cargo.toml` 里 `[profile.dev.package."*"] opt-level = 3` 是有原因的,删了 Argon2id 就废了。

## CI

push 和 PR 会跑 `cargo fmt`、`clippy`(警告当错误)、单测和 e2e、PostgreSQL 冒烟、`cargo-deny` 依赖审计、SBOM、Trivy 扫漏洞,还有 Flutter 的 analyze/test 和多平台构建。打 tag 的时候额外构建服务端镜像,用 cosign 签个名。都在 `.github/workflows/ci.yml`。

## 更多

- [模块拆分与依赖选型](docs/01-模块拆分与依赖选型.md) —— 每个依赖为什么选它
- [AGENTS.md](AGENTS.md) —— 开发约定

AGPL-3.0-only。
