package app.vaultone.server.audit;

import app.vaultone.server.audit.model.AuditEventEntity;
import java.util.List;
import org.springframework.data.domain.Limit;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

/** 审计仓储：按账户取最新 100 条（id 倒序）。 */
public interface AuditRepository extends JpaRepository<AuditEventEntity, Long> {
  @Query("select e from AuditEventEntity e where e.userId = :userId order by e.id desc")
  List<AuditEventEntity> latestForUser(@Param("userId") String userId, Limit limit);

  @Query(
      "select count(e) from AuditEventEntity e where e.userId = :userId and e.event = :event and e.createdAt >= :since")
  long countSince(
      @Param("userId") String userId, @Param("event") String event, @Param("since") String since);
}
