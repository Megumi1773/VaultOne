package app.vaultone.server.identity.model;

import app.vaultone.server.common.InstantText;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.IdClass;
import jakarta.persistence.Table;
import java.io.Serializable;
import java.time.Instant;
import java.util.Objects;
import org.hibernate.envers.Audited;
import org.hibernate.envers.NotAudited;

/** 设备表，复合主键 (user_id, id)。Envers 只审计批准/撤销等非敏感状态字段；approved_by 之外的材料不落修订。 */
@Entity
@Table(name = "devices")
@IdClass(DeviceEntity.Key.class)
@Audited
public class DeviceEntity {
  @Id
  @Column(name = "user_id", nullable = false)
  private String userId;

  @Id
  @Column(name = "id", nullable = false)
  private String id;

  @Column(name = "name", nullable = false)
  @NotAudited
  private String name;

  @Column(name = "platform", nullable = false)
  @NotAudited
  private String platform;

  @Column(name = "approved_at")
  private String approvedAt;

  @Column(name = "approved_by")
  private String approvedBy;

  @Column(name = "last_seen_at")
  @NotAudited
  private String lastSeenAt;

  @Column(name = "revoked_at")
  private String revokedAt;

  @Column(name = "epoch", nullable = false)
  @NotAudited
  private long epoch;

  @Column(name = "created_at", nullable = false)
  @NotAudited
  private String createdAt;

  protected DeviceEntity() {}

  public static DeviceEntity create(
      String userId,
      String id,
      String name,
      String platform,
      boolean approved,
      String approvedBy,
      Instant now) {
    DeviceEntity d = new DeviceEntity();
    d.userId = userId;
    d.id = id;
    d.name = name;
    d.platform = platform;
    d.approvedAt = approved ? InstantText.format(now) : null;
    d.approvedBy = approvedBy;
    d.lastSeenAt = InstantText.format(now);
    d.epoch = 1;
    d.createdAt = InstantText.format(now);
    return d;
  }

  public void rename(String newName, Instant now) {
    this.name = newName;
    this.lastSeenAt = InstantText.format(now);
  }

  public void approve(String by, Instant now) {
    this.approvedAt = InstantText.format(now);
    this.approvedBy = by;
  }

  public void markSeen(Instant now) {
    this.lastSeenAt = InstantText.format(now);
  }

  public void revoke(Instant now) {
    this.revokedAt = InstantText.format(now);
  }

  /** 设备代次 +1：撤销/重建后旧会话因 devices.epoch 不符而在 PG 授权处失效。 */
  public void bumpEpoch() {
    this.epoch = this.epoch + 1;
  }

  public String getUserId() {
    return userId;
  }

  public String getId() {
    return id;
  }

  public String getName() {
    return name;
  }

  public String getPlatform() {
    return platform;
  }

  public Instant getApprovedAt() {
    return InstantText.parse(approvedAt);
  }

  public String getApprovedBy() {
    return approvedBy;
  }

  public Instant getLastSeenAt() {
    return InstantText.parse(lastSeenAt);
  }

  public Instant getRevokedAt() {
    return InstantText.parse(revokedAt);
  }

  public long getEpoch() {
    return epoch;
  }

  public boolean isApproved() {
    return approvedAt != null;
  }

  public boolean isRevoked() {
    return revokedAt != null;
  }

  public Instant getCreatedAt() {
    return InstantText.parse(createdAt);
  }

  @Override
  public String toString() {
    return "DeviceEntity[userId=" + userId + ", id=" + id + ", approved=" + isApproved() + "]";
  }

  /** 复合主键。 */
  public static class Key implements Serializable {
    private String userId;
    private String id;

    public Key() {}

    public Key(String userId, String id) {
      this.userId = userId;
      this.id = id;
    }

    @Override
    public boolean equals(Object other) {
      return other instanceof Key key
          && Objects.equals(userId, key.userId)
          && Objects.equals(id, key.id);
    }

    @Override
    public int hashCode() {
      return Objects.hash(userId, id);
    }
  }
}
