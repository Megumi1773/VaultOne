package app.vaultone.server.identity.model;

import app.vaultone.server.common.InstantText;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.Transient;
import java.time.Instant;
import org.hibernate.envers.Audited;
import org.hibernate.envers.NotAudited;
import org.springframework.data.domain.Persistable;

/**
 * 账户主表。零知识：只保存公开参数与客户端密封盒密文。
 *
 * <p>时间为 ISO-8601 UTC 文本，经 {@link InstantText} 与 {@link Instant} 互转（对齐 Rust 既有库）。
 *
 * <p>Envers 只审计低频、非敏感的账户状态字段（vk_gen / session_epoch / updated_at）； 邮箱密文、SRP 材料、密钥封装、恢复材料一律 {@link
 * NotAudited}，绝不进入修订表。
 *
 * <p>实现 {@link Persistable}：`id` 为客户端指定的已赋值主键，Spring Data 无法据此判断新旧；靠 {@link #isNew} 标志确保新账户走
 * INSERT（persist），绝不因 merge 覆盖既有账户。
 */
@Entity
@Table(name = "users")
@Audited
public class UserEntity implements Persistable<String> {
  @Id
  @Column(name = "id", nullable = false)
  private String id;

  @Transient private boolean isNew = true;

  @Column(name = "email_hash", nullable = false, unique = true)
  @NotAudited
  private byte[] emailHash;

  @Column(name = "email_enc", nullable = false)
  @NotAudited
  private byte[] emailEnc;

  @Column(name = "kdf", nullable = false)
  @NotAudited
  private String kdf;

  @Column(name = "srp_salt", nullable = false)
  @NotAudited
  private byte[] srpSalt;

  @Column(name = "srp_verifier", nullable = false)
  @NotAudited
  private byte[] srpVerifier;

  @Column(name = "vault_id", nullable = false)
  @NotAudited
  private String vaultId;

  @Column(name = "vk_wrap", nullable = false)
  @NotAudited
  private byte[] vkWrap;

  @Column(name = "vk_gen", nullable = false)
  private long vkGen;

  @Column(name = "recovery_wrap", nullable = false)
  @NotAudited
  private byte[] recoveryWrap;

  @Column(name = "recovery_auth_hash", nullable = false)
  @NotAudited
  private byte[] recoveryAuthHash;

  @Column(name = "session_epoch", nullable = false)
  private long sessionEpoch;

  /** 昵称（计划书 §8.2）。空串表示未设置；只用于界面显示，不参与认证。 */
  @Column(name = "nickname", nullable = false)
  @NotAudited
  private String nickname = "";

  /**
   * 头像地址（计划书 §8.1 / §8.2）。存**地址**而不是图片本身：本部署没有对象存储， 且本实体是 @Audited，内联 base64 会被复制进每一版修订记录。空串表示未设置。
   */
  @Column(name = "avatar", nullable = false)
  @NotAudited
  private String avatar = "";

  @Column(name = "created_at", nullable = false)
  @NotAudited
  private String createdAt;

  @Column(name = "updated_at", nullable = false)
  private String updatedAt;

  protected UserEntity() {}

  @jakarta.persistence.PostLoad
  @jakarta.persistence.PostPersist
  void markPersisted() {
    this.isNew = false;
  }

  @Override
  @Transient
  public boolean isNew() {
    return isNew;
  }

  @Override
  public String getId() {
    return id;
  }

  /** 新建账户（注册）。 */
  public static UserEntity create(
      String id,
      byte[] emailHash,
      byte[] emailEnc,
      String kdfJson,
      byte[] srpSalt,
      byte[] srpVerifier,
      String vaultId,
      byte[] vkWrap,
      long vkGen,
      byte[] recoveryWrap,
      byte[] recoveryAuthHash,
      Instant now) {
    UserEntity user = new UserEntity();
    user.id = id;
    user.emailHash = emailHash;
    user.emailEnc = emailEnc;
    user.kdf = kdfJson;
    user.srpSalt = srpSalt;
    user.srpVerifier = srpVerifier;
    user.vaultId = vaultId;
    user.vkWrap = vkWrap;
    user.vkGen = vkGen;
    user.recoveryWrap = recoveryWrap;
    user.recoveryAuthHash = recoveryAuthHash;
    user.sessionEpoch = 1;
    user.createdAt = InstantText.format(now);
    user.updatedAt = InstantText.format(now);
    return user;
  }

  /** 改密：仅替换凭据材料，vk_gen 由调用方按协议设为客户端新代次。 */
  public void rotateCredentials(
      String kdfJson,
      byte[] srpSalt,
      byte[] srpVerifier,
      byte[] vkWrap,
      long newVkGen,
      byte[] recoveryWrap,
      byte[] recoveryAuthHash,
      Instant now) {
    this.kdf = kdfJson;
    this.srpSalt = srpSalt;
    this.srpVerifier = srpVerifier;
    this.vkWrap = vkWrap;
    this.vkGen = newVkGen;
    if (recoveryWrap != null) {
      this.recoveryWrap = recoveryWrap;
    }
    if (recoveryAuthHash != null) {
      this.recoveryAuthHash = recoveryAuthHash;
    }
    this.updatedAt = InstantText.format(now);
  }

  /** 恢复：轮换全部材料、vk_gen+1、session_epoch+1（使旧会话立即失效）。 */
  public void applyRecovery(
      String kdfJson,
      byte[] srpSalt,
      byte[] srpVerifier,
      byte[] vkWrap,
      byte[] recoveryWrap,
      byte[] recoveryAuthHash,
      Instant now) {
    this.kdf = kdfJson;
    this.srpSalt = srpSalt;
    this.srpVerifier = srpVerifier;
    this.vkWrap = vkWrap;
    this.recoveryWrap = recoveryWrap;
    this.recoveryAuthHash = recoveryAuthHash;
    this.vkGen = this.vkGen + 1;
    this.sessionEpoch = this.sessionEpoch + 1;
    this.updatedAt = InstantText.format(now);
  }

  public byte[] getEmailHash() {
    return emailHash;
  }

  public byte[] getEmailEnc() {
    return emailEnc;
  }

  public String getKdf() {
    return kdf;
  }

  public byte[] getSrpSalt() {
    return srpSalt;
  }

  public byte[] getSrpVerifier() {
    return srpVerifier;
  }

  public String getVaultId() {
    return vaultId;
  }

  public byte[] getVkWrap() {
    return vkWrap;
  }

  public long getVkGen() {
    return vkGen;
  }

  public byte[] getRecoveryWrap() {
    return recoveryWrap;
  }

  public byte[] getRecoveryAuthHash() {
    return recoveryAuthHash;
  }

  public long getSessionEpoch() {
    return sessionEpoch;
  }

  public String getNickname() {
    return nickname;
  }

  public String getAvatar() {
    return avatar;
  }

  /**
   * 更新资料（昵称 / 头像地址）。只动这两个字段，不碰密钥材料、不推进 session_epoch —— 改昵称不该把其他设备踢下线。
   *
   * <p>值已在服务层校验（长度、字符、地址形态）；这里只做落库与 updated_at 推进。
   */
  public void updateProfile(String nickname, String avatar, Instant now) {
    this.nickname = nickname;
    this.avatar = avatar;
    this.updatedAt = InstantText.format(now);
  }

  public Instant getCreatedAt() {
    return InstantText.parse(createdAt);
  }

  public Instant getUpdatedAt() {
    return InstantText.parse(updatedAt);
  }

  /** 敏感实体：禁止自动 toString 泄露密文。 */
  @Override
  public String toString() {
    return "UserEntity[id=" + id + ", vkGen=" + vkGen + "]";
  }
}
