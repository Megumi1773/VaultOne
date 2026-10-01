package app.vaultone.server.config;

import java.net.URI;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;
import org.springframework.context.ApplicationContextInitializer;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.core.env.Environment;

/** 在实例化连接池之前拒绝缺少密钥或不安全的部署；异常永不包含配置值。 */
public final class DeploymentGuard
    implements ApplicationContextInitializer<ConfigurableApplicationContext> {
  private static final Set<String> LOOPBACK = Set.of("127.0.0.1", "localhost", "::1", "[::1]");

  /** 允许的 Redis 键命名空间：字母数字与分隔符，避免通配/空白注入。 */
  private static final Pattern NAMESPACE = Pattern.compile("[A-Za-z0-9:_-]{1,64}");

  /** 严格 SQL 标识符：小写开头，仅小写字母/数字/下划线，长度 <= 63。 */
  private static final Pattern SQL_IDENTIFIER = Pattern.compile("[a-z_][a-z0-9_]{0,62}");

  @Override
  public void initialize(ConfigurableApplicationContext context) {
    validate(context.getEnvironment());
  }

  public static void validate(Environment env) {
    String secret = env.getProperty("vaultone.server-secret", "");
    require(secret.matches("[0-9a-fA-F]{64}"), "需要显式注入32字节服务端密钥");
    byte[] bytes = HexFormat.of().parseHex(secret);
    boolean varied = false;
    for (byte value : bytes) varied |= value != bytes[0];
    Arrays.fill(bytes, (byte) 0);
    require(varied, "服务端密钥不能为重复字节");
    require(
        "validate".equals(env.getProperty("spring.jpa.hibernate.ddl-auto", "validate")),
        "ORM必须只验证结构");
    require(
        "validate"
            .equals(env.getProperty("spring.jpa.properties.hibernate.hbm2ddl.auto", "validate")),
        "禁止原生Hibernate自动DDL覆盖");
    require(!env.getProperty("spring.jpa.generate-ddl", Boolean.class, false), "禁止JPA生成DDL");
    require(!env.getProperty("spring.jpa.open-in-view", Boolean.class, false), "禁止OSIV");
    for (String namespace : new String[] {"jakarta", "javax"}) {
      for (String target : new String[] {"database", "scripts"}) {
        require(
            "none"
                .equals(
                    env.getProperty(
                        "spring.jpa.properties."
                            + namespace
                            + ".persistence.schema-generation."
                            + target
                            + ".action",
                        "none")),
            "禁止JPA schema-generation覆盖");
      }
    }
    require(
        !env.getProperty("spring.jpa.show-sql", Boolean.class, false)
            && !env.getProperty("spring.jpa.properties.hibernate.show_sql", Boolean.class, false),
        "禁止输出SQL");
    for (String logger :
        new String[] {
          "org.hibernate.SQL",
          "org.hibernate.orm.jdbc.bind",
          "org.hibernate.orm.jdbc.extract",
          "org.hibernate.orm.results"
        }) {
      require(
          "OFF".equalsIgnoreCase(env.getProperty("logging.level." + logger, "OFF")),
          "禁止SQL绑定或结果日志");
    }
    require(
        !env.getProperty("spring.flyway.baseline-on-migrate", Boolean.class, false),
        "禁止自动baseline");
    String jdbc = env.getProperty("spring.datasource.url", "");
    require(jdbc.startsWith("jdbc:postgresql://"), "仅允许显式 PostgreSQL JDBC 地址");
    URI pg = parse(jdbc.substring(5));
    require(pg.getUserInfo() == null, "PostgreSQL凭据需通过独立配置注入");
    URI migrationPg = pg;
    if (env.getProperty("spring.flyway.enabled", Boolean.class, true)) {
      String migrationJdbc = env.getProperty("spring.flyway.url", jdbc);
      if (migrationJdbc.isBlank()) migrationJdbc = jdbc;
      require(migrationJdbc.startsWith("jdbc:postgresql://"), "Flyway仅允许PostgreSQL连接");
      migrationPg = parse(migrationJdbc.substring(5));
      require(migrationPg.getUserInfo() == null, "Flyway凭据需通过独立配置注入");
      require(
          java.util.Objects.equals(pg.getHost(), migrationPg.getHost())
              && postgresPort(pg) == postgresPort(migrationPg)
              && java.util.Objects.equals(pg.getRawPath(), migrationPg.getRawPath()),
          "Flyway必须与运行连接指向同一数据库");
    }
    URI redis = parse(env.getProperty("vaultone.redis.address", ""));
    require(pg.getHost() != null && redis.getHost() != null, "数据服务必须配置有效主机");
    require(Set.of("redis", "rediss").contains(redis.getScheme()), "Redis 地址协议不合法");
    require(redis.getUserInfo() == null, "Redis凭据需通过独立secret注入");
    require("none".equals(env.getProperty("server.forward-headers-strategy", "none")), "S1不信任转发头");
    require(
        NAMESPACE.matcher(env.getProperty("vaultone.redis.namespace", "")).matches(),
        "Redis键命名空间不合法");
    validateDatabaseRoles(env);

    List<String> profiles = Arrays.asList(env.getActiveProfiles());
    boolean dev = profiles.contains("dev");
    boolean prod = profiles.contains("prod");
    require(!(dev && prod), "dev 与 prod 不能同时激活");
    require(dev || prod, "必须显式激活 dev 或 prod profile");
    boolean development = env.getProperty("vaultone.development.enabled", Boolean.class, false);
    boolean allowTestKdf =
        env.getProperty("vaultone.development.allow-test-kdf", Boolean.class, false);
    boolean allowLan = env.getProperty("vaultone.development.allow-lan", Boolean.class, false);
    String mailMode = env.getProperty("vaultone.mail.mode", "log");
    String smtpHost = env.getProperty("vaultone.mail.smtp-host", "");
    String smtpFrom = env.getProperty("vaultone.mail.from", "");
    if (dev) {
      require(development, "dev 需显式启用 vaultone.development.enabled");
      String bind = env.getProperty("server.address", "");
      boolean loopback = DevelopmentNetworkPolicy.isLoopback(bind);
      require(
          loopback
              || (allowLan
                  && ("0.0.0.0".equals(bind) || DevelopmentNetworkPolicy.isPrivateIpv4(bind))),
          "非回环开发监听需显式启用 development.allow-lan，且只允许私网地址或 0.0.0.0");
      require(loopback || !allowTestKdf, "局域网联调禁止低成本测试 KDF；自动化测试必须绑定回环");
      require(
          LOOPBACK.contains(pg.getHost()) && LOOPBACK.contains(redis.getHost()), "本地开发仅允许回环数据服务");
      if (!"log".equals(mailMode)) {
        require(!smtpHost.isBlank() && !smtpFrom.isBlank(), "SMTP 模式必须配置 smtp-host 与 from");
      }
      return;
    }
    require(!development, "生产环境禁止启用 development");
    require(!allowLan, "生产环境禁止开启局域网开发例外");
    require(!allowTestKdf, "生产环境禁止启用低成本测试 KDF");
    require("smtp".equals(mailMode), "生产环境必须使用 SMTP 邮件模式");
    require(!smtpHost.isBlank(), "生产环境必须配置 SMTP 主机");
    require(!smtpFrom.isBlank(), "生产环境必须配置发件人");
    require(
        !env.getProperty("vaultone.mail.smtp-username", "").isBlank()
            && !env.getProperty("vaultone.mail.smtp-password", "").isBlank(),
        "生产环境必须配置 SMTP 凭据");
    boolean startTls = env.getProperty("vaultone.mail.start-tls-required", Boolean.class, true);
    boolean ssl = env.getProperty("vaultone.mail.ssl-enabled", Boolean.class, false);
    require(startTls || ssl, "生产 SMTP 必须启用 STARTTLS 或 TLS");
    require(env.getProperty("server.ssl.enabled", Boolean.class, false), "生产部署必须启用服务端TLS");
    requireVerifiedPostgresTls(pg);
    requireVerifiedPostgresTls(migrationPg);
    require("rediss".equals(redis.getScheme()), "Redis必须使用TLS");
    require(!env.getProperty("spring.datasource.password", "").isBlank(), "需要数据库凭据");
    require(!env.getProperty("vaultone.redis.password", "").isBlank(), "需要Redis凭据");
  }

  /** 角色占位符必须与实际连接身份一致，不能把运行权限意外授予迁移角色。 */
  private static void validateDatabaseRoles(Environment env) {
    String runtimeRole = env.getProperty("spring.flyway.placeholders.runtime_role", "");
    if (!runtimeRole.isBlank()) {
      require(SQL_IDENTIFIER.matcher(runtimeRole).matches(), "Flyway runtime_role 标识符不合法");
      require(
          runtimeRole.equals(env.getProperty("spring.datasource.username", "")),
          "Flyway runtime_role 必须与运行数据库用户一致");
    }
    String migratorRole = env.getProperty("spring.flyway.placeholders.migrator_role", "");
    if (!migratorRole.isBlank()) {
      require(SQL_IDENTIFIER.matcher(migratorRole).matches(), "Flyway migrator_role 标识符不合法");
      require(
          migratorRole.equals(env.getProperty("spring.flyway.user", "")),
          "Flyway migrator_role 必须与迁移数据库用户一致");
      require(!migratorRole.equals(runtimeRole), "迁移角色与运行角色必须分离");
    }
  }

  private static int postgresPort(URI address) {
    return address.getPort() == -1 ? 5432 : address.getPort();
  }

  private static void requireVerifiedPostgresTls(URI address) {
    String[] query =
        address.getRawQuery() == null ? new String[0] : address.getRawQuery().split("&");
    require(
        Arrays.stream(query)
            .filter(s -> s.startsWith("sslmode="))
            .toList()
            .equals(List.of("sslmode=verify-full")),
        "PostgreSQL运行与迁移连接必须验证TLS主机身份");
  }

  private static URI parse(String value) {
    try {
      return URI.create(value);
    } catch (IllegalArgumentException ex) {
      throw new IllegalStateException("数据服务地址格式无效");
    }
  }

  private static void require(boolean condition, String message) {
    if (!condition) throw new IllegalStateException(message);
  }
}
