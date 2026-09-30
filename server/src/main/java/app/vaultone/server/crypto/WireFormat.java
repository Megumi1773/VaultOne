package app.vaultone.server.crypto;

import java.util.Base64;

/**
 * 线协议字节文本格式：RFC 4648 <b>STANDARD</b> Base64（{@code +}/{@code /}，必需 {@code =} padding）。
 *
 * <p>严格性靠复用 JDK 解码器 + <b>重编码等价</b>：先用 {@link Base64#getDecoder()} 解码以复用成熟实现， 再把结果用 {@link
 * Base64#getEncoder()} 编码并要求与输入逐字符相等。由此一次性拒绝：
 *
 * <ul>
 *   <li>长度非 4 倍数 / 缺失 padding（STANDARD 编码必然带 padding）；
 *   <li>URL-safe 字符（{@code -}/{@code _}）与任何非法字符；
 *   <li>空白、换行；
 *   <li>非规范尾部位（如 {@code "AB=="}，JDK 宽松解码会接受，重编码会得到 {@code "AA=="} 而拒绝）。
 * </ul>
 *
 * <p>空字节串编码为 {@code ""}，不是 {@code null} 或 {@code []}。
 */
public final class WireFormat {
  private WireFormat() {}

  /** 严格 STANDARD Base64 编码。 */
  public static String base64Encode(byte[] bytes) {
    return Base64.getEncoder().encodeToString(bytes);
  }

  /**
   * 严格 STANDARD Base64 解码；任何不符合上述规则的输入抛出 {@link IllegalArgumentException}。
   *
   * @param text 待解码文本，不能为 {@code null}
   */
  public static byte[] base64Decode(String text) {
    if (text == null) {
      throw new IllegalArgumentException("Base64 文本不能为 null");
    }
    byte[] decoded;
    try {
      decoded = Base64.getDecoder().decode(text);
    } catch (IllegalArgumentException ex) {
      throw new IllegalArgumentException("非法 Base64");
    }
    // 重编码等价：拒绝非规范尾部位、缺失 padding、混入字符等 JDK 宽松接受的情形。
    if (!Base64.getEncoder().encodeToString(decoded).equals(text)) {
      throw new IllegalArgumentException("非规范 STANDARD Base64");
    }
    return decoded;
  }
}
