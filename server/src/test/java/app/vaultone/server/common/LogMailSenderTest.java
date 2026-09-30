package app.vaultone.server.common;

import static org.assertj.core.api.Assertions.assertThat;

import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import java.util.stream.Collectors;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;

/** 开发邮件日志不得输出验证码/正文/主题/邮箱或用户可控字段（防泄漏与日志注入）。 */
class LogMailSenderTest {
  @Test
  void devMailLogsOnlyFixedEvent() {
    Logger logger = (Logger) LoggerFactory.getLogger("vaultone.mail");
    ListAppender<ILoggingEvent> appender = new ListAppender<>();
    appender.start();
    logger.addAppender(appender);
    try {
      new LogMailSender().send("alice@example.test\nINJECT", "登录验证码", "OTP=654321");
      String logged =
          appender.list.stream()
              .map(ILoggingEvent::getFormattedMessage)
              .collect(Collectors.joining("\n"));
      assertThat(logged)
          .doesNotContain("654321")
          .doesNotContain("alice")
          .doesNotContain("example.test")
          .doesNotContain("INJECT")
          .doesNotContain("OTP")
          .doesNotContain("登录验证码")
          .contains("dev mail suppressed");
    } finally {
      logger.detachAppender(appender);
      appender.stop();
    }
  }
}
