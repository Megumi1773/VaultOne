# VaultOne Java 服务端：S1 工程底座

## 状态与边界

这是 **S1部分底座，完整S1尚未验收**（Docker阻塞，verify保持失败）。这是独立 `server/` Maven 工程，**不替换正在工作的 Rust 服务端**。当前只有基础设施、安全默认值和健康探针，没有注册、SRP、同步、恢复等 `/v1` 业务 API；任意 Bearer 凭据都拒绝，不能把本工程的启动或健康响应当作 S2 协议互通成功。

用户指定方向：Java21、Spring Boot4 MVC、Jetty、PostgreSQL、JPA/Envers、Redis/Redisson。未引入 WebFlux、H2、Lettuce、Jedis、Spring Data Redis。主工作区文档与CI不由本工程改动。

### 本次实际验证

| 命令/检查 | 实际结果 |
|---|---|
| 官方 Initializr 下载与 Maven Wrapper | 成功；Wrapper 3.3.4 `only-script`，Maven 3.9.16，不含手工制作的 wrapper jar |
| 隔离 Temurin21 校验 | 21.0.12.1+1，官方ZIP SHA256核对一致，未安装到系统/修改系统JAVA_HOME |
| `./mvnw spotless:apply validate` | **通过**；已实际格式化Java源码，Spotless check绑定validate，因此test/verify都会执行 |
| `./mvnw test` | **11 tests，0 failures，0 errors，0 skipped** |
| `./mvnw verify` | 单元/架构/真实Jetty/EL插值11项仍通过；**Failsafe失败**，Testcontainers找不到Docker，类初始化1 error，0 skipped，两个容器测试方法未执行 |
| `docker version` | 客户端29.6.1；desktop-linux daemon命名管道不存在 |

**未完成验收**：真实PG/Flyway/JPA启动、Redis/Redisson连接与TTL、数据库并发、Envers业务审计、生产TLS、Java与原客户端协议互通。不能以 `test` 通过替代 `verify` 通过；未设置 `disabledWithoutDocker`、skipITs或H2/mock数据库绕过验收。

测试期间启动的Jetty绑定回环临时端口并由测试关闭，不保留长驻服务。没有读取或访问用户数据库/线上实例；连接参数只来自容器或明确不连接数据服务的传输层测试。

## 脚手架与版本来源

Initializr参数先按官方元数据核对再下载：

```text
GET https://start.spring.io/starter.zip
  type=maven-project
  language=java
  bootVersion=4.1.1.RELEASE
  javaVersion=21
  groupId=app.vaultone
  artifactId=vaultone-server
  name=VaultOneServer
  packageName=app.vaultone.server
  packaging=jar
  dependencies=web,security,validation,data-jpa,postgresql,flyway,actuator,testcontainers
```

元数据 `web` 实际生成 `spring-boot-starter-webmvc`。Initializr产生的POM带 `4.1.1.RELEASE` 后缀；按 Maven Central 正式发布坐标规范为 **4.1.1**，不是另选旧版本。其余代码在官方脚手架基础上编辑；`mvnw`、`mvnw.cmd` 和 `.mvn/wrapper/maven-wrapper.properties` 来自该下载包。

| 组件 | 固定版本/来源 |
|---|---|
| Spring Boot | 4.1.1 parent/BOM |
| Hibernate ORM / Envers | **7.4.5.Final**，两者使用同一Boot BOM，无单独覆盖 |
| Jetty | **12.1.12**，Boot BOM |
| Testcontainers | **2.0.5**，Boot BOM |
| Redisson核心 | **4.7.0**，Central发行元数据核验后固定 |
| ArchUnit | **1.5.1**，Central发行元数据核验后固定 |
| Jakarta EL实现 | **Expressly 6.0.0**，官方POM依赖Jakarta EL API 6.0.1；替代Tomcat EL |
| 格式门禁 | **Spotless Maven 3.10.3 / google-java-format 1.36.1**，Central元数据核验并固定 |
| 容器镜像 | 首期沿用PG16；Redis8稳定候选经官方registry实核，完整tag+digest见下表，Docker恢复后仍需实际拉取/运行验证 |

### 官方镜像锁定（2026-09-29核验）

PostgreSQL官方支持表列出16系列最新补丁 **16.15**，支持截止 **2028-11-09**。Docker Hub官方 `library/postgres`、`library/redis` 的下列tag均为active；使用返回的多架构索引digest锁定，不能只写会漂移的tag。Redis **8.10.2** 已实核存在，不沿用未经依据选择的7.x镜像。

| 用途 | Testcontainers完整引用 | registry更新时间 |
|---|---|---|
| PG16 | `postgres:16.15-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea` | 2026-09-21T04:08:02.149832Z |
| Redis8候选 | `redis:8.10.2-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0` | 2026-09-24T21:05:07.843284Z |

核验registry元数据不等于镜像已拉取/启动、Redis许可部署审查通过或PG/Redis兼容性验收通过。

版本证据：

- <https://www.postgresql.org/support/versioning/>
- <https://hub.docker.com/v2/repositories/library/postgres/tags/16.15-alpine>
- <https://hub.docker.com/v2/repositories/library/redis/tags/8.10.2-alpine>
- <https://repo.maven.apache.org/maven2/com/diffplug/spotless/spotless-maven-plugin/maven-metadata.xml>
- <https://repo.maven.apache.org/maven2/com/google/googlejavaformat/google-java-format/maven-metadata.xml>
- <https://start.spring.io/metadata/client>
- <https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-dependencies/4.1.1/spring-boot-dependencies-4.1.1.pom>
- <https://repo.maven.apache.org/maven2/org/redisson/redisson/maven-metadata.xml>
- <https://repo.maven.apache.org/maven2/org/glassfish/expressly/expressly/6.0.0/expressly-6.0.0.pom>
- <https://repo.maven.apache.org/maven2/com/tngtech/archunit/archunit-junit5/maven-metadata.xml>
- <https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse>

本次Temurin ZIP文件名 `OpenJDK21U-jdk_x64_windows_hotspot_21.0.12.1_1.zip`，SHA256：

```text
f9d6e191ab098c0d416e7d588a24420a8621cd2f4720dab2459b8b7b2d2d8b4e
```

JDK与下载包只作本地工具，**不得提交二进制**。这不是生产Java版本升级策略或供应链完整审计。

## 工程约束

### MVC + Jetty + 有界资源

- 显式从webmvc starter排除Tomcat starter，加入Jetty starter，并从Jetty/validation依赖链排除 `tomcat-embed-el`，改用官方POM核验的 **Expressly 6.0.0 / Jakarta EL 6**。Maven Enforcer拒绝所有Tomcat组件（包括EL）、Lettuce、Jedis、Redis starter、H2，并要求Java `[21,22)`。
- `ValidationTest`实际执行Hibernate Validator约束，断言 `{value}` 参数与 `${validatedValue}` EL表达式都成功插值，并确认使用Expressly的ExpressionFactory；不通过关闭EL来绕过依赖门禁。
- 默认监听端口保留 **8787**；仅测试用 `server.port=0`，并发启动Rust服务需由用户显式安排端口，不能为避免冲突悄悄改变协议默认值。
- `spring.threads.virtual.enabled=true`。`JettyVirtualThreadsTest`通过真实Jetty HTTP请求，在Servlet filter内断言 `Thread.currentThread().isVirtual()`，不是只检查配置字符串或MockMvc。
- Jetty `NetworkConnectionLimit` 为256个网络连接；应用同步Servlet执行预算128个，超预算立即429 JSON，不排无界等待队列。
- Hikari最大10、最小空闲2、连接获取超时5s；Redisson最大8普通连接/2订阅连接、最小空闲2/1，工作线程2、Netty线程4，连接/命令超时3s，有限重试。
- 上述限制为S1固定默认值，未做容量/高并发验收；异步请求、S2大体积push需要单独资源设计，不能据此声称所有内存分配都有界。

### 默认拒绝与部署门禁

- `DeploymentGuard`通过 `META-INF/spring.factories` 注册为 `ApplicationContextInitializer`，在创建DB/Redis客户端之前检查配置。默认缺少server_secret/数据服务地址时拒绝启动。
- 不内置服务端密钥。只接受显式64位hex/32B且非全重复字节值；此检查不是熵证明，运维仍必须CSPRNG生成并通过secret注入。
- 生产必须启用本进程TLS；PostgreSQL必须 `sslmode=verify-full`；Redis必须 `rediss://`，使用严格TLS主机校验；必须注入DB和Redis口令。S1不接受未经审核的代理头方案，`server.forward-headers-strategy=none`。
- 本地开发需要**同时**显式激活 `local` profile和 `vaultone.development.enabled=true`；必须绑定回环地址且PG/Redis也只指向回环。没有自动local默认值，也不会因测试环境而绕过密钥门禁。
- Security stateless，禁用Basic、form login、logout、request cache，不产生认证session/cookie，不生成默认用户/随机密码。
- 仅 `/actuator/health/liveness` 和 `/actuator/health/readiness` 公开，所有其他路径默认拒绝。readiness包含readinessState、DB、Redis实际连接检查，show-details=never。
- Bearer边界当前对**任何 Authorization**拒绝401，尚没有会话查询/签发实现或测试后门token。S2必须接入真正的SHA256(token文本)会话验证后才能允许业务路径。
- 应用Security/MVC/error dispatcher响应使用 `{code,message}`，不回传异常消息/堆栈或默认ProblemDetail；no-store。容器在Servlet之前拒绝的畸形HTTP/头部超限不是此层完全可控的错误。S0已经记录Rust存在非JSON框架拒绝；S1统一错误外形不等于已通过旧客户端全量状态/消息契约验证。

### 数据与迁移

- `spring.jpa.hibernate.ddl-auto=validate`，`open-in-view=false`，`generate-ddl=false`，`hibernate.default_batch_fetch_size=32`；不允许ORM自动建库/升级。SQL、JDBC绑定/提取、结果日志分类默认OFF。
- 以上不是仅靠默认属性：启动门禁拒绝ddl-auto非validate、原生Hibernate hbm2ddl覆盖、JPA schema-generation动作、generate-ddl、OSIV、show-sql、列出的SQL日志分类非OFF、自动baseline等危险覆盖，已有逐项测试（本地profile也不豁免）。守卫是启动期配置检查，不是禁止第三方代码/运维运行期修改logger的沙盒；未来新增数据访问或审计日志分类仍需审查。
- Flyway独立目录 `db/migration/java`、独立历史表 `vaultone_java_schema_history`，`baseline-on-migrate=false`、`clean-disabled=true`。不认领已有Rust迁移历史，不对已有用户库自动baseline。
- V1只是 `SELECT 1` 的Java迁移链锚点，Flyway创建自己的历史记录；**没有业务实体/DDL**，因此不能把S1的JPA validate当作业务schema验证成功。S2开始增加业务DDL与实体，旧库迁移另行设计/审查。
- Envers仅接入同版本依赖，尚未定义业务审计实体或默认审计全部字段，避免将密钥/密文内部字段通过实体序列化泄露；后续审计白名单需单独实现与验证。
- Redisson核心单例 `@Bean(destroyMethod="shutdown")`，不使用每请求创建客户端；没有Lettuce/Jedis并存。S1没有把同步真相源或序列号迁到Redis，也没有声称已实现分布式限流/锁。

## 本机验证命令

从 `server/` 执行，JAVA_HOME仅设置在当前命令/终端，不能改系统默认Java以影响Flutter/Rust工具链：

```sh
# 需要已安装/校验的Java21；Windows PowerShell可运行 .\mvnw.cmd test
JAVA_HOME=/absolute/path/to/jdk-21 ./mvnw spotless:apply validate
JAVA_HOME=/absolute/path/to/jdk-21 ./mvnw test
# 必须先有可用Docker daemon；此命令不忽略容器失败
JAVA_HOME=/absolute/path/to/jdk-21 ./mvnw verify
```

- `validate`：自动执行Spotless check（Java固定google-java-format、文档/属性/SQL末尾空白与换行），格式不符即阻止test/verify。修改代码后先 `spotless:apply`。
- `test`：5项部署门禁（含真实应用默认拒启、ORM/日志危险覆盖拒绝） + 4项ArchUnit边界 + 1项真实Jetty/VT/无Basic无cookie/默认拒绝 + 1项真实Bean Validation/EL插值。
- `verify`：以上测试，加真实Testcontainers PostgreSQL、Redis和完整生产应用配置；断言Flyway迁移历史、拒绝非空库自动baseline、JPA validate/OSIV、Hibernate与Envers版本、Redisson单例/连接池/TTL。无Docker会在容器启动阶段直接失败。
- `JettyVirtualThreadsTest`是明确的**传输层测试**，只排除本测试中的DB/JPA/Flyway自动配置，不注入模拟数据服务；它不替代 `InfrastructureIT`。测试的无连接回环地址只用于通过配置格式门禁。
- 本次Windows终端部分javac中文输出出现编码乱码，不影响测试断言；Maven报告在 `target/surefire-reports` 和 `target/failsafe-reports`。target及日志不提交。

## 启动前准备（未代用户执行）

本地运行需要用户自行提供一次性PG/Redis开发实例、生成新的测试server_secret，并显式设置环境变量：

```text
SPRING_PROFILES_ACTIVE=local
VAULTONE_DEVELOPMENT_ENABLED=true
VAULTONE_SERVER_SECRET=<CSPRNG生成的64位hex，不使用测试夹具>
VAULTONE_JDBC_URL=jdbc:postgresql://127.0.0.1:5432/<专用空白开发库>
VAULTONE_DB_USER=<开发用户>
VAULTONE_DB_PASSWORD=<开发口令>
VAULTONE_REDIS_ADDRESS=redis://127.0.0.1:6379
VAULTONE_REDIS_PASSWORD=<开发Redis若设置了口令则填写>
```

随后才可由用户运行 `./mvnw spring-boot:run`。不得指向Rust正在使用的数据库或生产Redis。本次未运行此长驻命令。

## S1完成与阻塞清单

**已落地且本机验证**：官方脚手架/Wrapper、Java21编译、MVC+Jetty、实际VT、资源限制配置、Security默认拒绝、统一应用错误、启动安全门禁、ArchUnit及依赖禁用规则。

**已落地但待真实基础设施验证**：PG/JPA/Flyway/Envers依赖及配置、独立迁移链、Redisson单例与有界池、readiness DB/Redis检查、Testcontainers断言。Docker不可用导致验收阻塞，完整verify保持失败。

**S1尚未实现的业务相关门禁**：尚无租户/业务表，故未创建PostgreSQL RLS策略、未设置事务级租户上下文，也没有Envers审计实体、revision metadata与敏感字段审计白名单。不能把无实体的配置和依赖当作这些S1要求完成；需随首次真实业务DDL/实体补齐并通过PG容器测试。

**未开始/不能冒充完成**：旧协议认证/恢复/同步业务、服务端crypto Java黄金向量对齐、Rust/Flutter客户端互通、业务实体/Envers审计、旧PG数据迁移、Redis分布式原子语义、生产部署和灾备。
