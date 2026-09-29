package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.config.DeploymentGuard;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;

class DeploymentGuardTest {
  private MockEnvironment local() {
    var env =
        new MockEnvironment()
            .withProperty(
                "vaultone.server-secret",
                "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
            .withProperty("server.address", "127.0.0.1")
            .withProperty("spring.datasource.url", "jdbc:postgresql://localhost:5432/test")
            .withProperty("vaultone.redis.address", "redis://localhost:6379")
            .withProperty("vaultone.development.enabled", "true");
    env.setActiveProfiles("local");
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
                    local().withProperty("vaultone.server-secret", "00".repeat(32))))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageNotContaining("00000000");
  }

  @Test
  void developmentRequiresExplicitOptInAndLoopback() {
    assertThatCode(() -> DeploymentGuard.validate(local())).doesNotThrowAnyException();
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    local().withProperty("vaultone.development.enabled", "false")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () -> DeploymentGuard.validate(local().withProperty("server.address", "0.0.0.0")))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    local()
                        .withProperty(
                            "vaultone.redis.address", "redis://remote.example.test:6379")))
        .isInstanceOf(IllegalStateException.class);
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
      assertThatThrownBy(
              () -> DeploymentGuard.validate(local().withProperty(setting[0], setting[1])))
          .as(setting[0])
          .isInstanceOf(IllegalStateException.class);
    }
  }

  @Test
  void productionRejectsPlaintextAndUntrustedProxyConfiguration() {
    var env = local().withProperty("vaultone.development.enabled", "false");
    env.setActiveProfiles();
    assertThatThrownBy(() -> DeploymentGuard.validate(env))
        .isInstanceOf(IllegalStateException.class);
    env.withProperty("server.ssl.enabled", "true")
        .withProperty(
            "spring.datasource.url", "jdbc:postgresql://db.example.test/vault?sslmode=verify-full")
        .withProperty("spring.datasource.password", "public-test-only")
        .withProperty("vaultone.redis.address", "rediss://redis.example.test:6379")
        .withProperty("vaultone.redis.password", "public-test-only");
    assertThatCode(() -> DeploymentGuard.validate(env)).doesNotThrowAnyException();
    assertThatThrownBy(
            () ->
                DeploymentGuard.validate(
                    env.withProperty("server.forward-headers-strategy", "framework")))
        .isInstanceOf(IllegalStateException.class);
  }
}
