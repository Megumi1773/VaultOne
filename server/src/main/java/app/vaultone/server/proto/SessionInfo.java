package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/** 会话信息；token 为 Bearer token 文本，服务端只存 SHA-256。 */
public record SessionInfo(
    @JsonProperty(required = true) String token,
    @JsonProperty(required = true) long expiresAt,
    @JsonProperty(required = true) String deviceId,
    @JsonProperty(required = true) boolean deviceApproved) {
  public SessionInfo {
    Dto.requireAll(token, "token", deviceId, "device_id");
  }

  @Override
  public String toString() {
    return "SessionInfo[token=<redacted>, expiresAt="
        + expiresAt
        + ", deviceId="
        + deviceId
        + ", deviceApproved="
        + deviceApproved
        + "]";
  }
}
