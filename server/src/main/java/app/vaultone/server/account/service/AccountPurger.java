package app.vaultone.server.account.service;

import app.vaultone.server.account.repository.AccountPurgeRepository;
import app.vaultone.server.audit.AuditEvents;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.security.Approved;
import app.vaultone.server.sync.SyncService;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 账户注销的数据库事务边界。保险库和活动身份记录在同一事务删除，失败时回滚。
 *
 * <p>保留最小 {@code account_deleted} 安全事件；Envers 修订不在本方法中自动清理。Redis 会话索引由 {@link AccountService}
 * 在提交后清理。
 */
@Service
public class AccountPurger {
  private final SyncService syncService;
  private final AccountPurgeRepository purgeRepository;
  private final AuditService audit;

  public AccountPurger(
      SyncService syncService, AccountPurgeRepository purgeRepository, AuditService audit) {
    this.syncService = syncService;
    this.purgeRepository = purgeRepository;
    this.audit = audit;
  }

  @Transactional
  public void purge(Approved approved, String requestId, byte[] ipHash) {
    String userId = approved.userId();
    syncService.wipeAccount(approved);
    purgeRepository.deleteDeviceOtps(userId);
    purgeRepository.deleteDevices(userId);
    purgeRepository.deleteAuditEvents(userId);
    // 账户行删除通过外键级联清理关联握手和会话撤销标记。
    audit.record(
        userId, null, AuditEvents.ACCOUNT_DELETED, AuditService.SUCCESS, requestId, ipHash);
    purgeRepository.deleteUser(userId);
  }
}
