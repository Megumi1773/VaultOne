package app.vaultone.server.feedback.dto;

import java.util.List;

/** 文本反馈独立于保险库同步；正文及联系方式不得进入日志。 */
public final class FeedbackDtos {
  private FeedbackDtos() {}

  public record Create(
      String id, String category, String content, String contact, Boolean consent) {
    @com.fasterxml.jackson.annotation.JsonAnySetter
    public void unknown(String name, Object value) {
      throw app.vaultone.server.common.ApiException.badRequest("反馈字段不正确");
    }

    @Override
    public String toString() {
      return "FeedbackCreate[redacted]";
    }
  }

  public record Summary(
      String id, String category, String status, long createdAt, long updatedAt, long version) {}

  public record Detail(
      String id,
      String category,
      String status,
      long createdAt,
      long updatedAt,
      long version,
      String content,
      String contact,
      String reply) {
    @Override
    public String toString() {
      return "FeedbackDetail[redacted]";
    }
  }

  public record Page(List<Summary> items, Long nextBefore) {
    public Page {
      items = List.copyOf(items);
    }
  }

  public record Handle(long expectedVersion, String status, String reply) {
    @Override
    public String toString() {
      return "FeedbackHandle[redacted]";
    }
  }

  public record Created(Detail detail, boolean fresh) {
    @Override
    public String toString() {
      return "FeedbackCreated[fresh=" + fresh + "]";
    }
  }
}
