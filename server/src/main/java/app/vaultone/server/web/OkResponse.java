package app.vaultone.server.web;

/** 通用 OK 响应：{@code {"ok":true}}。 */
public record OkResponse(boolean ok) {
  public static OkResponse success() {
    return new OkResponse(true);
  }
}
