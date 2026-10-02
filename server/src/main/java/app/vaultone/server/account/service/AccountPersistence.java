package app.vaultone.server.account.service;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.identity.model.DeviceEntity;
import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.identity.repository.DeviceRepository;
import app.vaultone.server.identity.service.KeysMapper;
import app.vaultone.server.proto.AccountKeys;
import app.vaultone.server.security.AccountGuard;
import app.vaultone.server.security.Approved;
import app.vaultone.server.validate.WireValidation;
import java.time.Instant;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * 账户读改写的事务边界。每个方法在**同一事务**内：绑定 RLS 上下文 → 经 {@link AccountGuard#lock} 锁账户并 重验
 * principal（session_epoch/设备批准与撤销/devices.epoch/logout 标记）→ 读改写。
 *
 * <p>改密对该锁定的账户行读取 vk_gen 后条件更新；同 newGen 竞争在行锁下只能一胜；普通改密不推进 session_epoch、不撤其他设备合法会话。
 */
@Component
public class AccountPersistence {
  private final AccountGuard guard;
  private final KeysMapper keysMapper;
  private final DeviceRepository devices;

  public AccountPersistence(AccountGuard guard, KeysMapper keysMapper, DeviceRepository devices) {
    this.guard = guard;
    this.keysMapper = keysMapper;
    this.devices = devices;
  }

  /** 账户实体 + 其线协议密钥材料（同一授权事务内取得，不跨事务重读机密）。 */
  public record AccountView(UserEntity user, AccountKeys keys, DeviceEpoch deviceEpoch) {}

  /** 设备代次包装。 */
  public record DeviceEpoch(long value) {}

  @Transactional(readOnly = true)
  public AccountView view(Approved approved) {
    AccountGuard.Principal principal = guard.lock(approved.ref());
    UserEntity user = principal.user();
    return new AccountView(
        user, keysMapper.toKeys(user), new DeviceEpoch(principal.device().getEpoch()));
  }

  @Transactional
  public long changeCredentials(
      Approved approved,
      app.vaultone.server.proto.ChangeCredentialsRequest req,
      boolean allowTestKdf) {
    AccountGuard.Principal principal = guard.lock(approved.ref());
    UserEntity user = principal.user();
    WireValidation.kdfLenient(req.kdf(), allowTestKdf);
    WireValidation.srp(req.srpSalt().toByteArray(), req.srpVerifier().toByteArray());
    WireValidation.wrappedKey(req.vkWrap().toByteArray(), "vk_wrap");
    if (req.recoveryWrap() != null) {
      WireValidation.wrappedKey(req.recoveryWrap().toByteArray(), "recovery_wrap");
    }
    if (req.recoveryAuthHash() != null) {
      WireValidation.hash32(req.recoveryAuthHash().toByteArray(), "recovery_auth_hash");
    }
    // 账户行已 PESSIMISTIC_WRITE 锁定：并发同 newGen 只有一个能进入此判断。
    if (user.getVkGen() >= req.expectedVkGen()) {
      throw ApiException.conflict("主密码已在其他设备上更改，请先同步");
    }
    long newGen = req.expectedVkGen();
    user.rotateCredentials(
        keysMapper.toKdfJson(req.kdf()),
        req.srpSalt().toByteArray(),
        req.srpVerifier().toByteArray(),
        req.vkWrap().toByteArray(),
        newGen,
        req.recoveryWrap() == null ? null : req.recoveryWrap().toByteArray(),
        req.recoveryAuthHash() == null ? null : req.recoveryAuthHash().toByteArray(),
        Instant.now());
    return newGen;
  }

  /**
   * 更新账户资料（计划书 §8.2）。锁账户 → 校验 → 落库，返回更新后的实体。
   *
   * <p>**不推进 session_epoch、不撤设备**：改昵称不该把其他设备踢下线。资料字段也不进审计修订表 （users_aud 是白名单）。
   */
  @Transactional
  public AccountView updateProfile(Approved approved, String nickname, String avatar) {
    AccountGuard.Principal principal = guard.lock(approved.ref());
    UserEntity user = principal.user();
    WireValidation.profile(nickname, avatar);
    user.updateProfile(nickname.trim(), avatar.trim(), Instant.now());
    // 与 view() 同一形状：调用方要回完整的账户响应，不该再去读一次密钥材料。
    return new AccountView(
        user, keysMapper.toKeys(user), new DeviceEpoch(principal.device().getEpoch()));
  }

  /** 注销读取（锁账户）；调用方在同一事务内删除。 */
  @Transactional
  public UserEntity lockUser(Approved approved) {
    return guard.lock(approved.ref()).user();
  }

  /** 供设备撤销通知等读取邮箱；锁定账户并返回实体。 */
  @Transactional
  public UserEntity lockForRead(Approved approved) {
    return guard.lock(approved.ref()).user();
  }

  /** 注销前读取账户设备 ID 列表（已授权事务内按账户范围）。 */
  @Transactional(readOnly = true)
  public java.util.List<String> deviceIds(String accountId) {
    return devices.listByUser(accountId).stream().map(DeviceEntity::getId).toList();
  }
}
