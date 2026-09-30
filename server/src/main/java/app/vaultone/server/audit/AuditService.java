package app.vaultone.server.audit;

import app.vaultone.server.audit.model.AuditEventEntity;
import app.vaultone.server.common.ApiException;
import app.vaultone.server.proto.AuditEventOut;
import app.vaultone.server.security.AccountGuard;
import app.vaultone.server.security.Approved;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.time.Instant;
import java.util.List;
import org.springframework.data.domain.Limit;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** 成功审计随业务提交；失败审计使用独立事务。审计写入失败不得被当作成功提交。 */
@Service
public class AuditService {
  public static final String SUCCESS = "success";
  public static final String FAILURE = "failure";

  private final AuditRepository repository;
  private final AccountGuard guard;
  @PersistenceContext private EntityManager em;

  public AuditService(AuditRepository repository, AccountGuard guard) {
    this.repository = repository;
    this.guard = guard;
  }

  @Transactional(propagation = Propagation.REQUIRED)
  public void record(
      String userId,
      String deviceId,
      String event,
      String outcome,
      String requestId,
      byte[] ipHash) {
    write(userId, deviceId, event, outcome, requestId, ipHash);
  }

  @Transactional(propagation = Propagation.REQUIRES_NEW)
  public void recordFailure(
      String userId,
      String deviceId,
      String event,
      String outcome,
      String requestId,
      byte[] ipHash) {
    write(userId, deviceId, event, outcome, requestId, ipHash);
  }

  private void write(
      String userId,
      String deviceId,
      String event,
      String outcome,
      String requestId,
      byte[] ipHash) {
    em.createNativeQuery("SELECT set_config('vaultone.account_id', :acct, true)")
        .setParameter("acct", userId)
        .getSingleResult();
    repository.saveAndFlush(
        AuditEventEntity.of(
            userId,
            deviceId,
            event,
            AuditEvents.severityOf(event),
            outcome,
            requestId,
            ipHash,
            Instant.now()));
  }

  @Transactional(readOnly = true)
  public List<AuditEventOut> list(Approved approved) {
    var principal = guard.readOnly(approved.authed().ref());
    if (!principal.approved()) {
      throw ApiException.deviceNotApproved();
    }
    return repository.latestForUser(principal.userId(), Limit.of(100)).stream()
        .map(
            e ->
                new AuditEventOut(e.getEvent(), e.getDeviceId(), e.getCreatedAt().getEpochSecond()))
        .toList();
  }
}
