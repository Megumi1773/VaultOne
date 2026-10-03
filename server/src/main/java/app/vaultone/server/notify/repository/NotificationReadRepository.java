package app.vaultone.server.notify.repository;

import app.vaultone.server.notify.model.NotificationReadEntity;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

/** 已读记录仓储。复合主键，写入天然幂等。 */
public interface NotificationReadRepository
    extends JpaRepository<NotificationReadEntity, NotificationReadEntity.Key> {

  /** 该账户已读的通知 id 集合。列表页据此标出「已读」而不是再查一次每条的读状态。 */
  @Query("select r.notificationId from NotificationReadEntity r where r.accountId = :accountId")
  List<String> readIds(@Param("accountId") String accountId);
}
