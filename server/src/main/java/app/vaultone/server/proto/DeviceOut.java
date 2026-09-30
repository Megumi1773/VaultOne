package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/** {@code last_seen_at}/{@code revoked_at} 为 Option，允许缺失或显式 null；显式输出 null。 */
public record DeviceOut(
    @JsonProperty(required = true) String id,
    @JsonProperty(required = true) String name,
    @JsonProperty(required = true) Platform platform,
    @JsonProperty(required = true) boolean approved,
    @JsonProperty(required = true) boolean current,
    @JsonProperty(required = true) long createdAt,
    Long lastSeenAt,
    Long revokedAt) {
  public DeviceOut {
    Dto.requireAll(id, "id", name, "name", platform, "platform");
  }
}
