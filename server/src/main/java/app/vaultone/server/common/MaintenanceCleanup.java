package app.vaultone.server.common;

import app.vaultone.server.identity.repository.DeviceOtpRepository;
import app.vaultone.server.identity.repository.HandshakeRepository;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * 有界维护清理：只删已过期行，在独立短事务内执行（由 {@link MaintenanceScheduler} 先取锁后再调用，避免持锁跨事务）。
 *
 * <p>清理不读取或记录用户内容，只删除已到期的记录；会话索引随 Redis TTL 自然过期，无需逐请求写库。
 */
@Component
public class MaintenanceCleanup {
  private final HandshakeRepository handshakes;
  private final DeviceOtpRepository otps;
  @jakarta.persistence.PersistenceContext private jakarta.persistence.EntityManager em;

  public MaintenanceCleanup(HandshakeRepository handshakes, DeviceOtpRepository otps) {
    this.handshakes = handshakes;
    this.otps = otps;
  }

  /**
   * @return {@code [handshakes, otps, feedback]} 删除行数。
   */
  @Transactional
  public int[] purgeExpired(String now) {
    int feedback =
        ((Number)
                em.createNativeQuery("select public.vaultone_purge_expired_feedback()")
                    .getSingleResult())
            .intValue();
    return new int[] {handshakes.deleteExpired(now), otps.deleteExpired(now), feedback};
  }
}
