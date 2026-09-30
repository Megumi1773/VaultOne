package app.vaultone.server.identity.service;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.identity.model.DeviceEntity;
import app.vaultone.server.identity.repository.DeviceRepository;
import app.vaultone.server.security.AccountGuard;
import app.vaultone.server.security.Approved;
import app.vaultone.server.security.Authed;
import java.time.Instant;
import java.util.List;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * 设备读写的账户上下文与授权事务。每个方法在同一事务内经 {@link AccountGuard} 绑定 RLS、锁账户并重验 principal（含 devices.epoch / 撤销 /
 * logout 标记），再读改写。
 */
@Component
public class DevicePersistence {
  private final DeviceRepository devices;
  private final AccountGuard guard;

  public DevicePersistence(DeviceRepository devices, AccountGuard guard) {
    this.devices = devices;
    this.guard = guard;
  }

  /** 自身设备（会话级：允许未批准设备）。 */
  public record SelfDevice(DeviceEntity device) {}

  /** 授权后的调用者快照（仅非敏感账户/设备标识，用于请求内 current 映射与缓存键）。 */
  public record Caller(String userId, String deviceId) {}

  @Transactional
  public SelfDevice self(Authed authed) {
    AccountGuard.Principal principal = guard.lock(authed.ref());
    return new SelfDevice(principal.device());
  }

  /**
   * 仅做新鲜 PG 权威校验（session_epoch / 设备未撤销 / devices.epoch / logout 标记），不读设备列表、不加写锁。
   * 调用方须在**本短事务结束后**再访问 Redis 展示缓存，避免持 DB 连接做 Redis I/O，也保证授权永不来自缓存。
   */
  @Transactional(readOnly = true)
  public Caller authorize(Approved approved) {
    AccountGuard.Principal principal = guard.readOnly(approved.ref());
    return new Caller(principal.userId(), principal.deviceId());
  }

  /** 缓存未命中时在授权事务内读取真实列表（只读校验，不再取写锁）。 */
  @Transactional(readOnly = true)
  public List<DeviceEntity> list(Approved approved) {
    guard.readOnly(approved.ref());
    return devices.listByUser(approved.userId());
  }

  @Transactional
  public void approve(Approved approved, String deviceId) {
    guard.lock(approved.ref());
    DeviceEntity target =
        devices.find(approved.userId(), deviceId).orElseThrow(ApiException::notFound);
    if (target.isRevoked()) {
      throw ApiException.badRequest("该设备已被撤销");
    }
    target.approve(approved.deviceId(), Instant.now());
  }

  @Transactional
  public void revoke(Approved approved, String deviceId) {
    guard.lock(approved.ref());
    DeviceEntity target =
        devices.find(approved.userId(), deviceId).orElseThrow(ApiException::notFound);
    target.revoke(Instant.now());
    // 该设备代次 +1：即使其 Redis 会话未清，PG 授权也会因 epoch 不符拒绝。
    target.bumpEpoch();
  }
}
