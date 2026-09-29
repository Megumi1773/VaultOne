package app.vaultone.server.config;

import java.net.URI;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.Set;
import org.springframework.context.ApplicationContextInitializer;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.core.env.Environment;

/** 在实例化连接池之前拒绝缺少密钥或不安全的部署；异常永不包含配置值。 */
public final class DeploymentGuard
    implements ApplicationContextInitializer<ConfigurableApplicationContext> {
  private static final Set<String> LOOPBACK = Set.of("127.0.0.1", "localhost", "::1", "[::1]");

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
    URI redis = parse(env.getProperty("vaultone.redis.address", ""));
    require(pg.getHost() != null && redis.getHost() != null, "数据服务必须配置有效主机");
    require(Set.of("redis", "rediss").contains(redis.getScheme()), "Redis 地址协议不合法");
    require(redis.getUserInfo() == null, "Redis凭据需通过独立secret注入");
    require("none".equals(env.getProperty("server.forward-headers-strategy", "none")), "S1不信任转发头");
    boolean devProfile = Arrays.asList(env.getActiveProfiles()).contains("local");
    boolean devOptIn = env.getProperty("vaultone.development.enabled", Boolean.class, false);
    if (devProfile && devOptIn) {
      require(LOOPBACK.contains(env.getProperty("server.address", "")), "本地开发必须绑定回环地址");
      require(
          LOOPBACK.contains(pg.getHost()) && LOOPBACK.contains(redis.getHost()), "本地开发仅允许回环数据服务");
      return;
    }
    require(!devProfile && !devOptIn, "local profile与开发开关必须同时显式设置");
    require(env.getProperty("server.ssl.enabled", Boolean.class, false), "非本地部署必须启用服务端TLS");
    String[] query = pg.getRawQuery() == null ? new String[0] : pg.getRawQuery().split("&");
    require(
        Arrays.stream(query)
            .filter(s -> s.startsWith("sslmode="))
            .toList()
            .equals(java.util.List.of("sslmode=verify-full")),
        "PostgreSQL必须验证TLS主机身份");
    require("rediss".equals(redis.getScheme()), "Redis必须使用TLS");
    require(!env.getProperty("spring.datasource.password", "").isBlank(), "需要数据库凭据");
    require(!env.getProperty("vaultone.redis.password", "").isBlank(), "需要Redis凭据");
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
