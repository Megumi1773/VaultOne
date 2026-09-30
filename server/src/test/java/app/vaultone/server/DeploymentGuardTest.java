package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.config.DeploymentGuard;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;

class DeploymentGuardTest {
  private static final String SECRET =
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

  private MockEnvironment dev() {
    var env =
        new MockEnvironment()
            .withProperty("vaultone.server-secret", SECRET)
            .withProperty("server.address", "127.0.0.1")
            .withProperty("spring.datasource.url", "jdbc:postgresql://localhost:5432/test")
            .withProperty("vaultone.redis.address", "redis://localhost:6379")
            .withProperty("vaultone.redis.namespace", "vaultone:dev")
            .withProperty("vaultone.development.enabled", "true");
    env.setActiveProfiles("dev");
    return env;
  }

  private MockEnvironment prod() {
    var env =
        new MockEnvironment()
            .withProperty("vaultone.server-secret", SECRET)
            .withProperty("server.ssl.enabled", "true")
            .withProperty(
                "spring.datasource.url",
                "jdbc:postgresql://db.example.test/vault?sslmode=verify-full")
            .withProperty("spring.datasource.password", "public-test-only")
            .withProperty("vaultone.redis.address", "rediss://redis.example.test:6379")
            .withProperty("vaultone.redis.password", "public-test-only")
            .withProperty("vaultone.redis.namespace", "vaultone:prod")
            .withProperty("vaultone.development.enabled", "false")
            .withProperty("vaultone.mail.mode", "smtp")
            .withProperty("vaultone.mail.smtp-host", "smtp.example.test")
            .withProperty("vaultone.mail.from", "VaultOne <no-reply@vaultone.app>")
            .withProperty("vaultone.mail.smtp-username", "user")
            .withProperty("vaultone.mail.smtp-password", "public-test-only")
            .withProperty("vaultone.mail.start-tls-required", "true");
    env.setActiveProfiles("prod");
    return env;
  }

  @Test
  void registeredGuardStopsDefaultApplicationBeforeConnecting() {
    assertThatThrownBy(
            () ->
                new org.springframework.boot.builder.SpringApplicationBuilder(
                        VaultOneServerApplication.class)
                    .run("--vaultone.server-secret=", "--server.port=0"))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("服务端密钥");
  }

  @Test
  void missingAndRepeatedSecretsAreRejected() {
    assertThatThrownBy(() -> DeploymentGuard.validate(new MockEnvironment()))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    dev().withProperty("vaultone.server-secret", "00".repeat(32))))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageNotContaining("00000000");
  }

  @Test
  void devRequiresExplicitProfileAndLoopbackDataServices() {
    assertThatCode(() -> DeploymentGuard.validate(dev())).doesNotThrowAnyException();
    // 没有 profile：拒绝，不依赖未显式选择的 fallback。
    var noProfile = dev();
    noProfile.setActiveProfiles();
    assertThatThrownBy(() -> DeploymentGuard.validate(noProfile))
        .isInstanceOf(IllegalStateException.class);
    // dev 与 prod 同时激活：拒绝。
    var both = dev();
    both.setActiveProfiles("dev", "prod");
    assertThatThrownBy(() -> DeploymentGuard.validate(both))
        .isInstanceOf(IllegalStateException.class);
    // dev 未显式开启 development：拒绝。
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    dev().withProperty("vaultone.development.enabled", "false")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () -> DeploymentGuard.validate(dev().withProperty("server.address", "0.0.0.0")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    dev()
                        .withProperty(
                            "vaultone.redis.address", "redis://remote.example.test:6379")))
        .isInstanceOf(IllegalStateException.class);
    // dev 允许无口令的本机 PG/Redis。
    assertThatCode(() -> DeploymentGuard.validate(dev())).doesNotThrowAnyException();
  }

  @Test
  void dangerousOrmAndSqlLoggingOverridesAreRejected() {
    for (String[] setting :
        new String[][] {
          {"spring.jpa.hibernate.ddl-auto", "update"},
          {"spring.jpa.properties.hibernate.hbm2ddl.auto", "create-drop"},
          {"spring.jpa.generate-ddl", "true"},
          {"spring.jpa.open-in-view", "true"},
          {"spring.jpa.properties.jakarta.persistence.schema-generation.database.action", "create"},
          {"spring.jpa.show-sql", "true"},
          {"spring.jpa.properties.hibernate.show_sql", "true"},
          {"logging.level.org.hibernate.SQL", "DEBUG"},
          {"logging.level.org.hibernate.orm.jdbc.bind", "TRACE"},
          {"logging.level.org.hibernate.orm.jdbc.extract", "TRACE"},
          {"logging.level.org.hibernate.orm.results", "DEBUG"},
          {"spring.flyway.baseline-on-migrate", "true"}
        }) {
      assertThatThrownBy(() -> DeploymentGuard.validate(dev().withProperty(setting[0], setting[1])))
          .as(setting[0])
          .isInstanceOf(IllegalStateException.class);
    }
  }

  @Test
  void productionRejectsPlaintextUntrustedProxyAndDevelopmentSwitch() {
    // 缺少 TLS/verify-full/rediss/口令：拒绝。
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    prod()
                        .withProperty("server.ssl.enabled", "false")
                        .withProperty("spring.datasource.password", "")))
        .isInstanceOf(IllegalStateException.class);
    assertThatCode(() -> DeploymentGuard.validate(prod())).doesNotThrowAnyException();
    // 生产不得开启 development。
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    prod().withProperty("vaultone.development.enabled", "true")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    prod().withProperty("server.forward-headers-strategy", "framework")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    prod()
                        .withProperty(
                            "spring.datasource.url",
                            "jdbc:postgresql://db.example.test/vault?sslmode=require")))
        .isInstanceOf(IllegalStateException.class);
  }

  @Test
  void productionRejectsLogMailTestKdfAndInsecureSmtp() {
    // 生产必须真实 SMTP。
    assertThatThrownBy(
            () -> DeploymentGuard.validate(prod().withProperty("vaultone.mail.mode", "log")))
        .isInstanceOf(IllegalStateException.class);
    // 生产禁止低成本测试 KDF。
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    prod().withProperty("vaultone.development.allow-test-kdf", "true")))
        .isInstanceOf(IllegalStateException.class);
    // 生产必须有 SMTP 凭据。
    assertThatThrownBy(
            () -> DeploymentGuard.validate(prod().withProperty("vaultone.mail.smtp-password", "")))
        .isInstanceOf(IllegalStateException.class);
    // 生产必须 STARTTLS 或 TLS。
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    prod()
                        .withProperty("vaultone.mail.start-tls-required", "false")
                        .withProperty("vaultone.mail.ssl-enabled", "false")))
        .isInstanceOf(IllegalStateException.class);
  }

  @Test
  void migrationConnectionCannotTargetAnotherDatabaseOrDowngradeTls() {
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    dev()
                        .withProperty(
                            "spring.flyway.url", "jdbc:postgresql://remote.example.test/test")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    dev()
                        .withProperty(
                            "spring.flyway.url", "jdbc:postgresql://localhost:5432/another")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    prod()
                        .withProperty(
                            "spring.flyway.url",
                            "jdbc:postgresql://db.example.test/vault?sslmode=require")))
        .isInstanceOf(IllegalStateException.class);
    assertThatCode(
            () ->
                DeploymentGuard.validate(
                    dev().withProperty("spring.flyway.url", "jdbc:postgresql://localhost/test")))
        .doesNotThrowAnyException();
  }

  @Test
  void migrationRoleMustMatchItsConnectionAndRemainSeparate() {
    var env =
        dev()
            .withProperty("spring.datasource.username", "vaultone_runtime")
            .withProperty("spring.flyway.placeholders.runtime_role", "vaultone_runtime")
            .withProperty("spring.flyway.user", "vaultone_migrator")
            .withProperty("spring.flyway.placeholders.migrator_role", "vaultone_migrator");
    assertThatCode(() -> DeploymentGuard.validate(env)).doesNotThrowAnyException();
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    env.withProperty("spring.flyway.placeholders.migrator_role", "bad;role")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    env.withProperty("spring.flyway.placeholders.migrator_role", "another_role")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    env.withProperty("spring.flyway.user", "vaultone_runtime")
                        .withProperty(
                            "spring.flyway.placeholders.migrator_role", "vaultone_runtime")))
        .isInstanceOf(IllegalStateException.class);
  }

  @Test
  void redisNamespaceAndRuntimeRoleAreValidated() {
    assertThatThrownBy(
            () -> DeploymentGuard.validate(dev().withProperty("vaultone.redis.namespace", "")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () -> DeploymentGuard.validate(dev().withProperty("vaultone.redis.namespace", "a b")))
        .isInstanceOf(IllegalStateException.class);
    // runtime_role 非法标识符：拒绝。
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    dev().withProperty("spring.flyway.placeholders.runtime_role", "bad;role")))
        .isInstanceOf(IllegalStateException.class);
    // runtime_role 与运行用户不一致：拒绝。
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    dev()
                        .withProperty("spring.datasource.username", "vaultone_runtime")
                        .withProperty("spring.flyway.placeholders.runtime_role", "other_role")))
        .isInstanceOf(IllegalStateException.class);
    // 一致且合法：通过。
    assertThatCode(
            () ->
                DeploymentGuard.validate(
                    dev()
                        .withProperty("spring.datasource.username", "vaultone_runtime")
                        .withProperty(
                            "spring.flyway.placeholders.runtime_role", "vaultone_runtime")))
        .doesNotThrowAnyException();
  }
}
