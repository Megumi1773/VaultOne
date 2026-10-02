# AGENTS.md

VaultOne：零知识、本地优先的密码保险库。Rust 工作区（加密内核 + 同步服务端）+ Flutter 壳（flutter_rust_bridge）。全仓库注释/文档用中文，沿用该风格。

## 目录边界

- `crates/` — 新实现，参与根工作区构建：
  - `vault-crypto` 加密原语（Argon2id / AES-256-GCM 密封盒 / SRP-6a / Secret Key 解析）
  - `vault-proto` 协议类型与稳定错误码
  - `vault-core` 保险库逻辑：建号/解锁/条目 CRUD、SQLite 真相源、增量同步、三方合并、URL 匹配、TOTP、安全审计
  - `vault-server` axum HTTP 服务端
  - `vault-nmhost` 浏览器扩展的 Native Messaging 宿主（只做 stdin/stdout ⇄ 本地套接字转发）
- `server/` — Java 21 / Spring Boot 4 后端，独立 Maven 工程；**自 2026-10-01 起作为后续开发的基准后端，新功能与缺失服务能力只在 Java 侧补齐，不再扩展 Rust 服务端。** 兼容当前客户端协议，按后文工程规范实施；保留 Rust 服务端现有代码，不自动退役、接管旧库或切换生产。
- `app/` — Flutter 客户端。`app/rust`（crate `vaultone_bridge`）是 FFI 桥；`app/lib/src/rust/**` 全是生成代码。Android 自动填充的原生部分在 `app/android/app/src/main/kotlin/com/vaultone/app/autofill/`，其 Flutter 界面是独立 Dart 入口 `autofillMain`（`lib/main.dart` → `lib/src/autofill/`）。
- `extension/` — Chrome / Edge MV3 扩展（纯 JS，无构建步骤）。协议在 `vault-core/src/browser.rs`，两端靠交叉向量测试对齐。
- `fuzz/` — cargo-fuzz 目标，**独立工作区**（需 nightly），不在根工作区内。
- `legacy/` — 旧实现（Dart UI + 旧 Rust core + Go 服务端），**不在构建中、无引用，勿改**。仅作 UI 参考来源，新 UI 已不再从它移植。

## 参考文档

- `docs/01-模块拆分与依赖选型.md` — **唯一与当前实现同步的架构文档**：模块划分、每个依赖的选型理由、自研代码的不可替代性。改依赖或模块边界时同步更新。
- `docs/09-功能实现状态对照.md` — **功能进度的唯一口径**：按基线章节逐条给出已实现 / 部分 / 缺失，只描述实际代码。`docs/11-计划执行与验收记录.md` 是执行与验收证据。
- `docs/archive/` — 历史参考，**勿据以判断当前实现**：
  - `App功能总览-重构基线.md` — 旧 passmgr 功能清单，只对照「要做哪些功能」；其 SECP256K1 / AES-CBC 等实现与本仓库无关。
  - `09-开发计划与排期-已归档.md` — 原 09 的开发包编号（E1–E12 / G1–G5）与 Java 目标方案，已被实现取代。
  - `10-S0服务端迁移契约基线-已归档.md` — 旧基线时刻的协议快照；字节级细节仍可参考，结论已过时。
  - `VaultOne-MVP开发计划书.md` — 立项计划书；Tauri / Go / 原生移动端选型与现状不符，不依照。
- 文档与代码冲突时**以代码为准**。

## 命令

- 全量测试：`cargo test --locked --workspace`（2026-10-02 实测 179 项通过 / 0 失败 / 9 ignored；e2e 自启 SQLite 临时库，无需外部服务；ignored 为需真实 PG/Redis 或真实 Java 服务端的用例）。若 `target/debug` 下的服务端 exe 正被占用，加 `--target-dir target/xxx` 换输出目录。
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
- **Windows 桌面构建（含 cargokit）同样必须走 `subst`**：`subst V: <仓库路径>` 后在 `V:/app` 下 `flutter run -d windows` / `flutter build windows`。原因：`app/rust_builder/cargokit/run_build_tool.cmd` 用批处理 `echo` 把 `build_tool` 的绝对路径写进临时 `pubspec.yaml`，控制台代码页会把中文路径写成乱码（`CC密码箱` → `CC������`），`dart pub get` 随即失败、`vaultone_bridge.dll` 不产出，CMake 的 INSTALL 步骤报 `file INSTALL cannot find .../vaultone_bridge.dll`。**该临时目录会跨 `flutter clean` 存活**，一旦生成了坏路径会持续污染后续构建，须删掉 `app/build/windows/x64/plugins/vaultone_bridge/` 后重建。`V:` 映射重启后失效。
- 若 `flutter clean` 后出现 `cpp_client_wrapper/*.cc: No such file or directory`，删除 `app/windows/flutter/ephemeral/` 让工具链重新生成（`flutter pub get` 不会补回这些源码，只有 CMake configure 阶段会）。
- `printing` 插件在 CMake 阶段要从 GitHub 下载预编译 pdfium（`github.com/bblanchon/pdfium-binaries`）。网络不通时构建会卡在 `Build step for pdfium failed`；若 `app/build/windows/x64/pdfium-src/` 已完整（含 `bin/pdfium.dll`、`lib/pdfium.dll.lib`、`include/fpdfview.h`），刷新 `pdfium-download-prefix/src/pdfium-download-stamp/Debug/` 下的 stamp 文件即可跳过复验，不必重新下载。
- Windows 构建会经 CMake 调 `cargo build --release -p vault-nmhost` 并把宿主放到 exe 旁；桌面端启动时自动在 HKCU 登记 Native Messaging 宿主（指向当前构建目录）。
- 桌面端启动后可能**隐藏到托盘**（`desktop_shell.dart` 关闭时 `windowManager.hide()`），窗口可见但 `MainWindowHandle` 为 0 属正常，托盘图标可唤出。

## 文档与文本编辑（易踩）

- **不要用 `Set-Content -Raw` / `Out-File` 重写含中文的文件**：本机 PowerShell 5.1 以默认 ANSI 读取原始文件再以 UTF-8 写出，会静默丢字（曾把 `应用商店` 写成 `用用商店`、`删除会话` 写成 `删 会话`）。改文档一律用 `edit` 工具做定点替换；确需脚本改写时用 Python 且显式 `encoding="utf-8"`，改完 `git diff` 复核。
- 同理，`git checkout -- <file>` 可用来恢复被写坏的工作区文件（未提交内容会丢失），恢复后务必核对关键词是否复原。

## 代码生成（易踩）

- `app/lib/src/rust/**`（`frb_generated*.dart`、`api/*.dart`）由 flutter_rust_bridge 从 `app/rust/src/api/**` 生成，**不要手改**。改 Rust API 后在 `app/` 运行 `flutter_rust_bridge_codegen generate`（配置见 `app/flutter_rust_bridge.yaml`）。
- FRB 版本在两处精确锁定为 `=2.13.0`（`app/rust/Cargo.toml`、`app/pubspec.yaml`），必须保持一致。

## Rust 服务端配置（既有实现）

- 分层加载：默认值 → `vaultone.toml`（或 `$VAULTONE_CONFIG`）→ 环境变量 `VAULTONE_*`（嵌套用 `__`）。
- `server_secret` **无默认值**，缺失即拒绝启动；用 `gen-secret` 生成 64 位十六进制。
- DB 用 `sqlx` Any 驱动（`sqlite:` 或 `postgres://`），迁移在启动时自动执行（`migrations/{sqlite,postgres}`）。代码用运行时 `sqlx::query`，**无编译期宏**，构建不需要 `DATABASE_URL`。
- 开发期邮件 `mail.mode=log` 写日志；`smtp` 走真实投递。

## Java 后端工程规范（2026-09-30 决策）

以下是新开发的强制约束，不是已实现或已验收声明；与旧计划的目标方案冲突时以本节为准。现有协议事实仍以代码及交叉测试为准。`AGENTS.md` 与 `CLAUDE.md` 本节须同步维护。

### 协作、范围与可维护性

- 主代理负责需求澄清、架构决策、任务边界、代码审查和最终验收；开发实现优先委派 OpenCode，OpenCode 不可用时主代理直接接手，不能因工具故障停止推进。网页检索由 OpenCode 执行。委派不转移质量责任，必须核验实际 diff 和测试，不能直接转述“已完成”。
- 持续目标按 [docs/09 功能实现状态对照](docs/09-功能实现状态对照.md) 推进：优先补「未实现」中 P0/P1 项，逐项更新该文档与 `docs/11` 的真实进度；外部环境和生产授权阻塞单独记录，不把待验收项目记为完成。
- 优先官方脚手架、成熟组件和已选技术栈；不以“大厂规范”为由增加无业务收益的微服务、接口层、通用框架或中间件。每个组件必须有明确用途、负责人可理解的边界和故障策略。
- Java 采用按业务域组织的模块化单体，域内区分 controller / dto / service / model / repository；公共能力集中于 config / security / crypto / common。Controller 不写 SQL、密码运算或事务；Repository 不决定 HTTP 响应；Entity 不出现在 API 返回体。
- 使用构造器注入、明确类型和简短方法；禁止万能 Service、巨大工具类、裸 Map 贯穿业务、魔法数字、吞异常和无意义接口。敏感 record/Entity 禁止自动输出字段的 toString；集合和数组须控制可变性。
- 每个需求明确成功、失败、空态、取消、重试、权限及数据保留语义；先交付可验收闭环，不用空接口、TODO 或前端假数据宣称完成。功能新增不顺手重写无关模块。

### 配置与环境

- Java 统一采用 `application.yaml`、`application-dev.yaml`、`application-prod.yaml`：公共默认只放与环境无关的结构性配置，环境文件提供该环境的全部具体值。**配置值直接内联在 YAML（2026-10-01 决策），不再使用 `${ENV:default}` 占位**；默认环境由根 YAML 的 `spring.profiles.active: dev` 声明，生产必须显式覆盖为 prod，dev/prod 不可同时激活。`YamlConfigRegressionTest` 有"禁止占位回流"与"公共层不得含环境值"两条门禁；缺关键配置时由 `DeploymentGuard` 在连接池创建前拒绝启动。
- 配置以 `@ConfigurationProperties` 分组并校验，避免散落 `@Value`。端口、超时、连接池、限额、TTL、日志保留参数可配置且有单位及合理上界；未知/缺失的关键安全配置启动即失败。
- 本机开发库与凭据（独立库 `vaultone_java_dev`、`vaultone_java_migrator` / `vaultone_java_runtime`、回环 Redis）内联在 YAML；不得指向 Rust 服务端在用的 `vaultone` 库，也不得使用本机管理角色。生产用 `CHANGE_ME_*` 占位并必须在部署前替换，生产密钥不得与 dev 相同；生产禁止测试 KDF、固定 OTP、开发邮件明文日志及宽松 TLS。dev 默认回环规则可按后文“真机联调例外”显式放行私网 API，但不能因切换 profile 绕过零知识和数据库安全约束。
- 使用 Java 21 SDK；本机优先已有 `.jdks`，以 IDEA 项目 SDK 或进程级 JAVA_HOME 指定，不擅改全局环境。开发优先使用用户已提供的本机 PostgreSQL/Redis，不自动另起 Docker 数据服务。

### Redis 会话、缓存与协调

- **Java 会话主存采用 Redis，而非逐请求读写 PG sessions 表。** 保留现有非 JWT Bearer 线协议；只使用 `SHA-256(token UTF-8)` 摘要索引，Redis 与日志均不得保存原始 Token。
- 会话元数据含账户/设备关联、签发/过期时间及必要的撤销代次；统一管理 TTL、节流滑动续期、退出、单设备撤销、全账户失效和并发刷新。续期不得重建已删除会话；过期边界与客户端兼容；索引随主键过期/清理，不产生无限集合。
- 设备权限、账户状态、凭据代次和恢复凭据仍以 PG 为持久真相源。恢复/撤销与会话签发的竞争必须闭合；敏感操作不能只相信过期缓存。PG/Redis 双存储不假装具有单事务，必须定义提交失败、补偿、重试与恢复策略并测试。
- Redis 故障时受保护接口安全拒绝，不自动回退旧 PG 会话并复活失效令牌；不影响客户端合法本地解锁。Redis 数据丢失及恢复旧快照必须有重新登录或代次校验策略。旧 PG 会话迁移单独设计、校验和演练，不做长期双写。
- 缓存仅存可重建、经白名单批准的非敏感元数据，按环境/业务/账户隔离命名，版本化格式，设置容量与带抖动 TTL；定义更新后失效、防穿透/击穿和故障降级。会话存储、业务缓存、分布式协调须分清职责。
- 禁止缓存保险库条目及其密文、密钥信封、恢复包、邮箱密文、验证码原文、SRP 临时私值；禁止 JPA 二级缓存自动复制敏感实体。权限缓存必须有可验证的立即失效机制，不能用短 TTL 冒充撤销即时生效。
- 仅使用一个受控 RedissonClient；连接池、线程、命令超时与重试有界。分布式锁仅用于确需跨实例互斥的任务，有限 wait/lease、同线程释放；数据库 CAS/唯一约束或 fencing 才是最终正确性边界。禁止把锁加到所有 CRUD，或依赖无限 watchdog。

### API 契约与异常

- API 先定义契约再实现：字段命名、nullable、分页、时间、枚举、版本和幂等语义统一记录并测试。**已有 `/v1` 成功 DTO/数组保持兼容，禁止通过全局 ResponseBodyAdvice 突然套壳**；新增或破坏性契约需显式版本化及客户端迁移测试。
- 统一错误模型与集中异常转换，Security、MVC、参数校验采用同一稳定错误码目录；区分参数错误、未认证、未授权、不存在、冲突、限流、依赖暂不可用和内部故障。HTTP 状态与含义一致，禁止所有异常返回 200 或全转成“操作失败”。
- 业务异常返回明确、安全、可执行的提示；客户端按 code 分支，不解析 message。认证防枚举场景有意保持一致，不能为了“具体”暴露账户存在、验证码匹配情况或内部权限细节。
- 系统异常不返回异常类名、堆栈、SQL、地址、配置和依赖原始消息；返回约定安全提示及请求关联标识，完整诊断留服务端。既有错误码不能私自重新定义；新增字段/错误码须证明旧客户端兼容。
- 全局请求关联 ID 长度/字符受限，不盲信外部头；贯穿响应头、日志和审计。请求大小、JSON 深度、批量数、分页、SRP 并发及超时有界；拒绝请求也要有合理响应与可观察结果。

### 日志、操作审计与隐私

- 区分运行日志、用户安全操作审计和 Envers 元数据修订，三者不能互相冒充。操作审计记录最小 actor/账户范围、操作类型、对象类别、成功/失败、敏感等级、UTC 时间与请求 ID，不记录对象内容。
- 操作敏感等级固定为低/中/高并按事件目录维护；改密、恢复、设备授权/撤销、导出和注销属于重点审计。客户端本地行为不伪称服务端可见；新增上报只传最小动作元数据，不传恢复材料或条目。
- 运行日志使用 SLF4J/Logback 的参数化、结构化白名单字段，控制台便于开发阅读，生产文件按时间+大小轮转、压缩，限制总容量及保留期；日志目录不被 Web 暴露，持有者权限受限。
- 正常关键事件 INFO，可预期业务拒绝按需 WARN/计数，意外系统故障 ERROR 并在边界记录一次诊断。禁止每层重复打印堆栈、每条同步内容刷屏、无上界 DEBUG 或将所有 4xx 当服务器故障；高频事件采样但不能漏掉要求持久留存的安全审计。
- 禁止输出 Authorization/Cookie、密码、Secret Key、Vault Key、AuthKey、OTP、完整邮箱/请求响应体、SQL 绑定值和密文包。异常文本、MDC、第三方客户端、邮件与日志换行注入同样纳入脱敏测试；仅靠正则遮罩不是白名单的替代。
- 成功审计与业务提交一致，失败审计不随失败业务回滚而丢失；邮件和外部投递在提交后执行，关键事件采用可重试 outbox。明确日志/审计归档、访问权限、注销清理及法定保留策略，不无限保留。

### 数据、质量与发布门禁

- PG 事务负责持久一致性；短事务、账户范围查询、条件更新检查影响行数；禁止无条件批量 DML。同步 cursor、协议 revision、内部乐观锁和 Envers revision 分离，同账户提交顺序不得被序列预分配破坏。
- Flyway 是 schema 唯一变更入口，DDL validate、OSIV=false，迁移与运行角色隔离；RLS 在真实非超级用户/非 owner 角色下验证，事务级账户上下文不得串连接。禁止将开发管理员身份当作生产权限方案。
- 验收包括低成本单测、架构/格式、真实 Jetty、真实 PG/Redis、Rust 生产客户端互通与并发/故障路径。默认 CI 可用 Testcontainers，本机可显式选真实本地服务；禁止以 H2、Mock Redis、skip 或环境缺失提前 return 伪装成功。
- 本机测试使用显式授权的独立测试库/schema、随机 Redis 前缀；只清理本次创建资源，禁止 FLUSHDB/FLUSHALL、清空用户库或在业务库直接试迁移。缺连接凭据时报告阻塞，不能猜密码。
- 每次交付同步架构与验收记录，区分“实现”“本机通过”“跨端通过”“生产验收”；不以编译通过宣称迁移完成。提交、推送、接管旧库、生产切流和破坏性操作需明确授权；保留单一生产写入者及不丢新写入的回滚方案。

## 约定与不变量

- **2026-10-01 真机联调例外**：dev 可显式 `vaultone.development.allow-lan: true` 并绑定 `0.0.0.0`/RFC1918 IPv4，仅允许真实回环/私网对端；PG/Redis 仍回环、非回环监听禁止测试 KDF，prod 禁止该开关。客户端仅 Debug + `VAULTONE_ALLOW_LAN_HTTP=true` 允许已选定的私网 HTTP 端点，Release/Profile 不启用；Android/iOS 使用 Debug 专属配置。只用于可信局域网和测试账户，详见 docs/14。
- **2026-10-01 云账户模式决策**：注册、登录、设备验证、恢复、改密、退出及在线业务直接连接 Java；不再提供纯本地建号或可选关闭云同步。条目继续本地优先、离线读写、密文增量同步；已登录设备本机解锁不依赖网络。旧本地库引导显式接入，不自动删除；旧服务器绑定必须经同账户认证才换绑。开发默认 `http://127.0.0.1:9777`，发布启动要求显式 HTTPS 地址。详见 docs/13 与 docs/11 §9。

- 零知识红线：服务端绝不接触明文 / 主密码 / Secret Key。邮箱为 HMAC 索引 + AES-GCM 密文，条目为客户端密封盒——改服务端时勿破坏。
- 测试用低成本 KDF：`AppState::new(..., allow_test_kdf=true)` 与测试专用 `KdfParams`；勿在测试里用 recommended 参数（Argon2id 会很慢）。
- 根 `Cargo.toml` 的 `[profile.dev.package."*"] opt-level = 3` 是必需的（否则 Argon2id 慢到不可用），勿删。
- rust-version 1.85 / edition 2021。
- 桌面外壳（托盘 / 全局快捷键 / 浏览器扩展通道）只在 `main.dart` 正式启动路径创建（`VaultOneApp(desktopShell: true)`）；集成测试不创建，避免抢占系统快捷键与命名管道。
- 同一进程可能有多个 Flutter 引擎（Android 自动填充界面），`open_vault` 对同一路径幂等、共用一个保险库实例。
- 浏览器扩展的开发期 ID 由 `extension/manifest.json` 的 `key` 固定为 `pginfajjjgcjmijmddppkbhejjjcealc`；商店 ID 要追加到 `vault_proto::browser_ipc::EXTENSION_IDS`。

## 当前状态（2026-10-02 实测）

- **Flutter UI 已接通并可构建**：`app/lib/src/{core,state,ui,autofill}` 约 10600 行（不含生成代码）。15 个页面文件：backup_dialog / cloud_setup / conflicts / feedback / generator / home / item_detail / item_editor / item_list / onboarding / qr_scan / security / settings / sign_in / unlock；另有 Android 自动填充独立界面。
- **本机实测（2026-10-02）**：`cargo test --locked --workspace` **179 通过 / 0 失败 / 9 ignored**；`cargo clippy --workspace --all-targets -D warnings` 与 `cargo fmt --all --check` 通过；`app/` 下 `dart analyze` 无问题、`flutter test --no-pub` **124 通过**；`node --test extension/test/protocol.test.mjs` 2 通过。`server/` external 模式 `clean verify` **117 单测 + 42 真实 PG/Redis/Jetty IT 全绿**（含 `BackendContractIT` 真实 Rust 客户端互通）；**该验收需本机 PG/Redis，当前不可复跑（PG 未运行、Redis 未安装），见 docs/11 §16.5**。详见 [docs/11](docs/11-计划执行与验收记录.md)。
- `app/rust/src/api/**` 暴露约 79 个 FRB 函数（vault / sync / tools / clipboard / logging / browser / conflicts / cloud_account / feedback），与 UI 侧 `core/api.dart` 已对齐。
- 服务端：Rust axum 保留（不再新增功能）；Java 21 + Spring Boot 4 已实现 19 个 `/v1` 端点 + `/healthz`、`/readyz`，Redis 会话主存、PG RLS + Envers 白名单、多环境 YAML 与安全门禁齐备。**未替换生产 Rust 服务端、未切流、未接管旧库。**
- 已实现：云账户模式（注册/SRP 登录/设备批准/恢复/改密/注销直连 Java）；导出闭环（`.wljbak` + CSV + 导入）；本机加密冲突记录与裁决（候选快照、完整行 CAS、推送屏障、比较/裁决页）；导入（Chrome / Edge / Firefox / Bitwarden / LastPass / 1Password CSV + 1PIF）；桌面托盘 + 全局快捷键；浏览器扩展（配对 + HMAC + 按页面严格匹配 + 保存/更新 + TOTP）；Android AutofillService（填充 + 保存）；E11 首批文本反馈（Java 提交/历史/详情 + CLI 回复 + Rust/FRB/Flutter 接线）。
- 有 CI（`ci.yml`：fmt + clippy + 测试 + 覆盖率门禁 + fuzz 冒烟 + 扩展测试与打包 + PG 冒烟 + cargo-deny + SBOM + Trivy + Flutter + 多平台构建，以及 Java `mvnw verify`；`fuzz.yml`：每晚每目标 5 h）；有 `deploy/`、`store/screenshots`、根 `LICENSE`（AGPL-3.0）。
- **未完成 / 未验收**：iOS AutoFill Credential Provider 扩展（需 Xcode App Extension target，Windows 无法构建）；浏览器扩展与 Android 自动填充只有协议级/编译级验证，未真机跑通；macOS 沙盒写不了浏览器宿主清单目录；Java 容器路径、旧库接管、稳定性演练与生产切流/回滚未验收。

## 功能进度

> **详细逐条状态见 [docs/09-功能实现状态对照](docs/09-功能实现状态对照.md)**，本处只列概要。最近核对 2026-10-02（见 docs/11 §12–§13），判定以代码为准。

**已完成（主要调用链完整）**：身份主线（注册/SRP 登录/设备批准/恢复/改密/注销/生物识别解锁/审计日志）；条目 CRUD 与详情编辑（四类条目、自定义字段、TOTP、多 URL 匹配、标签与层级分类）；冲突处理与离线优先；导入导出（CSV/1PIF/`.wljbak`）；安全评分与 HIBP 泄露检测；**安全体检（§5.2：六维封顶评分、发现项、忽略、环境探测）**；浏览器扩展与 Android 自动填充（未真机验收）；Java 身份/同步/反馈服务端。

**未实现**：

- **国际化**（简中/繁中/英文）：基础已就绪（`l10n/strings.dart` 文案表 + `LocaleScope` + 设置页三语切换 + 持久化）。**全部客户端界面已迁移**，含 Android 自动填充独立界面、托盘菜单、生物识别系统弹窗，以及按语言渲染的恢复套件 PDF 与备份卡图（内嵌简中/繁中两套字体子集）；`ItemKind` / `UrlMatch` / `ConflictField` / `FeedbackCategory` / `FeedbackStatus` / `Strength` 等枚举标签改为引用文案表常量。内核与状态层构造的提示在显示点统一取词，未登记原文原样回退。三道门禁已接入 CI：`tools/check_l10n.py`、`tools/check_duplicates.py`、`tools/check_fonts.py`。docs/09 记为「部分」（繁中/英文为自译，未经母语审校）。
- **账户级锁定与封禁**（§1.6/§1.7）、**密钥升级**（§1.8）：客户端、内核、Java 三层零命中。
- **安全体检系统**（§5.2）：**已实现**。内核 `vault-core/src/health.rs` 为纯函数体检引擎（六维封顶扣分、0–100 总分、24h 时效、Finding 统一模型、snooze、环境探测），界面消费报告；未覆盖非 Windows 平台的环境探测。**§5.1 安全总览**（任务清单与宫格入口）仍缺失。
- **组织检索**（§3.6）：**多标签与层级分类已实现**（内核 `ItemData.tags`/`category` + 规范化 + 三方合并/冲突 + CSV 导入导出 + 编辑器输入 + 侧栏分类树 + 列表筛选 + 详情展示）；**分类即层级路径、分类树从条目派生**（零协议改动、天然多设备一致），代价是无空分类、无分组级元数据。**独立子列表页仍缺失**。§3.11 排序缺失（后代计数已实现）；条目模板（§3.3）已实现。
- **密钥与备份**：云端备份历史与备份上报失败提示（Java 无端点）、私钥更换。备份卡图、字节级二次确认与备份状态已实现。
- **导入预览 / 字段映射 / 覆盖策略 / 导入导出历史**；**动态 date/image 字段**。
- **账户资料**（§8.1/§8.2 昵称/头像/手机/邀请码）、**邮箱手机绑定**（§5.7）、**剪贴板与截图保护开关**（§8.3）。
- **SaaS 外围**：§6 通知与弹窗、§8.7 应用内更新、§9 积分/签到/邀请/商城（Java 侧零实现）；§8.5 反馈的图片附件与多轮线程。
- **平台**：iOS Credential Provider；相册保存与系统分享。

**已排除**：§7 组织 / 协作 / 工作区 / 密钥信封（E9），不计欠账。**替代**：四 Tab → 桌面侧栏分区、手机底部导航（保险库/生成器/安全/设置）；66 路由不逐页对照。

**建议优先级**：

- **P0 收口**：iOS AutoFill 扩展；浏览器扩展与 Android 填充的真机验证；E1 / E4 真实跨端与 PG 综合验收。
- **P1 核心体验**：独立子列表页（§3.6 剩余部分）；§3.11 自定义排序。
- **P2 账户与资料**：账户总览与资料编辑（§8.1/§8.2）、联系方式绑定（§5.7）、安全总览（§5.1）。
- **P3 SaaS 外围**：通知（§6）、应用内更新（§8.7）、反馈附件与线程、积分社区（§9）。
