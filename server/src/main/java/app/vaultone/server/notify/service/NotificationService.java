package app.vaultone.server.notify.service;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.notify.model.NotificationEntity;
import app.vaultone.server.notify.model.NotificationReadEntity;
import app.vaultone.server.notify.repository.NotificationReadRepository;
import app.vaultone.server.notify.repository.NotificationRepository;
import app.vaultone.server.proto.NotificationDtos;
import app.vaultone.server.security.Approved;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.springframework.data.domain.Limit;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 通知读取与已读标记（计划书 §6.1 / §6.2）。
 *
 * <p>只做读与「标记已读」两件事：通知由运维 SQL 发布，本服务不提供写入口。
 */
@Service
public class NotificationService {
  /** 单页上限。与请求参数校验共用同一个常量，避免两处各写一个数字然后不一致。 */
  public static final int MAX_LIMIT = 50;

  public static final int DEFAULT_LIMIT = 20;

  private final NotificationRepository notifications;
  private final NotificationReadRepository reads;

  public NotificationService(
      NotificationRepository notifications, NotificationReadRepository reads) {
    this.notifications = notifications;
    this.reads = reads;
  }

  /** 列表 + 未读统计。未读统计是**全量**的，不随当前页变化。 */
  @Transactional(readOnly = true)
  public NotificationDtos.Page list(Approved approved, String cursor, int limit) {
    long now = Instant.now().getEpochSecond();
    String accountId = approved.userId();

    NotificationCursor.Position after = NotificationCursor.decode(cursor);
    // 多取一条判断有没有下一页：比再发一次 count 查询便宜，也不会因为并发新增而误判。
    Limit fetch = Limit.of(limit + 1);
    List<NotificationEntity> rows =
        after == null
            ? notifications.firstPage(accountId, now, fetch)
            : notifications.pageAfter(accountId, now, after.publishedAt(), after.id(), fetch);

    boolean hasMore = rows.size() > limit;
    List<NotificationEntity> page = hasMore ? rows.subList(0, limit) : rows;

    Set<String> read = Set.copyOf(reads.readIds(accountId));
    List<NotificationDtos.Item> items =
        page.stream().map(n -> toItem(n, read.contains(n.getId()))).toList();
    String nextCursor =
        hasMore && !page.isEmpty()
            ? NotificationCursor.encode(
                page.get(page.size() - 1).getPublishedAt(), page.get(page.size() - 1).getId())
            : null;
    return new NotificationDtos.Page(items, nextCursor, unread(accountId, now));
  }

  /**
   * 标记已读（计划书 §6.1「已读标记（进入详情即标记）」）。
   *
   * <p>幂等：已读过再标一次不报错也不改时间。**但不是无声成功**——若该通知对当前账户不可见， 直接 404：否则可以拿 id 逐个试探，从「有没有报错」反推出别人的个人消息存在。
   */
  @Transactional
  public NotificationDtos.Unread markRead(Approved approved, String id) {
    long now = Instant.now().getEpochSecond();
    if (notifications.countVisible(approved.userId(), id, now) == 0) {
      throw ApiException.notFound();
    }
    reads.save(NotificationReadEntity.of(approved.userId(), id, now));
    return unread(approved.userId(), now);
  }

  /** 未读分类计数（计划书 §6.1）。 */
  private NotificationDtos.Unread unread(String accountId, long now) {
    long total = 0;
    Map<String, Long> byKind = new LinkedHashMap<>();
    for (Object[] row : notifications.unreadByKind(accountId, now)) {
      String kind = (String) row[0];
      long count = ((Number) row[1]).longValue();
      byKind.merge(kind, count, Long::sum);
      total += count;
    }
    // 弹窗与服务端公告合并计入「公告」：客户端也这么分（见 AppNotification.category），
    // 两处口径必须一致，否则角标与列表筛选会对不上。
    long announcement = byKind.getOrDefault("announcement", 0L) + byKind.getOrDefault("popup", 0L);
    return new NotificationDtos.Unread(
        total,
        announcement,
        byKind.getOrDefault("personal", 0L),
        byKind.getOrDefault("security", 0L));
  }

  private static NotificationDtos.Item toItem(NotificationEntity n, boolean read) {
    return new NotificationDtos.Item(
        n.getId(),
        n.getKind(),
        n.getLevel(),
        n.getTitle(),
        n.getBody(),
        n.getPublishedAt(),
        read,
        new NotificationDtos.Action(n.getActionKind(), n.getActionValue(), n.getActionLabel()));
  }
}
