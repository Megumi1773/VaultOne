package app.vaultone.server.common;

import java.time.Duration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 周期维护：清理过期握手与验证码。跨实例用 {@link MaintenanceLock} 互斥，先拿锁后开数据库事务（见 {@link
 * MaintenanceCleanup}），删改有界（只删已过期行）。不触碰用户数据内容。
 */
@Component
@EnableScheduling
public class MaintenanceScheduler {
  private static final Logger log = LoggerFactory.getLogger(MaintenanceScheduler.class);

  private final MaintenanceCleanup cleanup;
  private final MaintenanceLock lock;

  public MaintenanceScheduler(MaintenanceCleanup cleanup, MaintenanceLock lock) {
    this.cleanup = cleanup;
    this.lock = lock;
  }

  /** 每分钟尝试一次；只有拿到锁的实例执行。 */
  @Scheduled(fixedDelayString = "PT1M")
  public void purgeExpired() {
    String now = InstantText.format(java.time.Instant.now());
    try {
      lock.runIfLocked(
          "purge-expired",
          Duration.ofSeconds(1),
          Duration.ofSeconds(30),
          () -> {
            int[] removed = cleanup.purgeExpired(now);
            if (removed[0] + removed[1] > 0) {
              log.info("purged expired handshakes={} otps={}", removed[0], removed[1]);
            }
          });
    } catch (RuntimeException ex) {
      // Redis 不可用或清理失败：不影响请求路径，下一周期重试；只记事件，不输出异常原文。
      log.warn("maintenance purge skipped");
    }
  }
}
