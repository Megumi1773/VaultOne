package app.vaultone.server.validate;

import app.vaultone.server.crypto.SealedBox;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.crypto.WireFormat;
import app.vaultone.server.proto.DeviceInfo;
import app.vaultone.server.proto.KdfParams;
import java.util.Set;

/**
 * 输入校验：服务端虽看不懂密文，但可校验其结构。逐项对齐 {@code crates/vault-server/src/validate.rs}。
 *
 * <p>所有错误通过 {@link ValidationException} 抛出，S2 路由层将其映射为 {@code bad_request}（400）。
 */
public final class WireValidation {
  /** 256-bit 密钥密封盒长度：2 头 + 32 盐 + 12 IV + 32 密文 + 16 tag。 */
  public static final int WRAPPED_KEY_LEN = SealedBox.WRAPPED_KEY_LEN;

  public static final int MAX_BLOB_LEN = 1024 * 1024;

  private static final Set<String> KINDS = Set.of("login", "card", "note", "identity");

  private WireValidation() {}

  /** 指定字段的 UUID 校验，与 Rust {@code Uuid::parse_str} 接受集合一致；不强制 canonical。 */
  public static void uuid(String value, String what) {
    if (value == null || !isRustUuid(value)) {
      throw new ValidationException(what + " 不是合法 UUID");
    }
  }

  /**
   * 校验 UUID 文本。Rust {@code uuid::Uuid::parse_str} 接受标准带连字符形式（32 个十六进制位， 8-4-4-4-12），也接受
   * urn/braced/simple 等被 crate 放宽的形式。这里实现其核心接受集： 去空白后为 8-4-4-4-12 十六进制，或 32 位无连字符十六进制。
   */
  public static boolean isRustUuid(String value) {
    if (value == null) {
      return false;
    }
    String v = value;
    if (v.length() == 45 && v.regionMatches(true, 0, "urn:uuid:", 0, 9)) {
      v = v.substring(9);
    }
    if (v.length() >= 2 && v.charAt(0) == '{' && v.charAt(v.length() - 1) == '}') {
      v = v.substring(1, v.length() - 1);
    }
    if (v.length() == 32) {
      return isHex(v);
    }
    if (v.length() != 36) {
      return false;
    }
    for (int i = 0; i < 36; i++) {
      char c = v.charAt(i);
      boolean hyphen = i == 8 || i == 13 || i == 18 || i == 23;
      if (hyphen) {
        if (c != '-') {
          return false;
        }
      } else if (!isHexChar(c)) {
        return false;
      }
    }
    return true;
  }

  private static boolean isHex(String s) {
    for (int i = 0; i < s.length(); i++) {
      if (!isHexChar(s.charAt(i))) {
        return false;
      }
    }
    return true;
  }

  private static boolean isHexChar(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
  }

  /**
   * 邮箱轻量校验：按 Rust {@code trim()}（Unicode 空白）去首尾后按 <b>UTF-8 字节长度</b> ≤ 254、 存在首个 @、本地部分非空、域部分含
   * {@code .}。不使用 Java 严格邮箱正则，避免改变接受集合。
   */
  public static void email(String email) {
    if (email == null) {
      throw new ValidationException("邮箱格式不正确");
    }
    String e = ServerKeys.rustTrim(email);
    int bytes = e.getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
    if (bytes > 254) {
      throw new ValidationException("邮箱格式不正确");
    }
    int at = e.indexOf('@');
    if (at < 0) {
      throw new ValidationException("邮箱格式不正确");
    }
    String local = e.substring(0, at);
    String domain = e.substring(at + 1);
    if (local.isEmpty() || !domain.contains(".")) {
      throw new ValidationException("邮箱格式不正确");
    }
  }

  /** 生产 KDF 下限：alg=argon2id，m∈[19456,4194304] KiB，t∈[2,64]，p∈[1,16]，盐解码 ≥16B。 */
  public static void kdf(KdfParams k) {
    if (k == null) {
      throw new ValidationException("KDF 参数不合法或低于安全下限");
    }
    byte[] salt;
    try {
      salt = WireFormat.base64Decode(k.salt());
    } catch (IllegalArgumentException ex) {
      throw new ValidationException("KDF 参数不合法或低于安全下限");
    }
    boolean ok =
        "argon2id".equals(k.alg())
            && k.m() >= 19L * 1024
            && k.m() <= 4L * 1024 * 1024
            && k.t() >= 2
            && k.t() <= 64
            && k.p() >= 1
            && k.p() <= 16
            && salt.length >= 16;
    if (!ok) {
      throw new ValidationException("KDF 参数不合法或低于安全下限");
    }
  }

  /** 测试构建允许低成本 KDF 参数（对应客户端 {@code insecure-test-kdf}）。 */
  public static void kdfLenient(KdfParams k, boolean allowTest) {
    if (allowTest
        && k != null
        && "argon2id".equals(k.alg())
        && k.m() == 8
        && k.t() == 1
        && k.p() == 1) {
      return;
    }
    kdf(k);
  }

  /** SRP salt 16..64B；verifier 长度 1..384B（只验长度，不证明 verifier 合法）。 */
  public static void srp(byte[] salt, byte[] verifier) {
    if (salt == null
        || verifier == null
        || salt.length < 16
        || salt.length > 64
        || verifier.length == 0
        || verifier.length > 384) {
      throw new ValidationException("SRP 参数不合法");
    }
  }

  /** 256-bit 密钥的密封盒：长度 94B 且前两字节为 01/01。 */
  public static void wrappedKey(byte[] b, String what) {
    if (b == null
        || b.length != WRAPPED_KEY_LEN
        || (b[0] & 0xFF) != SealedBox.VERSION
        || (b[1] & 0xFF) != SealedBox.SUITE_AES256GCM_HKDF_SHA256) {
      throw new ValidationException(what + " 不是合法的 AES-256-GCM 密封盒");
    }
  }

  public static void hash32(byte[] b, String what) {
    if (b == null || b.length != 32) {
      throw new ValidationException(what + " 长度不正确");
    }
  }

  /** 设备校验：id 为 UUID；名称按 Rust {@code trim()} 后按 <b>Unicode scalar 个数</b> 1..64（不是 UTF-16 length）。 */
  public static void device(DeviceInfo d) {
    if (d == null) {
      throw new ValidationException("设备信息缺失");
    }
    uuid(d.id(), "device.id");
    String name = d.name() == null ? "" : ServerKeys.rustTrim(d.name());
    int scalars = name.codePointCount(0, name.length());
    if (scalars == 0 || scalars > 64) {
      throw new ValidationException("设备名需为 1-64 个字符");
    }
  }

  /** 条目类型：仅 login/card/note/identity。 */
  public static void kind(String k) {
    if (k == null || !KINDS.contains(k)) {
      throw new ValidationException("未知条目类型");
    }
  }

  /**
   * 条目信封结构校验：{@code {"v":2,"alg":"aes-256-gcm","wrappedKey":<密封盒>,"ct":<密封盒, 256B 对齐>}}， 恰好 4
   * 个键。仅结构校验，不验证 tag/明文。
   */
  public static void itemBlob(byte[] blob) {
    if (blob == null || blob.length > MAX_BLOB_LEN) {
      throw new ValidationException("条目过大");
    }
    tools.jackson.databind.JsonNode node;
    try {
      node = WireJson.MAPPER.readTree(blob);
    } catch (RuntimeException ex) {
      throw new ValidationException("条目密文格式不合法");
    }
    if (node == null || !node.isObject() || node.size() != 4) {
      throw new ValidationException("条目密文格式不合法");
    }
    tools.jackson.databind.JsonNode v = node.get("v");
    if (v == null
        || !v.isIntegralNumber()
        || v.asInt() != 2
        || !"aes-256-gcm".equals(textOrNull(node, "alg"))) {
      throw new ValidationException("条目密文格式不合法");
    }
    byte[] wrapped = decodeStrict(textOrNull(node, "wrappedKey"));
    wrappedKey(wrapped, "wrappedKey");
    byte[] ct = decodeStrict(textOrNull(node, "ct"));
    if (ct == null) {
      throw new ValidationException("条目密文格式不合法");
    }
    int body = ct.length - SealedBox.OVERHEAD;
    if (ct.length < SealedBox.OVERHEAD
        || (ct[0] & 0xFF) != SealedBox.VERSION
        || (ct[1] & 0xFF) != SealedBox.SUITE_AES256GCM_HKDF_SHA256
        || body == 0
        || body % 256 != 0) {
      throw new ValidationException("条目密文格式不合法");
    }
  }

  private static String textOrNull(tools.jackson.databind.JsonNode node, String field) {
    tools.jackson.databind.JsonNode value = node.get(field);
    return value != null && value.isString() ? value.asString() : null;
  }

  private static byte[] decodeStrict(String text) {
    if (text == null) {
      throw new ValidationException("条目密文格式不合法");
    }
    try {
      return WireFormat.base64Decode(text);
    } catch (IllegalArgumentException ex) {
      throw new ValidationException("条目密文格式不合法");
    }
  }

  /** 校验错误；S2 路由层映射为 400 {@code bad_request}。 */
  public static final class ValidationException extends RuntimeException {
    public ValidationException(String message) {
      super(message);
    }
  }
}
