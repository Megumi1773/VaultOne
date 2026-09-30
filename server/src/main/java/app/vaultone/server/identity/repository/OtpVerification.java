package app.vaultone.server.identity.repository;

import app.vaultone.server.audit.AuditEvents;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.common.InstantText;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.model.DeviceEntity;
import app.vaultone.server.security.AccountGuard;
import app.vaultone.server.security.Authed;
import java.time.Instant;
import javax.sql.DataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * OTP 校验的原子闭环（独立事务 bean）。编排入口 {@link
 * app.vaultone.server.identity.service.IdentityService#verifyDevice} 本身**不**开事务，避免业务 400
 * 回滚已提交的失败计数；本类的方法在自身事务内完成：
 *
 * <ol>
 *   <li>经 {@link AccountGuard#lock} 锁账户并重验当前授权（PG session_epoch / 设备未撤销 / devices.epoch / logout
 *       标记）； 身份失效或设备撤销时先拒绝，绝不消耗 OTP、绝不批准；
 *   <li>`SELECT ... FOR UPDATE` 锁定该 (user_id, device_id) OTP 行，同一密码版本内完成过期/上限判定与常量时间比较；
 *   <li>失败：自增 attempts 后正常提交（返回结果而非抛异常，外层再转 400）；
 *   <li>成功：删除 OTP + 通过 JPA 批准设备（触发 Envers 状态修订）+ 写成功业务审计，三者同一事务提交；
 *   <li>已批准：按当前 PG 状态幂等返回，不重复 success 审计。
 * </ol>
 *
 * <p>并发多请求不会同时看到 attempts=4：账户行锁 + OTP 行锁串行化，最后 1 份额度只会放行一个成功者。
 */
@Component
public class OtpVerification {
  /** 校验结果。 */
  public enum Result {
    SUCCESS,
    ALREADY_APPROVED,
    MISMATCH,
    EXPIRED_OR_EXHAUSTED
  }

  private final JdbcTemplate jdbc;
  private final AccountGuard accountGuard;
  private final AuditService audit;

  public OtpVerification(DataSource dataSource, AccountGuard accountGuard, AuditService audit) {
    this.jdbc = new JdbcTemplate(dataSource);
    this.accountGuard = accountGuard;
    this.audit = audit;
  }

  private record Row(byte[] codeHash, String expiresAt, long attempts) {}

  /**
   * 原子校验并（成功时）批准设备。所有写入随本事务提交。
   *
   * @param expectedCodeHash 期望的 OTP 摘要（由调用方用 ServerKeys.otpHash 计算，常量时间比较）
   * @param maxAttempts 允许的最大尝试次数
   * @param by 批准者标识（email-otp）
   */
  @Transactional
  public Result verify(
      Authed authed,
      byte[] expectedCodeHash,
      int maxAttempts,
      String by,
      byte[] ipHash,
      String requestId) {
    // 1) 账户锁 + 完整 principal 重验；失败抛 unauthorized，OTP 不被消耗。
    AccountGuard.Principal principal = accountGuard.lock(authed.ref());
    DeviceEntity device = principal.device();
    if (device.isApproved()) {
      // 2) 已批准：幂等返回，不重复 success 审计、不重复消费。
      return Result.ALREADY_APPROVED;
    }
    String userId = principal.userId();
    String deviceId = principal.deviceId();

    Row row =
        jdbc
            .query(
                "SELECT code_hash, expires_at, attempts FROM device_otps WHERE user_id = ? AND device_id = ? FOR UPDATE",
                (rs, i) -> new Row(rs.getBytes(1), rs.getString(2), rs.getLong(3)),
                userId,
                deviceId)
            .stream()
            .findFirst()
            .orElse(null);
    if (row == null) {
      return Result.EXPIRED_OR_EXHAUSTED;
    }
    Instant now = Instant.now();
    if (row.attempts() >= maxAttempts
        || InstantText.toEpochSecond(row.expiresAt()) < now.getEpochSecond()) {
      jdbc.update("DELETE FROM device_otps WHERE user_id = ? AND device_id = ?", userId, deviceId);
      return Result.EXPIRED_OR_EXHAUSTED;
    }
    if (!ServerKeys.constantTimeEquals(row.codeHash(), expectedCodeHash)) {
      // 失败计数在自身事务内提交（方法返回而非抛异常）。
      jdbc.update(
          "UPDATE device_otps SET attempts = attempts + 1 WHERE user_id = ? AND device_id = ?",
          userId,
          deviceId);
      return Result.MISMATCH;
    }
    // 3) 成功：消费 OTP + JPA 批准设备（Envers 修订）+ 成功审计，同一事务。
    jdbc.update("DELETE FROM device_otps WHERE user_id = ? AND device_id = ?", userId, deviceId);
    device.approve(by, now);
    audit.record(
        userId, deviceId, AuditEvents.DEVICE_APPROVED, AuditService.SUCCESS, requestId, ipHash);
    return Result.SUCCESS;
  }
}
