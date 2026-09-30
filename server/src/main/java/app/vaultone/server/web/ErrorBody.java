package app.vaultone.server.web;

import app.vaultone.server.common.ErrorCatalog;

/** 与现有客户端错误外形一致（{@code code,message}）；映射统一委托 {@link ErrorCatalog}，避免第二套目录。 */
public record ErrorBody(String code, String message) {
  public static ErrorBody forStatus(int status) {
    var body = ErrorCatalog.body(status);
    return new ErrorBody(body.code(), body.message());
  }
}
