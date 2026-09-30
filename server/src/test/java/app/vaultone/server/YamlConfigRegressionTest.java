package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.config.DeploymentGuard;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.boot.env.YamlPropertySourceLoader;
import org.springframework.core.env.PropertySource;
import org.springframework.core.io.FileSystemResource;
import org.springframework.mock.env.MockEnvironment;

/**
 * 直接用 {@link YamlPropertySourceLoader} 加载 {@code src/main/resources} 下的源码 YAML， 不经过
 * target/classes（避免被旧 application.properties 掩盖）：验证日志级别是字符串、 dev/prod 叠加顺序与部署门禁。
 */
class YamlConfigRegressionTest {
  private static final String SECRET =
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

  /** 先加 profile 专属（高优先级），再加公共（低优先级），模拟 Boot 的 profile 覆盖。 */
  private static MockEnvironment load(String... profiles) throws IOException {
    var env = new MockEnvironment();
    var loader = new YamlPropertySourceLoader();
    for (int i = profiles.length - 1; i >= 0; i--) {
      addSource(env, loader, "application-" + profiles[i] + ".yaml");
    }
    addSource(env, loader, "application.yaml");
    env.setActiveProfiles(profiles);
    return env;
  }

  private static void addSource(MockEnvironment env, YamlPropertySourceLoader loader, String name)
      throws IOException {
    Path path = sourceYaml(name);
    List<PropertySource<?>> sources = loader.load(name, new FileSystemResource(path));
    for (PropertySource<?> source : sources) {
      env.getPropertySources().addLast(source);
    }
  }

  private static Path sourceYaml(String name) {
    Path candidate = Path.of("src", "main", "resources", name);
    if (Files.exists(candidate)) return candidate;
    Path dir = Path.of("").toAbsolutePath();
    while (dir != null) {
      Path resolved = dir.resolve("src/main/resources").resolve(name);
      if (Files.exists(resolved)) return resolved;
      dir = dir.getParent();
    }
    throw new IllegalStateException("找不到源码 YAML: " + name);
  }

  /** 配置全部内联在 YAML：不允许残留 `${...}` 占位，否则又会变成必须注入环境变量才能启动。 */
  @Test
  void sourceYamlKeepsEveryValueInline() throws IOException {
    for (String name :
        List.of("application.yaml", "application-dev.yaml", "application-prod.yaml")) {
      assertThat(Files.readString(sourceYaml(name))).as(name).doesNotContain("${");
    }
  }

  /** 公共 YAML 只放结构性默认：任何可用连接、密钥、角色都不得出现在公共层， 否则 dev 会变成事实默认，环境文件沦为声明。 */
  @Test
  void commonYamlCarriesNoEnvironmentSpecificValues() throws IOException {
    var common = load();
    assertThat(common.getProperty("spring.datasource.url", "")).isBlank();
    assertThat(common.getProperty("spring.datasource.username", "")).isBlank();
    assertThat(common.getProperty("spring.datasource.password", "")).isBlank();
    assertThat(common.getProperty("spring.flyway.user", "")).isBlank();
    assertThat(common.getProperty("spring.flyway.password", "")).isBlank();
    assertThat(common.getProperty("spring.flyway.placeholders.runtime_role")).isNull();
    assertThat(common.getProperty("spring.flyway.placeholders.migrator_role")).isNull();
    assertThat(common.getProperty("vaultone.server-secret", "")).isBlank();
    assertThat(common.getProperty("vaultone.redis.address", "")).isBlank();
    // 公共层本身不构成可启动配置：缺密钥即拒绝。
    assertThatThrownBy(() -> DeploymentGuard.validate(common))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("服务端密钥");
    // 即使补上合法密钥，公共层仍没有数据服务地址，依旧拒绝。
    assertThatThrownBy(
            () -> DeploymentGuard.validate(load().withProperty("vaultone.server-secret", SECRET)))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("PostgreSQL");
  }

  /** 环境文件各自提供完整环境值，且两套密钥必须不同。 */
  @Test
  void profilesProvideTheirOwnEnvironmentValues() throws IOException {
    var dev = load("dev");
    var prod = load("prod");
    assertThat(dev.getProperty("vaultone.server-secret", "")).isNotBlank();
    assertThat(prod.getProperty("vaultone.server-secret", "")).isNotBlank();
    assertThat(dev.getProperty("vaultone.server-secret"))
        .isNotEqualTo(prod.getProperty("vaultone.server-secret"));
    assertThat(dev.getProperty("spring.datasource.url", "")).isNotBlank();
    assertThat(prod.getProperty("spring.datasource.url", "")).isNotBlank();
    assertThat(dev.getProperty("vaultone.redis.address", "")).isNotBlank();
    assertThat(prod.getProperty("vaultone.redis.address", "")).isNotBlank();
  }

  @Test
  void rolePlaceholdersFollowTheSeparateConnectionUsers() throws IOException {
    var env = load("dev");
    assertThat(env.getProperty("spring.flyway.placeholders.runtime_role"))
        .isEqualTo(env.getProperty("spring.datasource.username"));
    assertThat(env.getProperty("spring.flyway.placeholders.migrator_role"))
        .isEqualTo(env.getProperty("spring.flyway.user"));
    assertThat(env.getProperty("spring.flyway.placeholders.runtime_role"))
        .isNotEqualTo(env.getProperty("spring.flyway.placeholders.migrator_role"));
    assertThatCode(() -> DeploymentGuard.validate(env)).doesNotThrowAnyException();
  }

  @Test
  void sourceYamlKeepsOffAsStringAndOverlaysProfiles() throws IOException {
    var common = load();
    // YAML 1.1 下未加引号的 OFF 会变 boolean false，这里必须是字符串 "OFF"。
    assertThat(common.getProperty("logging.level.org.hibernate.SQL", String.class))
        .isEqualTo("OFF");
    assertThat(common.getProperty("logging.level.org.hibernate.orm.jdbc.bind", String.class))
        .isEqualTo("OFF");
    assertThat(common.getProperty("logging.level.org.hibernate.orm.jdbc.extract", String.class))
        .isEqualTo("OFF");
    assertThat(common.getProperty("logging.level.org.hibernate.orm.results", String.class))
        .isEqualTo("OFF");
    assertThat(common.getProperty("server.port", String.class)).isEqualTo("9777");
    assertThat(common.getProperty("spring.jpa.hibernate.ddl-auto", String.class))
        .isEqualTo("validate");
    assertThat(common.getProperty("spring.jpa.open-in-view", String.class)).isEqualTo("false");

    var dev = load("dev");
    assertThat(dev.getProperty("server.address", String.class)).isEqualTo("127.0.0.1");
    assertThat(dev.getProperty("vaultone.development.enabled", String.class)).isEqualTo("true");
    assertThat(dev.getProperty("vaultone.development.allow-test-kdf", String.class))
        .isEqualTo("false");
    assertThat(dev.getProperty("vaultone.redis.namespace", String.class)).isEqualTo("vaultone:dev");
    assertThat(dev.getProperty("vaultone.redis.address", String.class))
        .isEqualTo("redis://127.0.0.1:6379");
    // 连接、角色与密钥全部来自 application-dev.yaml（公共层保持为空）。
    assertThat(dev.getProperty("spring.datasource.url", String.class))
        .isEqualTo("jdbc:postgresql://127.0.0.1:5432/vaultone_java_dev");
    assertThat(dev.getProperty("spring.datasource.username", String.class))
        .isEqualTo("vaultone_java_runtime");
    assertThat(dev.getProperty("spring.flyway.user", String.class))
        .isEqualTo("vaultone_java_migrator");

    var prod = load("prod");
    assertThat(prod.getProperty("server.address", String.class)).isEqualTo("0.0.0.0");
    assertThat(prod.getProperty("server.ssl.enabled", String.class)).isEqualTo("true");
    // 启用 TLS 必须有证书材料，否则容器启动即失败。
    assertThat(prod.getProperty("server.ssl.certificate", String.class)).isNotBlank();
    assertThat(prod.getProperty("server.ssl.certificate-private-key", String.class)).isNotBlank();
    assertThat(prod.getProperty("vaultone.development.enabled", String.class)).isEqualTo("false");
    assertThat(prod.getProperty("vaultone.redis.namespace", String.class))
        .isEqualTo("vaultone:prod");
    assertThat(prod.getProperty("vaultone.mail.mode", String.class)).isEqualTo("smtp");
    assertThat(prod.getProperty("vaultone.mail.smtp-host", String.class)).isNotBlank();
    assertThat(prod.getProperty("spring.datasource.url", String.class))
        .contains("sslmode=verify-full");
  }

  @Test
  void guardAcceptsSourceYamlForDevAndProdButRejectsDefault() throws IOException {
    var dev = load("dev").withProperty("vaultone.server-secret", SECRET);
    assertThatCode(() -> DeploymentGuard.validate(dev)).doesNotThrowAnyException();

    var prod =
        load("prod")
            .withProperty("vaultone.server-secret", SECRET)
            .withProperty(
                "spring.datasource.url",
                "jdbc:postgresql://db.example.test/vault?sslmode=verify-full")
            .withProperty("spring.datasource.password", "public-test-only")
            .withProperty("vaultone.redis.address", "rediss://redis.example.test:6379")
            .withProperty("vaultone.redis.password", "public-test-only")
            .withProperty("vaultone.mail.smtp-host", "smtp.example.test")
            .withProperty("vaultone.mail.smtp-username", "user")
            .withProperty("vaultone.mail.smtp-password", "public-test-only");
    assertThatCode(() -> DeploymentGuard.validate(prod)).doesNotThrowAnyException();

    // 未激活任何 profile：即使给了完整回环设置也必须拒绝。
    var none =
        load()
            .withProperty("vaultone.server-secret", SECRET)
            .withProperty("spring.datasource.url", "jdbc:postgresql://127.0.0.1:5432/vaultone")
            .withProperty("vaultone.redis.address", "redis://127.0.0.1:6379");
    assertThatThrownBy(() -> DeploymentGuard.validate(none))
        .isInstanceOf(IllegalStateException.class);

    // prod 叠加 development 开关：拒绝。
    var prodDev =
        load("prod")
            .withProperty("vaultone.server-secret", SECRET)
            .withProperty(
                "spring.datasource.url",
                "jdbc:postgresql://db.example.test/vault?sslmode=verify-full")
            .withProperty("spring.datasource.password", "public-test-only")
            .withProperty("vaultone.redis.address", "rediss://redis.example.test:6379")
            .withProperty("vaultone.redis.password", "public-test-only")
            .withProperty("vaultone.mail.smtp-host", "smtp.example.test")
            .withProperty("vaultone.mail.smtp-username", "user")
            .withProperty("vaultone.mail.smtp-password", "public-test-only")
            .withProperty("vaultone.development.enabled", "true");
    assertThatThrownBy(() -> DeploymentGuard.validate(prodDev))
        .isInstanceOf(IllegalStateException.class);
  }
}
