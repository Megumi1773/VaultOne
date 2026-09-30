package app.vaultone.server.security;

/** 已认证且设备已批准的主体；由 {@link Authed} 解析后二次校验。写用例需在自身事务内持它再授权。 */
public record Approved(Authed authed) {
  public String userId() {
    return authed.userId();
  }

  public String deviceId() {
    return authed.deviceId();
  }

  public long sessionEpoch() {
    return authed.sessionEpoch();
  }

  public long deviceEpoch() {
    return authed.deviceEpoch();
  }

  public String tokenHashHex() {
    return authed.tokenHashHex();
  }

  public AccountGuard.PrincipalRef ref() {
    return authed.ref();
  }
}
