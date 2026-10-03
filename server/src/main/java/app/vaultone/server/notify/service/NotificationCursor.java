package app.vaultone.server.notify.service;

import app.vaultone.server.common.ApiException;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

/**
 * 通知列表的游标编解码（计划书 §6.1「分页游标 nextCursor」）。
 *
 * <p>游标是 `published_at|id` 的 Base64URL。做成不透明字符串而不是直接把两个字段放在 query 上：
 * 客户端没有理由自己拼游标，把结构摆出来只会诱使有人去构造「任意时间戳」的请求。
 *
 * <p>**解析一律严格**：长度、字符集、字段数、时间戳范围都校验。游标来自客户端， 不校验就等于把一个能拼任意值的字符串直接送进 `where published_at < ?`。
 */
public final class NotificationCursor {
  /** 解码后的最长字节数：一个毫秒级时间戳 + 一个 64 字符的 id 足够了，给到 128 是留余量。 */
  private static final int MAX_DECODED_BYTES = 128;

  /** 时间戳的合法上界：2100-01-01。再大说明不是本服务发出去的游标。 */
  private static final long MAX_EPOCH_SECONDS = 4_102_444_800L;

  private NotificationCursor() {}

  /** 编码。id 里若含 `|` 会在解码时被截断，因此这里直接拒绝，而不是悄悄产出一个坏游标。 */
  public static String encode(long publishedAt, String id) {
    if (id == null || id.isEmpty() || id.indexOf('|') >= 0) {
      throw new IllegalStateException("通知 id 不能为空且不能含 '|'：" + id);
    }
    return Base64.getUrlEncoder()
        .withoutPadding()
        .encodeToString((publishedAt + "|" + id).getBytes(StandardCharsets.UTF_8));
  }

  /** 解码结果。 */
  public record Position(long publishedAt, String id) {}

  public static Position decode(String cursor) {
    if (cursor == null || cursor.isEmpty()) {
      return null;
    }
    // Base64URL 的合法字符集：字母、数字、`-`、`_`。长度按「不解码就能判断上界」设限。
    if (cursor.length() > MAX_DECODED_BYTES * 2 || !cursor.matches("[A-Za-z0-9_-]+")) {
      throw ApiException.badRequest("分页游标不正确");
    }
    byte[] raw;
    try {
      raw = Base64.getUrlDecoder().decode(cursor);
    } catch (IllegalArgumentException e) {
      throw ApiException.badRequest("分页游标不正确");
    }
    if (raw.length > MAX_DECODED_BYTES) {
      throw ApiException.badRequest("分页游标不正确");
    }
    String text = new String(raw, StandardCharsets.UTF_8);
    int sep = text.indexOf('|');
    if (sep <= 0 || sep == text.length() - 1) {
      throw ApiException.badRequest("分页游标不正确");
    }
    long at;
    try {
      at = Long.parseLong(text.substring(0, sep));
    } catch (NumberFormatException e) {
      throw ApiException.badRequest("分页游标不正确");
    }
    // 负数与「未来很远」的时间都不可能是本服务编码出来的。
    if (at < 0 || at > MAX_EPOCH_SECONDS) {
      throw ApiException.badRequest("分页游标不正确");
    }
    return new Position(at, text.substring(sep + 1));
  }
}
