package app.vaultone.server.support;

import java.security.SecureRandom;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.HexFormat;

/**
 * 外部本机模式后端：root 只用于创建/回收隔离数据库与两种受限角色，业务与迁移各自使用专用角色。
 *
 * <ul>
 *   <li>随机库名与随机角色名；互不复用既有用户库/角色。
 *   <li><b>migrator</b>：库 owner，NONSUPERUSER / NOCREATEDB / NOCREATEROLE / NOINHERIT /
 *       NOBYPASSRLS；执行迁移与 DDL，也是 SECURITY DEFINER 函数 owner。
 *   <li><b>runtime</b>：非 owner，同样 NONSUPERUSER / NOBYPASSRLS 等；业务运行，RLS 真实生效。
 *   <li>清理：先删库（终止残留连接），再删两个角色；失败上抛，绝不 FLUSH Redis、不触碰既有库。
 *   <li>角色口令随机生成且从不输出/记录。
 * </ul>
 */
public final class ExternalBackend implements ItBackend {
  private static final SecureRandom RANDOM = new SecureRandom();

  private final ItConnection adminConn;
  private final ItConnection.RedisConn redisConn;
  private final String dbName;
  private final String migratorRole;
  private final String migratorPassword;
  private final String runtimeRole;
  private final String runtimePassword;
  private final String redisNamespace;
  private boolean databaseCreated;
  private boolean migratorCreated;
  private boolean runtimeCreated;

  private ExternalBackend(
      ItConnection adminConn,
      ItConnection.RedisConn redisConn,
      String dbName,
      String migratorRole,
      String migratorPassword,
      String runtimeRole,
      String runtimePassword,
      String redisNamespace) {
    this.adminConn = adminConn;
    this.redisConn = redisConn;
    this.dbName = dbName;
    this.migratorRole = migratorRole;
    this.migratorPassword = migratorPassword;
    this.runtimeRole = runtimeRole;
    this.runtimePassword = runtimePassword;
    this.redisNamespace = redisNamespace;
  }

  public static ExternalBackend create(ItConnection adminConn, ItConnection.RedisConn redisConn) {
    String suffix = ItBackend.randomSuffix();
    String db = ItBackend.safeIdentifier("vaultone_it_db", suffix);
    String migrator = ItBackend.safeIdentifier("vaultone_it_migrator", suffix);
    String runtime = ItBackend.safeIdentifier("vaultone_it_runtime", suffix);
    String namespace = "vaultone:it:" + suffix + ":";
    var backend =
        new ExternalBackend(
            adminConn,
            redisConn,
            db,
            migrator,
            randomPassword(),
            runtime,
            randomPassword(),
            namespace);
    backend.provision();
    return backend;
  }

  private void provision() {
    try (Connection connection =
        DriverManager.getConnection(adminConn.jdbcUrl(), adminConn.user(), adminConn.password())) {
      connection.setAutoCommit(true);
      createRole(connection, migratorRole, migratorPassword);
      migratorCreated = true;
      createRole(connection, runtimeRole, runtimePassword);
      runtimeCreated = true;
      createDatabase(connection);
      grantConnect(connection, migratorRole);
      grantConnect(connection, runtimeRole);
    } catch (SQLException ex) {
      // 创建失败也要尽量回收已建资源，再上抛原始错误（不吞）。
      cleanupQuietly();
      throw new IllegalStateException("外部模式创建隔离 PG 资源失败", ex);
    }
  }

  private void createRole(Connection connection, String role, String password) throws SQLException {
    String sql =
        "CREATE ROLE "
            + quote(role)
            + " LOGIN PASSWORD "
            + literal(password)
            + " NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS";
    try (Statement statement = connection.createStatement()) {
      statement.execute(sql);
    }
  }

  private void createDatabase(Connection connection) throws SQLException {
    // 库 owner 为 migrator（非 superuser）：普通 owner 在 FORCE RLS 下也受约束，贴近生产。
    try (Statement statement = connection.createStatement()) {
      statement.execute("CREATE DATABASE " + quote(dbName) + " OWNER " + quote(migratorRole));
    }
    databaseCreated = true;
  }

  private void grantConnect(Connection connection, String role) throws SQLException {
    try (Statement statement = connection.createStatement()) {
      statement.execute("GRANT CONNECT ON DATABASE " + quote(dbName) + " TO " + quote(role));
    }
  }

  @Override
  public ItConnection migrator() {
    return ItConnection.jdbc(adminConn.jdbcUrlFor(dbName), migratorRole, migratorPassword);
  }

  @Override
  public ItConnection runtime() {
    return ItConnection.jdbc(adminConn.jdbcUrlFor(dbName), runtimeRole, runtimePassword);
  }

  @Override
  public ItConnection.RedisConn redis() {
    return redisConn;
  }

  @Override
  public String redisNamespace() {
    return redisNamespace;
  }

  @Override
  public void close() {
    RuntimeException failure = cleanup();
    if (failure != null) {
      throw failure;
    }
  }

  /** 真正清理；返回非空表示清理失败（上层据此让测试失败，绝不静默）。 */
  private RuntimeException cleanup() {
    RuntimeException failure = null;
    try (Connection connection =
        DriverManager.getConnection(adminConn.jdbcUrl(), adminConn.user(), adminConn.password())) {
      if (databaseCreated) {
        try (Statement statement = connection.createStatement()) {
          statement.execute(
              "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = "
                  + literal(dbName)
                  + " AND pid <> pg_backend_pid()");
          statement.execute("DROP DATABASE IF EXISTS " + quote(dbName));
          databaseCreated = false;
        }
      }
      if (runtimeCreated) {
        try (Statement statement = connection.createStatement()) {
          statement.execute("DROP ROLE IF EXISTS " + quote(runtimeRole));
          runtimeCreated = false;
        }
      }
      if (migratorCreated) {
        try (Statement statement = connection.createStatement()) {
          statement.execute("DROP ROLE IF EXISTS " + quote(migratorRole));
          migratorCreated = false;
        }
      }
    } catch (SQLException ex) {
      failure = new IllegalStateException("清理外部模式隔离 PG 资源失败（" + dbName + "）", ex);
    }
    return failure;
  }

  private void cleanupQuietly() {
    try {
      cleanup();
    } catch (RuntimeException ignored) {
      // 创建阶段的兜底清理；原始错误更优先。
    }
  }

  /** 读取本机管理连接所需的严格环境变量。 */
  public static ExternalBackend fromEnvironment() {
    String jdbc = requireEnv("VAULTONE_IT_JDBC_URL");
    String user = requireEnv("VAULTONE_IT_DB_USER");
    String password = envOrEmpty("VAULTONE_IT_DB_PASSWORD");
    String redis = requireEnv("VAULTONE_IT_REDIS_ADDRESS");
    String redisPassword = envOrEmpty("VAULTONE_IT_REDIS_PASSWORD");
    ItConnection admin = ItConnection.jdbc(jdbc, user, password);
    ItConnection.RedisConn redisConn = ItConnection.redis(redis, redisPassword);
    return create(admin, redisConn);
  }

  static String requireEnv(String key) {
    String value = System.getenv(key);
    if (value == null || value.isBlank()) {
      throw new IllegalStateException("外部模式缺少环境变量 " + key);
    }
    return value;
  }

  static String envOrEmpty(String key) {
    String value = System.getenv(key);
    return value == null ? "" : value;
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

  /** 供测试断言：运行角色确实受限（非超级、无建库/建角色、无 BYPASSRLS）。 */
  public void assertRuntimeRoleRestricted() {
    assertRoleRestricted(runtimeRole, "运行");
  }

  /** 供测试断言：migrator 也受限（非超级、无建库/建角色、无 BYPASSRLS），只是库 owner。 */
  public void assertMigratorRoleRestricted() {
    assertRoleRestricted(migratorRole, "迁移");
  }

  private void assertRoleRestricted(String role, String label) {
    try (Connection connection =
            DriverManager.getConnection(
                adminConn.jdbcUrl(), adminConn.user(), adminConn.password());
        PreparedStatement statement =
            connection.prepareStatement(
                "SELECT rolsuper, rolcreatedb, rolcreaterole, rolbypassrls FROM pg_roles WHERE rolname = ?")) {
      statement.setString(1, role);
      try (ResultSet rs = statement.executeQuery()) {
        if (!rs.next()) {
          throw new IllegalStateException(label + "角色不存在");
        }
        if (rs.getBoolean("rolsuper")
            || rs.getBoolean("rolcreatedb")
            || rs.getBoolean("rolcreaterole")
            || rs.getBoolean("rolbypassrls")) {
          throw new IllegalStateException(label + "角色权限过高，RLS 结论不可信");
        }
      }
    } catch (SQLException ex) {
      throw new IllegalStateException("校验" + label + "角色权限失败", ex);
    }
  }
}
