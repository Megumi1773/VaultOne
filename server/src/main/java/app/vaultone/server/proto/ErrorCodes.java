package app.vaultone.server.proto;

/** 稳定错误码（对齐 {@code vault_proto::codes}）。message 仅面向展示，客户端不应据其分支。 */
public final class ErrorCodes {
  public static final String BAD_REQUEST = "bad_request";
  public static final String UNAUTHORIZED = "unauthorized";
  public static final String AUTH_FAILED = "auth_failed";
  public static final String DEVICE_NOT_APPROVED = "device_not_approved";
  public static final String CONFLICT = "conflict";
  public static final String EMAIL_TAKEN = "email_taken";
  public static final String NOT_FOUND = "not_found";
  public static final String RATE_LIMITED = "rate_limited";
  public static final String INTERNAL = "internal";

  private ErrorCodes() {}
}
