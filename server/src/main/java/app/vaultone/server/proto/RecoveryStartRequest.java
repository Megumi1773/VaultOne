package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record RecoveryStartRequest(@JsonProperty(required = true) String email) {
  public RecoveryStartRequest {
    Dto.require(email, "email");
  }
}
