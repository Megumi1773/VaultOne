package app.vaultone.server.identity.repository;

import app.vaultone.server.identity.model.DeviceEntity;
import java.util.List;
import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

/** 设备仓储。 */
public interface DeviceRepository extends JpaRepository<DeviceEntity, DeviceEntity.Key> {
  @Query("select d from DeviceEntity d where d.userId = :userId and d.id = :deviceId")
  Optional<DeviceEntity> find(@Param("userId") String userId, @Param("deviceId") String deviceId);

  @Query("select d from DeviceEntity d where d.userId = :userId order by d.createdAt")
  List<DeviceEntity> listByUser(@Param("userId") String userId);
}
