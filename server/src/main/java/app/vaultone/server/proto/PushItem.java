package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record PushItem(
    @JsonProperty(required = true) String id,
    @JsonProperty(required = true) String kind,
    @JsonProperty(required = true) Bytes blob,
    @JsonProperty(required = true) long baseRevision,
    @JsonProperty(required = true) long revision,
    @JsonProperty(required = true) boolean deleted,
    @JsonProperty(required = true) long updatedAt) {
  public PushItem {
    Dto.requireAll(id, "id", kind, "kind", blob, "blob");
  }
}
