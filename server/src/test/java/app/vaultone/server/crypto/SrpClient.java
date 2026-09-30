package app.vaultone.server.crypto;

import java.math.BigInteger;
import java.util.Arrays;

/**
 * SRP 客户端侧计算，仅供测试交叉验证：确认 Java 服务端实现与 Rust 客户端在字节级一致。
 *
 * <p>刻意放在测试目录，不让业务模块暴露接收 AuthKey 的“客户端”入口。公式与 RustCrypto {@code srp 0.6.0} 客户端一致（见 {@link Srp6a}
 * 类注释的协议要点）。
 */
final class SrpClient {
  private static final BigInteger N = Srp6a.modulus();
  private static final BigInteger G = BigInteger.valueOf(5);
  private static final int N_LEN = 384;

  private SrpClient() {}

  private static BigInteger k() {
    byte[] n = Srp6a.encodeUnsigned(N);
    byte[] g = Srp6a.encodeUnsigned(G);
    byte[] paddedG = new byte[N_LEN];
    System.arraycopy(g, 0, paddedG, N_LEN - g.length, g.length);
    return new BigInteger(1, sha256(concat(n, paddedG)));
  }

  static byte[] computeA(byte[] a) {
    return Srp6a.encodeUnsigned(G.modPow(new BigInteger(1, a), N));
  }

  /** B = (k*v + g^b) mod N，固定 b 用于黄金向量。 */
  static byte[] bPub(byte[] b, byte[] verifier) {
    BigInteger inter = k().multiply(new BigInteger(1, verifier)).mod(N);
    return Srp6a.encodeUnsigned(inter.add(G.modPow(new BigInteger(1, b), N)).mod(N));
  }

  /** v = g^x mod N，x = H(salt || H(I || ':' || AuthKey))。 */
  static byte[] computeVerifier(byte[] identity, byte[] authKey, byte[] salt) {
    return Srp6a.encodeUnsigned(G.modPow(x(salt, identity, authKey), N));
  }

  static byte[] clientSecret(byte[] a, byte[] identity, byte[] authKey, byte[] salt, byte[] bPub) {
    BigInteger b = new BigInteger(1, bPub);
    if (b.mod(N).signum() == 0) {
      throw new Srp6a.SrpException("B 模 N 为零");
    }
    BigInteger aInt = new BigInteger(1, a);
    BigInteger aPub = new BigInteger(1, computeA(a));
    BigInteger u = u(aPub, b);
    BigInteger x = x(salt, identity, authKey);
    BigInteger base = k().multiply(G.modPow(x, N)).mod(N);
    base = N.add(b).subtract(base).mod(N);
    BigInteger exp = u.multiply(x).add(aInt);
    return Srp6a.encodeUnsigned(base.modPow(exp, N));
  }

  static byte[] clientM1(byte[] a, byte[] identity, byte[] authKey, byte[] salt, byte[] bPub) {
    byte[] secret = clientSecret(a, identity, authKey, salt, bPub);
    return m1(computeA(a), bPub, secret);
  }

  static byte[] clientM2(byte[] a, byte[] identity, byte[] authKey, byte[] salt, byte[] bPub) {
    byte[] secret = clientSecret(a, identity, authKey, salt, bPub);
    byte[] aPub = computeA(a);
    return sha256(
        concat(aPub, m1(aPub, bPub, secret), Srp6a.encodeUnsigned(new BigInteger(1, secret))));
  }

  static byte[] m1(byte[] aPub, byte[] bPub, byte[] secret) {
    return sha256(
        concat(
            Srp6a.encodeUnsigned(new BigInteger(1, aPub)),
            Srp6a.encodeUnsigned(new BigInteger(1, bPub)),
            Srp6a.encodeUnsigned(new BigInteger(1, secret))));
  }

  private static BigInteger u(BigInteger aPub, BigInteger bPub) {
    return new BigInteger(
        1, sha256(concat(Srp6a.encodeUnsigned(aPub), Srp6a.encodeUnsigned(bPub))));
  }

  private static BigInteger x(byte[] salt, byte[] identity, byte[] authKey) {
    byte[] identityHash = sha256(concat(identity, new byte[] {':'}, authKey));
    return new BigInteger(1, sha256(concat(salt, identityHash)));
  }

  private static byte[] sha256(byte[] input) {
    return ServerKeys.sha256(input);
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

  static void wipe(byte[] data) {
    if (data != null) {
      Arrays.fill(data, (byte) 0);
    }
  }
}
