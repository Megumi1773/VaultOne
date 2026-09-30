package app.vaultone.server.common;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import org.junit.jupiter.api.Test;

/** InstantText 往返与 Instant 重载（回归：Instant 不支持 with(offset)，会抛 UnsupportedTemporalTypeException）。 */
class InstantTextTest {
  @Test
  void formatInstantDoesNotThrowAndMatchesEpochSeconds() {
    Instant instant = Instant.parse("2026-09-30T01:02:03Z");
    assertThat(InstantText.format(instant)).isEqualTo("2026-09-30T01:02:03Z");
    assertThat(InstantText.format(instant.getEpochSecond())).isEqualTo("2026-09-30T01:02:03Z");
  }

  @Test
  void millisecondInstantTruncatesToSeconds() {
    Instant instant = Instant.ofEpochMilli(1_700_000_000_999L);
    assertThat(InstantText.format(instant)).isEqualTo(InstantText.format(instant.getEpochSecond()));
    assertThat(InstantText.format(instant)).endsWith("Z");
    assertThat(InstantText.format(instant)).hasSize(20);
  }

  @Test
  void nullInstantRejected() {
    assertThatThrownBy(() -> InstantText.format((Instant) null))
        .isInstanceOf(NullPointerException.class);
  }

  @Test
  void roundTripOldIsoText() {
    String text = "2025-01-02T03:04:05Z";
    long seconds = InstantText.toEpochSecond(text);
    assertThat(InstantText.format(seconds)).isEqualTo(text);
    assertThat(InstantText.toEpochSecond(InstantText.format(seconds))).isEqualTo(seconds);
  }

  @Test
  void epochMillisToSecondsFloors() {
    assertThat(InstantText.epochMillisToSeconds(1_999L)).isEqualTo(1L);
    assertThat(InstantText.epochMillisToSeconds(2_000L)).isEqualTo(2L);
  }

  @Test
  void invalidOrNullTextReturnsZero() {
    assertThat(InstantText.toEpochSecond(null)).isZero();
    assertThat(InstantText.toEpochSecond("not-a-date")).isZero();
    assertThat(InstantText.parse(null)).isNull();
  }
}
