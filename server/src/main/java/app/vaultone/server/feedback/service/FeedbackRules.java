package app.vaultone.server.feedback.service;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.feedback.dto.FeedbackDtos;
import java.util.Set;
import java.util.UUID;

public final class FeedbackRules {
  private static final Set<String> CATEGORIES = Set.of("bug", "suggestion", "other");
  private static final Set<String> STATUSES = Set.of("open", "in_progress", "resolved");

  private FeedbackRules() {}

  public static String id(String value) {
    try {
      if (value != null && UUID.fromString(value).toString().equals(value)) return value;
    } catch (IllegalArgumentException ignored) {
      // 非规范 UUID 与缺失值走同一安全参数错误。
    }
    throw ApiException.badRequest("标识格式不正确");
  }

  public static FeedbackDtos.Create create(FeedbackDtos.Create request) {
    id(request.id());
    if (!Boolean.TRUE.equals(request.consent())) throw ApiException.badRequest("请确认反馈可由客服读取");
    if (request.category() == null || !CATEGORIES.contains(request.category()))
      throw ApiException.badRequest("反馈类型不正确");
    return new FeedbackDtos.Create(
        request.id(),
        request.category(),
        text(request.content(), 4000, true),
        text(request.contact(), 200, false),
        true);
  }

  public static FeedbackDtos.Handle handle(FeedbackDtos.Handle request) {
    if (request.expectedVersion() < 1
        || request.expectedVersion() == Long.MAX_VALUE
        || request.status() == null
        || !STATUSES.contains(request.status())) throw ApiException.badRequest("处理状态或版本不正确");
    return new FeedbackDtos.Handle(
        request.expectedVersion(),
        request.status(),
        text(request.reply(), 4000, "resolved".equals(request.status())));
  }

  public static int page(Long before, int limit) {
    if ((before != null && before < 1) || limit < 1 || limit > 50)
      throw ApiException.badRequest("分页参数不正确");
    return limit;
  }

  public static String operator(String value) {
    if (value == null || !value.matches("[A-Za-z0-9][A-Za-z0-9_.-]{0,63}"))
      throw ApiException.badRequest("操作员标识不正确");
    return value;
  }

  private static String text(String value, int max, boolean required) {
    String normalized = value == null ? "" : value.strip();
    if (normalized.length() > max
        || (required && normalized.isEmpty())
        || normalized
            .codePoints()
            .anyMatch(c -> Character.isISOControl(c) && c != '\n' && c != '\r' && c != '\t')) {
      throw ApiException.badRequest("文本为空、超长或包含不支持的控制字符");
    }
    return normalized.isEmpty() ? null : normalized;
  }
}
