package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record LoginFinishRequest(
    @JsonProperty(required = true) String handshakeId,
    @JsonProperty(required = true) Bytes aPub,
    @JsonProperty(required = true) Bytes m1,
    @JsonProperty(required = true) DeviceInfo device) {
  public LoginFinishRequest {
    Dto.requireAll(handshakeId, "handshake_id", aPub, "a_pub", m1, "m1", device, "device");
  }

  @Override
  public String toString() {
    return "LoginFinishRequest[handshakeId="
        + handshakeId
        + ", aPub=<redacted>, m1=<redacted>, device="
        + device
        + "]";
  }
}
