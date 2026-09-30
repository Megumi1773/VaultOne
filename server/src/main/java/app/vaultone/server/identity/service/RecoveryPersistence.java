package app.vaultone.server.identity.service;

import app.vaultone.server.audit.AuditEvents;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.common.ApiException;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.identity.repository.IdentityBootstrapRepository;
import app.vaultone.server.proto.AccountKeys;
import app.vaultone.server.proto.RecoveryCompleteRequest;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * 恢复流程：无账户上下文阶段只走窄 SECURITY DEFINER 函数读取/校验；CAS 轮换由 {@code vaultone_recovery_complete} 在数据库内锁账户 +
 * 重验旧凭据完成（仅一胜）。
 *
 * <p>旧凭据重验为常量时间；普通改密不经过本类，也不会推进 session_epoch。
 */
@Component
public class RecoveryPersistence {
  private final IdentityBootstrapRepository bootstrap;
  private final AccountContext accountContext;
  private final KeysMapper keysMapper;
  private final AuditService audit;

  public RecoveryPersistence(
      IdentityBootstrapRepository bootstrap,
      AccountContext accountContext,
      KeysMapper keysMapper,
      AuditService audit) {
    this.bootstrap = bootstrap;
    this.accountContext = accountContext;
    this.keysMapper = keysMapper;
    this.audit = audit;
  }

  /** 恢复凭据校验后的账户快照（供 fetch 返回 AccountKeys）。 */
  public record RecoverySnapshot(String userId, AccountKeys keys) {}

  /** CAS 前置快照。 */
  public record PreState(String userId, byte[] recoveryAuthHash, long sessionEpoch, long vkGen) {}

  /** CAS 结果。 */
  public record Result(boolean ok, String userId, long sessionEpoch, AccountKeys keys) {}

  /** 校验恢复凭据并返回账户密钥材料（不消费）。 */
  public RecoverySnapshot verify(
      String email, byte[] recoveryAuth, ServerKeys keys, byte[] ipHash) {
    UserEntity user = verifiedUser(email, recoveryAuth, keys, ipHash);
    return new RecoverySnapshot(user.getId(), keysMapper.toKeys(user));
  }

  /** 验证的哈希与 CAS 代次必须来自同一份账户快照，不能验证旧值后再读取已轮换的新哈希。 */
  public PreState preState(String email, byte[] recoveryAuth, ServerKeys keys, byte[] ipHash) {
    UserEntity user = verifiedUser(email, recoveryAuth, keys, ipHash);
    return new PreState(
        user.getId(), user.getRecoveryAuthHash(), user.getSessionEpoch(), user.getVkGen());
  }

  private UserEntity verifiedUser(
      String email, byte[] recoveryAuth, ServerKeys keys, byte[] ipHash) {
    app.vaultone.server.validate.WireValidation.email(email);
    var lookup =
        bootstrap.recoveryLookup(keys.emailHash(email)).orElseThrow(ApiException::authFailed);
    UserEntity user = accountContext.readAccount(lookup.id()).orElseThrow(ApiException::authFailed);
    if (!ServerKeys.constantTimeEquals(
        ServerKeys.sha256(recoveryAuth), user.getRecoveryAuthHash())) {
      audit.recordFailure(
          user.getId(), null, AuditEvents.RECOVERY_FAIL, AuditService.FAILURE, null, ipHash);
      throw ApiException.authFailed();
    }
    return user;
  }

  /** 事务内 CAS 轮换；成功后重读新快照返回新的 session_epoch 与 AccountKeys。 */
  @Transactional
  public Result complete(
      RecoveryCompleteRequest req,
      PreState pre,
      String newKdfJson,
      String requestId,
      byte[] ipHash) {
    boolean ok =
        bootstrap.recoveryComplete(
            pre.userId(),
            pre.recoveryAuthHash(),
            pre.sessionEpoch(),
            pre.vkGen(),
            newKdfJson,
            req.srpSalt().toByteArray(),
            req.srpVerifier().toByteArray(),
            req.vkWrap().toByteArray(),
            req.recoveryWrap().toByteArray(),
            req.recoveryAuthHash().toByteArray(),
            req.device().id(),
            ServerKeys.rustTrim(req.device().name()),
            req.device().platform().wire(),
            app.vaultone.server.common.InstantText.format(java.time.Instant.now()));
    if (!ok) {
      return new Result(false, pre.userId(), pre.sessionEpoch(), null);
    }
    var user = accountContext.readAccount(pre.userId()).orElseThrow(ApiException::authFailed);
    audit.record(
        user.getId(),
        req.device().id(),
        AuditEvents.RECOVERY_USED,
        AuditService.SUCCESS,
        requestId,
        ipHash);
    return new Result(true, user.getId(), user.getSessionEpoch(), keysMapper.toKeys(user));
  }
}
