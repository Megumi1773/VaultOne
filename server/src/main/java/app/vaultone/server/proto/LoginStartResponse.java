package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record LoginStartResponse(
    @JsonProperty(required = true) String handshakeId,
    @JsonProperty(required = true) String accountId,
    @JsonProperty(required = true) KdfParams kdf,
    @JsonProperty(required = true) Bytes srpSalt,
    @JsonProperty(required = true) Bytes bPub) {
  public LoginStartResponse {
    Dto.requireAll(
        handshakeId,
        "handshake_id",
        accountId,
        "account_id",
        kdf,
        "kdf",
        srpSalt,
        "srp_salt",
        bPub,
        "b_pub");
  }

  @Override
  public String toString() {
    return "LoginStartResponse[handshakeId="
        + handshakeId
        + ", accountId="
        + accountId
        + ", kdf="
        + kdf
        + ", srpSalt=<redacted>, bPub=<redacted>]";
  }
}
