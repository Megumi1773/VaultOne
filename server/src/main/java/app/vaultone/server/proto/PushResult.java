package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record PushResult(
    @JsonProperty(required = true) String id,
    @JsonProperty(required = true) PushStatus status,
    @JsonProperty(required = true) long revision) {
  public PushResult {
    Dto.requireAll(id, "id", status, "status");
  }
}
