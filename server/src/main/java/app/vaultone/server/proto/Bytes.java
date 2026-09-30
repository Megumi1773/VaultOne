package app.vaultone.server.proto;

import app.vaultone.server.crypto.WireFormat;
import java.util.Arrays;
import java.util.Objects;

/**
 * 以 STANDARD Base64 线格式承载的字节值。不可变、构造时防御复制、{@link #toString()}/{@link #hashCode()} 不泄露内容，仅输出长度。对齐
 * Rust {@code vault_proto::Bytes}（空串为 {@code ""}）。
 *
 * <p>序列化/反序列化由 {@link WireModule} 显式注册。
 */
public final class Bytes {
  private final byte[] value;

  private Bytes(byte[] value) {
    this.value = value;
  }

  /** 从字节数组构造；内部防御复制，保证实例不可变、不受调用方后续修改影响。 */
  public static Bytes wrap(byte[] bytes) {
    return new Bytes(Objects.requireNonNull(bytes, "bytes").clone());
  }

  /** 从已有数组防御复制构造（等价 {@link #wrap(byte[])}）。 */
  public static Bytes copyOf(byte[] bytes) {
    return wrap(bytes);
  }

  /** 从 STANDARD Base64 文本严格解码。 */
  public static Bytes fromBase64(String text) {
    return new Bytes(WireFormat.base64Decode(text));
  }

  /** 返回内部字节的副本，保证外部无法修改实例状态。 */
  public byte[] toByteArray() {
    return value.clone();
  }

  /** 内部读取，仅供同包与调用方在明确只读契约下使用；不会复制。 */
  byte[] raw() {
    return value;
  }

  public int length() {
    return value.length;
  }

  public boolean isEmpty() {
    return value.length == 0;
  }

  @Override
  public boolean equals(Object other) {
    return other instanceof Bytes bytes && Arrays.equals(this.value, bytes.value);
  }

  @Override
  public int hashCode() {
    // 固定常量，避免用内容做哈希而侧面暴露字节。
    return Bytes.class.hashCode();
  }

  @Override
  public String toString() {
    return "Bytes(" + value.length + " B)";
  }

  /** 编码为 STANDARD Base64 文本。 */
  public String toBase64() {
    return WireFormat.base64Encode(value);
  }

  /** 便捷：UTF-8 文本的字节值（用于 identity 等）。 */
  public static Bytes utf8(String text) {
    return new Bytes(text.getBytes(java.nio.charset.StandardCharsets.UTF_8));
  }
}
