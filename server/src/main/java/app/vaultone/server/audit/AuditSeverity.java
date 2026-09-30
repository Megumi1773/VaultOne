package app.vaultone.server.audit;

import java.util.Locale;

/** 操作敏感等级（固定低/中/高）；按事件目录维护。 */
public enum AuditSeverity {
  LOW,
  MEDIUM,
  HIGH;

  public String wire() {
    return name().toLowerCase(Locale.ROOT);
  }
}
