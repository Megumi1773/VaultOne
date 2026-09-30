package app.vaultone.server.identity.service;

import java.util.concurrent.Semaphore;
import java.util.function.Supplier;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** SRP 大整数运算的 CPU 并发上限：虚拟线程不是算力扩容，CPU 密集的 SRP 仍需单独限并发。 计算不持有 PG 连接（在事务外执行）。 */
@Component
public class SrpConcurrency {
  private final Semaphore slots;

  public SrpConcurrency(app.vaultone.server.config.VaultOneProperties properties) {
    this.slots = new Semaphore(properties.session().srpMaxConcurrent());
  }

  /** 在受限并发下执行 SRP 计算；无可用槽位时拒绝，避免无界排队。 */
  @Transactional(propagation = Propagation.NOT_SUPPORTED)
  public <T> T run(Supplier<T> work) {
    if (!slots.tryAcquire()) {
      throw app.vaultone.server.common.ApiException.rateLimited();
    }
    try {
      return work.get();
    } finally {
      slots.release();
    }
  }
}
