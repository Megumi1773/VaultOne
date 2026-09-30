package app.vaultone.server.security;

/** 已认证的请求主体（会话有效、设备未撤销）。 */
public record Authed(
    String userId,
    String deviceId,
    boolean approved,
    long sessionEpoch,
    long deviceEpoch,
    String tokenHashHex) {

  public boolean isApproved() {
    return approved;
  }

  public AccountGuard.PrincipalRef ref() {
    return new AccountGuard.PrincipalRef(userId, deviceId, sessionEpoch, deviceEpoch, tokenHashHex);
  }
}
