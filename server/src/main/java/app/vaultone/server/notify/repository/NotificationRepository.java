package app.vaultone.server.notify.repository;

import app.vaultone.server.notify.model.NotificationEntity;
import java.util.List;
import org.springframework.data.domain.Limit;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

/**
 * 通知仓储（计划书 §6.1）。
 *
 * <p>列表用**游标（keyset）分页**而不是 offset：通知会不断新增，offset 翻页在新增发生时 会让同一页内容整体后移，用户翻到第二页会看到第一页末尾那条。keyset 按
 * `(published_at, id)` 全序定位， 与插入无关。
 *
 * <p>可见性（广播 / 指定账户）与过期过滤都写在查询里，而不是取回来再在内存里筛： 后者会让分页大小失真——取 20 条筛掉 18 条，客户端拿到 2 条却以为还有更多。
 */
public interface NotificationRepository extends JpaRepository<NotificationEntity, String> {

  /** 第一页：按 (published_at, id) 倒序取前 `limit` 条。 */
  @Query(
      """
      select n from NotificationEntity n
       where (n.audience = 'all' or n.accountId = :accountId)
         and (n.expiresAt is null or n.expiresAt > :now)
       order by n.publishedAt desc, n.id desc
      """)
  List<NotificationEntity> firstPage(
      @Param("accountId") String accountId, @Param("now") long now, Limit limit);

  /**
   * 游标翻页：取严格早于游标位置的那一段。
   *
   * <p>比较写成「时间更早，或时间相同但 id 更小」，与排序键 `(published_at desc, id desc)` 完全一致 —— 只比时间会在同一秒内漏数据。
   */
  @Query(
      """
      select n from NotificationEntity n
       where (n.audience = 'all' or n.accountId = :accountId)
         and (n.expiresAt is null or n.expiresAt > :now)
         and (n.publishedAt < :cursorAt or (n.publishedAt = :cursorAt and n.id < :cursorId))
       order by n.publishedAt desc, n.id desc
      """)
  List<NotificationEntity> pageAfter(
      @Param("accountId") String accountId,
      @Param("now") long now,
      @Param("cursorAt") long cursorAt,
      @Param("cursorId") String cursorId,
      Limit limit);

  /**
   * 未读分类计数。
   *
   * <p>返回 `[kind, 未读数]` 的行，由服务层汇总成「总未读 / 公告 / 个人 / 安全」。 一条 SQL 算完，避免为每个分类各查一次。
   */
  @Query(
      """
      select n.kind, count(n) from NotificationEntity n
       where (n.audience = 'all' or n.accountId = :accountId)
         and (n.expiresAt is null or n.expiresAt > :now)
         and not exists (
           select 1 from NotificationReadEntity r
            where r.accountId = :accountId and r.notificationId = n.id)
       group by n.kind
      """)
  List<Object[]> unreadByKind(@Param("accountId") String accountId, @Param("now") long now);

  /** 该通知对该账户是否可见。标记已读前必须校验，否则可以凭 id 猜着标记别人的消息。 */
  @Query(
      """
      select count(n) from NotificationEntity n
       where n.id = :id
         and (n.audience = 'all' or n.accountId = :accountId)
         and (n.expiresAt is null or n.expiresAt > :now)
      """)
  long countVisible(
      @Param("accountId") String accountId, @Param("id") String id, @Param("now") long now);
}
