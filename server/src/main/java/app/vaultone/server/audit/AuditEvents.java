package app.vaultone.server.audit;

import java.util.Map;

/** 审计事件目录：事件名沿用既有用户审计事件（客户端/旧服务端可见），并固定敏感等级。 新增事件必须先在此登记，避免散落魔法字符串。 */
public final class AuditEvents {
  public static final String REGISTER = "register";
  public static final String LOGIN_OK = "login_ok";
  public static final String LOGIN_FAIL = "login_fail";
  public static final String DEVICE_ADDED = "device_added";
  public static final String DEVICE_APPROVED = "device_approved";
  public static final String DEVICE_REVOKED = "device_revoked";
  public static final String PWD_CHANGED = "pwd_changed";
  public static final String RECOVERY_USED = "recovery_used";
  public static final String RECOVERY_FAIL = "recovery_fail";
  public static final String LOGOUT = "logout";
  public static final String ACCOUNT_DELETED = "account_deleted";
  public static final String FEEDBACK_CREATED = "feedback_created";
  public static final String FEEDBACK_HANDLED = "feedback_handled";

  /** 账户资料变更（昵称 / 头像）。低敏感：不涉及密钥、设备或凭据。 */
  public static final String PROFILE_UPDATED = "profile_updated";

  /** 补填邀请人邀请码（§9）。中敏感：建立了一条撤销不了的账户间关联。 */
  public static final String INVITE_BOUND = "invite_bound";

  private static final Map<String, AuditSeverity> SEVERITIES =
      Map.ofEntries(
          Map.entry(REGISTER, AuditSeverity.MEDIUM),
          Map.entry(LOGIN_OK, AuditSeverity.LOW),
          Map.entry(LOGIN_FAIL, AuditSeverity.MEDIUM),
          Map.entry(DEVICE_ADDED, AuditSeverity.MEDIUM),
          Map.entry(DEVICE_APPROVED, AuditSeverity.HIGH),
          Map.entry(DEVICE_REVOKED, AuditSeverity.HIGH),
          Map.entry(PWD_CHANGED, AuditSeverity.HIGH),
          Map.entry(RECOVERY_USED, AuditSeverity.HIGH),
          Map.entry(RECOVERY_FAIL, AuditSeverity.HIGH),
          Map.entry(LOGOUT, AuditSeverity.LOW),
          Map.entry(ACCOUNT_DELETED, AuditSeverity.HIGH),
          Map.entry(FEEDBACK_CREATED, AuditSeverity.LOW),
          Map.entry(FEEDBACK_HANDLED, AuditSeverity.MEDIUM),
          Map.entry(PROFILE_UPDATED, AuditSeverity.LOW),
          Map.entry(INVITE_BOUND, AuditSeverity.MEDIUM));

  private AuditEvents() {}

  public static AuditSeverity severityOf(String event) {
    return SEVERITIES.getOrDefault(event, AuditSeverity.MEDIUM);
  }
}
