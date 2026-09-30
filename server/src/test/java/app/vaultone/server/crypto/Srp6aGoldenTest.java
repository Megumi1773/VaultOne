package app.vaultone.server.crypto;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Base64;
import org.junit.jupiter.api.Test;

/**
 * SRP-6a 黄金向量与非法值拒绝。expected 来自 Rust {@code
 * crates/vault-crypto/tests/server_vectors.rs::srp_fixed_transcript}，在测试内固化为字符串。
 *
 * <p>固定输入：identity={@code 00000000-0000-4000-8000-000000000001}，AuthKey=00..1f，salt=20..3f，
 * a={@code 0x01}，b=64 个 {@code 0x22}。a=1 时 A=05，特意检测错误的 PAD 规则。
 */
class Srp6aGoldenTest {
  private static final String IDENTITY = "00000000-0000-4000-8000-000000000001";
  private static final byte[] ID = IDENTITY.getBytes(StandardCharsets.UTF_8);
  private static final byte[] AUTH = range(0, 32);
  private static final byte[] SALT = range(32, 64);
  private static final byte[] B = fixedB();

  private static byte[] range(int from, int toExclusive) {
    byte[] out = new byte[toExclusive - from];
    for (int i = 0; i < out.length; i++) {
      out[i] = (byte) (from + i);
    }
    return out;
  }

  private static byte[] fixedB() {
    byte[] b = new byte[64];
    Arrays.fill(b, (byte) 0x22);
    return b;
  }

  private static String b64(byte[] bytes) {
    return Base64.getEncoder().encodeToString(bytes);
  }

  @Test
  void verifierMatchesRust() {
    assertThat(b64(SrpClient.computeVerifier(ID, AUTH, SALT)))
        .isEqualTo(
            "vbwhF0PrhG41PuxxrhCeykqvJFO8D2z1rf+jlRH+0Cq0/Z/cqkkivyuCEA859m5h/H8lNiYPEyuiwVcYrF8IaPhtKN8Lir2OWtZbQbUMUYlGZeY2yJB/uHBR0DPbcG7BbfCB/nLKT7eJMAlzhYYONYOg9Hu3lO7x44M1dzt+GJPrU454vNZdNIgONOr72dKd6YmpqTYC9CDctMNY1rCXCkF5TQZp3h0sA0ifmycpYlKPLK1t5IFpsfb+DeLepI6EQNLiVfj125YMY2cPo/qeJElCbtGA60nJQPmdQFBGE7y3zNccxYd3eeeY+8eUoJToLBt1wFo9WLCzMYvA2RyX47dVNhOEiTaOMG8TKuO8gTZH2ef2BZfMiUPEvIvnXIjIrEOGrF6KlIPfh/mdgeOSlF0gTF09jZ8pWgI0dnHHrtYX9UeSZWswmiqMrzknI4t6VRD8Q5rIcnF30J3l0noMnbSZTxB3PL1j762+GzHClTsNFO/mvT8IzKomZejAdc1K");
  }

  @Test
  void fixedTranscriptMatchesRust() {
    byte[] v = SrpClient.computeVerifier(ID, AUTH, SALT);

    byte[] a = new byte[] {1};
    byte[] aPub = SrpClient.computeA(a);
    assertThat(aPub).isEqualTo(new byte[] {5});
    assertThat(b64(aPub)).isEqualTo("BQ==");

    byte[] bPub = Srp6a.serverStart(v).bPub();
    // serverStart 使用随机 b；固定向量用固定 b 复算 B（服务端 B 与 b 绑定）。
    byte[] expectedBPub = fixedTranscriptBPub(v);
    assertThat(b64(expectedBPub))
        .isEqualTo(
            "LQ9O0xR9vsDxAToZ3O6kCbkWe5ln5bgi3V6gU8NojYfJ03ZMrth7khD/bQ1OWWUvLygbbBsCdZLC2pExiAdV9wxPAPUj2sIXJ0sX6OpU0GSlmNkhxYeHvdTk4/vhWi7pazMyxEJ0ouEwEBLYsdegbVnSuq94LDQCa/pjTIsqG8tSaNig9rT8FZU0O3gtzslxM5E9TSruQ/r97JbgRkC7NxP58/5pcXgNJw7DUcQOqRmmjre8bDJIZ02LpgP7GBv/jQkiaNFkZY1uN8+SQEJ2WjGm+IBWjPXsTjfczN4lHx+9s+C2+amZ5emqFYSTVmv0wttyxuKJbXKMIaDwBgiFhlWd/ks7YhXBNfSwX6QJpCTo1eP5rJFEt5ZguQhyiSfcNCVu1hwUDuXH/s6kVyu0J7rrnqtiS5ENJUN+lL8IoV7c3bTHRkrjnPXPxqc9j8l9VtqkYS5wXG35Ev48P2nJCWueWLe6vkYniQzu28FhzvePl1s3OO/a/7pnnk9TEAM7");

    byte[] clientSecret = SrpClient.clientSecret(a, ID, AUTH, SALT, expectedBPub);
    assertThat(b64(clientSecret))
        .isEqualTo(
            "uUFbJzZon6HRLDlmE/VnwUbyHAD/tSD+PG8tBQZKnRtcVifNBSXPBUo2qvUbfTHR2LKvthuV9qqDPONIx+HbNBZSNfuMKX/dwzNUMLPaJqTVkDkfsHkpeA6TLPUXlOIYKvm9V7Pf2PXGrc7vCLv5JkhZQIMSNNdl21HQs9sbngFqPsJB7FXeY7zm5jsA8jdHkuFOd2/MUkFxh7OfpAV+snRUER/Xq7L1H/ODIpm+bcIXEORa7wsc75hxW9Z3ZPiTIfdJ4TvUOhSZ0IAwONk33gfzsdnsErqpXREBbsP4u3URzhnrf+MgMrkJ+TFDEQHgQg1W85T/3x2RKKdN2Dj6cIyPF7fBe6yuXpqqBrEs7GLhqQpZsxHabA1f2UtTul7Fn7eDUI2ILqc/rTA4IOAjCGltdDQ0VRJ4cWXfRZGhtV83EUZw1hy6XrDZ0dyA3hLB6sH58lEFDgaKVbIs63iGXkEbgF7n/oxeQUyV39qR2Bj3sVBiKbFugMeh1D/wF2gc");

    byte[] m1 = SrpClient.clientM1(a, ID, AUTH, SALT, expectedBPub);
    assertThat(b64(m1)).isEqualTo("/c0Jmw7cI0bN+Bw7Sxch0bcOMPs4LLm09PDeg63yhoc=");

    byte[] m2 = Srp6a.serverFinish(B, v, aPub, m1);
    assertThat(b64(m2)).isEqualTo("cY8FzH+OodMB/PU1/sDkO/0jafHDYP6003nV5WF3D0o=");
    assertThat(Srp6a.serverFinish(B, v, aPub, m1)).as("相同输入应得到相同 M2（确定性）").isEqualTo(m2);
    assertThat(Arrays.copyOf(bPub, bPub.length)).isNotEmpty();
  }

  /** 与固定 b 复算 B：测试用私有适配，避免改生产 API 暴露固定随机入口。 */
  private static byte[] fixedTranscriptBPub(byte[] v) {
    return SrpClient.bPub(B, v);
  }

  @Test
  void serverFinishAcceptsCanonicalAndPaddedA() {
    byte[] v = SrpClient.computeVerifier(ID, AUTH, SALT);
    byte[] a = new byte[] {1};
    byte[] aPub = SrpClient.computeA(a); // 05
    byte[] bPub = SrpClient.bPub(B, v);
    byte[] m1 = SrpClient.clientM1(a, ID, AUTH, SALT, bPub);

    byte[] m2Canonical = Srp6a.serverFinish(B, v, aPub, m1);
    // A 前加 00（0005）是同一整数的另一种编码，必须得到完全相同的证明。
    byte[] paddedA = new byte[] {0x00, 0x05};
    byte[] m2Padded = Srp6a.serverFinish(B, v, paddedA, m1);
    assertThat(m2Padded).isEqualTo(m2Canonical);
  }

  @Test
  void serverStartProducesValidB() {
    byte[] v = SrpClient.computeVerifier(ID, AUTH, SALT);
    Srp6a.ServerStart start = Srp6a.serverStart(v);
    assertThat(start.b()).hasSize(64);
    assertThat(start.bPub()).isNotEmpty();
    // B 必须与 b 一致：用 b 走 serverFinish 应当能验证由客户端计算的 M1。
    byte[] bPub = start.bPub();
    byte[] a = range(10, 74);
    byte[] m1 = SrpClient.clientM1(a, ID, AUTH, SALT, bPub);
    byte[] m2 = Srp6a.serverFinish(start.b(), v, SrpClient.computeA(a), m1);
    assertThat(m2).hasSize(32);
  }

  @Test
  void serverSecretMatchesClient() {
    byte[] v = SrpClient.computeVerifier(ID, AUTH, SALT);
    byte[] a = new byte[] {3};
    byte[] aPub = SrpClient.computeA(a);
    byte[] b = range(100, 164);
    byte[] bPub = SrpClient.bPub(b, v);
    byte[] m1 = SrpClient.clientM1(a, ID, AUTH, SALT, bPub);
    // 服务端接受该 M1 即证明其 S 与客户端一致。
    assertThat(Srp6a.serverFinish(b, v, aPub, m1))
        .isEqualTo(SrpClient.clientM2(a, ID, AUTH, SALT, bPub));
  }

  @Test
  void wrongProofRejected() {
    byte[] v = SrpClient.computeVerifier(ID, AUTH, SALT);
    byte[] aPub = SrpClient.computeA(new byte[] {1});
    assertThatThrownBy(() -> Srp6a.serverFinish(B, v, aPub, new byte[32]))
        .isInstanceOf(Srp6a.SrpException.class);
    assertThatThrownBy(() -> Srp6a.serverFinish(B, v, aPub, new byte[31]))
        .isInstanceOf(Srp6a.SrpException.class);
  }

  @Test
  void maliciousZeroAndNPublicValuesRejected() {
    byte[] v = SrpClient.computeVerifier(ID, AUTH, SALT);
    byte[] m1 = new byte[32];
    // A = 0 → 拒绝
    assertThatThrownBy(() -> Srp6a.serverFinish(B, v, new byte[] {0}, m1))
        .isInstanceOf(Srp6a.SrpException.class);
    // A = N → A mod N == 0 → 拒绝
    byte[] nBytes = Srp6a.encodeUnsigned(Srp6a.modulus());
    assertThatThrownBy(() -> Srp6a.serverFinish(B, v, nBytes, m1))
        .isInstanceOf(Srp6a.SrpException.class);
    // A = N + 0（前导 00 的 N）仍应因 mod N == 0 拒绝
    byte[] paddedN = new byte[nBytes.length + 1];
    System.arraycopy(nBytes, 0, paddedN, 1, nBytes.length);
    assertThatThrownBy(() -> Srp6a.serverFinish(B, v, paddedN, m1))
        .isInstanceOf(Srp6a.SrpException.class);
  }

  @Test
  void modulusMatchesRustGroupBytes() {
    assertThat(Srp6a.modulus().bitLength()).isEqualTo(3072);
    assertThat(Srp6a.modulus().testBit(3071)).isTrue();
    assertThat(Srp6a.modulus().testBit(0)).isTrue();
    assertThat(Srp6a.encodeUnsigned(Srp6a.modulus())).hasSize(384);
  }
}
