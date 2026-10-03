package app.vaultone.server.notify.model;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.IdClass;
import jakarta.persistence.Table;
import java.io.Serializable;
import java.util.Objects;

/**
 * 一条已读记录（计划书 §6.1「已读标记」）。
 *
 * <p>复合主键 `(account_id, notification_id)`：重复标记天然幂等，不需要「先查再写」—— 也就没有查与写之间的竞态。
 * 反过来，如果用自增主键，同一个账户并发标两次就会插出两行。
 */
@Entity
@Table(name = "notification_reads")
@IdClass(NotificationReadEntity.Key.class)
public class NotificationReadEntity {
  @Id
  @Column(name = "account_id", nullable = false)
  private String accountId;

  @Id
  @Column(name = "notification_id", nullable = false)
  private String notificationId;

  @Column(name = "read_at", nullable = false)
  private long readAt;

  protected NotificationReadEntity() {}

  public static NotificationReadEntity of(String accountId, String notificationId, long readAt) {
    NotificationReadEntity r = new NotificationReadEntity();
    r.accountId = accountId;
    r.notificationId = notificationId;
    r.readAt = readAt;
    return r;
  }

  public String getAccountId() {
    return accountId;
  }

  public String getNotificationId() {
    return notificationId;
  }

  public long getReadAt() {
    return readAt;
  }

  /** 复合主键。JPA 要求它是 public static 且可序列化。 */
  public static class Key implements Serializable {
    private String accountId;
    private String notificationId;

    public Key() {}

    public Key(String accountId, String notificationId) {
      this.accountId = accountId;
      this.notificationId = notificationId;
    }

    @Override
    public boolean equals(Object o) {
      return o instanceof Key k
          && Objects.equals(accountId, k.accountId)
          && Objects.equals(notificationId, k.notificationId);
    }

    @Override
    public int hashCode() {
      return Objects.hash(accountId, notificationId);
    }
  }
}
