package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

/**
 * 通知的线协议 DTO（计划书 §6.1 / §6.2）。
 *
 * <p>**放在 `proto` 包而不是 `notify/dto`**：`Dto.requireAll`（出站字段的非空校验）是包内可见的，
 * 这是有意的——线协议类型集中在一个包里，才有人能一眼看全对外契约长什么样。
 *
 * <p>字段名用 camelCase 的 Java 名，由全局 `SNAKE_CASE` 策略输出成 snake_case—— 与既有 `/v1` 契约一致，客户端不需要为通知单独长一套解析。
 */
public final class NotificationDtos {
  private NotificationDtos() {}

  /** 通知详情（计划书 §6.2）。 */
  public record Item(
      @JsonProperty(required = true) String id,
      @JsonProperty(required = true) String type,
      @JsonProperty(required = true) String level,
      @JsonProperty(required = true) String title,
      @JsonProperty(required = true) String body,
      @JsonProperty(required = true) long publishedAt,
      @JsonProperty(required = true) boolean read,
      @JsonProperty(required = true) Action action) {
    public Item {
      Dto.requireAll(
          id, "id", type, "type", level, "level", title, "title", body, "body", action, "action");
    }
  }

  /**
   * 动作按钮（计划书 §6.1「动作类型 + 动作文案」）。
   *
   * <p>`none` 时 `value` 与 `label` 都是空串，而不是 null：客户端少一处判空， 少一处判空就少一个忘判的空指针。
   */
  public record Action(
      @JsonProperty(required = true) String kind,
      @JsonProperty(required = true) String value,
      @JsonProperty(required = true) String label) {
    public Action {
      Dto.requireAll(kind, "kind", value, "value", label, "label");
    }
  }

  /** 未读分类计数（计划书 §6.1）。 */
  public record Unread(
      @JsonProperty(required = true) long total,
      @JsonProperty(required = true) long announcement,
      @JsonProperty(required = true) long personal,
      @JsonProperty(required = true) long security) {
    public static final Unread EMPTY = new Unread(0, 0, 0, 0);
  }

  /** 列表响应：一页通知 + 下一页游标 + 未读统计。 */
  public record Page(
      @JsonProperty(required = true) List<Item> notifications,
      /** 为 null 表示没有下一页。 */
      @JsonProperty(required = false) String nextCursor,
      @JsonProperty(required = true) Unread unread) {}
}
