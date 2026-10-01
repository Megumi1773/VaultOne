package app.vaultone.server.feedback.model;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** 客服可读的主动反馈；不启用 Envers 或二级缓存。 */
@Entity
@Table(name = "feedback")
public class FeedbackEntity {
  @Id
  @GeneratedValue(strategy = GenerationType.IDENTITY)
  private Long seq;

  @Column(name = "user_id", nullable = false)
  private String userId;

  @Column(nullable = false)
  private String id;

  @Column(nullable = false)
  private String category;

  @Column(nullable = false)
  private String content;

  private String contact;

  @Column(nullable = false)
  private String status;

  private String reply;

  @Column(nullable = false)
  private long version;

  @Column(name = "created_at", nullable = false)
  private long createdAt;

  @Column(name = "updated_at", nullable = false)
  private long updatedAt;

  @Column(name = "expires_at", nullable = false)
  private long expiresAt;

  protected FeedbackEntity() {}

  public static FeedbackEntity create(
      String userId,
      String id,
      String category,
      String content,
      String contact,
      long now,
      long expiresAt) {
    var e = new FeedbackEntity();
    e.userId = userId;
    e.id = id;
    e.category = category;
    e.content = content;
    e.contact = contact;
    e.status = "open";
    e.version = 1;
    e.createdAt = now;
    e.updatedAt = now;
    e.expiresAt = expiresAt;
    return e;
  }

  public void handle(String status, String reply, long now) {
    this.status = status;
    this.reply = reply;
    this.updatedAt = now;
    this.version++;
  }

  public Long getSeq() {
    return seq;
  }

  public String getUserId() {
    return userId;
  }

  public String getId() {
    return id;
  }

  public String getCategory() {
    return category;
  }

  public String getContent() {
    return content;
  }

  public String getContact() {
    return contact;
  }

  public String getStatus() {
    return status;
  }

  public String getReply() {
    return reply;
  }

  public long getVersion() {
    return version;
  }

  public long getCreatedAt() {
    return createdAt;
  }

  public long getUpdatedAt() {
    return updatedAt;
  }

  public long getExpiresAt() {
    return expiresAt;
  }

  @Override
  public String toString() {
    return "FeedbackEntity[redacted]";
  }
}
