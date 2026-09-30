package app.vaultone.server.security;

import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.proto.SessionInfo;
import java.time.Instant;
import org.springframework.stereotype.Component;

/**
 * 跨 PG/Redis 会话签发：先生成候选 token 并把元数据写入 Redis，再由调用方在 PG 短事务提交业务状态； 只有 PG 提交后才把 token 返回客户端。PG 未提交时按
 * token 查不到授权状态，候选会话绝不可认证。
 */
@Component
public class SessionIssuer {
  private final SessionStore store;
  private final VaultOneProperties.Session session;

  public SessionIssuer(SessionStore store, VaultOneProperties properties) {
    this.store = store;
    this.session = properties.session();
  }

  /**
   * 准备候选会话：原子写 Redis，返回 token 与元数据。调用方必须在 PG 提交后调用 {@link #sessionInfo(PendingSession, boolean)}
   * 交付客户端，或在失败/未提交时 {@link #abort(PendingSession)} 清理候选键。
   */
  public PendingSession prepare(
      String userId,
      String deviceId,
      long deviceEpoch,
      boolean approved,
      long sessionEpoch,
      Instant now) {
    String token = SessionTokens.newToken();
    String hashHex = SessionTokens.hashHex(token);
    Instant expiresAt = now.plusSeconds(session.ttlDays() * 86400L);
    SessionMetadata metadata =
        new SessionMetadata(
            userId, deviceId, sessionEpoch, deviceEpoch, now, now, expiresAt, approved);
    store.put(hashHex, metadata);
    return new PendingSession(token, hashHex, metadata, expiresAt, deviceId);
  }

  /** PG 提交后交付给客户端的会话信息。 */
  public SessionInfo sessionInfo(PendingSession pending, boolean approved) {
    return new SessionInfo(
        pending.token(), pending.expiresAt().getEpochSecond(), pending.deviceId(), approved);
  }

  /** PG 未提交/失败：清理候选键。清理失败也不影响安全（PG 无授权状态，token 不可用）。 */
  public void abort(PendingSession pending) {
    try {
      store.delete(pending.tokenHashHex());
    } catch (RuntimeException ignored) {
      // Redis 不可用或键已过期：候选会话本就不可认证，无需上抛。
    }
  }

  /** 候选会话句柄。 */
  public record PendingSession(
      String token,
      String tokenHashHex,
      SessionMetadata metadata,
      Instant expiresAt,
      String deviceId) {
    @Override
    public String toString() {
      return "PendingSession[redacted]";
    }
  }
}
