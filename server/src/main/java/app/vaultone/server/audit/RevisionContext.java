package app.vaultone.server.audit;

import java.util.Optional;

/**
 * Envers 修订审计上下文：由 {@link RevisionContextAspect} 在事务边界绑定，从可信认证主体取得 account/device/request，并在事务
 * {@code afterCompletion} 恢复/清理。绝不从请求体读取所有者。
 */
public final class RevisionContext {
  /** 上下文值。 */
  public record Context(String accountId, String actorDeviceId, String requestId) {}

  private static final ThreadLocal<Context> CONTEXT = new ThreadLocal<>();

  private RevisionContext() {}

  public static void set(String accountId, String actorDeviceId, String requestId) {
    CONTEXT.set(new Context(accountId, actorDeviceId, requestId == null ? "-" : requestId));
  }

  /** 无认证主体的事务（注册等）显式标记为 system，不静默掩盖。 */
  public static void setSystem() {
    CONTEXT.set(new Context("system", null, "-"));
  }

  /**
   * 以被操作的账户补齐上下文（当当前为 system 占位时）：公开流程（登录/恢复）无 PrincipalHolder， 但写入的 @Audited 实体属于该账户，revinfo 的 RLS
   * 要求 user_id 与账户上下文一致。
   */
  public static void bindAccountIfAbsent(String accountId) {
    Context c = CONTEXT.get();
    if (c == null || "system".equals(c.accountId())) {
      CONTEXT.set(
          new Context(
              accountId, c == null ? null : c.actorDeviceId(), c == null ? "-" : c.requestId()));
    }
  }

  public static Context current() {
    Context c = CONTEXT.get();
    // 未绑定即视为编程错误：Envers 写入不可能在无上下文时发生（Aspect 覆盖 @Transactional）。
    if (c == null) {
      throw new IllegalStateException("审计上下文缺失：事务未经 RevisionContextAspect 绑定");
    }
    return c;
  }

  public static Optional<Context> peek() {
    return Optional.ofNullable(CONTEXT.get());
  }

  public static void clear() {
    CONTEXT.remove();
  }
}
