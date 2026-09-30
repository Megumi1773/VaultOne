package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record VerifyDeviceRequest(@JsonProperty(required = true) String code) {
  public VerifyDeviceRequest {
    Dto.require(code, "code");
  }
}
