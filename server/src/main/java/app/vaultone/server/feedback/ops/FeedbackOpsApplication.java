package app.vaultone.server.feedback.ops;

import app.vaultone.server.audit.AuditRepository;
import app.vaultone.server.audit.model.AuditEventEntity;
import app.vaultone.server.feedback.repository.FeedbackRepository;
import app.vaultone.server.feedback.service.FeedbackOperationsService;
import app.vaultone.server.feedback.service.FeedbackRecords;
import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.proto.WireJsonConfiguration;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.persistence.autoconfigure.EntityScan;
import org.springframework.context.annotation.Import;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;

/** 显式导入的窄 CLI 上下文；无组件扫描，不加载 HTTP、Redis、邮件或调度器。 */
@EnableAutoConfiguration
@EntityScan(
    basePackageClasses = {
      UserEntity.class,
      AuditEventEntity.class,
      app.vaultone.server.feedback.model.FeedbackEntity.class
    })
@EnableJpaRepositories(basePackageClasses = {FeedbackRepository.class, AuditRepository.class})
@Import({FeedbackOperationsService.class, FeedbackRecords.class, WireJsonConfiguration.class})
public class FeedbackOpsApplication {}
