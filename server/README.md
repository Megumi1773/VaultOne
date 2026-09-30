# VaultOne Java 服务端

Java 21 / Spring Boot 4 的零知识同步后端，兼容当前 Flutter + Rust 客户端的 `/v1` 协议。独立 Maven 工程，**没有替换生产 Rust 服务端，也不会自动接管已有数据库**。

注册、SRP 登录、设备批准/撤销、账户与凭据、恢复、审计、加密增量同步的实现已提交（`ec83b6a`）。2026-10-01 复核发现 external/容器 IT 启动被 `DeploymentGuard` 拒绝的测试夹具缺陷并已修复；修复后 external `verify` **BUILD SUCCESS**：单元/格式/架构 105 项 + 真实 PG/Redis/Jetty 集成 31 项全绿，含 `BackendContractIT`（真实 Rust 客户端互通）。容器路径由 CI 覆盖。详见 [docs/11 §7](../docs/11-计划执行与验收记录.md)。**本工程未替换生产 Rust 服务端，未切流，未接管已有数据库。**

## 1. 技术栈与模块

工程最初由 Spring Initializr 生成，保留官方 Maven Wrapper，不加入 Cargo 工作区。

| 组件 | 版本/来源 | 用途 |
|---|---|---|
| Java / Maven | Java 21；Wrapper 使用 Maven 3.9.16 | 不使用 preview 特性；不要求修改系统默认 Java |
| Spring Boot | 4.1.1 parent/BOM | MVC、Security、Validation、Actuator、Mail |
| Jetty | 12.1.12，Boot BOM | 嵌入式服务器、真实虚拟线程请求 |
| Hibernate / Envers | 7.4.5.Final，统一 Boot BOM | JPA、低频非敏感元数据修订 |
| PostgreSQL / Flyway | Boot BOM | 持久真相源、唯一 schema 变更入口 |
| Redisson | 4.7.0 | 单客户端、会话、展示缓存、分布式限流及维护锁 |
| Bouncy Castle | 1.86 | HKDF；AES-GCM/HMAC/SHA-256 复用 JCA |
| Expressly | 6.0.0 | Jakarta EL 实现，避免引入 Tomcat EL |
| 测试 | Testcontainers 2.0.5、ArchUnit 1.5.1 | 真实基础设施与架构边界 |
| 格式 | Spotless 3.10.3 / google-java-format 1.36.1 | Maven validate 门禁 |

不引入 WebFlux、Tomcat、Lettuce、Jedis、H2 或第二套 Redis 连接工厂。

`identity`、`account`、`sync`、`audit` 按业务域组织；`security`、`crypto`、`proto`、`validate`、`config`、`web`、`common` 承载横切能力。Controller 不访问数据库或进行密码运算，服务事务不得将 Entity 直接返回 HTTP。

架构与依赖理由见 [docs/01](../docs/01-模块拆分与依赖选型.md)，长期约束见根 [AGENTS.md](../AGENTS.md)。

## 2. 协议与数据边界

- 保留 `/v1` 注册、两阶段 SRP、退出、设备、账户、凭据更新、恢复、审计及同步接口，以及 `/healthz`、`/readyz`。成功 DTO/数组不新增全局 `data` 外壳。
- JSON 保留 snake_case、严格 STANDARD Base64、显式 null、lowercase 枚举和 Unix 秒整数；错误集中返回 `{code,message}`，关联编号在 `x-request-id`。
- 参数、认证、权限、冲突、限流、依赖故障与内部错误分开处理。系统异常不向客户端返回 SQL、堆栈、地址或原始异常文本；服务端使用白名单诊断字段。
- SRP 必须与 Rust 的 3072-bit / SHA-256、最短无符号整数及 M1/M2 证明格式互通；不是直接采用第三方库的默认 SRP 证明。黄金向量见 [docs/10](../docs/10-服务端迁移契约基线.md)。
- 服务端只处理不透明条目、密钥封装和恢复包，不获得主密码、Secret Key、Vault Key、AuthKey 或条目明文。邮箱仍为 HMAC 索引和服务端密封盒。
- 同步按账户锁串行提交，保留协议 revision、墓碑、精确重放及 `change_log.seq` 游标；不能用 Redis 锁、Envers revision 或 ORM 版本替代同步语义。

## 3. 会话、缓存与事务

- Redis 以 Token 文本的 SHA-256 摘要索引会话，只保存账户/设备关联、代次与时间元数据，不保存原始 Token。
- 创建与 TTL、续期与到期时间均原子处理；续期不重建删除键、不缩短有效期。按设备维护摘要索引，撤销定向、分批清理，不扫描全部账户会话。
- PG 的账户/设备状态、会话失效代次和持久注销标记仍是授权依据。敏感业务在自身事务中重验完整会话身份，不能只信请求开始时的快照；普通改密不会无故注销其他合法设备。
- 注册/恢复先准备 Redis 候选，再提交数据库状态，成功后交付会话；没有宣称 PG 与 Redis 是一个分布式事务。Redis 不可用时安全拒绝，不回源旧 PG sessions 复活令牌。
- 设备展示缓存不含 `current`，按请求设备映射；每次命中前仍验证当前 PG 权限。缓存短 TTL、容量有界、提交后失效，故障回源；它不负责授权。
- 成功审计与业务事务一致；失败审计独立处理。欢迎/安全通知等非关键邮件失败不能把已提交操作报告为回滚。**持久通知 outbox、归档和完整故障演练仍属后续发布门禁，当前不承诺通知必达。**

## 4. 多环境配置

| 文件 | 内容 |
|---|---|
| `application.yaml` | 与环境无关的结构性配置：连接池、TTL、请求预算、日志、限额、UTC 时区、优雅停机，以及默认环境声明 `spring.profiles.active: dev` |
| `application-dev.yaml` | 本机开发环境的全部具体值：回环数据服务（独立库 `vaultone_java_dev`）、开发密钥、Redis 地址与命名空间、`development.enabled=true` |
| `application-prod.yaml` | 生产环境的全部具体值：TLS 证书、SMTP、生产 PG/Redis、日志目录与待替换的 `CHANGE_ME_*` 凭据 |

配置项全部内联在 YAML，不从环境变量读取；`YamlConfigRegressionTest.sourceYamlKeepsEveryValueInline` 是禁止 `${...}` 占位回流的门禁。环境选择同样写在配置里：`application.yaml` 的 `spring.profiles.active: dev` 声明默认使用 dev，生产部署必须显式覆盖为 prod（`--spring.profiles.active=prod`）。公共 YAML 不承载任何可用连接或密钥，环境值只在环境文件里；`YamlConfigRegressionTest.commonYamlCarriesNoEnvironmentSpecificValues` 是该边界的门禁。dev/prod 不能同时使用，`DeploymentGuard` 在连接池创建前拒绝无 profile、缺密钥或降级配置的启动。生产密钥与口令以 `CHANGE_ME_*` 形式留在 `application-prod.yaml`，部署前必须替换为真实值，且生产密钥不得与 dev 相同。

默认端口 **9777**；测试使用随机端口。生产要求 Jetty TLS、PG `sslmode=verify-full`、Redis `rediss://`、真实 SMTP 和必要凭据；不信任未经配置审查的转发头。测试低成本 KDF 仅在显式开发测试配置下开放。

### IDEA 本机开发

1. Project SDK 选择已有 Java 21，例如 `C:/Users/qq479/.jdks/temurin-21.0.12.1`。不必切换系统 Java，避免影响其他项目。
2. 本机开发数据服务内联在 `application-dev.yaml`：库 `vaultone_java_dev`（owner 为迁移角色 `vaultone_java_migrator`）、运行角色 `vaultone_java_runtime`、Redis `redis://127.0.0.1:6379`（免密）。**不要指向 Rust 服务端在用的 `vaultone` 库，也不要让应用使用本机管理角色 `root`。**
3. 换机器时按同一口径重建（口令与 `application-dev.yaml` 一致；迁移角色是库 owner，运行角色非 owner、无 DDL、非超级用户、无 BYPASSRLS）：

```sql
CREATE ROLE vaultone_java_migrator LOGIN PASSWORD '<见 application-dev.yaml>' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
CREATE ROLE vaultone_java_runtime  LOGIN PASSWORD '<见 application-dev.yaml>' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
CREATE DATABASE vaultone_java_dev OWNER vaultone_java_migrator;
GRANT CONNECT ON DATABASE vaultone_java_dev TO vaultone_java_runtime;
```

4. Run Configuration 不需要设置任何环境变量：根 YAML 已声明 `spring.profiles.active: dev`，直接运行即可。要验证 prod 时才显式覆盖 `--spring.profiles.active=prod`。

迁移与运行必须指向同一数据库：`spring.flyway.url` 刻意不写，地址沿用 `spring.datasource.url`，只切换角色；`runtime_role` / `migrator_role` 必须分别与 `spring.datasource.username` / `spring.flyway.user` 一致，避免误授予权限。

已在发布步骤完成迁移时，可设置 `SPRING_FLYWAY_ENABLED=false`，运行进程只保留受限用户凭据；本机测试 fixture 也是先迁移、后启动受限应用。生产迁移、切流和回滚流程尚未实际演练。

从 `server/` 启动（默认即为 dev，无需额外参数）：

```bash
JAVA_HOME="C:/Users/qq479/.jdks/temurin-21.0.12.1" ./mvnw spring-boot:run
```

要验证生产配置时显式覆盖环境：`./mvnw spring-boot:run -Dspring-boot.run.arguments=--spring.profiles.active=prod`。

此命令不创建开发数据库或角色，不应指向 Rust 正在使用的数据库。

## 5. 可重复验证

所有 Maven 命令在 `server/` 执行；Java 21 通过进程 `JAVA_HOME` 或 IDEA SDK 指定。

```bash
JAVA_HOME="C:/Users/qq479/.jdks/temurin-21.0.12.1" ./mvnw spotless:apply test
```

### 本机已有 PostgreSQL / Redis

本机实测 PostgreSQL **16.15**、Redis **8.2.1 standalone**。以下 FlyEnv 示例使用已核实的本机管理角色 `root`，**仅由 fixture 创建和回收临时资源，绝不作为被测应用的运行用户**；需要口令时另行设置 `VAULTONE_IT_DB_PASSWORD` / `VAULTONE_IT_REDIS_PASSWORD`。

```bash
JAVA_HOME="C:/Users/qq479/.jdks/temurin-21.0.12.1" VAULTONE_IT_MODE=external VAULTONE_IT_JDBC_URL=jdbc:postgresql://127.0.0.1:5432/postgres VAULTONE_IT_DB_USER=root VAULTONE_IT_REDIS_ADDRESS=redis://127.0.0.1:6379 ./mvnw clean verify
```

fixture 严格限制回环连接；每次建立随机数据库、非超级用户迁移角色、受限运行角色和独立 Redis 前缀。结束时只清理本次资源，清理失败可见；禁止 FLUSHDB/FLUSHALL。外部模式不会启动 Docker。

> **2026-10-01 修复记录**：此前 external/容器 `verify` 会在应用启动阶段被 `DeploymentGuard` 拒绝（报 `Flyway runtime_role 必须与运行数据库用户一致`），根因是 `LocalTestServices` 用 `builder.properties(...)`（最低优先级）注入随机 `runtime_role`，被 `application-dev.yaml` 内联的同名占位符覆盖。已改为命令行参数注入 `runtime_role`/`migrator_role` 并同步 `spring.flyway.user`；修复后 external `verify` BUILD SUCCESS（105 单测 + 31 IT，含 Rust 客户端互通）。容器路径由 CI 覆盖。

### CI 默认模式

不设置 `VAULTONE_IT_MODE=external` 时使用 Testcontainers，执行同一套测试；Docker 不可用就失败，不静默跳过。容器版本锁定在 `support/ContainerBackend.java`：

- PostgreSQL：`postgres:16.15-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea`
- Redis：`redis:8.10.2-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0`

`BackendContractIT` 会调用 Cargo，用真实 `vault-core::Vault` 执行注册、设备批准、同步/冲突/分页、改密、恢复、撤销、退出和注销。因此 Java CI 也要有 Rust 工具链。它不是 Java 自写客户端的自测。

其余测试覆盖：协议黄金向量、真实 Jetty/虚拟线程、RLS/连接复用/临时表遮蔽、迁移角色权限、Redis 会话/索引/限流、OTP 失败计数与并发、同步事务内身份重验、注册失败回滚与恢复竞争。报告位于 `target/surefire-reports`、`target/failsafe-reports`。

## 6. 发布前仍需完成

- Rust 旧 PG/SQLite 服务库接管、旧 sessions 一次性迁移或受控作废、字节/序列高水位核对，以及回切后不丢新写入的演练。
- 真实生产 TLS/SMTP、代理信任链、Redis/PG 故障切换、饱和压测、虚拟线程 pinning、审计保留/归档与持久通知投递。
- 新空库本机互通不等于已有账户迁移成功；测试配置不替代生产权限评审。
- CI 配置已接入 Java 校验、Rust 互通、制品/SBOM 与扫描，但未经本轮推送运行，不宣称远端 CI 已通过。

已有 Rust 服务端、客户端 Rust 内核和 Flutter 构建入口继续保留；本工程不会自动发布或切流。

## 7. 版本与协议来源

- [Spring Initializr](https://start.spring.io/metadata/client)
- [Spring Boot 4.1.1 BOM](https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-dependencies/4.1.1/spring-boot-dependencies-4.1.1.pom)
- [Redisson 发布元数据](https://repo.maven.apache.org/maven2/org/redisson/redisson/maven-metadata.xml)
- [Bouncy Castle 制品](https://repo.maven.apache.org/maven2/org/bouncycastle/bcprov-jdk18on/1.86/)
- [FlyEnv PostgreSQL 默认配置](https://flyenv.com/features/postgresql)
- [本仓库字节级契约](../docs/10-服务端迁移契约基线.md)

在线版本与镜像信息是选型证据，不替代对应运行环境中的验收。旧阶段记录见 [docs/11](../docs/11-计划执行与验收记录.md)，不再把已过时的“仅S1/无业务”说明混入当前启动指南。
