package app.vaultone.server.audit.model;

import app.vaultone.server.audit.RevisionContext;
import org.hibernate.envers.RevisionListener;

/**
 * 修订监听器：从可信事务审计上下文填充 {@code user_id/actor_device_id/request_id}，并设置毫秒时间。 上下文由业务在写事务进入时设置、在 finally
 * 清理；缺失账户时使用占位值，不静默写空。
 */
public final class VaultOneRevisionListener implements RevisionListener {
  @Override
  public void newRevision(Object revisionEntity) {
    VaultOneRevisionEntity revision = (VaultOneRevisionEntity) revisionEntity;
    RevisionContext.Context context = RevisionContext.current();
    revision.setUserId(context.accountId());
    revision.setActorDeviceId(context.actorDeviceId());
    revision.setRequestId(context.requestId());
  }
}
