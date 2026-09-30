package app.vaultone.server.audit;

import app.vaultone.server.security.Authed;
import app.vaultone.server.security.PrincipalHolder;
import java.util.Optional;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 将可信事务审计上下文（{@link RevisionContext}）绑定到每个 {@code @Transactional} 方法的实际事务生命周期：
 *
 * <ul>
 *   <li>进入前从 {@link PrincipalHolder} 取当前认证主体，设置 account/device（无主体则为 system 占位并显式标记）；
 *   <li>注册事务同步，在 {@code afterCompletion} 恢复此前值（处理 {@code REQUIRES_NEW} 的挂起/恢复）；
 *   <li>不在方法 finally 提前清理，避免 AOP 提交/flush 前上下文缺失导致 Envers 写入错误 actor 或被 RLS 拒绝。
 * </ul>
 *
 * <p>只设置可信来源（认证结果），绝不从请求体取 account。仅对 Envers 审计实体的事务有意义；对无主体的 （注册等）事务，RevisionContext 明确为 {@code
 * system}，不静默掩盖。
 */
@Aspect
@Component
@Order(0)
public class RevisionContextAspect {
  @Around(
      "@annotation(org.springframework.transaction.annotation.Transactional) || "
          + "@within(org.springframework.transaction.annotation.Transactional)")
  public Object bindContext(ProceedingJoinPoint joinPoint) throws Throwable {
    Optional<RevisionContext.Context> previous = RevisionContext.peek();
    Authed authed = PrincipalHolder.get();
    if (authed != null) {
      RevisionContext.set(authed.userId(), authed.deviceId(), currentRequestId());
    } else {
      RevisionContext.setSystem();
    }
    if (TransactionSynchronizationManager.isSynchronizationActive()) {
      TransactionSynchronizationManager.registerSynchronization(
          new TransactionSynchronization() {
            @Override
            public void afterCompletion(int status) {
              restore(previous);
            }
          });
    }
    try {
      return joinPoint.proceed();
    } catch (Throwable ex) {
      // 若事务同步未激活（无事务），此处兜底恢复，避免上下文泄漏到后续调用。
      if (!TransactionSynchronizationManager.isSynchronizationActive()) {
        restore(previous);
      }
      throw ex;
    }
  }

  private static void restore(Optional<RevisionContext.Context> previous) {
    if (previous.isPresent()) {
      RevisionContext.Context c = previous.get();
      RevisionContext.set(c.accountId(), c.actorDeviceId(), c.requestId());
    } else {
      RevisionContext.clear();
    }
  }

  private static String currentRequestId() {
    return org.slf4j.MDC.get("requestId");
  }
}
