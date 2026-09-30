package app.vaultone.server.identity.service;

import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.identity.repository.UserRepository;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.util.Optional;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * 账户上下文：在使用用户数据的事务内，首条参数化设置 {@code vaultone.account_id}（事务级，连接归还即清）， 使 RLS 生效；无上下文时 RLS 默认拒绝。
 *
 * <p>同时提供账户授权快照读取：以认证得到的 account_id 为准，不信任请求体中的所有者。
 */
@Component
public class AccountContext {
  @PersistenceContext private EntityManager em;
  private final UserRepository users;

  public AccountContext(UserRepository users) {
    this.users = users;
  }

  /** 在当前事务（或新事务）设置 RLS 账户上下文；必须在该事务访问用户数据前调用。 */
  @Transactional(propagation = Propagation.MANDATORY)
  public void bind(String accountId) {
    em.createNativeQuery("SELECT set_config('vaultone.account_id', :acct, true)")
        .setParameter("acct", accountId)
        .getSingleResult();
    // 同步 Envers 修订上下文到被操作账户：公开流程（登录等）无 PrincipalHolder，但写入的审计实体属于该账户，
    // revinfo 的 RLS 要求 user_id = 当前账户上下文，故此处以账户身份补齐（非 system 占位）。
    app.vaultone.server.audit.RevisionContext.bindAccountIfAbsent(accountId);
  }

  /** 绑定上下文并读取账户快照（RLS 生效后）。 */
  @Transactional
  public Optional<UserEntity> readAccount(String accountId) {
    bind(accountId);
    return users.findById(accountId);
  }
}
