package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record RecoveryCompleteResponse(
    @JsonProperty(required = true) SessionInfo session,
    @JsonProperty(required = true) AccountKeys keys) {
  public RecoveryCompleteResponse {
    Dto.requireAll(session, "session", keys, "keys");
  }

  @Override
  public String toString() {
    return "RecoveryCompleteResponse[session=" + session + ", keys=<redacted>]";
  }
}
