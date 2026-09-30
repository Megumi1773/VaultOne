package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record AccountResponse(
    @JsonProperty(required = true) String email, @JsonProperty(required = true) AccountKeys keys) {
  public AccountResponse {
    Dto.requireAll(email, "email", keys, "keys");
  }

  @Override
  public String toString() {
    return "AccountResponse[email=<redacted>, keys=" + (keys == null ? "null" : "<redacted>") + "]";
  }
}
