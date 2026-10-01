package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.support.LocalTestServices;
import com.zaxxer.hikari.HikariDataSource;
import jakarta.persistence.EntityManagerFactory;
import java.time.Duration;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.redisson.api.RedissonClient;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;

/**
 * 真实基础设施集成测试（Failsafe，{@code *IT}）。两种模式共用同一套断言：
 *
 * <ul>
 *   <li>默认：Testcontainers 真实 PG16 + Redis8（无 Docker 直接失败，不 skip）。
 *   <li>{@code VAULTONE_IT_MODE=external}：本机 PG/Redis，管理员只建随机库/受限角色与迁移，业务用受限角色。
 * </ul>
 *
 * <p>只创建所选后端；不使用 {@code @Container} 静态初始化，外部模式不会触发 Docker。随机库/角色/Redis 前缀， 结束时只清本次资源；清理失败可见且保留原始失败。
 */
class InfrastructureIT {

  @Test
  void realPostgresFlywayJpaJettyAndSingletonRedisson() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      // 真实 Jetty 启动。
      assertThat(((ServletWebServerApplicationContext) context).getWebServer().getClass().getName())
          .contains("Jetty");

      // JPA validate + OSIV 关闭（门禁与 YAML 的实际落地）。
      assertThat(context.getBean(EntityManagerFactory.class).isOpen()).isTrue();
      assertThat(context.getEnvironment().getProperty("spring.jpa.hibernate.ddl-auto"))
          .isEqualTo("validate");
      assertThat(context.getEnvironment().getProperty("spring.jpa.open-in-view"))
          .isEqualTo("false");
      assertThat(org.hibernate.Version.getVersionString()).isEqualTo("7.4.5.Final");
      assertThat(org.hibernate.envers.Audited.class.getPackage().getImplementationVersion())
          .isEqualTo("7.4.5.Final");

      // 迁移边界：迁移由 fixture 用 migrator 在应用启动前完成，应用侧关闭自跑 Flyway（无 Flyway bean）。
      assertThat(context.getBeansOfType(Flyway.class))
          .as("运行上下文不应有 Flyway bean：迁移是独立的 migrator 步骤")
          .isEmpty();
      assertThat(services.currentSchemaVersion()).isEqualTo("5");

      // 迁移历史确实由 migrator 落在隔离库：4 条 success 记录。
      try (var connection =
              java.sql.DriverManager.getConnection(
                  services.migrator().jdbcUrl(),
                  services.migrator().user(),
                  services.migrator().password());
          var statement = connection.createStatement();
          var rows =
              statement.executeQuery(
                  "SELECT COUNT(*) FROM vaultone_java_schema_history WHERE success")) {
        assertThat(rows.next()).isTrue();
        assertThat(rows.getInt(1)).isEqualTo(5);
      }

      // 非 baseline 策略：与 fixture 相同配置的 Flyway 报告当前版本 4 且不自动 baseline。
      var configured =
          Flyway.configure()
              .dataSource(
                  services.migrator().jdbcUrl(),
                  services.migrator().user(),
                  services.migrator().password())
              .locations("classpath:db/migration/java")
              .table("vaultone_java_schema_history")
              .load();
      assertThat(configured.getConfiguration().isBaselineOnMigrate()).isFalse();
      assertThat(configured.info().current().getVersion().toString()).isEqualTo("5");

      // 运行角色在真实库上确实受限（非超级/无建库/无 BYPASSRLS），RLS 结论才可信。
      if (services.backend() instanceof app.vaultone.server.support.ExternalBackend external) {
        external.assertRuntimeRoleRestricted();
      }

      var pool = context.getBean(HikariDataSource.class);
      assertThat(pool.getMaximumPoolSize()).isEqualTo(4);

      // Redisson 单例与命名空间隔离的键写入/TTL。
      assertThat(context.getBeansOfType(RedissonClient.class)).hasSize(1);
      var redis = context.getBean(RedissonClient.class);
      assertThat(redis.getConfig().useSingleServer().getConnectionPoolSize()).isEqualTo(8);
      String key = services.redisNamespace() + "probe";
      var bucket = redis.<String>getBucket(key);
      bucket.set("test-value", Duration.ofSeconds(10));
      try {
        assertThat(bucket.get()).isEqualTo("test-value");
        assertThat(bucket.remainTimeToLive()).isBetween(1L, 10000L);
      } finally {
        bucket.delete();
      }
    }
  }

  @Test
  void nonemptyUnmanagedSchemaIsNotAutomaticallyBaselined() throws Exception {
    try (LocalTestServices services = LocalTestServices.start()) {
      var admin = services.admin();
      try (var connection =
              java.sql.DriverManager.getConnection(
                  admin.jdbcUrl(), admin.user(), admin.password());
          var statement = connection.createStatement()) {
        statement.execute("CREATE SCHEMA unmanaged_test");
        statement.execute("CREATE TABLE unmanaged_test.existing_data(id BIGINT PRIMARY KEY)");
      }
      var flyway =
          Flyway.configure()
              .dataSource(admin.jdbcUrl(), admin.user(), admin.password())
              .schemas("unmanaged_test")
              .table("vaultone_java_schema_history")
              .locations("classpath:db/migration/java")
              .baselineOnMigrate(false)
              .load();
      assertThatThrownBy(flyway::migrate).isInstanceOf(org.flywaydb.core.api.FlywayException.class);
    }
  }
}
