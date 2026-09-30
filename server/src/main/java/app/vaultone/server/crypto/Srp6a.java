package app.vaultone.server.crypto;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Arrays;

/**
 * SRP-6a 服务端适配（RFC 5054 3072-bit 群，g=5，H=SHA-256），逐字节对齐 RustCrypto {@code srp 0.6.0}。
 *
 * <p>协议要点（非显然，勿改）：
 *
 * <ul>
 *   <li>不使用 BC 的 {@code SRP6Server}：其 u 用 {@code PAD(A)|PAD(B)}，k 与证明格式也不同，默认配置下不与本项目互通。
 *   <li>参与 u/M1/M2 的 A/B/S 一律先按无符号大端读入 {@link BigInteger} 再以<b>最短</b>大端编码输出（无前导 0、不左补齐）；因此 {@code
 *       A=05} 与 {@code A=0005} 得到相同证明。
 *   <li>k 中 g 左补齐到 N 的长度（384B），不是 32B PAD；identity=account_id 原样 UTF-8；口令=AuthKey 原始 32 字节。
 * </ul>
 *
 * <p>N 的权威字节为 {@code srp-0.6.0/src/groups/3072.bin}（384 字节，测试逐字节核对）。
 */
public final class Srp6a {
  private static final byte[] N_BYTES =
      java.util.HexFormat.of()
          .parseHex(
              "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22"
                  + "514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7"
                  + "ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ec"
                  + "e45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f35"
                  + "6208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3be39e"
                  + "772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae5"
                  + "15d2261898fa051015728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbe"
                  + "f0a8aea71575d060c7db3970f85a6e1e4c7abf5ae8cdb0933d71e8c94e04a25619dcee3d2261"
                  + "ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988"
                  + "c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff");

  private static final BigInteger N = new BigInteger(1, N_BYTES);
  private static final BigInteger G = BigInteger.valueOf(5);
  private static final BigInteger K = computeKInternal();
  private static final int N_LEN = 384;

  /** 生产临时私钥 b 长度（字节）。 */
  public static final int EPHEMERAL_LEN = 64;

  private static final int HASH_LEN = 32;

  private static final SecureRandom RANDOM = new SecureRandom();

  private Srp6a() {}

  /** 最短无符号大端编码（对齐 Rust {@code BigUint::to_bytes_be()}，去除 Java 符号前导 0）。 */
  public static byte[] encodeUnsigned(BigInteger value) {
    byte[] raw = value.toByteArray();
    int start = 0;
    while (start < raw.length - 1 && raw[start] == 0) {
      start++;
    }
    return start == 0 ? raw : Arrays.copyOfRange(raw, start, raw.length);
  }

  private static BigInteger decodeUnsigned(byte[] bytes) {
    return new BigInteger(1, bytes);
  }

  private static BigInteger normalize(byte[] unsignedBytes) {
    return decodeUnsigned(unsignedBytes);
  }

  /** 服务端第一步：生成随机 b 与 B。 */
  public static ServerStart serverStart(byte[] verifier) {
    byte[] b = new byte[EPHEMERAL_LEN];
    RANDOM.nextBytes(b);
    byte[] bPub = encodeUnsigned(bPub(decodeUnsigned(b), decodeUnsigned(verifier)));
    return new ServerStart(b, bPub);
  }

  /** 3072-bit 模数（包内可见，供测试核对群参数）。 */
  static BigInteger modulus() {
    return N;
  }

  private static BigInteger k() {
    return K;
  }

  private static BigInteger computeKInternal() {
    byte[] g = encodeUnsigned(G);
    byte[] paddedG = new byte[N_LEN];
    System.arraycopy(g, 0, paddedG, N_LEN - g.length, g.length);
    return decodeUnsigned(sha256(concat(N_BYTES, paddedG)));
  }

  private static BigInteger bPub(BigInteger b, BigInteger v) {
    BigInteger inter = k().multiply(v).mod(N);
    return inter.add(G.modPow(b, N)).mod(N);
  }

  private static BigInteger computeU(BigInteger aPub, BigInteger bPub) {
    return decodeUnsigned(sha256(concat(encodeUnsigned(aPub), encodeUnsigned(bPub))));
  }

  /**
   * 服务端第二步：校验客户端证明 M1 并返回 M2。
   *
   * <p>A 按无符号读入并重新最短编码后参与 u/M1/M2（见类注释），M1 必须 32B。
   *
   * @throws SrpException A mod N=0 或证明不匹配时
   */
  public static byte[] serverFinish(byte[] b, byte[] verifier, byte[] aPub, byte[] m1) {
    if (m1 == null || m1.length != HASH_LEN) {
      throw new SrpException("M1 长度不正确");
    }
    BigInteger a = normalize(aPub);
    if (a.mod(N).signum() == 0) {
      throw new SrpException("A 模 N 为零");
    }
    byte[] secret = null;
    try {
      BigInteger v = decodeUnsigned(verifier);
      BigInteger bInt = decodeUnsigned(b);
      BigInteger bPubInt = bPub(bInt, v);
      BigInteger u = computeU(a, bPubInt);
      secret = encodeUnsigned(a.multiply(v.modPow(u, N)).mod(N).modPow(bInt, N));
      byte[] aCanonical = encodeUnsigned(a);
      byte[] bCanonical = encodeUnsigned(bPubInt);
      byte[] expected = sha256(concat(aCanonical, bCanonical, secret));
      if (!ServerKeys.constantTimeEquals(expected, m1)) {
        throw new SrpException("客户端证明不匹配");
      }
      return sha256(concat(aCanonical, expected, secret));
    } finally {
      wipe(secret);
    }
  }

  /** 服务端第一步结果：随机私钥 b 与公钥 B。调用方用后应擦除 {@link #b()}。 */
  public record ServerStart(byte[] b, byte[] bPub) {}

  private static byte[] sha256(byte[] input) {
    return ServerKeys.sha256(input);
  }

  private static void wipe(byte[] data) {
    if (data != null) {
      Arrays.fill(data, (byte) 0);
    }
  }

  private static byte[] concat(byte[]... parts) {
    int total = 0;
    for (byte[] part : parts) {
      total += part.length;
    }
    byte[] out = new byte[total];
    int pos = 0;
    for (byte[] part : parts) {
      System.arraycopy(part, 0, out, pos, part.length);
      pos += part.length;
    }
    return out;
  }

  /** identity 的 UTF-8 字节（account_id 原样，不做规范化）。 */
  public static byte[] identityBytes(String accountId) {
    return accountId.getBytes(StandardCharsets.UTF_8);
  }

  /** SRP 运算错误（非法公开值、证明不匹配等），不携带密码学细节。 */
  public static final class SrpException extends RuntimeException {
    public SrpException(String message) {
      super(message);
    }
  }
}
