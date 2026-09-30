package app.vaultone.server.common;

/** 稳定错误码目录（对齐 {@code vault_proto::codes} 并补充分类明确的服务端码）。 */
public final class ErrorCatalog {
  public static final String BAD_REQUEST = "bad_request";
  public static final String UNAUTHORIZED = "unauthorized";
  public static final String AUTH_FAILED = "auth_failed";
  public static final String DEVICE_NOT_APPROVED = "device_not_approved";
  public static final String CONFLICT = "conflict";
  public static final String EMAIL_TAKEN = "email_taken";
  public static final String NOT_FOUND = "not_found";
  public static final String METHOD_NOT_ALLOWED = "method_not_allowed";
  public static final String RATE_LIMITED = "rate_limited";
  public static final String PAYLOAD_TOO_LARGE = "payload_too_large";
  public static final String UNSUPPORTED_MEDIA_TYPE = "unsupported_media_type";
  public static final String UNPROCESSABLE = "unprocessable_entity";
  public static final String SERVICE_UNAVAILABLE = "service_unavailable";
  public static final String INTERNAL = "internal";

  private ErrorCatalog() {}

  /** HTTP 状态 → 统一错误体（{@code code,message}），供 Security/容器等 Web 层之外的边界复用。 不返回异常消息/堆栈/内部细节。 */
  public static app.vaultone.server.proto.ErrorBody body(int status) {
    return switch (status) {
      case 400 -> new app.vaultone.server.proto.ErrorBody(BAD_REQUEST, "请求格式不正确");
      case 401 -> new app.vaultone.server.proto.ErrorBody(UNAUTHORIZED, "会话无效或已过期，请重新登录");
      case 403 -> new app.vaultone.server.proto.ErrorBody(DEVICE_NOT_APPROVED, "请求未获授权");
      case 404 -> new app.vaultone.server.proto.ErrorBody(NOT_FOUND, "接口不存在");
      case 405 -> new app.vaultone.server.proto.ErrorBody(METHOD_NOT_ALLOWED, "请求方法不被支持");
      case 409 -> new app.vaultone.server.proto.ErrorBody(CONFLICT, "请求冲突");
      case 413 -> new app.vaultone.server.proto.ErrorBody(PAYLOAD_TOO_LARGE, "请求体过大");
      case 415 -> new app.vaultone.server.proto.ErrorBody(UNSUPPORTED_MEDIA_TYPE, "不支持的媒体类型");
      case 422 -> new app.vaultone.server.proto.ErrorBody(UNPROCESSABLE, "请求体格式不正确");
      case 429 -> new app.vaultone.server.proto.ErrorBody(RATE_LIMITED, "请求过于频繁，请稍后再试");
      case 503 -> new app.vaultone.server.proto.ErrorBody(SERVICE_UNAVAILABLE, "服务暂时不可用，请稍后再试");
      default -> new app.vaultone.server.proto.ErrorBody(INTERNAL, "服务暂时不可用");
    };
  }
}
