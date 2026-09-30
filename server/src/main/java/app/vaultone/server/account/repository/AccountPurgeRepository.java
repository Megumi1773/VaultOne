package app.vaultone.server.account.repository;

import javax.sql.DataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

/**
 * 注销账户的原生删除：全部按 {@code user_id} 账户范围限定，绝不使用无条件批量 DML。
 *
 * <p>条目、版本历史与 change_log 由 {@link
 * app.vaultone.server.sync.SyncService#wipeAccount(app.vaultone.server.security.Approved)}
 * 负责；关联握手和会话撤销标记通过账户外键级联清理。
 */
@Repository
public class AccountPurgeRepository {
  private final JdbcTemplate jdbc;

  public AccountPurgeRepository(DataSource dataSource) {
    this.jdbc = new JdbcTemplate(dataSource);
  }

  public int deleteDeviceOtps(String userId) {
    return jdbc.update("DELETE FROM device_otps WHERE user_id = ?", userId);
  }

  public int deleteDevices(String userId) {
    return jdbc.update("DELETE FROM devices WHERE user_id = ?", userId);
  }

  public int deleteAuditEvents(String userId) {
    return jdbc.update("DELETE FROM audit_events WHERE user_id = ?", userId);
  }

  public int deleteUser(String userId) {
    return jdbc.update("DELETE FROM users WHERE id = ?", userId);
  }
}
