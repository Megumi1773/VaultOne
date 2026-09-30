package app.vaultone.server.common;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;

/**
 * Unix 秒与 ISO-8601 UTC 文本互转，对齐 Rust {@code crates/vault-server/src/db.rs} 的时间列格式： {@code
 * YYYY-MM-DDTHH:MM:SSZ}（恒定 20 字节，字典序即时间序）。API 边界仍以 Unix 秒（i64）收发。
 */
public final class InstantText {
  private static final DateTimeFormatter FORMAT =
      DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);

  private InstantText() {}

  /** Unix 秒 → ISO-8601 UTC 文本。 */
  public static String format(long epochSeconds) {
    return FORMAT.format(Instant.ofEpochSecond(epochSeconds));
  }

  /** {@link Instant} → ISO-8601 UTC 文本（formatter 已 withZone(UTC)，绝不对 Instant 调 with(offset)）。 */
  public static String format(Instant instant) {
    java.util.Objects.requireNonNull(instant, "instant");
    // Instant 不支持 ZoneOffset 查询字段；这里直接交给已带 UTC 时区的 formatter（秒精度）。
    return FORMAT.format(instant.truncatedTo(java.time.temporal.ChronoUnit.SECONDS));
  }

  /** 毫秒级 UTC epoch → Unix 秒（截断），用于 Envers revtstmp 等场景。 */
  public static long epochMillisToSeconds(long epochMillis) {
    return Math.floorDiv(epochMillis, 1000L);
  }

  /** ISO-8601 UTC 文本 → Unix 秒；非法或 null 返回 0（与 Rust 读取语义一致）。 */
  public static long toEpochSecond(String text) {
    Instant instant = parse(text);
    return instant == null ? 0L : instant.getEpochSecond();
  }

  /** 解析；失败返回 {@code null}。 */
  public static Instant parse(String text) {
    if (text == null || text.length() < 20) {
      return null;
    }
    try {
      return Instant.parse(text);
    } catch (RuntimeException ex) {
      return null;
    }
  }
}
