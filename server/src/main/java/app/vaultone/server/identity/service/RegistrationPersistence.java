package app.vaultone.server.identity.service;

import app.vaultone.server.audit.AuditEvents;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.identity.model.DeviceEntity;
import app.vaultone.server.identity.repository.DeviceRepository;
import app.vaultone.server.identity.repository.IdentityBootstrapRepository;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.time.Instant;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * 注册的场景化短事务。
 *
 * <p>账户与首台设备使用纯 INSERT，成功审计随同一事务提交。Redis 候选会话由调用方提前准备，只有本事务成功后才交付客户端。
 */
@Component
public class RegistrationPersistence {
  private final IdentityBootstrapRepository bootstrap;
  private final DeviceRepository devices;
  private final AuditService audit;

  @PersistenceContext private EntityManager em;

  public RegistrationPersistence(
      IdentityBootstrapRepository bootstrap, DeviceRepository devices, AuditService audit) {
    this.bootstrap = bootstrap;
    this.devices = devices;
    this.audit = audit;
  }

  /** 原子写入用户与首台已批准设备；唯一约束冲突由调用方分类映射。 */
  @Transactional
  public void persist(
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
      String deviceId,
      String deviceName,
      String devicePlatform,
      Instant now,
      String requestId,
      byte[] ipHash) {
    bootstrap.registerAccount(
        id,
        emailHash,
        emailEnc,
        kdfJson,
        srpSalt,
        srpVerifier,
        vaultId,
        vkWrap,
        vkGen,
        recoveryWrap,
        recoveryAuthHash,
        deviceId,
        deviceName,
        devicePlatform,
        app.vaultone.server.common.InstantText.format(now));
    audit.record(id, deviceId, AuditEvents.REGISTER, AuditService.SUCCESS, requestId, ipHash);
  }

  /**
   * 设备登录时登记：不存在则 INSERT（未批准）；存在则只更新名称/活跃时间，**绝不复活已撤销**。
   *
   * @return 是否新插入
   */
  @Transactional
  public boolean registerDeviceIfAbsent(DeviceEntity device) {
    var existing = devices.find(device.getUserId(), device.getId());
    if (existing.isPresent()) {
      return false;
    }
    em.persist(device);
    return true;
  }

  /** 更新设备名称与最近活跃时间（读取现有实体后更新，不走新增）。 */
  @Transactional
  public void touchDevice(String userId, String deviceId, String name, Instant now) {
    devices
        .find(userId, deviceId)
        .ifPresent(
            d -> {
              d.rename(name, now);
            });
  }
}
