package app.vaultone.server.sync;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.common.InstantText;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.proto.Bytes;
import app.vaultone.server.proto.PullResponse;
import app.vaultone.server.proto.PushItem;
import app.vaultone.server.proto.PushRequest;
import app.vaultone.server.proto.PushResponse;
import app.vaultone.server.proto.PushResult;
import app.vaultone.server.proto.PushStatus;
import app.vaultone.server.proto.RemoteItem;
import app.vaultone.server.security.AccountGuard;
import app.vaultone.server.security.Approved;
import app.vaultone.server.sync.repository.SyncRepository;
import app.vaultone.server.sync.repository.SyncRepository.ItemRow;
import app.vaultone.server.sync.repository.SyncRepository.PullRow;
import app.vaultone.server.validate.WireValidation;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * E2EE 增量同步：推送（版本号乐观锁 + 幂等）与按 change_log 游标拉取。逐条对齐 {@code crates/vault-server/src/routes_sync.rs}。
 *
 * <p>整批推送在同一事务内完成：任一条目写入失败即整批回滚；DB 错误不半提交。blob 是不透明密封盒，服务端只算 SHA-256 与结构校验。
 */
@Service
@Transactional
public class SyncService {
  static final int PUSH_MAX_ITEMS = 500;
  static final long PULL_PAGE_SIZE = 500;

  private final SyncRepository repository;
  private final AccountGuard guard;

  public SyncService(SyncRepository repository, AccountGuard guard) {
    this.repository = repository;
    this.guard = guard;
  }

  /** 推送一批条目；单项冲突返回 {@code conflict} 状态而非 HTTP 409。 */
  public PushResponse push(Approved approved, PushRequest req) {
    var principal = requireApproved(approved);
    String userId = principal.userId();
    String deviceId = principal.deviceId();
    List<PushItem> items = req.items();
    if (items.size() > PUSH_MAX_ITEMS) {
      throw ApiException.badRequest("单次最多推送 " + PUSH_MAX_ITEMS + " 条");
    }
    for (PushItem it : items) {
      WireValidation.uuid(it.id(), "item.id");
      WireValidation.kind(it.kind());
      WireValidation.itemBlob(it.blob().toByteArray());
      if (it.revision() < 1 || it.revision() <= it.baseRevision() || it.baseRevision() < 0) {
        throw ApiException.badRequest("版本号不合法");
      }
    }
    String now = InstantText.format(Instant.now().getEpochSecond());
    List<PushResult> results = new ArrayList<>(items.size());
    // 授权时取得的账户行锁持续至提交，游标不能越过尚未提交的同账户写入。
    for (PushItem it : items) {
      byte[] blob = it.blob().toByteArray();
      byte[] hash = ServerKeys.sha256(blob);
      long deleted = it.deleted() ? 1L : 0L;
      Optional<ItemRow> current = repository.currentItem(userId, it.id());
      PushStatus status;
      long revision;
      boolean changed;
      if (current.isPresent()) {
        ItemRow row = current.get();
        if (row.revision() == it.revision()
            && Arrays.equals(row.blobHash(), hash)
            && row.kind().equals(it.kind())
            && row.deleted() == deleted
            && row.updatedAt().equals(InstantText.format(it.updatedAt()))) {
          // 旧客户端响应丢失后的重试仍携带旧 base_revision；不比较 base 或设备。
          // 但所有实际写入字段必须相同，不能把删除/类型/时间变更误当重放吞掉。
          status = PushStatus.APPLIED;
          revision = row.revision();
          changed = false;
        } else if (row.revision() == it.baseRevision()) {
          repository.upsertItem(
              userId,
              it.id(),
              it.kind(),
              blob,
              hash,
              it.revision(),
              deleted,
              InstantText.format(it.updatedAt()),
              deviceId,
              now);
          status = PushStatus.APPLIED;
          revision = it.revision();
          changed = true;
        } else {
          status = PushStatus.CONFLICT;
          revision = row.revision();
          changed = false;
        }
      } else {
        repository.upsertItem(
            userId,
            it.id(),
            it.kind(),
            blob,
            hash,
            it.revision(),
            deleted,
            InstantText.format(it.updatedAt()),
            deviceId,
            now);
        status = PushStatus.APPLIED;
        revision = it.revision();
        changed = true;
      }
      if (changed) {
        // 只为真正的新写入追加历史和移动游标；历史被 GC 后的合法重试也保持无副作用。
        repository.insertVersion(userId, it.id(), it.revision(), blob, deviceId, now);
        repository.replaceChangeLog(userId, it.id(), it.revision(), now);
      }
      results.add(new PushResult(it.id(), status, revision));
    }
    return new PushResponse(results);
  }

  /** 按游标拉取：limit 默认 500、钳至 1..1000；额外取 1 行判 has_more，空页保留输入钳制后 cursor。 */
  public PullResponse pull(Approved approved, long cursor, Long limit) {
    String userId = requireApproved(approved).userId();
    long pageSize = limit == null ? PULL_PAGE_SIZE : limit;
    pageSize = Math.clamp(pageSize, 1L, 1000L);
    long clampedCursor = Math.max(0L, cursor);
    List<PullRow> rows = repository.pull(userId, clampedCursor, (int) (pageSize + 1));
    boolean hasMore = rows.size() > pageSize;
    long newCursor = clampedCursor;
    int take = (int) Math.min(pageSize, rows.size());
    List<RemoteItem> items = new ArrayList<>(take);
    for (int i = 0; i < take; i++) {
      PullRow r = rows.get(i);
      newCursor = r.seq();
      items.add(
          new RemoteItem(
              r.id(),
              r.kind(),
              Bytes.wrap(r.blob()),
              r.revision(),
              r.deleted() != 0,
              InstantText.toEpochSecond(r.updatedAt())));
    }
    long vkGen = repository.currentVkGen(userId);
    return new PullResponse(items, newCursor, hasMore, vkGen);
  }

  /** 注销账户：清理条目、版本历史与 change_log。由身份注销流程调用。 */
  public void wipeAccount(Approved approved) {
    String userId = requireApproved(approved).userId();
    repository.deleteItemVersions(userId);
    repository.deleteChangeLog(userId);
    repository.deleteItems(userId);
  }

  private AccountGuard.Principal requireApproved(Approved approved) {
    var principal = guard.lock(approved.authed().ref());
    if (!principal.approved()) {
      throw ApiException.deviceNotApproved();
    }
    return principal;
  }
}
