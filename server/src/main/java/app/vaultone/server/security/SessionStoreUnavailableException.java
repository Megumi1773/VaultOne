package app.vaultone.server.security;

/** Redis 会话存储不可用；受保护接口据此安全拒绝（503），不得回退 PG 会话。 */
public class SessionStoreUnavailableException extends RuntimeException {
  public SessionStoreUnavailableException(String message, Throwable cause) {
    super(message, cause);
  }

  public SessionStoreUnavailableException(String message) {
    super(message);
  }
}
