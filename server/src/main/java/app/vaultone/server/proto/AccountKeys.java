package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/** 账户密钥材料（全部为密文或公开参数），服务端只做保管与下发。 */
public record AccountKeys(
    @JsonProperty(required = true) String accountId,
    @JsonProperty(required = true) String vaultId,
    @JsonProperty(required = true) KdfParams kdf,
    @JsonProperty(required = true) Bytes vkWrap,
    @JsonProperty(required = true) long vkGen,
    @JsonProperty(required = true) Bytes recoveryWrap) {
  public AccountKeys {
    Dto.requireAll(
        accountId,
        "account_id",
        vaultId,
        "vault_id",
        kdf,
        "kdf",
        vkWrap,
        "vk_wrap",
        recoveryWrap,
        "recovery_wrap");
  }

  @Override
  public String toString() {
    return "AccountKeys[accountId="
        + accountId
        + ", vaultId="
        + vaultId
        + ", kdf="
        + kdf
        + ", vkWrap=<redacted>, vkGen="
        + vkGen
        + ", recoveryWrap=<redacted>]";
  }
}
