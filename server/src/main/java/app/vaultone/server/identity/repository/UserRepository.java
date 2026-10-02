package app.vaultone.server.identity.repository;

import app.vaultone.server.identity.model.UserEntity;
import jakarta.persistence.LockModeType;
import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

/** 账户仓储。读路径按 ID/邮箱 HMAC；写路径使用 {@link #lockById} 的悲观写锁串行化同账户变更 （配合事务内 RLS 账户上下文与 principal 重验）。 */
public interface UserRepository extends JpaRepository<UserEntity, String> {
  Optional<UserEntity> findByEmailHash(byte[] emailHash);

  /** 账户行悲观写锁：同账户的改密/恢复/撤销等变更串行化至提交。必须在其后立即重验 principal。 */
  @Lock(LockModeType.PESSIMISTIC_WRITE)
  @Query("select u from UserEntity u where u.id = :id")
  Optional<UserEntity> lockById(@Param("id") String id);

  /** 按邀请码查邀请人（计划书 §9）。只读，不需要锁——被邀请人绑定的是别人的账户， 锁自己的行就够了；邀请码本身不可变，读到之后不会突然变成另一个人。 */
  Optional<UserEntity> findByInviteCode(String inviteCode);
}
