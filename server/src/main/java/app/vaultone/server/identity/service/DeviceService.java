package app.vaultone.server.identity.service;

import app.vaultone.server.account.service.AccountPersistence;
import app.vaultone.server.audit.AuditEvents;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.common.AfterCommit;
import app.vaultone.server.common.MailSender;
import app.vaultone.server.common.SafeDiagnostics;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.model.DeviceEntity;
import app.vaultone.server.proto.DeviceOut;
import app.vaultone.server.proto.Platform;
import app.vaultone.server.security.Approved;
import app.vaultone.server.security.Authed;
import app.vaultone.server.security.SessionStore;
import java.util.List;
import java.util.Optional;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** 设备管理：自查、列表、批准、撤销。授权与写在同一事务；成功审计同事务；通知/Redis 清理提交后受控执行。 */
@Service
public class DeviceService {
  private final DevicePersistence persistence;
  private final AccountPersistence accounts;
  private final SessionStore sessionStore;
  private final AuditService audit;
  private final MailSender mailer;
  private final ServerKeys keys;
  private final DeviceListCache cache;

  public DeviceService(
      DevicePersistence persistence,
      AccountPersistence accounts,
      SessionStore sessionStore,
      AuditService audit,
      MailSender mailer,
      ServerKeys keys,
      DeviceListCache cache) {
    this.persistence = persistence;
    this.accounts = accounts;
    this.sessionStore = sessionStore;
    this.audit = audit;
    this.mailer = mailer;
    this.keys = keys;
    this.cache = cache;
  }

  @Transactional
  public DeviceOut deviceSelf(Authed authed) {
    return toOut(persistence.self(authed).device(), authed.deviceId());
  }

  /**
   * 列表：先以新鲜 PG 权威状态验证调用者（短事务，不缓存授权），事务结束后再读 Redis；命中直接映射本请求 current，
   * 不读整张设备列表；未命中才在授权事务读真实列表、事务外写缓存。Redis 故障保守回源，权限失败照常抛出（不当作 miss 绕过）。
   */
  public List<DeviceOut> listDevices(Approved approved) {
    DevicePersistence.Caller caller = persistence.authorize(approved);
    Optional<List<DeviceListCache.Entry>> cached = cache.get(caller.userId());
    List<DeviceListCache.Entry> entries;
    if (cached.isPresent()) {
      entries = cached.get();
    } else {
      entries = persistence.list(approved).stream().map(DeviceService::toEntry).toList();
      cache.put(caller.userId(), entries);
    }
    return entries.stream().map(e -> toOut(e, caller.deviceId())).toList();
  }

  @Transactional
  public void approveDevice(Approved approved, String deviceId, byte[] ipHash, String requestId) {
    persistence.approve(approved, deviceId);
    audit.record(
        approved.userId(),
        deviceId,
        AuditEvents.DEVICE_APPROVED,
        AuditService.SUCCESS,
        requestId,
        ipHash);
    // 提交后失效展示缓存；不在提交前删除，避免并发旧值回填。
    AfterCommit.runSafely(() -> cache.invalidate(approved.userId()));
    // 被批准设备需重新登录后取 keys；此处仅记录。
  }

  @Transactional
  public void revokeDevice(Approved approved, String deviceId, byte[] ipHash, String requestId) {
    persistence.revoke(approved, deviceId);
    audit.record(
        approved.userId(),
        deviceId,
        AuditEvents.DEVICE_REVOKED,
        AuditService.SUCCESS,
        requestId,
        ipHash);
    // 缓存失效、Redis 索引清理与邮件均在提交后执行；失败不影响已提交的撤销结果。
    String email = safeEmail(approved);
    AfterCommit.runSafely(
        () -> {
          cache.invalidate(approved.userId());
          try {
            sessionStore.deleteByDevice(approved.userId(), deviceId);
          } catch (RuntimeException ex) {
            SafeDiagnostics.logUnhandled(ex);
          }
          if (email != null) {
            mailer.send(email, "VaultOne 设备已撤销", "一台设备已被撤销，其会话已全部失效。如非本人操作，请立即修改主密码。");
          }
        });
  }

  private String safeEmail(Approved approved) {
    try {
      return keys.decryptEmail(accounts.lockForRead(approved).getEmailEnc());
    } catch (RuntimeException ex) {
      SafeDiagnostics.logUnhandled(ex);
      return null;
    }
  }

  private static DeviceListCache.Entry toEntry(DeviceEntity d) {
    return new DeviceListCache.Entry(
        d.getId(),
        d.getName(),
        d.getPlatform(),
        d.isApproved(),
        d.getCreatedAt() == null ? 0L : d.getCreatedAt().getEpochSecond(),
        d.getLastSeenAt() == null ? null : d.getLastSeenAt().getEpochSecond(),
        d.getRevokedAt() == null ? null : d.getRevokedAt().getEpochSecond());
  }

  private static DeviceOut toOut(DeviceEntity d, String currentDeviceId) {
    return toOut(toEntry(d), currentDeviceId);
  }

  private static DeviceOut toOut(DeviceListCache.Entry e, String currentDeviceId) {
    Platform platform = Platform.fromWire(e.platform());
    return new DeviceOut(
        e.id(),
        e.name(),
        platform == null ? Platform.OTHER : platform,
        e.approved(),
        e.id().equals(currentDeviceId),
        e.createdAt(),
        e.lastSeenAt(),
        e.revokedAt());
  }
}
