package app.vaultone.server.notify.model;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
import org.junit.jupiter.api.Test;

/** 通知实体的可见性、过期与排序键（计划书 §6.1）。 */
class NotificationEntityTest {

  private static final Instant T = Instant.ofEpochSecond(1_700_000_000L);

  private static NotificationEntity of(
      String id, String audience, String accountId, Long expiresAt) {
    return NotificationEntity.publish(
        id,
        audience,
        accountId,
        "announcement",
        "info",
        "标题",
        "正文",
        "none",
        "",
        "",
        null,
        null,
        false,
        T,
        expiresAt);
  }

  @Test
  void broadcastIsVisibleToEveryone() {
    assertThat(of("n1", "all", null, null).isVisibleTo("a")).isTrue();
    assertThat(of("n1", "all", null, null).isVisibleTo("b")).isTrue();
  }

  @Test
  void targetedIsVisibleOnlyToItsAccount() {
    assertThat(of("n2", "account", "a", null).isVisibleTo("a")).isTrue();
    // 定向通知落到别人手里就是把私信投给了所有人。
    assertThat(of("n2", "account", "a", null).isVisibleTo("b")).isFalse();
  }

  @Test
  void missingTargetAccountIsVisibleToNobody() {
    // audience = account 但没写 account_id：既不广播给所有人，也不给某个账户。
    // 不能因为「没有目标」就退化成广播——那是把私信发给全站。
    assertThat(of("n3", "account", null, null).isVisibleTo("a")).isFalse();
    assertThat(of("n3", "account", null, null).isVisibleTo(null)).isFalse();
  }

  @Test
  void expiryIsExclusiveAndOptional() {
    assertThat(of("n4", "all", null, null).isExpiredAt(Long.MAX_VALUE)).isFalse();

    NotificationEntity until = of("n5", "all", null, 1_700_000_100L);
    assertThat(until.isExpiredAt(1_700_000_099L)).isFalse();
    // 边界是「到点即过期」，不是「过了才过期」。
    assertThat(until.isExpiredAt(1_700_000_100L)).isTrue();
    assertThat(until.isExpiredAt(1_700_000_101L)).isTrue();
  }

  @Test
  void sortKeyIsATotalOrder() {
    // 同一秒内的两条通知：只按时间排序会并列，翻页时可能漏掉或重复，带上 id 才是全序。
    assertThat(of("a", "all", null, null).sortKey())
        .isNotEqualTo(of("b", "all", null, null).sortKey())
        .startsWith("1700000000|");
  }

  @Test
  void actionColumnsAreNeverNull() {
    // 三个动作列在表里是 NOT NULL，缺省填空值而不是留 null 让读取方到处判空。
    NotificationEntity n =
        NotificationEntity.publish(
            "n6",
            "all",
            null,
            "announcement",
            "info",
            "t",
            "b",
            null,
            null,
            null,
            null,
            null,
            false,
            T,
            null);
    assertThat(n.getActionKind()).isEqualTo("none");
    assertThat(n.getActionValue()).isEmpty();
    assertThat(n.getActionLabel()).isEmpty();
  }

  @Test
  void toStringDoesNotLeakContent() {
    NotificationEntity n =
        NotificationEntity.publish(
            "n7",
            "all",
            null,
            "announcement",
            "info",
            "机密标题",
            "机密正文",
            "none",
            "",
            "",
            null,
            null,
            false,
            T,
            null);
    assertThat(n.toString()).doesNotContain("机密标题").doesNotContain("机密正文");
  }
}
