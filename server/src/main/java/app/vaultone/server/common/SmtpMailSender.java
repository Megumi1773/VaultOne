package app.vaultone.server.common;

import app.vaultone.server.config.VaultOneProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.mail.MailException;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;

/**
 * 生产 SMTP 邮件：委托成熟 {@link JavaMailSender}（连接/读取/写超时与 STARTTLS/主机名校验在 {@link MailConfiguration} 固定）。
 *
 * <p>发送失败统一映射为 503 依赖不可用；日志只记事件与结果，绝不输出收件人、主题、正文或验证码。
 */
public class SmtpMailSender implements MailSender {
  private static final Logger log = LoggerFactory.getLogger("vaultone.mail");

  private final JavaMailSender sender;
  private final String from;

  public SmtpMailSender(JavaMailSender sender, VaultOneProperties.Mail mail) {
    this.sender = sender;
    this.from = mail.from();
  }

  @Override
  public void send(String to, String subject, String body) {
    try {
      SimpleMailMessage message = new SimpleMailMessage();
      message.setFrom(from);
      message.setTo(to);
      message.setSubject(subject);
      message.setText(body);
      sender.send(message);
      log.info("mail delivered");
    } catch (MailException ex) {
      // 不记录异常原文（可能含收件人/服务器信息），只记事件与结果。
      log.warn("mail delivery failed");
      throw ApiException.dependencyUnavailable();
    }
  }
}
