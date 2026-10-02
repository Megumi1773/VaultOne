package app.vaultone.server.validate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.crypto.WireFormat;
import app.vaultone.server.proto.DeviceInfo;
import app.vaultone.server.proto.KdfParams;
import app.vaultone.server.proto.Platform;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;

/**
 * 输入校验对齐 {@code crates/vault-server/src/validate.rs}：邮箱、KDF 下限、SRP 长度、密封盒长度、 设备名 Unicode
 * scalar、条目信封结构与 256B 对齐。
 */
class WireValidationTest {
  private static final String ID = "00000000-0000-4000-8000-000000000001";

  private static KdfParams kdf(long m, long t, long p, int saltLen) {
    return new KdfParams("argon2id", m, t, p, WireFormat.base64Encode(new byte[saltLen]));
  }

  private static DeviceInfo device(String name) {
    return new DeviceInfo(ID, name, Platform.WINDOWS);
  }

  // ── 邮箱 ──

  @Test
  void emailAcceptsRustLightweightRules() {
    assertThatCode(() -> WireValidation.email("a@b.c")).doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.email("  ALICE@Example.TEST\n")).doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.email("x@y.z" + "a".repeat(240)))
        .doesNotThrowAnyException();
  }

  @Test
  void emailRejectsMalformed() {
    for (String bad : new String[] {"no-at", "a@b", "@b.c", "a@", "x".repeat(255) + "@b.c"}) {
      assertThatThrownBy(() -> WireValidation.email(bad))
          .as(bad)
          .isInstanceOf(WireValidation.ValidationException.class);
    }
  }

  // ── UUID ──

  @Test
  void uuidAcceptsRustForms() {
    assertThatCode(() -> WireValidation.uuid(ID, "id")).doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.uuid("00000000000040008000000000000001", "id"))
        .doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.uuid("{00000000-0000-4000-8000-000000000001}", "id"))
        .doesNotThrowAnyException();
  }

  @Test
  void uuidRejectsMalformed() {
    for (String bad :
        new String[] {
          "", "abc", "00000000-0000-4000-8000-00000000000", "g0000000-0000-4000-8000-000000000001"
        }) {
      assertThatThrownBy(() -> WireValidation.uuid(bad, "id"))
          .as(bad)
          .isInstanceOf(WireValidation.ValidationException.class);
    }
  }

  // ── KDF ──

  @Test
  void kdfProductionBounds() {
    assertThatCode(() -> WireValidation.kdf(kdf(65536, 3, 4, 32))).doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.kdf(kdf(19 * 1024, 2, 1, 16))).doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.kdf(kdf(4 * 1024 * 1024, 64, 16, 32)))
        .doesNotThrowAnyException();
  }

  @Test
  void kdfRejectsDowngradeAndShortSalt() {
    assertThatThrownBy(() -> WireValidation.kdf(kdf(1024, 1, 1, 32)))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.kdf(kdf(65536, 1, 4, 32)))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.kdf(kdf(65536, 3, 0, 32)))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.kdf(kdf(65536, 3, 17, 32)))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.kdf(kdf(65536, 3, 4, 8)))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(
            () ->
                WireValidation.kdf(
                    new KdfParams("pbkdf2", 65536, 3, 4, WireFormat.base64Encode(new byte[32]))))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  @Test
  void kdfLenientOnlyAllowsTestCostWhenEnabled() {
    KdfParams test = kdf(8, 1, 1, 32);
    assertThatCode(() -> WireValidation.kdfLenient(test, true)).doesNotThrowAnyException();
    assertThatThrownBy(() -> WireValidation.kdfLenient(test, false))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  // ── SRP / 密封盒 / hash ──

  @Test
  void srpSaltAndVerifierBounds() {
    assertThatCode(() -> WireValidation.srp(new byte[16], new byte[1])).doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.srp(new byte[64], new byte[384]))
        .doesNotThrowAnyException();
    assertThatThrownBy(() -> WireValidation.srp(new byte[15], new byte[1]))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.srp(new byte[65], new byte[1]))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.srp(new byte[32], new byte[0]))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.srp(new byte[32], new byte[385]))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  @Test
  void wrappedKeyMustBe94BytesWithHeader() {
    byte[] good = new byte[94];
    good[0] = 1;
    good[1] = 1;
    assertThatCode(() -> WireValidation.wrappedKey(good, "vk_wrap")).doesNotThrowAnyException();
    assertThatThrownBy(() -> WireValidation.wrappedKey(new byte[93], "vk_wrap"))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.wrappedKey(new byte[95], "vk_wrap"))
        .isInstanceOf(WireValidation.ValidationException.class);
    byte[] badHeader = good.clone();
    badHeader[1] = 2;
    assertThatThrownBy(() -> WireValidation.wrappedKey(badHeader, "vk_wrap"))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  @Test
  void hash32Length() {
    assertThatCode(() -> WireValidation.hash32(new byte[32], "h")).doesNotThrowAnyException();
    assertThatThrownBy(() -> WireValidation.hash32(new byte[31], "h"))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  // ── 设备名（Unicode scalar 计数）──

  @Test
  void deviceNameCountsUnicodeScalars() {
    assertThatCode(() -> WireValidation.device(device("我的设备"))).doesNotThrowAnyException();
    // 64 个 emoji（每个 2 UTF-16 code unit）应合法，若按 UTF-16 长度会误判为 128 超限
    assertThatCode(() -> WireValidation.device(device("\uD83D\uDE00".repeat(64))))
        .doesNotThrowAnyException();
    assertThatThrownBy(() -> WireValidation.device(device("")))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.device(device("   ")))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.device(device("\uD83D\uDE00".repeat(65))))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  // ── kind ──

  @Test
  void kindWhitelist() {
    for (String k : new String[] {"login", "card", "note", "identity"}) {
      assertThatCode(() -> WireValidation.kind(k)).doesNotThrowAnyException();
    }
    for (String k : new String[] {"Login", "totp", "", "other"}) {
      assertThatThrownBy(() -> WireValidation.kind(k))
          .isInstanceOf(WireValidation.ValidationException.class);
    }
  }

  // ── 条目信封结构 ──

  @Test
  void itemBlobRejectsPlaintextAndBadShape() {
    assertThatThrownBy(
            () ->
                WireValidation.itemBlob(
                    "{\"title\":\"GitHub\",\"password\":\"hunter2\"}"
                        .getBytes(StandardCharsets.UTF_8)))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.itemBlob("plaintext".getBytes(StandardCharsets.UTF_8)))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.itemBlob(new byte[WireValidation.MAX_BLOB_LEN + 1]))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  @Test
  void itemBlobAcceptsStructuralEnvelope() {
    // 构造结构合法的信封：wrappedKey=94B 盒，ct=62B 开销 + 256B body
    byte[] wrapped = new byte[94];
    wrapped[0] = 1;
    wrapped[1] = 1;
    byte[] ct = new byte[62 + 256];
    ct[0] = 1;
    ct[1] = 1;
    String blob =
        "{\"v\":2,\"alg\":\"aes-256-gcm\",\"wrappedKey\":\""
            + WireFormat.base64Encode(wrapped)
            + "\",\"ct\":\""
            + WireFormat.base64Encode(ct)
            + "\"}";
    assertThatCode(() -> WireValidation.itemBlob(blob.getBytes(StandardCharsets.UTF_8)))
        .doesNotThrowAnyException();
  }

  @Test
  void itemBlobRejectsUnalignedCiphertext() {
    byte[] wrapped = new byte[94];
    wrapped[0] = 1;
    wrapped[1] = 1;
    byte[] ct = new byte[62 + 100]; // 100 未按 256 对齐
    ct[0] = 1;
    ct[1] = 1;
    String blob =
        "{\"v\":2,\"alg\":\"aes-256-gcm\",\"wrappedKey\":\""
            + WireFormat.base64Encode(wrapped)
            + "\",\"ct\":\""
            + WireFormat.base64Encode(ct)
            + "\"}";
    assertThatThrownBy(() -> WireValidation.itemBlob(blob.getBytes(StandardCharsets.UTF_8)))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  @Test
  void itemBlobRejectsExtraKeys() {
    String blob =
        "{\"v\":2,\"alg\":\"aes-256-gcm\",\"wrappedKey\":\"AA==\",\"ct\":\"AA==\",\"extra\":1}";
    assertThatThrownBy(() -> WireValidation.itemBlob(blob.getBytes(StandardCharsets.UTF_8)))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  // ── 邮箱规范化（Unicode 空白与大小写）──

  @Test
  void emailNormalizationMatchesRustTrimLowercase() {
    assertThat(ServerKeys.normalizeEmail("  ALICE@Example.TEST\n")).isEqualTo("alice@example.test");
    // NBSP (U+00A0) 属于 Rust White_Space，Java Character.isWhitespace 漏掉，应由自定义实现去除
    assertThat(ServerKeys.normalizeEmail("\u00A0a@b.com\u00A0")).isEqualTo("a@b.com");
    assertThat(ServerKeys.normalizeEmail("\u0085a@b.com")).isEqualTo("a@b.com");
    // 零宽空格 U+200B 不是 White_Space，不去除
    assertThat(ServerKeys.normalizeEmail("\u200Ba@b.com")).isEqualTo("\u200Ba@b.com");
  }

  // ── 校验必须使用 Rust trim（不是 Java trim）──

  @Test
  void emailValidationUsesRustTrim() {
    // U+00A0 / U+0085 是 Rust White_Space 但 Java String.trim 不去除；rustTrim 应去掉。
    assertThatCode(() -> WireValidation.email("\u00A0a@b.c\u00A0")).doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.email("\u0085a@b.c")).doesNotThrowAnyException();
    // Java trim 不会去掉 U+200B，这里照样是合法本地部分字符（不强制拒绝）
    assertThatCode(() -> WireValidation.email("\u200Ba@b.c")).doesNotThrowAnyException();
  }

  @Test
  void deviceValidationUsesRustTrim() {
    // 名称前后 NBSP 应被 rustTrim 去掉；若用 Java trim 会保留为空白名并被判空。
    assertThatCode(() -> WireValidation.device(device("\u00A0我的设备\u00A0")))
        .doesNotThrowAnyException();
    // 纯 NBSP 去空白后为空 → 拒绝
    assertThatThrownBy(() -> WireValidation.device(device("\u00A0")))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  // ── 信封 v 必须是整数节点 2 ──

  @Test
  void itemBlobRequiresIntegralV() {
    byte[] wrapped = new byte[94];
    wrapped[0] = 1;
    wrapped[1] = 1;
    byte[] ct = new byte[62 + 256];
    ct[0] = 1;
    ct[1] = 1;
    String tail = "\",\"ct\":\"" + WireFormat.base64Encode(ct) + "\"}";
    String wrappedB64 = WireFormat.base64Encode(wrapped);

    // 字符串 "2" 必须拒绝（不是整数节点）
    String asString = "{\"v\":\"2\",\"alg\":\"aes-256-gcm\",\"wrappedKey\":\"" + wrappedB64 + tail;
    assertThatThrownBy(() -> WireValidation.itemBlob(asString.getBytes(StandardCharsets.UTF_8)))
        .isInstanceOf(WireValidation.ValidationException.class);
    // 小数 2.0 必须拒绝
    String asFloat = "{\"v\":2.0,\"alg\":\"aes-256-gcm\",\"wrappedKey\":\"" + wrappedB64 + tail;
    assertThatThrownBy(() -> WireValidation.itemBlob(asFloat.getBytes(StandardCharsets.UTF_8)))
        .isInstanceOf(WireValidation.ValidationException.class);
    // 整数 2 接受
    String asInt = "{\"v\":2,\"alg\":\"aes-256-gcm\",\"wrappedKey\":\"" + wrappedB64 + tail;
    assertThatCode(() -> WireValidation.itemBlob(asInt.getBytes(StandardCharsets.UTF_8)))
        .doesNotThrowAnyException();
  }

  // ── 账户资料（§8.2）──

  @Test
  void profileAcceptsEmptyAndOrdinaryValues() {
    assertThatCode(() -> WireValidation.profile("", "")).doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.profile("阿澈", "https://example.com/a.png"))
        .doesNotThrowAnyException();
    // 中文、emoji、空格都允许：昵称只用于显示，不参与认证或寻址。
    assertThatCode(() -> WireValidation.profile(" 小 明 🎉 ", "")).doesNotThrowAnyException();
    // 首尾空白会被裁掉，因此"全是空白"等价于未设置，不该报错。
    assertThatCode(() -> WireValidation.profile("   ", "   ")).doesNotThrowAnyException();
  }

  @Test
  void profileRejectsOverlongNicknameByCodePoints() {
    assertThatCode(() -> WireValidation.profile("字".repeat(WireValidation.NICKNAME_MAX), ""))
        .doesNotThrowAnyException();
    assertThatThrownBy(
            () -> WireValidation.profile("字".repeat(WireValidation.NICKNAME_MAX + 1), ""))
        .isInstanceOf(WireValidation.ValidationException.class);
    // 按码点而不是 UTF-16 长度：emoji 是代理对，按长度算会少一半名额。
    assertThatCode(() -> WireValidation.profile("🎉".repeat(WireValidation.NICKNAME_MAX), ""))
        .doesNotThrowAnyException();
  }

  @Test
  void profileRejectsControlCharacters() {
    assertThatThrownBy(() -> WireValidation.profile("a\nb", ""))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.profile("a\u0000b", ""))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.profile("", "https://example.com/a\nb"))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  @Test
  void avatarOnlyAcceptsHttpAndHttps() {
    assertThatCode(() -> WireValidation.profile("", "http://example.com/a.png"))
        .doesNotThrowAnyException();
    assertThatCode(() -> WireValidation.profile("", "HTTPS://example.com/a.png"))
        .doesNotThrowAnyException();
    // 这个值最终会被客户端拿去渲染，伪协议必须挡住。
    for (String bad :
        new String[] {
          "javascript:alert(1)",
          "data:image/png;base64,AAAA",
          "file:///etc/passwd",
          "/local/path.png"
        }) {
      assertThatThrownBy(() -> WireValidation.profile("", bad), bad)
          .isInstanceOf(WireValidation.ValidationException.class);
    }
  }

  @Test
  void avatarRejectsOverlongAndNull() {
    assertThatCode(
            () ->
                WireValidation.profile(
                    "", "https://e.com/" + "a".repeat(WireValidation.AVATAR_MAX - 20)))
        .doesNotThrowAnyException();
    assertThatThrownBy(
            () ->
                WireValidation.profile(
                    "", "https://e.com/" + "a".repeat(WireValidation.AVATAR_MAX)))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.profile(null, ""))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> WireValidation.profile("", null))
        .isInstanceOf(WireValidation.ValidationException.class);
  }
}
