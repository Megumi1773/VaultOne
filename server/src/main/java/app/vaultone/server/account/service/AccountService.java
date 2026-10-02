package app.vaultone.server.account.service;

import app.vaultone.server.audit.AuditEvents;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.common.AfterCommit;
import app.vaultone.server.common.MailSender;
import app.vaultone.server.common.SafeDiagnostics;
import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.proto.AccountResponse;
import app.vaultone.server.proto.BindInviteRequest;
import app.vaultone.server.proto.ChangeCredentialsRequest;
import app.vaultone.server.proto.ChangeCredentialsResponse;
import app.vaultone.server.proto.UpdateProfileRequest;
import app.vaultone.server.security.Approved;
import app.vaultone.server.security.SessionStore;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 账户服务：读取账户密钥材料、变更主密码、注销账户。逐条对齐 {@code crates/vault-server/src/routes_account.rs}。
 *
 * <p>改密以账户行悲观锁 + vk_gen 条件更新防并发覆盖；<b>不</b>撤销会话、<b>不</b>推进 {@code session_epoch}
 * （普通改密不强制退出）。成功审计写入**同一事务**；邮件/Redis 清理在提交后受控执行，失败不影响已提交的安全变更。
 */
@Service
public class AccountService {
  private final AccountPersistence persistence;
  private final ServerKeys serverKeys;
  private final AuditService audit;
  private final MailSender mail;
  private final AccountPurger purger;
  private final SessionStore sessions;
  private final boolean allowTestKdf;

  public AccountService(
      AccountPersistence persistence,
      ServerKeys serverKeys,
      AuditService audit,
      MailSender mail,
      AccountPurger purger,
      SessionStore sessions,
      VaultOneProperties properties) {
    this.persistence = persistence;
    this.serverKeys = serverKeys;
    this.audit = audit;
    this.mail = mail;
    this.purger = purger;
    this.sessions = sessions;
    this.allowTestKdf = properties.development().allowTestKdf();
  }

  /** 读取账户信息与密钥材料（授权事务内取得，不跨事务重读机密）。 */
  @Transactional
  public AccountResponse getAccount(Approved approved) {
    var view = persistence.view(approved);
    return toResponse(view);
  }

  /** 更新账户资料（计划书 §8.2）：昵称与头像地址。成功审计同事务，敏感等级低。 */
  @Transactional
  public AccountResponse updateProfile(
      Approved approved, UpdateProfileRequest req, byte[] ipHash, String requestId) {
    var view = persistence.updateProfile(approved, req.nickname(), req.avatar());
    audit.record(
        approved.userId(),
        approved.deviceId(),
        AuditEvents.PROFILE_UPDATED,
        AuditService.SUCCESS,
        requestId,
        ipHash);
    return toResponse(view);
  }

  /**
   * 补填邀请人邀请码（计划书 §9）。一次性绑定，成功审计同事务。
   *
   * <p>审计记 MEDIUM：它建立了一条账户之间的关联，撤销不了，比改昵称重。
   */
  @Transactional
  public AccountResponse bindInvite(
      Approved approved, BindInviteRequest req, byte[] ipHash, String requestId) {
    var view = persistence.bindInviter(approved, req.code());
    audit.record(
        approved.userId(),
        approved.deviceId(),
        AuditEvents.INVITE_BOUND,
        AuditService.SUCCESS,
        requestId,
        ipHash);
    return toResponse(view);
  }

  private AccountResponse toResponse(AccountPersistence.AccountView view) {
    return new AccountResponse(
        serverKeys.decryptEmail(view.user().getEmailEnc()),
        view.keys(),
        view.user().getNickname(),
        view.user().getAvatar(),
        view.user().getCreatedAt().getEpochSecond(),
        view.user().getInviteCode());
  }

  /** 变更主密码：账户行悲观锁 + vk_gen 条件更新；成功审计同事务。 */
  @Transactional
  public ChangeCredentialsResponse changeCredentials(
      Approved approved, ChangeCredentialsRequest req, byte[] ipHash, String requestId) {
    long newGen = persistence.changeCredentials(approved, req, allowTestKdf);
    audit.record(
        approved.userId(),
        approved.deviceId(),
        AuditEvents.PWD_CHANGED,
        AuditService.SUCCESS,
        requestId,
        ipHash);
    String email = safeDecrypt(persistence.lockUser(approved));
    if (email != null) {
      AfterCommit.runSafely(
          () -> mail.send(email, "VaultOne 主密码已变更", "您的主密码刚刚被修改。如非本人操作，请立即使用 Recovery Kit 恢复账户。"));
    }
    return new ChangeCredentialsResponse(newGen);
  }

  /** 注销账户（删除权）：PG 删除在同一事务；成功审计同事务；Redis 清理与邮件在提交后受控执行。 */
  @Transactional
  public void deleteAccount(Approved approved, byte[] ipHash, String requestId) {
    UserEntity user = persistence.lockUser(approved);
    String email = safeDecrypt(user);
    List<String> deviceIds = persistence.deviceIds(approved.userId());
    purger.purge(approved, requestId, ipHash);
    AfterCommit.runSafely(
        () -> {
          for (String deviceId : deviceIds) {
            try {
              sessions.deleteByDevice(approved.userId(), deviceId);
            } catch (RuntimeException ex) {
              SafeDiagnostics.logUnhandled(ex);
            }
          }
          if (email != null) {
            mail.send(email, "VaultOne 账户已注销", "您的账户已注销，云端保险库内容已删除。");
          }
        });
  }

  private String safeDecrypt(UserEntity user) {
    try {
      return serverKeys.decryptEmail(user.getEmailEnc());
    } catch (RuntimeException ex) {
      SafeDiagnostics.logUnhandled(ex);
      return null;
    }
  }
}
