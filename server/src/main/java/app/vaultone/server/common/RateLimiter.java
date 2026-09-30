package app.vaultone.server.common;

/**
 * 分布式限流抽象。按分组（auth / api）与可信客户端来源键限流；实现负责把来源地址摘要化，不保存原始 IP。
 *
 * <p>后端不可用时抛 {@link RateLimitUnavailableException}，由 Web 边界安全拒绝（503），不得静默放行。
 */
public interface RateLimiter {
  /**
   * 尝试获取一个令牌。
   *
   * @param group 限流分组（例如 {@code auth} / {@code api}）
   * @param clientAddress 可信连接来源地址（不信任 Forwarded 头）
   * @return 允许则 true；超限 false
   */
  boolean tryAcquire(String group, String clientAddress);
}
