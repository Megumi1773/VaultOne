package app.vaultone.server.support;

import java.security.SecureRandom;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.HexFormat;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * 默认（CI）后端：Testcontainers 提供真实 PG16 与 Redis8。只在本模式实例化容器；外部模式绝不触碰本类。
 *
 * <p>容器超级用户只用于创建随机库与 migrator/runtime 两个受限角色；库 owner 为 migrator（非超级）， 迁移由 migrator 执行、业务由 runtime
 * 执行，与外部模式断言路径一致。无 Docker 时容器启动直接失败，不 skip。
 */
public final class ContainerBackend implements ItBackend {
  private static final SecureRandom RANDOM = new SecureRandom();

  private final PostgreSQLContainer pg;
  private final GenericContainer<?> redis;
  private final String dbName;
  private final String migratorRole;
  private final String migratorPassword;
  private final String runtimeRole;
  private final String runtimePassword;
  private final String redisNamespace;

  private ContainerBackend(
      PostgreSQLContainer pg,
      GenericContainer<?> redis,
      String dbName,
      String migratorRole,
      String migratorPassword,
      String runtimeRole,
      String runtimePassword,
      String redisNamespace) {
    this.pg = pg;
    this.redis = redis;
    this.dbName = dbName;
    this.migratorRole = migratorRole;
    this.migratorPassword = migratorPassword;
    this.runtimeRole = runtimeRole;
    this.runtimePassword = runtimePassword;
    this.redisNamespace = redisNamespace;
  }

  public static ContainerBackend start() {
    PostgreSQLContainer pg =
        new PostgreSQLContainer(
            DockerImageName.parse(
                    "postgres:16.15-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea")
                .asCompatibleSubstituteFor("postgres"));
    GenericContainer<?> redis =
        new GenericContainer<>(
                DockerImageName.parse(
                    "redis:8.10.2-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0"))
            .withExposedPorts(6379);
    pg.start();
    redis.start();
    String suffix = ItBackend.randomSuffix();
    var backend =
        new ContainerBackend(
            pg,
            redis,
            ItBackend.safeIdentifier("vaultone_it_db", suffix),
            ItBackend.safeIdentifier("vaultone_it_migrator", suffix),
            randomPassword(),
            ItBackend.safeIdentifier("vaultone_it_runtime", suffix),
            randomPassword(),
            "vaultone:it:" + suffix + ":");
    backend.provision();
    return backend;
  }

  private void provision() {
    try (Connection admin =
        DriverManager.getConnection(adminUrl(), pg.getUsername(), pg.getPassword())) {
      admin.setAutoCommit(true);
      try (Statement statement = admin.createStatement()) {
        statement.execute(createRoleSql(migratorRole, migratorPassword));
        statement.execute(createRoleSql(runtimeRole, runtimePassword));
        statement.execute("CREATE DATABASE " + quote(dbName) + " OWNER " + quote(migratorRole));
        statement.execute(
            "GRANT CONNECT ON DATABASE " + quote(dbName) + " TO " + quote(migratorRole));
        statement.execute(
            "GRANT CONNECT ON DATABASE " + quote(dbName) + " TO " + quote(runtimeRole));
      }
    } catch (SQLException ex) {
      throw new IllegalStateException("容器模式创建隔离 PG 资源失败", ex);
    }
  }

  private static String createRoleSql(String role, String password) {
    return "CREATE ROLE "
        + quote(role)
        + " LOGIN PASSWORD "
        + literal(password)
        + " NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS";
  }

  @Override
  public ItConnection migrator() {
    return ItConnection.jdbc(urlFor(dbName), migratorRole, migratorPassword);
  }

  @Override
  public ItConnection runtime() {
    return ItConnection.jdbc(urlFor(dbName), runtimeRole, runtimePassword);
  }

  @Override
  public ItConnection.RedisConn redis() {
    return ItConnection.redis("redis://" + redis.getHost() + ":" + redis.getMappedPort(6379), "");
  }

  @Override
  public String redisNamespace() {
    return redisNamespace;
  }

  @Override
  public void close() {
    RuntimeException failure = null;
    try (Connection admin =
        DriverManager.getConnection(adminUrl(), pg.getUsername(), pg.getPassword())) {
      try (Statement statement = admin.createStatement()) {
        statement.execute("DROP DATABASE IF EXISTS " + quote(dbName));
        statement.execute("DROP ROLE IF EXISTS " + quote(runtimeRole));
        statement.execute("DROP ROLE IF EXISTS " + quote(migratorRole));
      }
    } catch (SQLException ex) {
      failure = new IllegalStateException("清理容器模式隔离 PG 资源失败", ex);
    }
    try {
      redis.stop();
      pg.stop();
    } catch (RuntimeException ex) {
      if (failure == null) {
        failure = new IllegalStateException("停止容器失败", ex);
      }
    }
    if (failure != null) {
      throw failure;
    }
  }

  private String adminUrl() {
    return pg.getJdbcUrl();
  }

  private String urlFor(String database) {
    String base = pg.getJdbcUrl();
    int slash = base.lastIndexOf('/');
    return base.substring(0, slash + 1) + database;
  }

  private static String randomPassword() {
    byte[] raw = new byte[24];
    RANDOM.nextBytes(raw);
    return "it_" + HexFormat.of().formatHex(raw);
  }

  private static String quote(String identifier) {
    return "\"" + identifier.replace("\"", "\"\"") + "\"";
  }

  private static String literal(String value) {
    return "'" + value.replace("'", "''") + "'";
  }
}
