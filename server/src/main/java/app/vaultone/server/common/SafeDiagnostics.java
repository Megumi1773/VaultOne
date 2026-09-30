package app.vaultone.server.common;

import java.sql.SQLException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;

/**
 * 系统异常诊断白名单：只输出异常类型、SQLState、有限安全堆栈位置与请求关联 ID。
 *
 * <p>绝不输出原始 {@link Throwable#getMessage()}、cause message、SQL 绑定值、DTO 或请求体；避免 JDBC DETAIL/参数/凭据
 * 泄漏到日志。每次只记录一份诊断。
 */
public final class SafeDiagnostics {
  private static final Logger log = LoggerFactory.getLogger("vaultone.diagnostics");
  private static final int MAX_CHAIN = 10;

  private SafeDiagnostics() {}

  /** 记录一次安全诊断（不抛异常）。 */
  public static void logUnhandled(Throwable ex) {
    if (ex == null) {
      return;
    }
    log.error("unhandled server error {}", describe(ex));
  }

  /** 生成安全诊断文本；包可见以便单测断言不泄漏敏感内容。 */
  static String describe(Throwable ex) {
    StringBuilder sb = new StringBuilder(128);
    sb.append("type=").append(ex.getClass().getName());
    String sqlState = sqlState(ex);
    if (sqlState != null) {
      sb.append(" sqlState=").append(sqlState);
    }
    String location = firstSafeLocation(ex);
    if (location != null) {
      sb.append(" at=").append(location);
    }
    String requestId = MDC.get("requestId");
    if (requestId != null && !requestId.isBlank()) {
      sb.append(" requestId=").append(requestId);
    }
    return sb.toString();
  }

  private static String sqlState(Throwable ex) {
    Throwable t = ex;
    int depth = 0;
    while (t != null && depth++ < MAX_CHAIN) {
      if (t instanceof SQLException sql) {
        String state = sql.getSQLState();
        if (state != null && !state.isBlank()) {
          return state;
        }
      }
      t = t.getCause();
    }
    return null;
  }

  /** 优先取本应用内第一帧（代码位置，无参数值）；否则退化为类名与方法名，不含 message。 */
  private static String firstSafeLocation(Throwable ex) {
    StackTraceElement[] frames = ex.getStackTrace();
    if (frames == null || frames.length == 0) {
      return null;
    }
    for (StackTraceElement frame : frames) {
      if (frame.getClassName().startsWith("app.vaultone.")) {
        return frame.getClassName()
            + "."
            + frame.getMethodName()
            + "("
            + frame.getFileName()
            + ":"
            + frame.getLineNumber()
            + ")";
      }
    }
    StackTraceElement first = frames[0];
    return first.getClassName() + "." + first.getMethodName();
  }
}
