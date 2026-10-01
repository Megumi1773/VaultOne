package app.vaultone.server.audit.model;

import app.vaultone.server.audit.AuditSeverity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.Instant;
import org.hibernate.envers.NotAudited;

/** 操作审计事件：最小 actor/账户范围、操作类型、成功/失败、敏感等级、UTC 时间与请求 ID； <b>不记录对象内容</b>。与 Envers 修订历史、运行日志职责分离。 */
@Entity
@Table(name = "audit_events")
public class AuditEventEntity {
  @Id
  @GeneratedValue(strategy = GenerationType.IDENTITY)
  @NotAudited
  @Column(name = "id")
  private Long id;

  @NotAudited
  @Column(name = "user_id", nullable = false)
  private String userId;

  @NotAudited
  @Column(name = "device_id")
  private String deviceId;

  @NotAudited
  @Column(name = "event", nullable = false)
  private String event;

  @NotAudited
  @Column(name = "severity", nullable = false)
  private String severity;

  @NotAudited
  @Column(name = "outcome", nullable = false)
  private String outcome;

  @NotAudited
  @Column(name = "request_id")
  private String requestId;

  @NotAudited
  @Column(name = "ip_hash")
  private byte[] ipHash;

  @NotAudited
  @Column(name = "created_at", nullable = false)
  private String createdAt;

  @NotAudited
  @Column(name = "operator_id")
  private String operatorId;

  @NotAudited
  @Column(name = "target_id")
  private String targetId;

  protected AuditEventEntity() {}

  public void feedbackTarget(String operatorId, String targetId) {
    this.operatorId = operatorId;
    this.targetId = targetId;
  }

  public static AuditEventEntity of(
      String userId,
      String deviceId,
      String event,
      AuditSeverity severity,
      String outcome,
      String requestId,
      byte[] ipHash,
      Instant now) {
    AuditEventEntity e = new AuditEventEntity();
    e.userId = userId;
    e.deviceId = deviceId;
    e.event = event;
    e.severity = severity.wire();
    e.outcome = outcome;
    e.requestId = requestId;
    e.ipHash = ipHash;
    e.createdAt = app.vaultone.server.common.InstantText.format(now);
    return e;
  }

  public Long getId() {
    return id;
  }

  public String getUserId() {
    return userId;
  }

  public String getDeviceId() {
    return deviceId;
  }

  public String getEvent() {
    return event;
  }

  public String getSeverity() {
    return severity;
  }

  public String getOutcome() {
    return outcome;
  }

  public String getRequestId() {
    return requestId;
  }

  public byte[] getIpHash() {
    return ipHash;
  }

  public Instant getCreatedAt() {
    return app.vaultone.server.common.InstantText.parse(createdAt);
  }

  @Override
  public String toString() {
    return "AuditEventEntity[userId=" + userId + ", event=" + event + ", outcome=" + outcome + "]";
  }
}
