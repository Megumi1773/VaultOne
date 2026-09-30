package app.vaultone.server.common;

/** 业务错误：携带 HTTP 状态与稳定错误码（不依赖 message 文本分支）。message 面向展示、安全且可执行。 */
public class ApiException extends RuntimeException {
  private final int status;
  private final String code;

  public ApiException(int status, String code, String message) {
    super(message);
    this.status = status;
    this.code = code;
  }

  public int status() {
    return status;
  }

  public String code() {
    return code;
  }

  public static ApiException badRequest(String message) {
    return new ApiException(400, ErrorCatalog.BAD_REQUEST, message);
  }

  public static ApiException unauthorized() {
    return new ApiException(401, ErrorCatalog.UNAUTHORIZED, "会话无效或已过期，请重新登录");
  }

  public static ApiException authFailed() {
    return new ApiException(401, ErrorCatalog.AUTH_FAILED, "认证失败");
  }

  public static ApiException deviceNotApproved() {
    return new ApiException(403, ErrorCatalog.DEVICE_NOT_APPROVED, "设备尚未批准");
  }

  public static ApiException notFound() {
    return new ApiException(404, ErrorCatalog.NOT_FOUND, "资源不存在");
  }

  public static ApiException conflict(String message) {
    return new ApiException(409, ErrorCatalog.CONFLICT, message);
  }

  public static ApiException emailTaken() {
    return new ApiException(409, ErrorCatalog.EMAIL_TAKEN, "该邮箱已注册");
  }

  public static ApiException rateLimited() {
    return new ApiException(429, ErrorCatalog.RATE_LIMITED, "请求过于频繁，请稍后再试");
  }

  public static ApiException dependencyUnavailable() {
    return new ApiException(503, ErrorCatalog.SERVICE_UNAVAILABLE, "服务暂时不可用，请稍后再试");
  }

  public static ApiException internal() {
    return new ApiException(500, ErrorCatalog.INTERNAL, "服务暂时不可用");
  }
}
