package app.vaultone.server.feedback.service;

import app.vaultone.server.audit.AuditEvents;
import app.vaultone.server.audit.AuditRepository;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.audit.model.AuditEventEntity;
import app.vaultone.server.common.ApiException;
import app.vaultone.server.feedback.dto.FeedbackDtos;
import jakarta.persistence.EntityManager;
import java.time.Instant;
import java.util.Objects;
import org.springframework.transaction.annotation.Transactional;

/** 只由显式非 Web 运维上下文注册，不伪造用户会话，不提供跨账户队列。 */
public class FeedbackOperationsService {
  private final EntityManager em;
  private final FeedbackRecords records;
  private final AuditRepository audit;

  public FeedbackOperationsService(
      EntityManager em, FeedbackRecords records, AuditRepository audit) {
    this.em = em;
    this.records = records;
    this.audit = audit;
  }

  @Transactional(readOnly = true)
  public FeedbackDtos.Page list(String account, Long before, int limit) {
    scope(account, false);
    return records.page(account, before, limit);
  }

  @Transactional(readOnly = true)
  public FeedbackDtos.Detail get(String account, String id) {
    scope(account, false);
    return FeedbackRecords.detail(records.require(account, id));
  }

  @Transactional
  public FeedbackDtos.Detail handle(
      String account, String id, String operator, FeedbackDtos.Handle input, String requestId) {
    FeedbackRules.operator(operator);
    var request = FeedbackRules.handle(input);
    scope(account, true);
    var f = records.require(account, id);
    if (f.getVersion() != request.expectedVersion()) {
      if (f.getVersion() == request.expectedVersion() + 1
          && f.getStatus().equals(request.status())
          && Objects.equals(f.getReply(), request.reply())) return FeedbackRecords.detail(f);
      throw ApiException.conflict("反馈已被更新，请重新读取后处理");
    }
    f.handle(request.status(), request.reply(), Instant.now().getEpochSecond());
    record(account, id, operator, AuditService.SUCCESS, requestId);
    return FeedbackRecords.detail(f);
  }

  /** 由 CLI 在处理事务回滚后另开事务记录；绝不在持账户锁时嵌套新事务。 */
  @Transactional
  public void recordFailure(String account, String id, String operator, String requestId) {
    FeedbackRules.id(id);
    FeedbackRules.operator(operator);
    scope(account, false);
    record(account, id, operator, AuditService.FAILURE, requestId);
  }

  private void record(
      String account, String id, String operator, String outcome, String requestId) {
    var entry =
        AuditEventEntity.of(
            account,
            null,
            AuditEvents.FEEDBACK_HANDLED,
            AuditEvents.severityOf(AuditEvents.FEEDBACK_HANDLED),
            outcome,
            requestId,
            null,
            Instant.now());
    entry.feedbackTarget(operator, id);
    audit.saveAndFlush(entry);
  }

  private void scope(String account, boolean lock) {
    FeedbackRules.id(account);
    em.createNativeQuery("select set_config('vaultone.account_id', :account, true)")
        .setParameter("account", account)
        .getSingleResult();
    var users =
        em.createNativeQuery(
                "select id from users where id = :account" + (lock ? " for update" : ""))
            .setParameter("account", account)
            .getResultList();
    if (users.isEmpty()) throw ApiException.notFound();
  }
}
