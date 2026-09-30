package app.vaultone.server.identity.repository;

import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.util.Optional;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

/**
 * 身份引导（无账户上下文）仓储：只调用 SQL 侧窄 SECURITY DEFINER 函数（见 {@code
 * target/java-migration-check/identity-db-contract.md}），不直接对用户表做无身份 SELECT/INSERT。
 *
 * <p>函数签名由 SQL 作者按契约实现；调用一律参数化，不拼接 SQL。
 */
@Repository
public class IdentityBootstrapRepository {
  @PersistenceContext private EntityManager em;

  /** 邮箱 HMAC 是否已注册（并发仍以唯一约束为准）。 */
  public boolean emailExists(byte[] emailHash) {
    Object result =
        em.createNativeQuery("SELECT vaultone_email_exists(:hash)")
            .setParameter("hash", emailHash)
            .getSingleResult();
    return toBoolean(result);
  }

  /** 按邮箱 HMAC 取账户 ID。 */
  public Optional<String> accountIdByEmailHash(byte[] emailHash) {
    @SuppressWarnings("unchecked")
    java.util.List<String> rows =
        em.createNativeQuery("SELECT vaultone_lookup_account_id(:hash)")
            .setParameter("hash", emailHash)
            .getResultList();
    return rows.isEmpty() || rows.get(0) == null ? Optional.empty() : Optional.of(rows.get(0));
  }

  /** 账户 + 首台设备原子插入（仅 INSERT，不 UPDATE/MERGE）。 */
  @Transactional
  public void registerAccount(
      String id,
      byte[] emailHash,
      byte[] emailEnc,
      String kdf,
      byte[] srpSalt,
      byte[] srpVerifier,
      String vaultId,
      byte[] vkWrap,
      long vkGen,
      byte[] recoveryWrap,
      byte[] recoveryAuthHash,
      String deviceId,
      String deviceName,
      String devicePlatform,
      String now) {
    em.createNativeQuery(
            "SELECT vaultone_register_account("
                + ":id,:emailHash,:emailEnc,:kdf,:srpSalt,:srpVerifier,:vaultId,"
                + ":vkWrap,:vkGen,:recoveryWrap,:recoveryAuthHash,"
                + ":deviceId,:deviceName,:devicePlatform,:now)")
        .setParameter("id", id)
        .setParameter("emailHash", emailHash)
        .setParameter("emailEnc", emailEnc)
        .setParameter("kdf", kdf)
        .setParameter("srpSalt", srpSalt)
        .setParameter("srpVerifier", srpVerifier)
        .setParameter("vaultId", vaultId)
        .setParameter("vkWrap", vkWrap)
        .setParameter("vkGen", vkGen)
        .setParameter("recoveryWrap", recoveryWrap)
        .setParameter("recoveryAuthHash", recoveryAuthHash)
        .setParameter("deviceId", deviceId)
        .setParameter("deviceName", deviceName)
        .setParameter("devicePlatform", devicePlatform)
        .setParameter("now", now)
        .getSingleResult();
  }

  /** 恢复引导：按邮箱取账户 ID 与恢复校验哈希。 */
  public Optional<RecoveryLookup> recoveryLookup(byte[] emailHash) {
    @SuppressWarnings("unchecked")
    java.util.List<Object[]> rows =
        em.createNativeQuery("SELECT id, recovery_auth_hash FROM vaultone_recovery_lookup(:hash)")
            .setParameter("hash", emailHash)
            .getResultList();
    if (rows.isEmpty()) {
      return Optional.empty();
    }
    Object[] row = rows.get(0);
    return Optional.of(new RecoveryLookup((String) row[0], (byte[]) row[1]));
  }

  /** 恢复完成：锁账户 + 重验旧凭据快照 + CAS（仅一胜），返回是否成功。 */
  @Transactional
  public boolean recoveryComplete(
      String id,
      byte[] expectRecoveryAuthHash,
      long expectSessionEpoch,
      long expectVkGen,
      String kdf,
      byte[] srpSalt,
      byte[] srpVerifier,
      byte[] vkWrap,
      byte[] recoveryWrap,
      byte[] recoveryAuthHash,
      String deviceId,
      String deviceName,
      String devicePlatform,
      String now) {
    Object result =
        em.createNativeQuery(
                "SELECT vaultone_recovery_complete("
                    + ":id,:expectHash,:expectEpoch,:expectVkGen,:kdf,:srpSalt,:srpVerifier,"
                    + ":vkWrap,:recoveryWrap,:recoveryAuthHash,"
                    + ":deviceId,:deviceName,:devicePlatform,:now)")
            .setParameter("id", id)
            .setParameter("expectHash", expectRecoveryAuthHash)
            .setParameter("expectEpoch", expectSessionEpoch)
            .setParameter("expectVkGen", expectVkGen)
            .setParameter("kdf", kdf)
            .setParameter("srpSalt", srpSalt)
            .setParameter("srpVerifier", srpVerifier)
            .setParameter("vkWrap", vkWrap)
            .setParameter("recoveryWrap", recoveryWrap)
            .setParameter("recoveryAuthHash", recoveryAuthHash)
            .setParameter("deviceId", deviceId)
            .setParameter("deviceName", deviceName)
            .setParameter("devicePlatform", devicePlatform)
            .setParameter("now", now)
            .getSingleResult();
    return toBoolean(result);
  }

  /** 握手写入（user_id 可为 null）。 */
  @Transactional
  public void insertHandshake(String id, String userId, byte[] bEnc, String expiresAt) {
    em.createNativeQuery("SELECT vaultone_insert_handshake(:id,:uid,:b,:exp)")
        .setParameter("id", id)
        .setParameter("uid", userId)
        .setParameter("b", bEnc)
        .setParameter("exp", expiresAt)
        .getSingleResult();
  }

  private static boolean toBoolean(Object value) {
    if (value instanceof Boolean b) {
      return b;
    }
    return value != null && Boolean.parseBoolean(value.toString());
  }

  /** 恢复引导结果。 */
  public record RecoveryLookup(String id, byte[] recoveryAuthHash) {}
}
