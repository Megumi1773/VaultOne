package app.vaultone.server.web;

/** 设备验证响应：{@code {"approved":true}}。 */
public record ApprovedResponse(boolean approved) {
  public static ApprovedResponse yes() {
    return new ApprovedResponse(true);
  }
}
