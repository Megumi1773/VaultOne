package app.vaultone.server.security;

/**
 * 当前请求的认证主体持有者（ThreadLocal，同一虚拟线程内有效）。由 {@link AuthArgumentResolver} 在解析 {@link Authed}/{@link
 * Approved} 时设置；供事务审计上下文（Envers 修订 actor）读取可信 account/device。
 *
 * <p>请求结束必须清理（由 {@link app.vaultone.server.web.RequestIdFilter} 在 finally 调用 {@link #clear()}）。
 * 不跨线程继承；异步/派生线程需显式传递（本批次不使用）。
 */
public final class PrincipalHolder {
  private static final ThreadLocal<Authed> CURRENT = new ThreadLocal<>();

  private PrincipalHolder() {}

  public static void set(Authed authed) {
    CURRENT.set(authed);
  }

  public static Authed get() {
    return CURRENT.get();
  }

  public static void clear() {
    CURRENT.remove();
  }
}
