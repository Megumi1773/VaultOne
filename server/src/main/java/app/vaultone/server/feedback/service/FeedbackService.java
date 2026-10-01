package app.vaultone.server.feedback.service;

import app.vaultone.server.audit.AuditEvents;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.common.ApiException;
import app.vaultone.server.feedback.FeedbackProperties;
import app.vaultone.server.feedback.dto.FeedbackDtos;
import app.vaultone.server.feedback.model.FeedbackEntity;
import app.vaultone.server.feedback.repository.FeedbackRepository;
import app.vaultone.server.security.AccountGuard;
import app.vaultone.server.security.Approved;
import java.time.Instant;
import java.util.Objects;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
@EnableConfigurationProperties(FeedbackProperties.class)
public class FeedbackService {
  private final AccountGuard guard;
  private final FeedbackRepository repository;
  private final FeedbackRecords records;
  private final FeedbackProperties properties;
  private final AuditService audit;

  public FeedbackService(
      AccountGuard guard,
      FeedbackRepository repository,
      FeedbackRecords records,
      FeedbackProperties properties,
      AuditService audit) {
    this.guard = guard;
    this.repository = repository;
    this.records = records;
    this.properties = properties;
    this.audit = audit;
  }

  @Transactional
  public FeedbackDtos.Created create(
      Approved approved, FeedbackDtos.Create input, String requestId) {
    var request = FeedbackRules.create(input);
    var principal = guard.lock(approved.authed().ref());
    requireApproved(principal);
    long now = Instant.now().getEpochSecond();
    var existing = repository.find(principal.userId(), request.id());
    if (existing.isPresent()) {
      var f = existing.get();
      if (f.getExpiresAt() <= now) throw ApiException.conflict("反馈已到期，请新建提交");
      if (!f.getCategory().equals(request.category())
          || !f.getContent().equals(request.content())
          || !Objects.equals(f.getContact(), request.contact()))
        throw ApiException.conflict("同一提交标识不能用于不同反馈");
      return new FeedbackDtos.Created(FeedbackRecords.detail(f), false);
    }
    if (repository.activeCount(principal.userId(), now) >= properties.maxActivePerAccount()
        || repository.recentCount(principal.userId(), now - 86400) >= properties.maxPerDay()) {
      throw ApiException.rateLimited();
    }
    var f =
        repository.save(
            FeedbackEntity.create(
                principal.userId(),
                request.id(),
                request.category(),
                request.content(),
                request.contact(),
                now,
                now + properties.retentionDays() * 86400L));
    audit.recordFeedback(
        principal.userId(),
        principal.deviceId(),
        null,
        f.getId(),
        AuditEvents.FEEDBACK_CREATED,
        AuditService.SUCCESS,
        requestId);
    return new FeedbackDtos.Created(FeedbackRecords.detail(f), true);
  }

  @Transactional(readOnly = true)
  public FeedbackDtos.Page list(Approved approved, Long before, int limit) {
    var principal = guard.readOnly(approved.authed().ref());
    requireApproved(principal);
    return records.page(principal.userId(), before, limit);
  }

  @Transactional(readOnly = true)
  public FeedbackDtos.Detail get(Approved approved, String id) {
    var principal = guard.readOnly(approved.authed().ref());
    requireApproved(principal);
    return FeedbackRecords.detail(records.require(principal.userId(), id));
  }

  private static void requireApproved(AccountGuard.Principal principal) {
    if (!principal.approved()) throw ApiException.deviceNotApproved();
  }
}
