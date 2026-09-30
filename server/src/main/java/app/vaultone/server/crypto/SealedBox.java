package app.vaultone.server.crypto;

import java.security.SecureRandom;
import java.util.Arrays;
import javax.crypto.AEADBadTagException;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * 密封盒（Sealed Box）——VaultOne 唯一的对称加密格式，对齐 {@code crates/vault-crypto/src/sealed.rs}： {@code 01 | 01
 * | salt[32] | iv[12] | ciphertext | tag[16]}。
 *
 * <p>消息密钥 {@code HKDF-SHA256(长期密钥, salt, "vaultone/v1/sealed")}；AAD 为 {@code header(46B) ||
 * u64be(len(外部AAD)) || 外部AAD}（头部与外部 AAD 均受认证保护）。生产入口 {@link #seal} 每次用独立随机盐与 IV。
 */
public final class SealedBox {
  public static final int VERSION = 0x01;
  public static final int SUITE_AES256GCM_HKDF_SHA256 = 0x01;
  public static final int SALT_LEN = 32;
  public static final int IV_LEN = 12;
  public static final int TAG_LEN = 16;
  public static final int HEADER_LEN = 2 + SALT_LEN + IV_LEN;

  /** 密封盒相对明文的固定开销。 */
  public static final int OVERHEAD = HEADER_LEN + TAG_LEN;

  /** 256-bit 密钥的密封盒总长度。 */
  public static final int WRAPPED_KEY_LEN = OVERHEAD + 32;

  private static final SecureRandom RANDOM = new SecureRandom();

  private SealedBox() {}

  /** 加密；每次生成随机盐与 IV。{@code aad} 为不加密但受认证的上下文绑定数据。 */
  public static byte[] seal(byte[] key, byte[] plaintext, byte[] aad) {
    byte[] salt = new byte[SALT_LEN];
    byte[] iv = new byte[IV_LEN];
    RANDOM.nextBytes(salt);
    RANDOM.nextBytes(iv);
    return sealWith(key, plaintext, aad, salt, iv);
  }

  /** 固定盐/IV 的加密：仅包内可见，供黄金向量测试使用；生产只能走 {@link #seal}。 */
  static byte[] sealWith(byte[] key, byte[] plaintext, byte[] aad, byte[] salt, byte[] iv) {
    if (salt.length != SALT_LEN || iv.length != IV_LEN) {
      throw new IllegalArgumentException("盐/IV 长度不正确");
    }
    byte[] header = new byte[HEADER_LEN];
    header[0] = (byte) VERSION;
    header[1] = (byte) SUITE_AES256GCM_HKDF_SHA256;
    System.arraycopy(salt, 0, header, 2, SALT_LEN);
    System.arraycopy(iv, 0, header, 2 + SALT_LEN, IV_LEN);

    byte[] messageKey = Hkdf.derive(key, salt, Hkdf.SEALED_INFO, 32);
    try {
      byte[] ciphertext = gcm(Cipher.ENCRYPT_MODE, messageKey, iv, plaintext, fullAad(header, aad));
      byte[] out = new byte[header.length + ciphertext.length];
      System.arraycopy(header, 0, out, 0, header.length);
      System.arraycopy(ciphertext, 0, out, header.length, ciphertext.length);
      return out;
    } finally {
      Arrays.fill(messageKey, (byte) 0);
    }
  }

  /** 解密并校验认证标签。密钥错、AAD 不符、篡改、截断、未知 version/suite 都抛出 {@link IntegrityException}。 */
  public static byte[] open(byte[] key, byte[] sealed, byte[] aad) {
    if (sealed.length < OVERHEAD) {
      throw new IntegrityException("密封盒长度不足");
    }
    if ((sealed[0] & 0xFF) != VERSION) {
      throw new IntegrityException("密封盒版本不受支持");
    }
    if ((sealed[1] & 0xFF) != SUITE_AES256GCM_HKDF_SHA256) {
      throw new IntegrityException("密封盒套件不受支持");
    }
    byte[] header = new byte[HEADER_LEN];
    System.arraycopy(sealed, 0, header, 0, HEADER_LEN);
    byte[] salt = new byte[SALT_LEN];
    System.arraycopy(header, 2, salt, 0, SALT_LEN);
    byte[] iv = new byte[IV_LEN];
    System.arraycopy(header, 2 + SALT_LEN, iv, 0, IV_LEN);

    byte[] messageKey = Hkdf.derive(key, salt, Hkdf.SEALED_INFO, 32);
    try {
      byte[] body = new byte[sealed.length - HEADER_LEN];
      System.arraycopy(sealed, HEADER_LEN, body, 0, body.length);
      return gcm(Cipher.DECRYPT_MODE, messageKey, iv, body, fullAad(header, aad));
    } finally {
      Arrays.fill(messageKey, (byte) 0);
    }
  }

  private static byte[] fullAad(byte[] header, byte[] aad) {
    byte[] out = new byte[header.length + 8 + aad.length];
    System.arraycopy(header, 0, out, 0, header.length);
    long len = aad.length;
    for (int i = 0; i < 8; i++) {
      out[header.length + 7 - i] = (byte) (len & 0xFF);
      len >>>= 8;
    }
    System.arraycopy(aad, 0, out, header.length + 8, aad.length);
    return out;
  }

  private static byte[] gcm(int mode, byte[] key, byte[] iv, byte[] input, byte[] aad) {
    try {
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(mode, new SecretKeySpec(key, "AES"), new GCMParameterSpec(TAG_LEN * 8, iv));
      cipher.updateAAD(aad);
      return cipher.doFinal(input);
    } catch (AEADBadTagException e) {
      throw new IntegrityException("密封盒认证失败");
    } catch (java.security.GeneralSecurityException e) {
      throw new IntegrityException("密封盒不可解密");
    }
  }

  /** 认证失败（密钥/AAD/篡改/截断）统一异常，不携带细节。 */
  public static final class IntegrityException extends RuntimeException {
    public IntegrityException(String message) {
      super(message);
    }
  }
}
