package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/** {@code keys} 为 Option：仅当设备已批准时下发，允许缺失或显式 null。 */
public record LoginFinishResponse(
    @JsonProperty(required = true) Bytes m2,
    @JsonProperty(required = true) SessionInfo session,
    AccountKeys keys) {
  public LoginFinishResponse {
    Dto.requireAll(m2, "m2", session, "session");
  }

  @Override
  public String toString() {
    return "LoginFinishResponse[m2=<redacted>, session="
        + session
        + ", keys="
        + (keys == null ? "null" : "<redacted>")
        + "]";
  }
}
