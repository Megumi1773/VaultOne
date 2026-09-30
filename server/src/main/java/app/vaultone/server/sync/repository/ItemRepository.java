package app.vaultone.server.sync.repository;

import app.vaultone.server.sync.model.ItemEntity;
import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

/** 条目仓储。按复合主键 {@code (user_id, id)} 查找；同步写路径的事务/乐观锁见 {@link SyncRepository}。 */
public interface ItemRepository extends JpaRepository<ItemEntity, ItemEntity.Key> {
  @Query("select i from ItemEntity i where i.userId = :userId and i.id = :itemId")
  Optional<ItemEntity> findItem(@Param("userId") String userId, @Param("itemId") String itemId);
}
