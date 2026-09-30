package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record RecoveryStartResponse(@JsonProperty(required = true) String accountId) {
  public RecoveryStartResponse {
    Dto.require(accountId, "account_id");
  }
}
