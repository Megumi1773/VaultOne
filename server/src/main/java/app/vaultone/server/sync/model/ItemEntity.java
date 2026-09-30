package app.vaultone.server.sync.model;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.IdClass;
import jakarta.persistence.Table;
import java.io.Serializable;
import java.util.Objects;
import org.hibernate.envers.NotAudited;

/**
 * E2EE 条目主表，复合主键 {@code (user_id, id)}。零知识：{@code blob}/{@code blob_hash} 是客户端密封盒材料，服务端不解密。
 *
 * <p>同步写路径走 {@link app.vaultone.server.sync.repository.SyncRepository} 的原生 SQL（版本乐观锁 + change_log
 * 游标），本实体只承担结构映射。本实体不加 {@code @Audited}（Envers 默认不审计），且每个字段显式 {@link NotAudited}， 密文与哈希绝不进入修订历史。
 */
@Entity
@Table(name = "items")
@IdClass(ItemEntity.Key.class)
public class ItemEntity {
  @Id
  @NotAudited
  @Column(name = "user_id", nullable = false)
  private String userId;

  @Id
  @NotAudited
  @Column(name = "id", nullable = false)
  private String id;

  @NotAudited
  @Column(name = "kind", nullable = false)
  private String kind;

  @NotAudited
  @Column(name = "blob", nullable = false)
  private byte[] blob;

  @NotAudited
  @Column(name = "blob_hash", nullable = false)
  private byte[] blobHash;

  @NotAudited
  @Column(name = "revision", nullable = false)
  private long revision;

  @NotAudited
  @Column(name = "deleted", nullable = false)
  private long deleted;

  @NotAudited
  @Column(name = "updated_at", nullable = false)
  private String updatedAt;

  @NotAudited
  @Column(name = "device_id", nullable = false)
  private String deviceId;

  @NotAudited
  @Column(name = "created_at", nullable = false)
  private String createdAt;

  protected ItemEntity() {}

  public String getUserId() {
    return userId;
  }

  public String getId() {
    return id;
  }

  public String getKind() {
    return kind;
  }

  public byte[] getBlob() {
    return blob;
  }

  public byte[] getBlobHash() {
    return blobHash;
  }

  public long getRevision() {
    return revision;
  }

  public long getDeleted() {
    return deleted;
  }

  public String getUpdatedAt() {
    return updatedAt;
  }

  public String getDeviceId() {
    return deviceId;
  }

  public String getCreatedAt() {
    return createdAt;
  }

  /** 敏感实体：禁止自动 toString 泄露密文/哈希。 */
  @Override
  public String toString() {
    return "ItemEntity[userId="
        + userId
        + ", id="
        + id
        + ", kind="
        + kind
        + ", revision="
        + revision
        + ", deleted="
        + deleted
        + "]";
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
