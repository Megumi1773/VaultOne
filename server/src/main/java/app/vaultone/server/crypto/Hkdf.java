package app.vaultone.server.crypto;

import java.nio.charset.StandardCharsets;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.bouncycastle.crypto.digests.SHA256Digest;
import org.bouncycastle.crypto.generators.HKDFBytesGenerator;
import org.bouncycastle.crypto.params.HKDFParameters;

/**
 * 服务端密码学原语的统一封装。所有算法（HKDF-SHA256、HMAC-SHA256）都来自成熟库，本类只负责按 现有实现固定参数与域分离标签，<b>不自行实现任何算法</b>。
 *
 * <p>对齐 {@code crates/vault-server/src/keys.rs} 与 {@code crates/vault-crypto/src/sealed.rs}：
 *
 * <ul>
 *   <li>子密钥派生：{@code HKDF-SHA256(IKM=secret, salt="vaultone-server/v1", info=label, L=32)}；
 *   <li>长度前缀 MAC：对每个 part 先写 {@code u64be(part.len)} 再写 part，最后 HMAC-SHA256；
 *   <li>密封盒消息密钥：{@code HKDF-SHA256(IKM=长期密钥, salt=盒内salt, info="vaultone/v1/sealed", L=32)}。
 * </ul>
 */
public final class Hkdf {
  /** 服务端子密钥派生的固定 salt。 */
  public static final byte[] SERVER_SALT = "vaultone-server/v1".getBytes(StandardCharsets.US_ASCII);

  /** 密封盒消息密钥派生的固定 info。 */
  public static final byte[] SEALED_INFO = "vaultone/v1/sealed".getBytes(StandardCharsets.US_ASCII);

  private Hkdf() {}

  /** HKDF-SHA256，输出 {@code length} 字节。 */
  public static byte[] derive(byte[] ikm, byte[] salt, byte[] info, int length) {
    HKDFBytesGenerator generator = new HKDFBytesGenerator(new SHA256Digest());
    generator.init(new HKDFParameters(ikm, salt, info));
    byte[] out = new byte[length];
    generator.generateBytes(out, 0, length);
    return out;
  }

  /** 服务端子密钥：{@code HKDF-SHA256(secret, "vaultone-server/v1", label, 32)}。 */
  public static byte[] serverSubkey(byte[] secret, String label) {
    return derive(secret, SERVER_SALT, label.getBytes(StandardCharsets.UTF_8), 32);
  }

  /**
   * 带长度前缀的 HMAC-SHA256：对每个 part 先写 8 字节大端长度再写 part。
   *
   * <p>长度按<b>字节数</b>计（不是字符数），无结尾 NUL。该构造避免拼接歧义（挪动 part 边界不能伪造）。
   */
  public static byte[] lengthPrefixedMac(byte[] key, byte[]... parts) {
    try {
      Mac mac = Mac.getInstance("HmacSHA256");
      mac.init(new SecretKeySpec(key, "HmacSHA256"));
      for (byte[] part : parts) {
        long len = part.length;
        byte[] prefix = new byte[8];
        for (int i = 7; i >= 0; i--) {
          prefix[i] = (byte) (len & 0xFF);
          len >>>= 8;
        }
        mac.update(prefix);
        mac.update(part);
      }
      return mac.doFinal();
    } catch (java.security.GeneralSecurityException e) {
      // HmacSHA256 是 JDK 必备算法，缺失属于环境损坏。
      throw new IllegalStateException("HMAC-SHA256 不可用", e);
    }
  }
}
