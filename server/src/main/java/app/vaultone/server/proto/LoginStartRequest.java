package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record LoginStartRequest(@JsonProperty(required = true) String email) {
  public LoginStartRequest {
    Dto.require(email, "email");
  }
}
