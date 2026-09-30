package app.vaultone.server.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** 开发期邮件：只写事件日志，不投递。为防泄漏与日志注入，日志不输出验证码、正文、主题、邮箱或用户可控字段， 只记固定事件。生产禁止使用本实现。 */
public class LogMailSender implements MailSender {
  private static final Logger log = LoggerFactory.getLogger("vaultone.mail");

  @Override
  public void send(String to, String subject, String body) {
    log.info("dev mail suppressed (log mode)");
  }
}
