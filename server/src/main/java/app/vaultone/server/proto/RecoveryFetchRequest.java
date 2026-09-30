package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record RecoveryFetchRequest(
    @JsonProperty(required = true) String email,
    @JsonProperty(required = true) Bytes recoveryAuth) {
  public RecoveryFetchRequest {
    Dto.requireAll(email, "email", recoveryAuth, "recovery_auth");
  }

  @Override
  public String toString() {
    return "RecoveryFetchRequest[email=<redacted>, recoveryAuth=<redacted>]";
  }
}
