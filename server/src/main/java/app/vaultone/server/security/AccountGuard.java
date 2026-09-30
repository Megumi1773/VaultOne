package app.vaultone.server.security;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.common.InstantText;
import app.vaultone.server.identity.model.DeviceEntity;
import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.identity.repository.DeviceRepository;
import app.vaultone.server.identity.repository.SessionRevocation;
import app.vaultone.server.identity.repository.UserRepository;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.time.Instant;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * 唯一认证授权入口。所有敏感用例（读 DTO、改密、设备批准/撤销、logout、恢复后访问、同步 push/pull、注销） 必须在**同一事务**内调用本类：
 *
 * <ol>
 *   <li>绑定 RLS 账户上下文 {@code vaultone.account_id}；
 *   <li>锁账户行（{@code SELECT ... FOR UPDATE}），使同账户变更按同一锁顺序线性化；
 *   <li>重验 PG 当前权威状态：账户 session_epoch、设备存在/未撤销/已批准、devices.epoch、持久 logout 标记；
 *   <li>返回锁定的账户与设备实体供用例在同一事务内读改写。
 * </ol>
 *
 * <p>解析器只用 {@link #readOnly} 版本（不锁、只读事务）做门禁；**不能**替代用例事务内的授权—— 写用例必须持 principal（{@link
 * Authed}/{@link Approved}）在自身事务内再次调用授权。
 */
@Component
public class AccountGuard {
  @PersistenceContext private EntityManager em;
  private final UserRepository users;
  private final DeviceRepository devices;
  private final SessionRevocation revocations;

  public AccountGuard(
      UserRepository users, DeviceRepository devices, SessionRevocation revocations) {
    this.users = users;
    this.devices = devices;
    this.revocations = revocations;
  }

  /** 授权后的权威快照：锁定实体 + 当前代次。 */
  public record Principal(UserEntity user, DeviceEntity device, long sessionEpoch) {
    public String userId() {
      return user.getId();
    }

    public String deviceId() {
      return device.getId();
    }

    public boolean approved() {
      return device.isApproved();
    }
  }

  /**
   * 写用例授权：绑定上下文 + 锁账户 + 重验 principal。必须由调用方的写事务进入（{@code @Transactional}）。
   *
   * @param authed 认证主体（含 tokenHash 与签发时的 sessionEpoch/deviceEpoch）
   */
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public Principal lock(PrincipalRef authed) {
    bind(authed.userId());
    UserEntity user = users.lockById(authed.userId()).orElseThrow(ApiException::unauthorized);
    return validate(user, authed);
  }

  /** 解析器授权：只读事务、不加写锁（门禁）。 */
  @Transactional(readOnly = true)
  public Principal readOnly(PrincipalRef authed) {
    bind(authed.userId());
    UserEntity user = users.findById(authed.userId()).orElseThrow(ApiException::unauthorized);
    return validate(user, authed);
  }

  private Principal validate(UserEntity user, PrincipalRef authed) {
    if (user.getSessionEpoch() != authed.sessionEpoch()) {
      throw ApiException.unauthorized();
    }
    DeviceEntity device =
        devices.find(user.getId(), authed.deviceId()).orElseThrow(ApiException::unauthorized);
    if (device.isRevoked()) {
      throw ApiException.unauthorized();
    }
    if (authed.deviceEpoch() != null && device.getEpoch() != authed.deviceEpoch()) {
      throw ApiException.unauthorized();
    }
    if (revocations.isRevoked(
        user.getId(), authed.tokenHashHex(), InstantText.format(Instant.now()))) {
      throw ApiException.unauthorized();
    }
    return new Principal(user, device, user.getSessionEpoch());
  }

  private void bind(String accountId) {
    em.createNativeQuery("SELECT set_config('vaultone.account_id', :acct, true)")
        .setParameter("acct", accountId)
        .getSingleResult();
    app.vaultone.server.audit.RevisionContext.bindAccountIfAbsent(accountId);
  }

  /** 授权输入：来自已解析的 {@link Authed}。 */
  public record PrincipalRef(
      String userId, String deviceId, long sessionEpoch, Long deviceEpoch, String tokenHashHex) {

    public static PrincipalRef of(Authed authed) {
      return new PrincipalRef(
          authed.userId(),
          authed.deviceId(),
          authed.sessionEpoch(),
          authed.deviceEpoch(),
          authed.tokenHashHex());
    }
  }
}
