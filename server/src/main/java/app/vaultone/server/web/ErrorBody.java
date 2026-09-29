package app.vaultone.server.web;

/** 与现有客户端错误外形一致；S1未实现任何/v1业务。 */
public record ErrorBody(String code, String message) {
  public static ErrorBody forStatus(int status) {
    return switch (status) {
      case 400, 413, 415, 422 -> new ErrorBody("bad_request", "请求格式不正确");
      case 401 -> new ErrorBody("unauthorized", "会话无效或已过期，请重新登录");
      case 403 -> new ErrorBody("unauthorized", "请求未获授权");
      case 404, 405 -> new ErrorBody("not_found", "接口不存在");
      case 429 -> new ErrorBody("rate_limited", "请求过于频繁，请稍后再试");
      default -> new ErrorBody("internal", "服务暂时不可用");
    };
  }
}
