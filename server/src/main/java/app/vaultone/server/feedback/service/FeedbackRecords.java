package app.vaultone.server.feedback.service;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.feedback.dto.FeedbackDtos;
import app.vaultone.server.feedback.model.FeedbackEntity;
import app.vaultone.server.feedback.repository.FeedbackRepository;
import java.time.Instant;
import org.springframework.data.domain.Limit;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** 调用方必须在同一事务内建立账户授权；此处只负责有范围的读取与 DTO 映射。 */
@Service
@Transactional(propagation = Propagation.MANDATORY)
public class FeedbackRecords {
  private final FeedbackRepository repository;

  public FeedbackRecords(FeedbackRepository repository) {
    this.repository = repository;
  }

  public FeedbackDtos.Page page(String account, Long before, int limit) {
    FeedbackRules.page(before, limit);
    var rows =
        repository.page(
            account,
            before == null ? Long.MAX_VALUE : before,
            Instant.now().getEpochSecond(),
            Limit.of(limit + 1));
    var visible = rows.stream().limit(limit).toList();
    var items =
        visible.stream()
            .map(
                r ->
                    new FeedbackDtos.Summary(
                        r.getId(),
                        r.getCategory(),
                        r.getStatus(),
                        r.getCreatedAt(),
                        r.getUpdatedAt(),
                        r.getVersion()))
            .toList();
    return new FeedbackDtos.Page(items, rows.size() > limit ? visible.getLast().getSeq() : null);
  }

  public FeedbackEntity require(String account, String id) {
    FeedbackRules.id(id);
    return repository
        .find(account, id)
        .filter(f -> f.getExpiresAt() > Instant.now().getEpochSecond())
        .orElseThrow(ApiException::notFound);
  }

  public static FeedbackDtos.Detail detail(FeedbackEntity f) {
    return new FeedbackDtos.Detail(
        f.getId(),
        f.getCategory(),
        f.getStatus(),
        f.getCreatedAt(),
        f.getUpdatedAt(),
        f.getVersion(),
        f.getContent(),
        f.getContact(),
        f.getReply());
  }
}
