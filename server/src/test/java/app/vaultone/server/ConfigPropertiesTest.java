package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.config.VaultOneProperties;
import jakarta.validation.Validator;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.bind.Bindable;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.context.properties.source.MapConfigurationPropertySource;
import org.springframework.validation.beanvalidation.LocalValidatorFactoryBean;

/** 强类型配置：分组绑定、必填校验与敏感字段脱敏。 */
class ConfigPropertiesTest {
  private static final String SECRET =
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

  @Test
  void bindsGroupedPropertiesAndRedactsSecrets() {
    var source =
        new MapConfigurationPropertySource(
            Map.of(
                "vaultone.server-secret", SECRET,
                "vaultone.redis.address", "redis://127.0.0.1:6379",
                "vaultone.redis.password", "redis-secret-value",
                "vaultone.redis.namespace", "vaultone:test",
                "vaultone.development.enabled", "true",
                "vaultone.development.allow-test-kdf", "true",
                "vaultone.web.max-body-bytes", "2048",
                "vaultone.web.allowed-origins", "https://app.example.test"));
    VaultOneProperties props =
        new Binder(source).bind("vaultone", Bindable.of(VaultOneProperties.class)).get();
    assertThat(props.serverSecret()).isEqualTo(SECRET);
    assertThat(props.redis().address()).isEqualTo("redis://127.0.0.1:6379");
    assertThat(props.redis().namespace()).isEqualTo("vaultone:test");
    assertThat(props.development().enabled()).isTrue();
    assertThat(props.development().allowTestKdf()).isTrue();
    assertThat(props.web().maxBodyBytes()).isEqualTo(2048L);
    assertThat(props.web().allowedOrigins()).containsExactly("https://app.example.test");
    assertThat(props.toString()).doesNotContain(SECRET).doesNotContain("redis-secret-value");
    assertThat(props.redis().toString()).doesNotContain("redis-secret-value");
  }

  @Test
  void bindsMailTlsAndTimeoutOverrides() {
    var source =
        new MapConfigurationPropertySource(
            Map.of(
                "vaultone.server-secret", SECRET,
                "vaultone.mail.mode", "smtp",
                "vaultone.mail.from", "VaultOne <no-reply@vaultone.app>",
                "vaultone.mail.smtp-host", "smtp.example.test",
                "vaultone.mail.smtp-port", "587",
                "vaultone.mail.start-tls-required", "true",
                "vaultone.mail.ssl-enabled", "false",
                "vaultone.mail.connection-timeout-millis", "4000"));
    VaultOneProperties props =
        new Binder(source).bind("vaultone", Bindable.of(VaultOneProperties.class)).get();
    assertThat(props.mail().smtpHost()).isEqualTo("smtp.example.test");
    assertThat(props.mail().smtpPort()).isEqualTo(587);
    assertThat(props.mail().startTlsRequired()).isTrue();
    assertThat(props.mail().sslEnabled()).isFalse();
    assertThat(props.mail().connectionTimeoutMillis()).isEqualTo(4000);
  }

  @Test
  void legacyConstructorsRemainCompatibleWithSafeDefaults() {
    var redis = new VaultOneProperties.Redis("redis://127.0.0.1:6379", null);
    assertThat(redis.namespace()).isEqualTo("vaultone");
    var development = new VaultOneProperties.Development(true);
    assertThat(development.allowTestKdf()).isFalse();
    var web = new VaultOneProperties.Web(1048576L, 67108864L, 128, 100, 256, null);
    assertThat(web.allowedOrigins()).isEmpty();
  }

  @Test
  void blankSecretAndRedisAddressFailValidation() throws Exception {
    try (var factory = new LocalValidatorFactoryBean()) {
      factory.afterPropertiesSet();
      Validator validator = factory.getValidator();
      var props =
          new VaultOneProperties(
              "local",
              "",
              new VaultOneProperties.Redis("", null),
              new VaultOneProperties.Development(false),
              new VaultOneProperties.Session(60, 3600, 120, 600, 5, 3000, 10, 100, 120, 16),
              new VaultOneProperties.Mail(
                  "log", "VaultOne <no-reply@vaultone.app>", "", 587, "", ""),
              new VaultOneProperties.Ops(
                  30, java.time.Duration.ofDays(30), "100MB", "2GB", "logs", 64));
      var violations = validator.validate(props);
      assertThat(violations).isNotEmpty();
      assertThat(violations.stream().map(v -> v.getPropertyPath().toString()).toList())
          .contains("serverSecret", "redis.address");
    }
  }
}
