package app.vaultone.server.common;

/** 限流后端（Redis）不可用；受保护/认证入口据此安全拒绝（503），不无限放行。 */
public class RateLimitUnavailableException extends RuntimeException {
  public RateLimitUnavailableException(String message, Throwable cause) {
    super(message, cause);
  }
}
