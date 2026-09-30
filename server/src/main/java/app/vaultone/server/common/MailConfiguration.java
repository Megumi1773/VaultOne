package app.vaultone.server.common;

import app.vaultone.server.config.VaultOneProperties;
import java.util.Properties;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.mail.javamail.JavaMailSenderImpl;

/**
 * 邮件实现选择：{@code vaultone.mail.mode=log}（缺省）用日志实现，{@code =smtp} 用真实 SMTP。
 *
 * <p>条件互斥，确保容器内只有一个业务 {@link MailSender}，业务层无需感知实现。SMTP 走 Spring Boot 支持的 {@link
 * JavaMailSenderImpl}，固定连接/读取/写超时，强制主机名校验，不手搓协议。
 */
@Configuration(proxyBeanMethods = false)
public class MailConfiguration {
  @Bean
  @ConditionalOnProperty(name = "vaultone.mail.mode", havingValue = "log", matchIfMissing = true)
  MailSender logMailSender() {
    return new LogMailSender();
  }

  @Bean
  @ConditionalOnProperty(name = "vaultone.mail.mode", havingValue = "smtp")
  JavaMailSender javaMailSender(VaultOneProperties properties) {
    return smtpJavaMailSender(properties.mail());
  }

  @Bean
  @ConditionalOnProperty(name = "vaultone.mail.mode", havingValue = "smtp")
  MailSender smtpMailSender(JavaMailSender sender, VaultOneProperties properties) {
    return new SmtpMailSender(sender, properties.mail());
  }

  /** 构造真实 SMTP 发送器；缺关键配置立即失败，不静默降级。 */
  static JavaMailSenderImpl smtpJavaMailSender(VaultOneProperties.Mail mail) {
    if (mail.smtpHost() == null || mail.smtpHost().isBlank()) {
      throw new IllegalStateException("SMTP 模式必须配置 vaultone.mail.smtp-host");
    }
    if (mail.from() == null || mail.from().isBlank()) {
      throw new IllegalStateException("SMTP 模式必须配置 vaultone.mail.from");
    }
    JavaMailSenderImpl sender = new JavaMailSenderImpl();
    sender.setHost(mail.smtpHost());
    sender.setPort(mail.smtpPort());
    sender.setDefaultEncoding("UTF-8");
    boolean auth = mail.smtpUsername() != null && !mail.smtpUsername().isBlank();
    if (auth) {
      sender.setUsername(mail.smtpUsername());
    }
    if (mail.smtpPassword() != null) {
      sender.setPassword(mail.smtpPassword());
    }
    Properties props = sender.getJavaMailProperties();
    props.put("mail.transport.protocol", "smtp");
    props.put("mail.smtp.auth", Boolean.toString(auth));
    props.put("mail.smtp.starttls.enable", "true");
    props.put("mail.smtp.starttls.required", Boolean.toString(mail.startTlsRequired()));
    props.put("mail.smtp.ssl.enable", Boolean.toString(mail.sslEnabled()));
    props.put("mail.smtp.ssl.checkserveridentity", "true");
    props.put("mail.smtp.connectiontimeout", Integer.toString(mail.connectionTimeoutMillis()));
    props.put("mail.smtp.timeout", Integer.toString(mail.readTimeoutMillis()));
    props.put("mail.smtp.writetimeout", Integer.toString(mail.writeTimeoutMillis()));
    return sender;
  }
}
