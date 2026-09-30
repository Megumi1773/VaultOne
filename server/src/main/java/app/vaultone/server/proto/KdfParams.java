package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * KDF 参数（对齐 Rust {@code vault_crypto::kdf::KdfParams}）。{@code salt} 自身为字符串，业务校验时再按 STANDARD 解码，不做二次
 * Base64。
 *
 * <p>{@code m}/{@code t}/{@code p} 在线协议是 <b>u32</b>；Java 用 long 承载 JSON 整数，但必须在构造时拒绝 负数与超过 {@code
 * 4294967295} 的值，否则结构上接受了 Rust 不接受的输入。安全下限由后续 validator 负责。
 */
public record KdfParams(
    @JsonProperty(required = true) String alg,
    @JsonProperty(required = true) long m,
    @JsonProperty(required = true) long t,
    @JsonProperty(required = true) long p,
    @JsonProperty(required = true) String salt) {

  private static final long U32_MAX = 0xFFFFFFFFL;

  public KdfParams {
    Dto.requireAll(alg, "alg", salt, "salt");
    requireU32(m, "m");
    requireU32(t, "t");
    requireU32(p, "p");
  }

  private static void requireU32(long value, String field) {
    if (value < 0 || value > U32_MAX) {
      throw new IllegalArgumentException(field + " 超出 u32 范围");
    }
  }
}
