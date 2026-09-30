package app.vaultone.server.security;

import java.time.Instant;
import java.util.Optional;

/**
 * 会话主存抽象。生产实现为 Redis；同一接口让业务层不直接依赖 Redisson。
 *
 * <p>Redis 故障时实现必须抛 {@link SessionStoreUnavailableException}，由上层安全拒绝（503），不得静默回退到 PG
 * 或返回“未认证”冒充密码错误。
 */
public interface SessionStore {
  /**
   * 原子创建会话（写全部字段并设置 TTL，一次 Lua 完成；不得先写后设 TTL，避免断连留下永久键）。 Redis 失败抛 {@link
   * SessionStoreUnavailableException}。
   */
  void put(String tokenHashHex, SessionMetadata metadata);

  /** 读取会话；缺失返回空。Redis 失败抛 {@link SessionStoreUnavailableException}。 */
  Optional<SessionMetadata> get(String tokenHashHex);

  /**
   * 原子滑动续期：仅当键存在、格式版本匹配、账户/设备/代次一致且未过期时，按节流判定后只更新 expiresAt 与
   * lastRenewedAt；不重建已删除键，不允许并发旧续期缩短有效期。返回是否实际续期。
   */
  boolean renewIfPresent(String tokenHashHex, SessionMetadata expected, Renewal renewal);

  /** 删除单个会话（logout / 单设备撤销）。 */
  void delete(String tokenHashHex);

  /** 删除某账户某设备的全部会话索引（撤销设备时清理）。 */
  void deleteByDevice(String userId, String deviceId);

  /** 续期参数：目标新过期时间与新的 lastRenewedAt。 */
  record Renewal(Instant newExpiresAt, Instant renewedAt) {}
}
