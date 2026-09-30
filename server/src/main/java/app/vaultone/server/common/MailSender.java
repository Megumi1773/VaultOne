package app.vaultone.server.common;

/** 邮件发送抽象。业务在业务事务提交后调用；dev 用日志、prod 用 SMTP。 */
public interface MailSender {
  void send(String to, String subject, String body);
}
