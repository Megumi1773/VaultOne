package app.vaultone.server.identity.service;

import app.vaultone.server.validate.WireValidation;
import java.security.SecureRandom;
import java.util.Locale;

/**
 * 邀请码的生成与规范化（计划书 §8.1 / §9）。
 *
 * <p>字母表刻意去掉易混字符（0/O、1/I/L）：邀请码是要念给别人、或让人手抄的， 把 `O` 和 `0` 混在一起会带来没必要的来回。 去掉后剩 31 个字符，12 位约 59 bit
 * 熵——远超穷举成本。
 */
public final class InviteCodes {
  private static final char[] ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789".toCharArray();

  public static final int LENGTH = 12;

  private static final SecureRandom RANDOM = new SecureRandom();

  private InviteCodes() {}

  /** 生成一个新邀请码。 */
  public static String generate() {
    StringBuilder sb = new StringBuilder(LENGTH);
    for (int i = 0; i < LENGTH; i++) {
      sb.append(ALPHABET[RANDOM.nextInt(ALPHABET.length)]);
    }
    return sb.toString();
  }

  /**
   * 规范化用户填的邀请码：去首尾空白、去掉分隔符（有人会写成 `ABCD-EFGH`）、转大写。
   *
   * <p>规范化而不是严格拒绝：用户从聊天记录里复制过来的邀请码经常带空格或连字符， 为此报「格式不对」纯属为难人。长度不对才是真的错。
   */
  public static String normalize(String raw) {
    if (raw == null) {
      throw new WireValidation.ValidationException("请填写邀请码");
    }
    String cleaned = raw.replaceAll("[\\s\\-]", "").toUpperCase(Locale.ROOT);
    if (cleaned.isEmpty()) {
      throw new WireValidation.ValidationException("请填写邀请码");
    }
    if (cleaned.length() != LENGTH) {
      throw new WireValidation.ValidationException("邀请码应为 " + LENGTH + " 位");
    }
    for (int i = 0; i < cleaned.length(); i++) {
      if (new String(ALPHABET).indexOf(cleaned.charAt(i)) < 0) {
        // 不回显具体是哪个字符不对，避免被拿来逐位试探。
        throw new WireValidation.ValidationException("邀请码格式不正确");
      }
    }
    return cleaned;
  }
}
