package app.vaultone.server.support;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.List;
import java.util.regex.Pattern;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;

/**
 * 统一真实服务 fixture：按 {@code VAULTONE_IT_MODE} 选择外部本机或 Testcontainers，只实例化被选中的后端。
 *
 * <ul>
 *   <li>默认（未设 external）：Testcontainers；无 Docker 直接失败。
 *   <li>{@code external}：本机 PG/Redis。root 只用于创建/回收随机库与 migrator/runtime 两个受限角色； 迁移由非 superuser 的
 *       migrator（库 owner）执行，业务由非 owner 的 runtime 执行。
 * </ul>
 *
 * <p>迁移经 Flyway placeholder {@code runtime_role}/{@code migrator_role} 引用已存在的受限角色名； 每个测试实例随机 Redis
 * 前缀；关闭时只清本次资源，清理失败上抛并保留原始失败。
 */
public final class LocalTestServices implements AutoCloseable {
  public static final String EXTERNAL_MODE = "external";
  private static final Pattern ROLE_PATTERN = Pattern.compile("[A-Za-z_][A-Za-z0-9_]{0,62}");
  private static final SecureRandom RANDOM = new SecureRandom();

  private final ItBackend backend;
  private final ItConnection migrator;
  private final ItConnection runtime;
  private final String serverSecret;
  private final String redisNamespace;

  private LocalTestServices(ItBackend backend, String serverSecret) {
    this.backend = backend;
    this.migrator = backend.migrator();
    this.runtime = backend.runtime();
    this.serverSecret = serverSecret;
    this.redisNamespace = backend.redisNamespace();
  }

  public static boolean externalMode() {
    String mode = System.getenv("VAULTONE_IT_MODE");
    return EXTERNAL_MODE.equals(mode);
  }

  /** 按模式创建后端并执行迁移（由非 superuser 的 migrator 角色）。 */
  public static LocalTestServices start() {
    String secret = randomServerSecret();
    ItBackend backend =
        externalMode() ? ExternalBackend.fromEnvironment() : ContainerBackend.start();
    var services = new LocalTestServices(backend, secret);
    try {
      services.migrate();
      return services;
    } catch (RuntimeException ex) {
      // 迁移失败：回收资源后原样上抛，不吞掉根因。
      try {
        backend.close();
      } catch (RuntimeException suppressed) {
        ex.addSuppressed(suppressed);
      }
      throw ex;
    }
  }

  /** 用本地源码迁移（classpath:db/migration/java），运行/迁移角色经 placeholder 注入。 */
  private void migrate() {
    String runtimeRole = requireRole(backend.runtime().user());
    String migratorRole = requireRole(backend.migrator().user());
    Flyway.configure()
        .dataSource(migrator.jdbcUrl(), migrator.user(), migrator.password())
        .locations("classpath:db/migration/java")
        .table("vaultone_java_schema_history")
        .baselineOnMigrate(false)
        .cleanDisabled(true)
        .validateOnMigrate(true)
        .placeholders(java.util.Map.of("runtime_role", runtimeRole, "migrator_role", migratorRole))
        .load()
        .migrate();
  }

  /**
   * 启动被测 Spring 应用：dev profile + 测试限流放宽 + 随机 Redis 命名空间与隔离库。
   *
   * <p>Redis 键前缀由随机 {@code vaultone.redis.namespace} 与 {@code vaultone.environment} 共同隔离； Flyway 已由
   * fixture 用 migrator 执行，故应用侧关闭自跑迁移并注入一致的 {@code runtime_role}。
   */
  public ConfigurableApplicationContext startServerApplication() {
    String environment = safeEnvironment(redisNamespace);
    String namespace = redisNamespace; // 形如 vaultone:it:<uuid>:，匹配 DeploymentGuard 的命名空间白名单
    var builder = new SpringApplicationBuilder(app.vaultone.server.VaultOneServerApplication.class);
    builder.properties("spring.flyway.placeholders.runtime_role=" + runtime.user());
    return builder.run(
        "--spring.profiles.active=dev",
        "--vaultone.development.enabled=true",
        "--vaultone.development.allow-test-kdf=true",
        "--vaultone.environment=" + environment,
        "--vaultone.server-secret=" + serverSecret,
        "--spring.datasource.url=" + runtime.jdbcUrl(),
        "--spring.datasource.username=" + runtime.user(),
        "--spring.datasource.password=" + runtime.password(),
        "--spring.datasource.hikari.maximum-pool-size=4",
        // 迁移已由 fixture 用 migrator 执行；运行角色无迁移历史表权限，业务启动不再自跑 Flyway（对齐生产“迁移角色独立”）。
        "--spring.flyway.enabled=false",
        "--vaultone.redis.address=" + backend.redis().address(),
        "--vaultone.redis.password=" + backend.redis().password(),
        "--vaultone.redis.namespace=" + namespace,
        "--vaultone.session.auth-rate-millis=1",
        "--vaultone.session.auth-burst=100000",
        "--vaultone.session.api-rate-millis=1",
        "--vaultone.session.api-burst=100000",
        "--server.port=0");
  }

  /** Redis 键命名空间片段：只保留字母数字，确保随每次测试变化。 */
  public static String safeEnvironment(String namespace) {
    String cleaned = namespace.replaceAll("[^a-zA-Z0-9]", "");
    return cleaned.isEmpty() ? "it" : "it" + cleaned;
  }

  /** 迁移/DDL 与 SECURITY DEFINER owner 连接（非 superuser 库 owner）。 */
  public ItConnection migrator() {
    return migrator;
  }

  /** 兼容既有测试：迁移连接别名（等同 {@link #migrator()}）。 */
  public ItConnection admin() {
    return migrator;
  }

  public DataSource adminDataSource() {
    return new org.springframework.jdbc.datasource.DriverManagerDataSource(
        migrator.jdbcUrl(), migrator.user(), migrator.password());
  }

  public ItConnection runtime() {
    return runtime;
  }

  public ItConnection.RedisConn redis() {
    return backend.redis();
  }

  public ItBackend backend() {
    return backend;
  }

  public String redisNamespace() {
    return redisNamespace;
  }

  public String serverSecret() {
    return serverSecret;
  }

  /** 读取并校验运行角色名；非法直接失败，避免标识符注入。 */
  static String requireRole(String role) {
    if (role == null || !ROLE_PATTERN.matcher(role).matches()) {
      throw new IllegalStateException("角色名不合法: " + role);
    }
    return role;
  }

  private static String quote(String identifier) {
    return "\"" + identifier.replace("\"", "\"\"") + "\"";
  }

  /** 随机 server-secret（64 位 hex，非固定模式）。 */
  private static String randomServerSecret() {
    byte[] raw = new byte[32];
    RANDOM.nextBytes(raw);
    return java.util.HexFormat.of().formatHex(raw);
  }

  /** 供校验：外部模式必须来自显式环境变量；默认容器模式。 */
  static List<String> modes() {
    return List.of(EXTERNAL_MODE, "container(default)");
  }

  @Override
  public void close() {
    // 只清理本次创建资源；失败上抛，不静默。
    backend.close();
  }

  static String readResource(String path) {
    try (InputStream in = LocalTestServices.class.getClassLoader().getResourceAsStream(path)) {
      if (in == null) {
        throw new IllegalStateException("找不到资源: " + path);
      }
      return new String(in.readAllBytes(), StandardCharsets.UTF_8);
    } catch (IOException ex) {
      throw new IllegalStateException("读取资源失败: " + path, ex);
    }
  }

  /** 迁移是否真的执行（供断言）：期望最终版本号。 */
  public String currentSchemaVersion() {
    Flyway flyway =
        Flyway.configure()
            .dataSource(migrator.jdbcUrl(), migrator.user(), migrator.password())
            .locations("classpath:db/migration/java")
            .table("vaultone_java_schema_history")
            .load();
    return flyway.info().current() == null ? null : flyway.info().current().getVersion().toString();
  }
}
