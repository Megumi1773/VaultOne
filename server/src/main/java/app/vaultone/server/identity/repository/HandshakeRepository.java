package app.vaultone.server.identity.repository;

import java.util.List;
import java.util.Optional;
import javax.sql.DataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

/**
 * 登录握手临时记录。无账户上下文（登录 start 尚未建立身份），故经 SQL 侧窄 SECURITY DEFINER 函数 {@code
 * vaultone_insert_handshake}/{@code vaultone_claim_handshake} 访问，不直接对启用了 RLS 的 handshakes 表做无身份读写。
 *
 * <p>领取即删除（{@code DELETE ... RETURNING}）；独立短事务提交后才验 proof，错误 proof 不复活握手。
 */
@Repository
public class HandshakeRepository {
  private final JdbcTemplate jdbc;

  public HandshakeRepository(DataSource dataSource) {
    this.jdbc = new JdbcTemplate(dataSource);
  }

  /** 领取结果：{@code userId} 可为 null（未注册邮箱的 decoy 握手），{@code expiresAt} 为 ISO-8601 UTC 文本。 */
  public record HandshakeRow(String userId, byte[] bEnc, String expiresAt) {}

  /** 独立短事务写入握手。 */
  @Transactional
  public void insert(String id, String userId, byte[] bEnc, String expiresAt) {
    jdbc.queryForObject(
        "SELECT vaultone_insert_handshake(?, ?, ?, ?)", Object.class, id, userId, bEnc, expiresAt);
  }

  /** 独立短事务：原子领取并删除；不存在返回空。 */
  @Transactional
  public Optional<HandshakeRow> claim(String id) {
    List<HandshakeRow> rows =
        jdbc.query(
            "SELECT user_id, b_enc, expires_at FROM vaultone_claim_handshake(?)",
            (rs, i) -> new HandshakeRow(rs.getString(1), rs.getBytes(2), rs.getString(3)),
            id);
    return rows.isEmpty() ? Optional.empty() : Optional.of(rows.get(0));
  }

  @Transactional
  public int deleteExpired(String now) {
    Object result =
        jdbc.queryForObject("SELECT vaultone_purge_expired_handshakes(?)", Object.class, now);
    return result instanceof Number n ? n.intValue() : 0;
  }
}
