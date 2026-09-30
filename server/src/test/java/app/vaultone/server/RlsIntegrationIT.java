package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.support.ExternalBackend;
import app.vaultone.server.support.LocalTestServices;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.UUID;
import org.junit.jupiter.api.Test;

/**
 * 行级安全（RLS）、最小权限与 SECURITY DEFINER 加固的真实 PG 验证：必须用受限运行角色与受限 migrator， 不能拿超级用户业务连接“证明 RLS 成功”。
 *
 * <p>覆盖：无上下文默认拒绝、事务级账户上下文生效、跨账户不可见、池复用不串号、无 DDL 权限、引导函数最小权限、 临时关系无法污染 definer、handshakes
 * 无直接表权限、清理有界且按服务端时间钳制、revinfo 账户隔离。
 */
class RlsIntegrationIT {

  static void insertUser(Connection connection, String accountId, String vaultId)
      throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement(
            "INSERT INTO users(id, email_hash, email_enc, kdf, srp_salt, srp_verifier, vault_id,"
                + " vk_wrap, vk_gen, recovery_wrap, recovery_auth_hash, session_epoch, created_at,"
                + " updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 1, ?, ?)")) {
      statement.setString(1, accountId);
      statement.setBytes(2, accountId.getBytes());
      statement.setBytes(3, new byte[] {1});
      statement.setString(
          4,
          "{\"alg\":\"argon2id\",\"m\":8,\"t\":1,\"p\":1,\"salt\":\"AAAAAAAAAAAAAAAAAAAAAA==\"}");
      statement.setBytes(5, new byte[16]);
      statement.setBytes(6, new byte[] {1});
      statement.setString(7, vaultId);
      statement.setBytes(8, new byte[] {1});
      statement.setBytes(9, new byte[] {1});
      statement.setBytes(10, new byte[] {1});
      statement.setString(11, "2026-01-01T00:00:00Z");
      statement.setString(12, "2026-01-01T00:00:00Z");
      statement.executeUpdate();
    }
  }

  static void setAccountContext(Connection connection, String accountId) throws SQLException {
    try (PreparedStatement statement =
        connection.prepareStatement("SELECT set_config('vaultone.account_id', ?, true)")) {
      statement.setString(1, accountId);
      statement.executeQuery();
    }
  }

  static int countUsers(Connection connection) throws SQLException {
    try (Statement statement = connection.createStatement();
        ResultSet rs = statement.executeQuery("SELECT count(*) FROM users")) {
      rs.next();
      return rs.getInt(1);
    }
  }

  static Connection runtime(LocalTestServices services) throws SQLException {
    return DriverManager.getConnection(
        services.runtime().jdbcUrl(), services.runtime().user(), services.runtime().password());
  }

  static Connection migrator(LocalTestServices services) throws SQLException {
    return DriverManager.getConnection(
        services.migrator().jdbcUrl(), services.migrator().user(), services.migrator().password());
  }

  @Test
  void rlsDefaultDenyContextIsolationAndPoolReuse() throws Exception {
    try (LocalTestServices services = LocalTestServices.start()) {
      String acctA = "11111111-1111-4111-8111-111111111111";
      String acctB = "22222222-2222-4222-8222-222222222222";
      // 用 migrator（受限库 owner）写入两账户：只测试准备数据，业务路径必须用受限角色 + 上下文。
      try (Connection migrator = migrator(services)) {
        insertUser(migrator, acctA, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        insertUser(migrator, acctB, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
      }
      try (Connection runtime = runtime(services)) {
        runtime.setAutoCommit(true);
        // 无上下文：默认拒绝，看不到任何行。
        assertThat(countUsers(runtime)).isEqualTo(0);

        // 事务内设置账户 A：只看到 A。
        runtime.setAutoCommit(false);
        setAccountContext(runtime, acctA);
        assertThat(countUsers(runtime)).isEqualTo(1);
        try (Statement st = runtime.createStatement();
            ResultSet rs = st.executeQuery("SELECT id FROM users")) {
          rs.next();
          assertThat(rs.getString(1)).isEqualTo(acctA);
        }
        runtime.commit();

        // 事务提交后上下文自动清除（set_config(..., true) == 事务级）：再次无上下文即看不到行。
        assertThat(countUsers(runtime)).isEqualTo(0);

        // 池复用不串号：同一连接上开新事务、设置 B，仅看到 B。
        runtime.setAutoCommit(false);
        setAccountContext(runtime, acctB);
        try (Statement st = runtime.createStatement();
            ResultSet rs = st.executeQuery("SELECT id FROM users")) {
          rs.next();
          assertThat(rs.getString(1)).isEqualTo(acctB);
          assertThat(rs.next()).isFalse();
        }
        runtime.rollback();
      }
    }
  }

  @Test
  void runtimeAndMigratorRolesAreRestrictedAndRuntimeCannotDdl() throws Exception {
    try (LocalTestServices services = LocalTestServices.start()) {
      if (services.backend() instanceof ExternalBackend external) {
        external.assertRuntimeRoleRestricted();
        external.assertMigratorRoleRestricted();
      }
      try (Connection runtime = runtime(services)) {
        assertThatThrownBy(
                () -> {
                  try (Statement st = runtime.createStatement()) {
                    st.execute("CREATE TABLE should_not_exist(id int)");
                  }
                })
            .isInstanceOf(SQLException.class);
        assertThat(countUsers(runtime)).isEqualTo(0);

        try (PreparedStatement st =
            runtime.prepareStatement("SELECT vaultone_lookup_account_id(?)")) {
          st.setBytes(1, "nobody".getBytes());
          try (ResultSet rs = st.executeQuery()) {
            assertThat(rs.next()).isTrue();
            assertThat(rs.getString(1)).isNull();
          }
        }
        try (PreparedStatement st = runtime.prepareStatement("SELECT vaultone_email_exists(?)")) {
          st.setBytes(1, "nobody".getBytes());
          try (ResultSet rs = st.executeQuery()) {
            assertThat(rs.next()).isTrue();
            assertThat(rs.getBoolean(1)).isFalse();
          }
        }
      }
    }
  }

  /** definer 函数必须指向真正的 public 表：运行会话建同名临时表也不能污染特权操作。 */
  @Test
  void definerFunctionsResistTempTableShadowing() throws Exception {
    try (LocalTestServices services = LocalTestServices.start()) {
      String accountId = "33333333-3333-4333-8333-333333333333";
      byte[] emailHash = "shadow@example.test".getBytes();
      try (Connection migrator = migrator(services);
          PreparedStatement st =
              migrator.prepareStatement(
                  "INSERT INTO users(id, email_hash, email_enc, kdf, srp_salt, srp_verifier, vault_id,"
                      + " vk_wrap, vk_gen, recovery_wrap, recovery_auth_hash, session_epoch, created_at,"
                      + " updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 1, ?, ?)")) {
        st.setString(1, accountId);
        st.setBytes(2, emailHash);
        st.setBytes(3, new byte[] {1});
        st.setString(
            4,
            "{\"alg\":\"argon2id\",\"m\":8,\"t\":1,\"p\":1,\"salt\":\"AAAAAAAAAAAAAAAAAAAAAA==\"}");
        st.setBytes(5, new byte[16]);
        st.setBytes(6, new byte[] {1});
        st.setString(7, "shadow-vault");
        st.setBytes(8, new byte[] {1});
        st.setBytes(9, new byte[] {1});
        st.setBytes(10, new byte[] {1});
        st.setString(11, "2026-01-01T00:00:00Z");
        st.setString(12, "2026-01-01T00:00:00Z");
        st.executeUpdate();
      }
      try (Connection runtime = runtime(services)) {
        // 运行会话建立同名临时表，若不限定 schema 会遮蔽 public.users。
        try (Statement st = runtime.createStatement()) {
          st.execute("CREATE TEMP TABLE users(x int)");
        }
        try (Statement st = runtime.createStatement();
            ResultSet rs = st.executeQuery("SELECT count(*) FROM users")) {
          rs.next();
          assertThat(rs.getInt(1)).as("会话内裸查询确实看到临时表").isEqualTo(0);
        }
        // definer 函数仍读 public.users。
        try (PreparedStatement st = runtime.prepareStatement("SELECT vaultone_email_exists(?)")) {
          st.setBytes(1, emailHash);
          try (ResultSet rs = st.executeQuery()) {
            rs.next();
            assertThat(rs.getBoolean(1)).as("definer 必须读 public.users 而非临时表").isTrue();
          }
        }
        try (PreparedStatement st =
            runtime.prepareStatement("SELECT vaultone_lookup_account_id(?)")) {
          st.setBytes(1, emailHash);
          try (ResultSet rs = st.executeQuery()) {
            rs.next();
            assertThat(rs.getString(1)).isEqualTo(accountId);
          }
        }
      }
    }
  }

  /** handshakes 无直接表权限：无上下文直接读写被拒；窄函数可用。 */
  @Test
  void handshakesHaveNoDirectRuntimeAccessButFunctionsWork() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        Connection runtime = runtime(services)) {
      assertThatThrownBy(
              () -> {
                try (Statement st = runtime.createStatement();
                    ResultSet rs = st.executeQuery("SELECT count(*) FROM handshakes")) {
                  rs.next();
                }
              })
          .as("运行角色不得直接 SELECT handshakes")
          .isInstanceOf(SQLException.class);
      assertThatThrownBy(
              () -> {
                try (Statement st = runtime.createStatement()) {
                  st.execute("DELETE FROM handshakes");
                }
              })
          .as("运行角色不得直接 DELETE handshakes")
          .isInstanceOf(SQLException.class);

      // 经窄函数：写入 + 原子领取成功。
      String id = UUID.randomUUID().toString();
      try (PreparedStatement st =
          runtime.prepareStatement("SELECT vaultone_insert_handshake(?, ?, ?, ?)")) {
        st.setString(1, id);
        st.setString(2, null);
        st.setBytes(3, new byte[] {1, 2, 3});
        st.setString(4, "2999-01-01T00:00:00Z");
        st.executeQuery();
      }
      try (PreparedStatement st =
          runtime.prepareStatement(
              "SELECT user_id, b_enc, expires_at FROM vaultone_claim_handshake(?)")) {
        st.setString(1, id);
        try (ResultSet rs = st.executeQuery()) {
          assertThat(rs.next()).isTrue();
          assertThat(rs.getBytes(2)).containsExactly(1, 2, 3);
        }
      }
      // 领取即删除：再次领取为空。
      try (PreparedStatement st =
          runtime.prepareStatement("SELECT user_id FROM vaultone_claim_handshake(?)")) {
        st.setString(1, id);
        try (ResultSet rs = st.executeQuery()) {
          assertThat(rs.next()).isFalse();
        }
      }
    }
  }

  /** 清理过期握手：有界（单次 ≤500）且以服务端当前时间为上界，未来阈值不误删有效挑战。 */
  @Test
  void purgeExpiredHandshakesIsBoundedAndClampedToServerTime() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        Connection runtime = runtime(services)) {
      // 一个尚未过期的挑战。
      String valid = UUID.randomUUID().toString();
      insertHandshake(runtime, valid, "2999-01-01T00:00:00Z");
      // 三个已过期。
      for (int i = 0; i < 3; i++) {
        insertHandshake(runtime, UUID.randomUUID().toString(), "2000-01-01T00:00:00Z");
      }
      // 传入未来阈值：服务端按 now() 钳制，过期项被删，有效项保留。
      assertThat(purge(runtime, "2999-12-31T00:00:00Z")).isGreaterThanOrEqualTo(3);
      assertThat(claim(runtime, valid)).isTrue();

      // 有界：插入 600 条过期，单次最多删 500。
      for (int i = 0; i < 600; i++) {
        insertHandshake(runtime, UUID.randomUUID().toString(), "2000-01-01T00:00:00Z");
      }
      assertThat(purge(runtime, "2999-12-31T00:00:00Z")).isEqualTo(500);
      assertThat(purge(runtime, "2999-12-31T00:00:00Z")).isEqualTo(100);
    }
  }

  /** revinfo 与 _AUD 表账户隔离：跨账户不可见/不可写，无上下文不可写。 */
  @Test
  void revinfoIsAccountScoped() throws Exception {
    try (LocalTestServices services = LocalTestServices.start()) {
      String acctA = "77777777-7777-4777-8777-777777777777";
      String acctB = "88888888-8888-4888-8888-888888888888";
      try (Connection migrator = migrator(services)) {
        insertUser(migrator, acctA, "a-vault");
        insertUser(migrator, acctB, "b-vault");
      }
      try (Connection runtime = runtime(services)) {
        runtime.setAutoCommit(false);
        // 无上下文写入 revinfo：WITH CHECK 拒绝。
        assertThatThrownBy(
                () -> {
                  try (PreparedStatement st =
                      runtime.prepareStatement(
                          "INSERT INTO revinfo(revtstmp, user_id, request_id) VALUES(0, ?, 'r')")) {
                    st.setString(1, acctA);
                    st.executeUpdate();
                  }
                })
            .isInstanceOf(SQLException.class);
        runtime.rollback();

        // 上下文 A 写入成功。
        runtime.setAutoCommit(false);
        setAccountContext(runtime, acctA);
        try (PreparedStatement st =
            runtime.prepareStatement(
                "INSERT INTO revinfo(revtstmp, user_id, request_id) VALUES(0, ?, 'r')")) {
          st.setString(1, acctA);
          st.executeUpdate();
        }
        assertThat(countRevinfo(runtime)).isEqualTo(1);
        runtime.commit();

        // 上下文 B 看不到 A 的修订；删除影响 0 行。
        runtime.setAutoCommit(false);
        setAccountContext(runtime, acctB);
        assertThat(countRevinfo(runtime)).isEqualTo(0);
        try (PreparedStatement st =
            runtime.prepareStatement("DELETE FROM revinfo WHERE user_id = ?")) {
          st.setString(1, acctA);
          assertThat(st.executeUpdate()).isEqualTo(0);
        }
        runtime.rollback();
      }
    }
  }

  private static void insertHandshake(Connection connection, String id, String expiresAt)
      throws SQLException {
    try (PreparedStatement st =
        connection.prepareStatement("SELECT vaultone_insert_handshake(?, ?, ?, ?)")) {
      st.setString(1, id);
      st.setString(2, null);
      st.setBytes(3, new byte[] {9});
      st.setString(4, expiresAt);
      st.executeQuery();
    }
  }

  private static int purge(Connection connection, String now) throws SQLException {
    try (PreparedStatement st =
        connection.prepareStatement("SELECT vaultone_purge_expired_handshakes(?)")) {
      st.setString(1, now);
      try (ResultSet rs = st.executeQuery()) {
        rs.next();
        return rs.getInt(1);
      }
    }
  }

  private static boolean claim(Connection connection, String id) throws SQLException {
    try (PreparedStatement st =
        connection.prepareStatement("SELECT user_id FROM vaultone_claim_handshake(?)")) {
      st.setString(1, id);
      try (ResultSet rs = st.executeQuery()) {
        return rs.next();
      }
    }
  }

  private static int countRevinfo(Connection connection) throws SQLException {
    try (Statement st = connection.createStatement();
        ResultSet rs = st.executeQuery("SELECT count(*) FROM revinfo")) {
      rs.next();
      return rs.getInt(1);
    }
  }
}
