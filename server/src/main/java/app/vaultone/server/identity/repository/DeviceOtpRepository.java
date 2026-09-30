package app.vaultone.server.identity.repository;

import java.util.Optional;
import javax.sql.DataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

/**
 * 新设备验证码：只存哈希、过期与尝试次数；复合主键 (user_id, device_id)。device_otps 受 RLS 约束，故每个 事务先设置账户上下文（user_id），否则
 * WITH CHECK 会因无上下文拒绝。
 */
@Repository
public class DeviceOtpRepository {
  private final JdbcTemplate jdbc;

  public DeviceOtpRepository(DataSource dataSource) {
    this.jdbc = new JdbcTemplate(dataSource);
  }

  public record OtpRow(byte[] codeHash, String expiresAt, long attempts) {}

  @Transactional
  public void replace(String userId, String deviceId, byte[] codeHash, String expiresAt) {
    bindContext(userId);
    jdbc.update("DELETE FROM device_otps WHERE user_id = ? AND device_id = ?", userId, deviceId);
    jdbc.update(
        "INSERT INTO device_otps(user_id, device_id, code_hash, expires_at, attempts) VALUES(?, ?, ?, ?, 0)",
        userId,
        deviceId,
        codeHash,
        expiresAt);
  }

  @Transactional
  public Optional<OtpRow> find(String userId, String deviceId) {
    bindContext(userId);
    var rows =
        jdbc.query(
            "SELECT code_hash, expires_at, attempts FROM device_otps WHERE user_id = ? AND device_id = ?",
            (rs, i) -> new OtpRow(rs.getBytes(1), rs.getString(2), rs.getLong(3)),
            userId,
            deviceId);
    return rows.isEmpty() ? Optional.empty() : Optional.of(rows.get(0));
  }

  @Transactional
  public void delete(String userId, String deviceId) {
    bindContext(userId);
    jdbc.update("DELETE FROM device_otps WHERE user_id = ? AND device_id = ?", userId, deviceId);
  }

  @Transactional
  public int deleteExpired(String now) {
    // 维护路径：无账户上下文，按过期时间删除；仅能删 user_id 与应用上下文一致的行（无上下文则仅删 user_id IS NULL）。
    return jdbc.update("DELETE FROM device_otps WHERE expires_at < ?", now);
  }

  private void bindContext(String userId) {
    jdbc.queryForObject("SELECT set_config('vaultone.account_id', ?, true)", String.class, userId);
  }
}
