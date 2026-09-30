package app.vaultone.server.identity.service;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.model.DeviceEntity;
import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.identity.repository.DeviceRepository;
import app.vaultone.server.identity.repository.UserRepository;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.time.Instant;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 登录 finish 的数据库事务边界：SRP 校验成功后再登记/更新设备，避免错误 proof 产生副作用。
 *
 * <p>两个独立短事务：
 *
 * <ol>
 *   <li>{@link #readAccount}：账户上下文内读取账户（提供 verifier 供 SRP 校验）。
 *   <li>{@link #applyDevice}：SRP 成功后，在账户上下文内登记（未批准）或更新设备；绝不复活已撤销设备。
 * </ol>
 */
@Component
public class LoginPersistence {
  private final UserRepository users;
  private final DeviceRepository devices;
  private final AccountContext accountContext;
  private final DeviceListCache cache;

  @PersistenceContext private EntityManager em;

  public LoginPersistence(
      UserRepository users,
      DeviceRepository devices,
      AccountContext accountContext,
      DeviceListCache cache) {
    this.users = users;
    this.devices = devices;
    this.accountContext = accountContext;
    this.cache = cache;
  }

  /** 账户快照（供 SRP 校验与会话签发）；无副作用。 */
  public record AccountSnapshot(
      String userId,
      byte[] srpVerifier,
      byte[] emailEnc,
      String kdf,
      String vaultId,
      byte[] vkWrap,
      long vkGen,
      byte[] recoveryWrap,
      long sessionEpoch) {}

  @Transactional
  public AccountSnapshot readAccount(String accountId) {
    accountContext.bind(accountId);
    UserEntity user = users.findById(accountId).orElseThrow(ApiException::authFailed);
    return new AccountSnapshot(
        user.getId(),
        user.getSrpVerifier(),
        user.getEmailEnc(),
        user.getKdf(),
        user.getVaultId(),
        user.getVkWrap(),
        user.getVkGen(),
        user.getRecoveryWrap(),
        user.getSessionEpoch());
  }

  /** 设备登记/更新结果（含设备代次，用于会话元数据）。 */
  public record DeviceState(
      boolean approved, boolean newDevice, boolean revoked, long deviceEpoch) {}

  /** SRP 校验成功后调用：账户上下文内登记（未批准）或按当前状态更新设备。 已撤销设备返回 {@code revoked=true}（调用方据此拒绝登录），不修改其状态。 */
  @Transactional
  public DeviceState applyDevice(
      String accountId, String deviceId, String deviceName, String platform) {
    accountContext.bind(accountId);
    Instant now = Instant.now();
    var existing = devices.find(accountId, deviceId);
    if (existing.isPresent()) {
      DeviceEntity device = existing.get();
      if (device.isRevoked()) {
        return new DeviceState(false, false, true, device.getEpoch());
      }
      if (deviceName != null && !deviceName.equals(device.getName())) {
        device.rename(deviceName, now);
        invalidateCacheAfterCommit(accountId);
      }
      return new DeviceState(device.isApproved(), false, false, device.getEpoch());
    }
    DeviceEntity created =
        DeviceEntity.create(accountId, deviceId, deviceName, platform, false, null, now);
    em.persist(created);
    invalidateCacheAfterCommit(accountId);
    return new DeviceState(false, true, false, created.getEpoch());
  }

  /** 提交后失效设备展示缓存；不在提交前删除，避免并发旧值回填。失败由短 TTL 兜底。 */
  private void invalidateCacheAfterCommit(String accountId) {
    if (TransactionSynchronizationManager.isSynchronizationActive()) {
      TransactionSynchronizationManager.registerSynchronization(
          new TransactionSynchronization() {
            @Override
            public void afterCommit() {
              cache.invalidate(accountId);
            }
          });
    } else {
      cache.invalidate(accountId);
    }
  }

  /** 设备名 trim。 */
  public static String canonicalName(String raw) {
    return ServerKeys.rustTrim(raw == null ? "" : raw);
  }
}
