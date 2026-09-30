package app.vaultone.server.common;

import java.util.Objects;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** 非关键外部动作只能在提交后执行；其失败不能把已提交的数据库操作报告成回滚。 */
public final class AfterCommit {
  private AfterCommit() {}

  public static void runSafely(Runnable action) {
    Objects.requireNonNull(action);
    if (TransactionSynchronizationManager.isSynchronizationActive()) {
      TransactionSynchronizationManager.registerSynchronization(
          new TransactionSynchronization() {
            @Override
            public void afterCommit() {
              execute(action);
            }
          });
    } else {
      execute(action);
    }
  }

  private static void execute(Runnable action) {
    try {
      action.run();
    } catch (RuntimeException ex) {
      SafeDiagnostics.logUnhandled(ex);
    }
  }
}
