package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * 改密请求。{@code recoveryWrap}/{@code recoveryAuthHash} 为 Option，允许缺失或显式 null （对应 Rust serde default）。
 */
public record ChangeCredentialsRequest(
    @JsonProperty(required = true) KdfParams kdf,
    @JsonProperty(required = true) Bytes srpSalt,
    @JsonProperty(required = true) Bytes srpVerifier,
    @JsonProperty(required = true) Bytes vkWrap,
    @JsonProperty(required = true) long expectedVkGen,
    Bytes recoveryWrap,
    Bytes recoveryAuthHash) {
  public ChangeCredentialsRequest {
    Dto.requireAll(kdf, "kdf", srpSalt, "srp_salt", srpVerifier, "srp_verifier", vkWrap, "vk_wrap");
  }

  @Override
  public String toString() {
    return "ChangeCredentialsRequest[kdf="
        + kdf
        + ", srpSalt=<redacted>, srpVerifier=<redacted>, vkWrap=<redacted>, expectedVkGen="
        + expectedVkGen
        + ", recoveryWrap=<redacted>, recoveryAuthHash=<redacted>]";
  }
}
