package app.vaultone.server.common;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.config.VaultOneProperties;
import java.util.Properties;
import org.junit.jupiter.api.Test;
import org.springframework.mail.javamail.JavaMailSenderImpl;

/** SMTP 契约测试：确认实际构造的 host/port/超时/STARTTLS/主机名校验，并验证失败映射为 503。 */
class SmtpMailSenderTest {
  private static VaultOneProperties.Mail mail(String host, int port) {
    return new VaultOneProperties.Mail(
        "smtp",
        "VaultOne <no-reply@vaultone.app>",
        host,
        port,
        "user",
        "public-test-only",
        true,
        false,
        4000,
        5000,
        6000);
  }

  @Test
  void missingHostFailsFast() {
    try {
      MailConfiguration.smtpJavaMailSender(mail("", 587));
      org.assertj.core.api.Assertions.fail("应当因缺少 SMTP 主机而拒绝");
    } catch (IllegalStateException expected) {
      assertThat(expected).hasMessageContaining("smtp-host");
    }
  }

  @Test
  void configuresTimeoutsStartTlsAndHostnameVerification() {
    JavaMailSenderImpl sender =
        MailConfiguration.smtpJavaMailSender(mail("smtp.example.test", 587));
    assertThat(sender.getHost()).isEqualTo("smtp.example.test");
    assertThat(sender.getPort()).isEqualTo(587);
    Properties props = sender.getJavaMailProperties();
    assertThat(props.getProperty("mail.smtp.connectiontimeout")).isEqualTo("4000");
    assertThat(props.getProperty("mail.smtp.timeout")).isEqualTo("5000");
    assertThat(props.getProperty("mail.smtp.writetimeout")).isEqualTo("6000");
    assertThat(props.getProperty("mail.smtp.starttls.required")).isEqualTo("true");
    assertThat(props.getProperty("mail.smtp.ssl.checkserveridentity")).isEqualTo("true");
    assertThat(props.getProperty("mail.smtp.auth")).isEqualTo("true");
  }

  @Test
  void sendFailureMapsToServiceUnavailableWithoutLeaking() {
    JavaMailSenderImpl impl = new JavaMailSenderImpl();
    impl.setHost("127.0.0.1");
    impl.setPort(1);
    impl.getJavaMailProperties().put("mail.smtp.connectiontimeout", "200");
    impl.getJavaMailProperties().put("mail.smtp.timeout", "200");
    var sender = new SmtpMailSender(impl, mail("127.0.0.1", 1));

    try {
      sender.send("alice@example.test", "subject", "body");
      org.assertj.core.api.Assertions.fail("连接失败应映射为 503");
    } catch (ApiException ex) {
      assertThat(ex.status()).isEqualTo(503);
      assertThat(ex.getMessage()).doesNotContain("alice@example.test");
    }
  }
}
