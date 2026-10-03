package app.vaultone.server.notify.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.common.ApiException;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import org.junit.jupiter.api.Test;

/** 通知游标的编解码（计划书 §6.1）。游标直接来自客户端，是这里最需要严格校验的输入。 */
class NotificationCursorTest {

  @Test
  void roundTrips() {
    String cursor = NotificationCursor.encode(1_700_000_000L, "abc-123");
    NotificationCursor.Position p = NotificationCursor.decode(cursor);
    assertThat(p.publishedAt()).isEqualTo(1_700_000_000L);
    assertThat(p.id()).isEqualTo("abc-123");
  }

  @Test
  void emptyCursorMeansFirstPage() {
    assertThat(NotificationCursor.decode(null)).isNull();
    assertThat(NotificationCursor.decode("")).isNull();
  }

  @Test
  void encodeRefusesIdsThatWouldCorruptTheCursor() {
    // id 里含分隔符会让解码时被截断，产出「能用但错误」的游标——不如在这里就炸掉。
    assertThatThrownBy(() -> NotificationCursor.encode(1L, "a|b"))
        .isInstanceOf(IllegalStateException.class);
    assertThatThrownBy(() -> NotificationCursor.encode(1L, ""))
        .isInstanceOf(IllegalStateException.class);
  }

  @Test
  void rejectsGarbageInsteadOfSendingItToTheQuery() {
    // 这些都会一路走到 `where published_at < ?`，不校验就是把任意值送进 SQL 参数。
    for (String bad : new String[] {"!!!!", "a b c", "not base64!", "中文"}) {
      assertThatThrownBy(() -> NotificationCursor.decode(bad), bad)
          .as(bad)
          .isInstanceOf(ApiException.class);
    }
  }

  @Test
  void rejectsOverlongInput() {
    String huge = "A".repeat(NotificationCursor.class.getDeclaredFields().length * 0 + 400);
    assertThatThrownBy(() -> NotificationCursor.decode(huge)).isInstanceOf(ApiException.class);
  }

  @Test
  void rejectsStructurallyWrongPayloads() {
    // 合法 Base64URL，但解出来的内容不是「时间戳|id」。
    // 注意不含空串：空 Base64 就是空串，而空游标本就表示「第一页」，见 emptyCursorMeansFirstPage。
    for (String raw :
        new String[] {"|", "abc", "123", "123|", "|abc", "abc|def", "-1|id", "9999999999999|id"}) {
      String cursor =
          Base64.getUrlEncoder()
              .withoutPadding()
              .encodeToString(raw.getBytes(StandardCharsets.UTF_8));
      assertThatThrownBy(() -> NotificationCursor.decode(cursor), raw)
          .as("原文 %s", raw)
          .isInstanceOf(ApiException.class);
    }
  }

  @Test
  void acceptsTheBoundaryTimestamp() {
    // 2100-01-01 是本实现的合法上界，含边界。
    assertThatCode(() -> NotificationCursor.decode(NotificationCursor.encode(4_102_444_800L, "id")))
        .doesNotThrowAnyException();
  }

  @Test
  void cursorIsOpaqueNotHumanReadable() {
    String cursor = NotificationCursor.encode(1_700_000_000L, "abc");
    // 不直接把 `1700000000|abc` 摆在 query 上：摆出来只会诱使有人去构造任意时间戳。
    assertThat(cursor).doesNotContain("|").doesNotContain("1700000000");
  }
}
