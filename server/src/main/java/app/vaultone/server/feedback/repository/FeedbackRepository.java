package app.vaultone.server.feedback.repository;

import app.vaultone.server.feedback.model.FeedbackEntity;
import java.util.List;
import java.util.Optional;
import org.springframework.data.domain.Limit;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.Repository;
import org.springframework.data.repository.query.Param;

public interface FeedbackRepository extends Repository<FeedbackEntity, Long> {
  FeedbackEntity save(FeedbackEntity value);

  @Query("select f from FeedbackEntity f where f.userId = :account and f.id = :id")
  Optional<FeedbackEntity> find(@Param("account") String account, @Param("id") String id);

  interface Row {
    Long getSeq();

    String getId();

    String getCategory();

    String getStatus();

    long getCreatedAt();

    long getUpdatedAt();

    long getVersion();
  }

  @Query(
      "select f.seq as seq, f.id as id, f.category as category, f.status as status, "
          + "f.createdAt as createdAt, f.updatedAt as updatedAt, f.version as version "
          + "from FeedbackEntity f where f.userId = :account and f.expiresAt > :now "
          + "and f.seq < :before order by f.seq desc")
  List<Row> page(
      @Param("account") String account,
      @Param("before") long before,
      @Param("now") long now,
      Limit limit);

  @Query("select count(f) from FeedbackEntity f where f.userId = :account and f.expiresAt > :now")
  long activeCount(@Param("account") String account, @Param("now") long now);

  @Query("select count(f) from FeedbackEntity f where f.userId = :account and f.createdAt > :since")
  long recentCount(@Param("account") String account, @Param("since") long since);
}
