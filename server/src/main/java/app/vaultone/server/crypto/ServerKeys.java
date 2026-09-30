package app.vaultone.server.crypto;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;

/**
 * 服务端密钥：全部由 {@code server_secret}（32B）经 HKDF-SHA256 域分离派生，不落盘、不硬编码。 对齐 {@code
 * crates/vault-server/src/keys.rs}。
 *
 * <table>
 *   <caption>子密钥用途</caption>
 *   <tr><td>email-index</td><td>HMAC-SHA256(规范化邮箱) → 登录查找索引（不可反查）</td></tr>
 *   <tr><td>email-enc</td><td>AES-256-GCM 密封盒加密邮箱（发送通知时解密）</td></tr>
 *   <tr><td>handshake</td><td>AES-256-GCM 密封盒加密 SRP 临时私钥 b（存数据库，支持多实例）</td></tr>
 *   <tr><td>decoy</td><td>未注册邮箱的伪造 KDF/SRP 参数（防账户枚举）</td></tr>
 *   <tr><td>otp</td><td>HMAC 保存设备验证码</td></tr>
 * </table>
 */
public final class ServerKeys {
  private static final byte[] EMAIL_AAD =
      "vaultone-server/email".getBytes(StandardCharsets.US_ASCII);

  private final byte[] emailIndex;
  private final byte[] emailEnc;
  private final byte[] handshake;
  private final byte[] decoy;
  private final byte[] otp;

  /** 由 32 字节 server_secret 构造；不保留 secret 引用。 */
  public ServerKeys(byte[] secret) {
    if (secret == null || secret.length != 32) {
      throw new IllegalArgumentException("server_secret 必须为 32 字节");
    }
    this.emailIndex = Hkdf.serverSubkey(secret, "email-index");
    this.emailEnc = Hkdf.serverSubkey(secret, "email-enc");
    this.handshake = Hkdf.serverSubkey(secret, "handshake");
    this.decoy = Hkdf.serverSubkey(secret, "decoy");
    this.otp = Hkdf.serverSubkey(secret, "otp");
  }

  /** SHA-256 摘要。 */
  public static byte[] sha256(byte[] data) {
    try {
      return MessageDigest.getInstance("SHA-256").digest(data);
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException("SHA-256 不可用", e);
    }
  }

  /**
   * 邮箱规范化：Rust {@code trim().to_lowercase()}（Unicode），无 NFKC/IDNA/点号折叠/plus 别名。
   *
   * <p>Java 的 {@link String#trim()} 只去 ASCII 空白，与 Rust {@code str::trim} 的 Unicode {@code
   * White_Space} 语义不同；这里显式实现 Rust 行为：去除首尾满足 {@code char::is_whitespace} 的字符（含 U+00A0 等），随后整体小写。
   */
  public static String normalizeEmail(String email) {
    return rustTrim(email).toLowerCase(java.util.Locale.ROOT);
  }

  /** 对齐 Rust {@code str::trim()}：去首尾 Unicode 空白。 */
  public static String rustTrim(String s) {
    int start = 0;
    int end = s.length();
    while (start < end && isRustWhitespace(s.codePointAt(start))) {
      start += Character.charCount(s.codePointAt(start));
    }
    while (end > start && isRustWhitespace(s.codePointBefore(end))) {
      end -= Character.charCount(s.codePointBefore(end));
    }
    return s.substring(start, end);
  }

  /**
   * 对齐 Rust {@code char::is_whitespace}：Unicode {@code White_Space} 属性，<b>包含</b> U+0085 （NEL）与
   * U+00A0（NBSP），不含 U+200B。注意 Java {@link Character#isWhitespace} 会漏掉 NBSP/NEL，故不能直接使用。
   */
  public static boolean isRustWhitespace(int cp) {
    switch (cp) {
      case 0x09:
      case 0x0A:
      case 0x0B:
      case 0x0C:
      case 0x0D:
      case 0x20:
      case 0x85:
      case 0xA0:
      case 0x1680:
      case 0x2028:
      case 0x2029:
      case 0x202F:
      case 0x205F:
      case 0x3000:
        return true;
      default:
        return cp >= 0x2000 && cp <= 0x200A;
    }
  }

  public byte[] emailHash(String email) {
    return Hkdf.lengthPrefixedMac(
        emailIndex, normalizeEmail(email).getBytes(StandardCharsets.UTF_8));
  }

  public byte[] encryptEmail(String email) {
    return SealedBox.seal(
        emailEnc, normalizeEmail(email).getBytes(StandardCharsets.UTF_8), EMAIL_AAD);
  }

  public String decryptEmail(byte[] blob) {
    byte[] raw = SealedBox.open(emailEnc, blob, EMAIL_AAD);
    return new String(raw, StandardCharsets.UTF_8);
  }

  public byte[] sealHandshake(String handshakeId, byte[] b) {
    return SealedBox.seal(handshake, b, handshakeId.getBytes(StandardCharsets.UTF_8));
  }

  /** 打开握手封装；调用方负责用量后清零返回数组。 */
  public byte[] openHandshake(String handshakeId, byte[] blob) {
    return SealedBox.open(handshake, blob, handshakeId.getBytes(StandardCharsets.UTF_8));
  }

  /** 为未注册邮箱生成确定性伪造值，使响应与真实账户不可区分；跨块截至所需长度。 */
  public byte[] decoy(String email, String label, int len) {
    byte[] normalized = normalizeEmail(email).getBytes(StandardCharsets.UTF_8);
    byte[] labelBytes = label.getBytes(StandardCharsets.UTF_8);
    byte[] out = new byte[len];
    int filled = 0;
    int counter = 0;
    while (filled < len) {
      byte[] counterBytes = new byte[4];
      counterBytes[0] = (byte) (counter >>> 24);
      counterBytes[1] = (byte) (counter >>> 16);
      counterBytes[2] = (byte) (counter >>> 8);
      counterBytes[3] = (byte) counter;
      byte[] block = Hkdf.lengthPrefixedMac(decoy, normalized, labelBytes, counterBytes);
      int take = Math.min(block.length, len - filled);
      System.arraycopy(block, 0, out, filled, take);
      filled += take;
      counter++;
    }
    return out;
  }

  /** OTP 摘要：三 parts = user_id、device_id、code；不能把 {@code 000123} 当数字 123。 */
  public byte[] otpHash(String userId, String deviceId, String code) {
    return Hkdf.lengthPrefixedMac(
        otp,
        userId.getBytes(StandardCharsets.UTF_8),
        deviceId.getBytes(StandardCharsets.UTF_8),
        code.getBytes(StandardCharsets.UTF_8));
  }

  /** 常量时间比较（对齐 Rust {@code subtle::ConstantTimeEq}）。 */
  public static boolean constantTimeEquals(byte[] a, byte[] b) {
    return MessageDigest.isEqual(a, b);
  }

  /** 释放子密钥引用（构造失败或测试清理时使用）。 */
  public void destroy() {
    for (byte[] key : Arrays.asList(emailIndex, emailEnc, handshake, decoy, otp)) {
      Arrays.fill(key, (byte) 0);
    }
  }
}
