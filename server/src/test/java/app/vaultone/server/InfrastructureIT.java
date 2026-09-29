package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.zaxxer.hikari.HikariDataSource;
import jakarta.persistence.EntityManagerFactory;
import java.sql.DriverManager;
import java.time.Duration;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.redisson.api.RedissonClient;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

/** 真实PG/Redis；没有Docker必须失败。不得改成disabledWithoutDocker或H2替代。 */
@Testcontainers
class InfrastructureIT {
  @Container
  static final PostgreSQLContainer PG =
      new PostgreSQLContainer(
          // TC2.0对tag+digest不能自动推断仓库别名；此digest已核验为官方postgres。
          DockerImageName.parse(
                  "postgres:16.15-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea")
              .asCompatibleSubstituteFor("postgres"));

  @Container
  static final GenericContainer<?> REDIS =
      new GenericContainer<>(
              DockerImageName.parse(
                  "redis:8.10.2-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0"))
          .withExposedPorts(6379);

  @Test
  void realPostgresFlywayJpaAndSingletonRedisson() throws Exception {
    try (var context =
        new SpringApplicationBuilder(VaultOneServerApplication.class)
            .run(
                "--spring.profiles.active=local",
                "--vaultone.development.enabled=true",
                "--vaultone.server-secret=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                "--spring.datasource.url=" + PG.getJdbcUrl(),
                "--spring.datasource.username=" + PG.getUsername(),
                "--spring.datasource.password=" + PG.getPassword(),
                "--vaultone.redis.address=redis://"
                    + REDIS.getHost()
                    + ":"
                    + REDIS.getMappedPort(6379),
                "--server.port=0")) {
      assertThat(((ServletWebServerApplicationContext) context).getWebServer().getClass().getName())
          .contains("Jetty");
      var pool = context.getBean(HikariDataSource.class);
      assertThat(pool.getMaximumPoolSize()).isEqualTo(10);
      assertThat(context.getBean(EntityManagerFactory.class).isOpen()).isTrue();
      assertThat(context.getEnvironment().getProperty("spring.jpa.hibernate.ddl-auto"))
          .isEqualTo("validate");
      assertThat(context.getEnvironment().getProperty("spring.jpa.open-in-view"))
          .isEqualTo("false");
      assertThat(org.hibernate.Version.getVersionString()).isEqualTo("7.4.5.Final");
      assertThat(org.hibernate.envers.Audited.class.getPackage().getImplementationVersion())
          .isEqualTo("7.4.5.Final");
      var flyway = context.getBean(Flyway.class);
      assertThat(flyway.getConfiguration().isBaselineOnMigrate()).isFalse();
      assertThat(flyway.info().current().getVersion().toString()).isEqualTo("1");
      try (var connection = pool.getConnection();
          var statement = connection.createStatement();
          var rows =
              statement.executeQuery(
                  "SELECT COUNT(*) FROM vaultone_java_schema_history WHERE success")) {
        assertThat(rows.next()).isTrue();
        assertThat(rows.getInt(1)).isEqualTo(1);
      }
      assertThat(context.getBeansOfType(RedissonClient.class)).hasSize(1);
      var redis = context.getBean(RedissonClient.class);
      assertThat(redis.getConfig().useSingleServer().getConnectionPoolSize()).isEqualTo(8);
      var bucket = redis.<String>getBucket("vaultone:s1:public-test-only");
      bucket.set("test-value", Duration.ofSeconds(10));
      assertThat(bucket.get()).isEqualTo("test-value");
      assertThat(bucket.remainTimeToLive()).isBetween(1L, 10000L);
      assertThat(bucket.delete()).isTrue();
    }
  }

  @Test
  void nonemptyUnmanagedSchemaIsNotAutomaticallyBaselined() throws Exception {
    try (var connection =
            DriverManager.getConnection(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        var statement = connection.createStatement()) {
      statement.execute("CREATE SCHEMA unmanaged_test");
      statement.execute("CREATE TABLE unmanaged_test.existing_data(id BIGINT PRIMARY KEY)");
    }
    var flyway =
        Flyway.configure()
            .dataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword())
            .schemas("unmanaged_test")
            .table("vaultone_java_schema_history")
            .locations("classpath:db/migration/java")
            .baselineOnMigrate(false)
            .load();
    assertThatThrownBy(flyway::migrate).isInstanceOf(org.flywaydb.core.api.FlywayException.class);
  }
}
