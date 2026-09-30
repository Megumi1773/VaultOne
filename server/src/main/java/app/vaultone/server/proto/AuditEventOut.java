package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/** {@code device_id} 为 Option，允许缺失或显式 null。 */
public record AuditEventOut(
    @JsonProperty(required = true) String event,
    String deviceId,
    @JsonProperty(required = true) long createdAt) {
  public AuditEventOut {
    Dto.require(event, "event");
  }
}
