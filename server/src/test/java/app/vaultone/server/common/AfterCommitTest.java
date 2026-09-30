package app.vaultone.server.common;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;

import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

class AfterCommitTest {
  @Test
  void externalActionRunsOnlyAfterCommit() {
    AtomicInteger calls = new AtomicInteger();
    TransactionSynchronizationManager.initSynchronization();
    try {
      AfterCommit.runSafely(calls::incrementAndGet);
      assertThat(calls).hasValue(0);
      TransactionSynchronizationManager.getSynchronizations()
          .forEach(TransactionSynchronization::afterCommit);
      assertThat(calls).hasValue(1);
    } finally {
      TransactionSynchronizationManager.clearSynchronization();
    }
  }

  @Test
  void notificationFailureCannotEscapeAfterCommit() {
    TransactionSynchronizationManager.initSynchronization();
    try {
      AfterCommit.runSafely(
          () -> {
            throw new IllegalStateException("test-only mail failure");
          });
      assertThatCode(
              () ->
                  TransactionSynchronizationManager.getSynchronizations()
                      .forEach(TransactionSynchronization::afterCommit))
          .doesNotThrowAnyException();
    } finally {
      TransactionSynchronizationManager.clearSynchronization();
    }
  }

  @Test
  void rolledBackTransactionDoesNotRunTheAction() {
    AtomicInteger calls = new AtomicInteger();
    TransactionSynchronizationManager.initSynchronization();
    try {
      AfterCommit.runSafely(calls::incrementAndGet);
      TransactionSynchronizationManager.getSynchronizations()
          .forEach(sync -> sync.afterCompletion(TransactionSynchronization.STATUS_ROLLED_BACK));
      assertThat(calls).hasValue(0);
    } finally {
      TransactionSynchronizationManager.clearSynchronization();
    }
  }
}
