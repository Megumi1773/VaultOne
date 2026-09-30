package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/** 注册请求。非 Option 字段缺失/为 null 均拒绝；未知字段忽略（与 Rust 普通 DTO 一致）。 */
public record RegisterRequest(
    @JsonProperty(required = true) String email,
    @JsonProperty(required = true) AccountKeys keys,
    @JsonProperty(required = true) Bytes srpSalt,
    @JsonProperty(required = true) Bytes srpVerifier,
    @JsonProperty(required = true) Bytes recoveryAuthHash,
    @JsonProperty(required = true) DeviceInfo device) {
  public RegisterRequest {
    Dto.requireAll(
        email,
        "email",
        keys,
        "keys",
        srpSalt,
        "srp_salt",
        srpVerifier,
        "srp_verifier",
        recoveryAuthHash,
        "recovery_auth_hash",
        device,
        "device");
  }

  @Override
  public String toString() {
    return "RegisterRequest[email=<redacted>, keys=<redacted>, srpSalt=<redacted>, srpVerifier=<redacted>, recoveryAuthHash=<redacted>, device="
        + device
        + "]";
  }
}
