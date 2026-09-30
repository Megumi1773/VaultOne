package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record RecoveryCompleteRequest(
    @JsonProperty(required = true) String email,
    @JsonProperty(required = true) Bytes recoveryAuth,
    @JsonProperty(required = true) KdfParams kdf,
    @JsonProperty(required = true) Bytes srpSalt,
    @JsonProperty(required = true) Bytes srpVerifier,
    @JsonProperty(required = true) Bytes vkWrap,
    @JsonProperty(required = true) Bytes recoveryWrap,
    @JsonProperty(required = true) Bytes recoveryAuthHash,
    @JsonProperty(required = true) DeviceInfo device) {
  public RecoveryCompleteRequest {
    Dto.requireAll(
        email, "email",
        recoveryAuth, "recovery_auth",
        kdf, "kdf",
        srpSalt, "srp_salt",
        srpVerifier, "srp_verifier",
        vkWrap, "vk_wrap",
        recoveryWrap, "recovery_wrap",
        recoveryAuthHash, "recovery_auth_hash",
        device, "device");
  }

  @Override
  public String toString() {
    return "RecoveryCompleteRequest[email=<redacted>, recoveryAuth=<redacted>, kdf="
        + kdf
        + ", srpSalt=<redacted>, srpVerifier=<redacted>, vkWrap=<redacted>, recoveryWrap=<redacted>, recoveryAuthHash=<redacted>, device="
        + device
        + "]";
  }
}
