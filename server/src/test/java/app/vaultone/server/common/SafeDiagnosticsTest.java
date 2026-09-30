package app.vaultone.server.common;

import static org.assertj.core.api.Assertions.assertThat;

import java.sql.SQLException;
import org.junit.jupiter.api.Test;

/** 安全诊断白名单：嵌套 SQLException 的口令/邮箱/token 不得进入日志文本。 */
class SafeDiagnosticsTest {
  @Test
  void nestedSqlExceptionDoesNotLeakSensitiveText() {
    String sensitive = "password=sup3r-secret email=alice@example.test token=abc123";
    SQLException root = new SQLException("JDBC DETAIL: " + sensitive, "23505");
    RuntimeException wrapped = new RuntimeException("wrapper " + sensitive, root);

    String text = SafeDiagnostics.describe(wrapped);

    assertThat(text).contains("type=java.lang.RuntimeException").contains("sqlState=23505");
    assertThat(text)
        .doesNotContain("sup3r-secret")
        .doesNotContain("alice@example.test")
        .doesNotContain("abc123")
        .doesNotContain("JDBC DETAIL")
        .doesNotContain("wrapper");
  }
}
