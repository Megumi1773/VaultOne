package app.vaultone.server.identity.repository;

import javax.sql.DataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * 单会话撤销标记（PG 持久化，不依赖 Redis 快照）。仅 logout 生命周期写一行；授权检查时一并查询。
 *
 * <p>{@code token_hash} 为 {@code SHA-256(token 文本 UTF-8)} 十六进制文本，不存 token 原文。 表 {@code
 * session_revocations(user_id, token_hash, expires_at)}，按 user_id RLS；写/查都在账户上下文内。
 */
@Component
public class SessionRevocation {
  private final JdbcTemplate jdbc;

  public SessionRevocation(DataSource dataSource) {
    this.jdbc = new JdbcTemplate(dataSource);
  }

  /** 记录撤销标记（幂等）。 */
  @Transactional
  public void revoke(String userId, String tokenHashHex, String expiresAt) {
    jdbc.queryForObject("SELECT set_config('vaultone.account_id', ?, true)", String.class, userId);
    jdbc.update(
        "INSERT INTO session_revocations(user_id, token_hash, expires_at) VALUES(?, ?, ?)"
            + " ON CONFLICT (user_id, token_hash) DO UPDATE SET expires_at = EXCLUDED.expires_at",
        userId,
        tokenHashHex,
        expiresAt);
  }

  /** 是否存在未过期的撤销标记（授权检查用）。在账户上下文内调用。 */
  @Transactional(propagation = Propagation.MANDATORY)
  public boolean isRevoked(String userId, String tokenHashHex, String now) {
    Integer count =
        jdbc.queryForObject(
            "SELECT COUNT(*) FROM session_revocations WHERE user_id = ? AND token_hash = ? AND expires_at > ?",
            Integer.class,
            userId,
            tokenHashHex,
            now);
    return count != null && count > 0;
  }

  /** 清理已过期标记（不影响有效会话快照）。 */
  @Transactional
  public int purgeExpired(String now) {
    return jdbc.update("DELETE FROM session_revocations WHERE expires_at < ?", now);
  }
}
