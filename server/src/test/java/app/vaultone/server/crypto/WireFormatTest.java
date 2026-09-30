package app.vaultone.server.crypto;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.Base64;
import org.junit.jupiter.api.Test;

/** STANDARD Base64 严格解码：与 Rust {@code base64::STANDARD} 接受集一致。 */
class WireFormatTest {
  @Test
  void encodeMatchesJdkStandard() {
    for (byte[] input :
        new byte[][] {
          {},
          {0},
          {0, 1},
          {0, 1, 2},
          {0, 1, 2, (byte) 255},
          "hello world".getBytes(java.nio.charset.StandardCharsets.US_ASCII)
        }) {
      assertThat(WireFormat.base64Encode(input))
          .isEqualTo(Base64.getEncoder().encodeToString(input));
    }
  }

  @Test
  void roundTrip() {
    byte[] data = new byte[257];
    for (int i = 0; i < data.length; i++) {
      data[i] = (byte) (i * 7);
    }
    assertThat(WireFormat.base64Decode(WireFormat.base64Encode(data))).isEqualTo(data);
  }

  @Test
  void rejectsNonStandardInput() {
    for (String bad :
        new String[] {
          "AAEC/w", // 缺失 padding
          "AAEC_w==", // URL-safe
          "AAEC+w==" + " ", // 尾部空白
          "AB==", // 非规范尾部位
          "AAB=", // 非规范尾部位（第二字节低 4 位非零）
          "A", // 长度非 4 倍数
          "A===", // padding 过多
          "AAA=AAAA", // padding 在非末尾块
          "!!!!" // 非字母表字符
        }) {
      assertThatThrownBy(() -> WireFormat.base64Decode(bad))
          .as(bad)
          .isInstanceOf(IllegalArgumentException.class);
    }
  }

  @Test
  void nullRejected() {
    assertThatThrownBy(() -> WireFormat.base64Decode(null))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void acceptsCanonicalVectors() {
    // RFC 4648 样例
    assertThat(WireFormat.base64Decode("")).isEmpty();
    assertThat(WireFormat.base64Decode("Zg==")).isEqualTo("f".getBytes());
    assertThat(WireFormat.base64Decode("Zm8=")).isEqualTo("fo".getBytes());
    assertThat(WireFormat.base64Decode("Zm9v")).isEqualTo("foo".getBytes());
    assertThat(WireFormat.base64Decode("Zm9vYg==")).isEqualTo("foob".getBytes());
    assertThat(WireFormat.base64Decode("Zm9vYmE=")).isEqualTo("fooba".getBytes());
    assertThat(WireFormat.base64Decode("Zm9vYmFy")).isEqualTo("foobar".getBytes());
  }
}
