package app.vaultone.server.crypto;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import org.junit.jupiter.api.Test;

/**
 * 服务端密钥与密封盒黄金向量。expected 全部来自 Rust 基线 {@code crates/vault-crypto/tests/server_vectors.rs} 与 {@code
 * docs/10 §7}，在测试内固化为字符串， 不用 Java 自己的实现临时计算 expected 再比较（那不是互通证据）。
 */
class ServerKeysGoldenTest {
  /** 固定随机输入：server_secret、SRP AuthKey = 00..1f。 */
  private static final byte[] SECRET = range(0, 32);

  /** 密封盒 salt = 20..3f。 */
  private static final byte[] SEAL_SALT = range(32, 64);

  /** 密封盒 IV = 40..4b。 */
  private static final byte[] SEAL_IV = range(64, 76);

  private static byte[] range(int from, int toExclusive) {
    byte[] out = new byte[toExclusive - from];
    for (int i = 0; i < out.length; i++) {
      out[i] = (byte) (from + i);
    }
    return out;
  }

  private static String b64(byte[] bytes) {
    return Base64.getEncoder().encodeToString(bytes);
  }

  @Test
  void emailHashMatchesRust() {
    ServerKeys keys = new ServerKeys(SECRET);
    byte[] hash = keys.emailHash("  ALICE@Example.TEST\n");
    assertThat(b64(hash)).isEqualTo("Uz8Jmkx7MwP3HWmIZWVEMbGI8+RZXZAVRWPRJWmIRl8=");
    // 规范化：Unicode trim + lowercase，与大小写/空白无关
    assertThat(keys.emailHash("alice@example.test")).isEqualTo(hash);
    assertThat(keys.emailHash("  ALICE@Example.TEST\n")).isEqualTo(hash);
  }

  @Test
  void otpHashMatchesRust() {
    ServerKeys keys = new ServerKeys(SECRET);
    byte[] hash =
        keys.otpHash(
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002",
            "000123");
    assertThat(b64(hash)).isEqualTo("DrM1BF0mRIroNUsZn4Pf43HB+eCYwb7EbnZsPGiuaKA=");
    // 不能把 000123 当数字 123
    assertThat(
            keys.otpHash(
                "00000000-0000-4000-8000-000000000001",
                "00000000-0000-4000-8000-000000000002",
                "123"))
        .isNotEqualTo(hash);
  }

  @Test
  void decoyMatchesRustAcrossBlocks() {
    ServerKeys keys = new ServerKeys(SECRET);
    byte[] decoy = keys.decoy("  ALICE@Example.TEST\n", "srp-salt", 48);
    assertThat(b64(decoy))
        .isEqualTo("berGTVV/EG19AMkQHioZQDd9/39OWVqlfo4aq8gOJaifqQFtjuhD5i/5oK9+urlv");
    assertThat(decoy).hasSize(48);
    // 跨块：384B（>32B 的单块 HMAC 输出）依然确定
    assertThat(keys.decoy("  ALICE@Example.TEST\n", "verifier", 384))
        .isEqualTo(keys.decoy("alice@example.test", "verifier", 384));
    assertThat(keys.decoy("alice@example.test", "verifier", 384)).hasSize(384);
    assertThat(keys.decoy("alice@example.test", "srp-salt", 32))
        .isNotEqualTo(keys.decoy("alice@example.test", "kdf-salt", 32));
  }

  @Test
  void tokenTextHashMatchesRust() {
    // session token：32B 随机值 URL_SAFE_NO_PAD 编码，库中 SHA256 的输入是 token 字符串 UTF-8
    byte[] raw = range(0, 32);
    String token = Base64.getUrlEncoder().withoutPadding().encodeToString(raw);
    byte[] hash = ServerKeys.sha256(token.getBytes(StandardCharsets.UTF_8));
    assertThat(b64(hash)).isEqualTo("6oZqdX5MOLq/qBJ8vppAnT4fk6AP8UiP9zX8+Rev/9A=");
  }

  @Test
  void emailSealedBoxMatchesRustFixedVector() {
    ServerKeys keys = new ServerKeys(SECRET);
    byte[] blob =
        SealedBox.sealWith(
            HKDF_LABEL(keys, "email-enc"),
            "alice@example.test".getBytes(StandardCharsets.UTF_8),
            "vaultone-server/email".getBytes(StandardCharsets.UTF_8),
            SEAL_SALT,
            SEAL_IV);
    assertThat(b64(blob))
        .isEqualTo(
            "AQEgISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0R/sbohjyMTIxfgIc/IBvyfiDZ9cR/DPf7eo8/+eJr0MDE=");
    // 往返解密
    assertThat(keys.decryptEmail(blob)).isEqualTo("alice@example.test");
    // 错误密钥不得解出
    ServerKeys other = new ServerKeys(range(1, 33));
    assertThatThrownBy(() -> other.decryptEmail(blob))
        .isInstanceOf(SealedBox.IntegrityException.class);
  }

  @Test
  void handshakeSealedBoxMatchesRustFixedVector() {
    ServerKeys keys = new ServerKeys(SECRET);
    byte[] b = new byte[64];
    java.util.Arrays.fill(b, (byte) 0x22);
    byte[] blob =
        SealedBox.sealWith(
            HKDF_LABEL(keys, "handshake"),
            b,
            "00000000-0000-4000-8000-000000000001".getBytes(StandardCharsets.UTF_8),
            SEAL_SALT,
            SEAL_IV);
    assertThat(b64(blob))
        .isEqualTo(
            "AQEgISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS1cFkHrSAXIWUJUGbCwZuAeYyUpBqeekUhza7tlUIYdLb9DdttyPtdPLiN44O2PFUs81SBuGpBwkwpImj2HTie3RZ+UnM4kCc67D0HpTGDc/");
    assertThat(keys.openHandshake("00000000-0000-4000-8000-000000000001", blob)).isEqualTo(b);
    assertThatThrownBy(() -> keys.openHandshake("00000000-0000-4000-8000-000000000002", blob))
        .isInstanceOf(SealedBox.IntegrityException.class);
  }

  /** 通过公开 API 暴露的子密钥：从私钥字段读取受限，这里用反射以外的确定性方式重算域分离子密钥。 */
  private static byte[] HKDF_LABEL(ServerKeys keys, String label) {
    // 与 ServerKeys 内部一致地由 secret 派生；测试独立重算，验证域分离标签。
    return Hkdf.serverSubkey(SECRET, label);
  }

  @Test
  void sealedBoxTamperEveryByteRejected() {
    ServerKeys keys = new ServerKeys(SECRET);
    byte[] blob =
        SealedBox.sealWith(
            Hkdf.serverSubkey(SECRET, "email-enc"),
            "alice@example.test".getBytes(StandardCharsets.UTF_8),
            "vaultone-server/email".getBytes(StandardCharsets.UTF_8),
            SEAL_SALT,
            SEAL_IV);
    for (int i = 0; i < blob.length; i++) {
      byte[] tampered = blob.clone();
      tampered[i] ^= 0x01;
      assertThatThrownBy(() -> keys.decryptEmail(tampered))
          .as("byte %d 应受认证保护", i)
          .isInstanceOf(SealedBox.IntegrityException.class);
    }
  }

  @Test
  void productionSealUsesFreshSaltAndIv() {
    ServerKeys keys = new ServerKeys(SECRET);
    byte[] a = keys.encryptEmail("a@b.com");
    byte[] b = keys.encryptEmail("a@b.com");
    assertThat(a).isNotEqualTo(b);
    assertThat(a).hasSize(SealedBox.OVERHEAD + "a@b.com".length());
    assertThat(keys.decryptEmail(a)).isEqualTo("a@b.com");
    assertThat(keys.decryptEmail(b)).isEqualTo("a@b.com");
  }

  @Test
  void domainSeparatedSubkeysDiffer() {
    ServerKeys keys = new ServerKeys(SECRET);
    byte[] emailIndex = Hkdf.serverSubkey(SECRET, "email-index");
    byte[] otp = Hkdf.serverSubkey(SECRET, "otp");
    assertThat(emailIndex).hasSize(32).isNotEqualTo(otp);
  }
}
