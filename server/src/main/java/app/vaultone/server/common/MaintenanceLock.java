package app.vaultone.server.common;

import app.vaultone.server.config.VaultOneProperties;
import java.time.Duration;
import java.util.concurrent.TimeUnit;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * 跨实例维护任务的分布式锁：用于过期握手/OTP 等周期清理，避免多副本重复执行。
 *
 * <p>有限 {@code waitTime}/{@code leaseTime}，同线程 {@code finally} 释放；锁只是“少做重复工作”，正确性仍由 PG 条件
 * 约束保证。任务后校验租期是否仍持有，租期提前过期会告警（不再假设独占）。锁前不持有数据库连接（事务在拿到锁后才开启）。
 */
@Component
public class MaintenanceLock {
  private static final Logger log = LoggerFactory.getLogger(MaintenanceLock.class);

  private final RedissonClient redis;
  private final String namespace;
  private final String environment;

  public MaintenanceLock(RedissonClient redis, VaultOneProperties properties) {
    this.redis = redis;
    this.namespace = properties.redis().namespace();
    this.environment = properties.environment();
  }

  /**
   * 尝试获取命名锁并执行任务；未获取到锁则不执行（另一实例正在处理）。
   *
   * @return 是否实际执行了任务
   */
  public boolean runIfLocked(String name, Duration wait, Duration lease, Runnable task) {
    RLock lock = redis.getLock(namespace + ":lock:" + environment + ":" + name);
    boolean locked = false;
    try {
      locked = lock.tryLock(wait.toMillis(), lease.toMillis(), TimeUnit.MILLISECONDS);
      if (!locked) {
        return false;
      }
      task.run();
      if (!lock.isHeldByCurrentThread()) {
        log.warn("maintenance lease expired during task name={}", name);
      }
      return true;
    } catch (InterruptedException ex) {
      Thread.currentThread().interrupt();
      return false;
    } finally {
      if (locked && lock.isHeldByCurrentThread()) {
        lock.unlock();
      }
    }
  }
}
