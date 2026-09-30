package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.security.SessionMetadata;
import app.vaultone.server.security.SessionStore;
import app.vaultone.server.security.SessionTokens;
import app.vaultone.server.support.LocalTestServices;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.Test;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;
import tools.jackson.databind.json.JsonMapper;

/**
 * OTP 校验的真实 HTTP + PG/Redis 回归（收口 A3）。
 *
 * <p>关键回归：OTP 失败计数必须**跨请求累积提交**——外层服务异常（400）不得回滚已提交的 attempts。 之前 {@code
 * IdentityService.verifyDevice} 被 {@code @Transactional} 包裹，内层事务提交的计数随外层 400 回滚，
 * 导致同一密码版本可被无限尝试。本测试从真实 HTTP 入口连续输错，直连数据库核验 attempts 真实增长到上限。
 *
 * <p>同时覆盖：最后 1 份额度并发仅一次 MISMATCH、其余 exhausted；正确码成功且 device/audit/Envers 一致、 重复验证无额外审计；设备撤销/epoch
 * 失效拒绝且 OTP 未被消耗。
 */
class OTPIntegrationIT {
  private static final JsonMapper JSON = JsonMapper.builder().build();

  private record Seeded(String accountId, String deviceId, String token) {}

  private static Seeded seed(LocalTestServices services, SessionStore sessions, ServerKeys keys)
      throws SQLException {
    String accountId =
        "77777777-7777-4777-8777-" + String.format("%012d", System.nanoTime() % 1_000_000_000_000L);
    String deviceId = "otp-dev-1";
    try (Connection admin =
        DriverManager.getConnection(
            services.admin().jdbcUrl(), services.admin().user(), services.admin().password())) {
      setAccountContext(admin, accountId);
      try (PreparedStatement st =
          admin.prepareStatement(
              "INSERT INTO users(id, email_hash, email_enc, kdf, srp_salt, srp_verifier, vault_id,"
                  + " vk_wrap, vk_gen, recovery_wrap, recovery_auth_hash, session_epoch, created_at,"
                  + " updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 1, ?, ?)")) {
        st.setString(1, accountId);
        st.setBytes(2, (accountId + "-h").getBytes(StandardCharsets.UTF_8));
        st.setBytes(3, new byte[] {1});
        st.setString(
            4,
            "{\"alg\":\"argon2id\",\"m\":8,\"t\":1,\"p\":1,\"salt\":\"AAAAAAAAAAAAAAAAAAAAAA==\"}");
        st.setBytes(5, new byte[16]);
        st.setBytes(6, new byte[] {1});
        st.setString(7, accountId + "-vault");
        st.setBytes(8, new byte[] {1});
        st.setBytes(9, new byte[] {1});
        st.setBytes(10, new byte[] {1});
        st.setString(11, "2026-01-01T00:00:00Z");
        st.setString(12, "2026-01-01T00:00:00Z");
        st.executeUpdate();
      }
      insertDevice(admin, accountId, deviceId);
    }
    // 已登录但未批准的设备会话（经 Redis 会话主存，与真实登录一致）。
    String token = SessionTokens.newToken();
    Instant now = Instant.now();
    sessions.put(
        SessionTokens.hashHex(token),
        new SessionMetadata(accountId, deviceId, 1L, 1L, now, now, now.plusSeconds(3600), false));
    return new Seeded(accountId, deviceId, token);
  }

  private static void insertDevice(Connection admin, String accountId, String deviceId)
      throws SQLException {
    try (PreparedStatement st =
        admin.prepareStatement(
            "INSERT INTO devices(user_id, id, name, platform, approved_at, approved_by,"
                + " last_seen_at, revoked_at, epoch, created_at)"
                + " VALUES(?, ?, ?, ?, NULL, NULL, ?, NULL, 1, ?)")) {
      st.setString(1, accountId);
      st.setString(2, deviceId);
      st.setString(3, "OTP device");
      st.setString(4, "linux");
      st.setString(5, "2026-01-01T00:00:00Z");
      st.setString(6, "2026-01-01T00:00:00Z");
      st.executeUpdate();
    }
  }

  private static void seedOtp(
      LocalTestServices services, ServerKeys keys, Seeded seeded, String code) throws SQLException {
    byte[] hash = keys.otpHash(seeded.accountId(), seeded.deviceId(), code);
    try (Connection admin =
        DriverManager.getConnection(
            services.admin().jdbcUrl(), services.admin().user(), services.admin().password())) {
      // 迁移/管理角色同样受 FORCE RLS 约束，测试准备需先设账户上下文。
      setAccountContext(admin, seeded.accountId());
      try (PreparedStatement del =
          admin.prepareStatement("DELETE FROM device_otps WHERE user_id = ? AND device_id = ?")) {
        del.setString(1, seeded.accountId());
        del.setString(2, seeded.deviceId());
        del.executeUpdate();
      }
      try (PreparedStatement st =
          admin.prepareStatement(
              "INSERT INTO device_otps(user_id, device_id, code_hash, expires_at, attempts)"
                  + " VALUES(?, ?, ?, ?, 0)")) {
        st.setString(1, seeded.accountId());
        st.setString(2, seeded.deviceId());
        st.setBytes(3, hash);
        st.setString(4, Instant.now().plusSeconds(600).toString());
        st.executeUpdate();
      }
    }
  }

  private static void setAccountContext(Connection connection, String accountId)
      throws SQLException {
    try (PreparedStatement st =
        connection.prepareStatement("SELECT set_config('vaultone.account_id', ?, false)")) {
      st.setString(1, accountId);
      st.executeQuery();
    }
  }

  private static int readAttempts(LocalTestServices services, Seeded seeded) throws SQLException {
    try (Connection admin =
        DriverManager.getConnection(
            services.admin().jdbcUrl(), services.admin().user(), services.admin().password())) {
      setAccountContext(admin, seeded.accountId());
      try (PreparedStatement st =
          admin.prepareStatement(
              "SELECT attempts FROM device_otps WHERE user_id = ? AND device_id = ?")) {
        st.setString(1, seeded.accountId());
        st.setString(2, seeded.deviceId());
        try (ResultSet rs = st.executeQuery()) {
          return rs.next() ? rs.getInt(1) : -1;
        }
      }
    }
  }

  private static boolean deviceApproved(LocalTestServices services, Seeded seeded)
      throws SQLException {
    try (Connection admin =
        DriverManager.getConnection(
            services.admin().jdbcUrl(), services.admin().user(), services.admin().password())) {
      setAccountContext(admin, seeded.accountId());
      try (PreparedStatement st =
          admin.prepareStatement("SELECT approved_at FROM devices WHERE user_id = ? AND id = ?")) {
        st.setString(1, seeded.accountId());
        st.setString(2, seeded.deviceId());
        try (ResultSet rs = st.executeQuery()) {
          return rs.next() && rs.getString(1) != null;
        }
      }
    }
  }

  private static int auditCount(LocalTestServices services, Seeded seeded) throws SQLException {
    try (Connection admin =
        DriverManager.getConnection(
            services.admin().jdbcUrl(), services.admin().user(), services.admin().password())) {
      setAccountContext(admin, seeded.accountId());
      try (PreparedStatement st =
          admin.prepareStatement(
              "SELECT count(*) FROM audit_events WHERE user_id = ? AND device_id = ? AND event = 'device_approved'")) {
        st.setString(1, seeded.accountId());
        st.setString(2, seeded.deviceId());
        try (ResultSet rs = st.executeQuery()) {
          return rs.next() ? rs.getInt(1) : -1;
        }
      }
    }
  }

  private static int enversCount(LocalTestServices services, Seeded seeded) throws SQLException {
    try (Connection admin =
        DriverManager.getConnection(
            services.admin().jdbcUrl(), services.admin().user(), services.admin().password())) {
      setAccountContext(admin, seeded.accountId());
      try (PreparedStatement st =
          admin.prepareStatement("SELECT count(*) FROM devices_aud WHERE user_id = ? AND id = ?")) {
        st.setString(1, seeded.accountId());
        st.setString(2, seeded.deviceId());
        try (ResultSet rs = st.executeQuery()) {
          return rs.next() ? rs.getInt(1) : -1;
        }
      }
    }
  }

  private static HttpResponse<String> verify(int port, String token, String code) throws Exception {
    try (HttpClient client = HttpClient.newHttpClient()) {
      return client.send(
          HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/v1/devices/self/verify"))
              .header("Authorization", "Bearer " + token)
              .header("Content-Type", "application/json")
              .POST(HttpRequest.BodyPublishers.ofString("{\"code\":\"" + code + "\"}"))
              .build(),
          HttpResponse.BodyHandlers.ofString());
    }
  }

  @Test
  void wrongCodesAccumulateCommittedAttemptsAndExhaustWithinCodeVersion() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore sessions = context.getBean(SessionStore.class);
      ServerKeys keys = context.getBean(ServerKeys.class);
      int port = ((ServletWebServerApplicationContext) context).getWebServer().getPort();
      Seeded seeded = seed(services, sessions, keys);
      seedOtp(services, keys, seeded, "000123");

      // 连续 4 次错误：每次返回 400，且 attempts 必须在数据库真实累积（外层不得回滚）。
      for (int i = 1; i <= 4; i++) {
        HttpResponse<String> resp = verify(port, seeded.token(), "999999");
        assertThat(resp.statusCode()).isEqualTo(400);
        assertThat(readAttempts(services, seeded)).as("第 %d 次错误后 attempts 应提交", i).isEqualTo(i);
      }

      // 第 5 次错误：达到上限。
      assertThat(verify(port, seeded.token(), "999999").statusCode()).isEqualTo(400);
      assertThat(readAttempts(services, seeded)).isEqualTo(5);

      // 达到上限后即使输对也失败（同一密码版本用尽）。
      assertThat(verify(port, seeded.token(), "000123").statusCode()).isEqualTo(400);
      assertThat(deviceApproved(services, seeded)).isFalse();
    }
  }

  @Test
  void successConsumesOtpApprovesDeviceAuditsOnceAndIsIdempotent() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore sessions = context.getBean(SessionStore.class);
      ServerKeys keys = context.getBean(ServerKeys.class);
      int port = ((ServletWebServerApplicationContext) context).getWebServer().getPort();
      Seeded seeded = seed(services, sessions, keys);
      seedOtp(services, keys, seeded, "000123");

      assertThat(verify(port, seeded.token(), "000123").statusCode()).isEqualTo(200);
      assertThat(deviceApproved(services, seeded)).isTrue();
      assertThat(readAttempts(services, seeded)).isEqualTo(-1); // OTP 已消费删除
      assertThat(auditCount(services, seeded)).isEqualTo(1);
      assertThat(enversCount(services, seeded)).isGreaterThanOrEqualTo(1);

      // 重复验证：幂等，不新增审计、不报错。
      assertThat(verify(port, seeded.token(), "000123").statusCode()).isEqualTo(200);
      assertThat(auditCount(services, seeded)).isEqualTo(1);
    }
  }

  @Test
  void lastQuotaConcurrentOnlyOneMismatchOthersExhausted() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore sessions = context.getBean(SessionStore.class);
      ServerKeys keys = context.getBean(ServerKeys.class);
      int port = ((ServletWebServerApplicationContext) context).getWebServer().getPort();
      Seeded seeded = seed(services, sessions, keys);
      seedOtp(services, keys, seeded, "000123");

      // 先错 4 次（提交），只剩最后 1 份额度。
      for (int i = 0; i < 4; i++) {
        assertThat(verify(port, seeded.token(), "999999").statusCode()).isEqualTo(400);
      }
      assertThat(readAttempts(services, seeded)).isEqualTo(4);

      // 并发同时输错：只有一次能拿到最后额度（MISMATCH，attempts→5），其余 exhausted。
      int threads = 5;
      var barrier = new CyclicBarrier(threads);
      ExecutorService pool = Executors.newFixedThreadPool(threads);
      List<Future<Integer>> futures = new ArrayList<>();
      for (int i = 0; i < threads; i++) {
        futures.add(
            pool.submit(
                (Callable<Integer>)
                    () -> {
                      barrier.await();
                      return verify(port, seeded.token(), "999999").statusCode();
                    }));
      }
      int forbidden = 0;
      for (Future<Integer> f : futures) {
        assertThat(f.get()).isEqualTo(400);
        forbidden++;
      }
      pool.shutdownNow();
      assertThat(forbidden).isEqualTo(threads);
      // 计数恰好到上限，未被并发重复自增超过上限。
      assertThat(readAttempts(services, seeded)).isLessThanOrEqualTo(5);
      assertThat(deviceApproved(services, seeded)).isFalse();
    }
  }

  @Test
  void revokedDeviceOrStaleEpochRejectedWithoutConsumingOtp() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore sessions = context.getBean(SessionStore.class);
      ServerKeys keys = context.getBean(ServerKeys.class);
      int port = ((ServletWebServerApplicationContext) context).getWebServer().getPort();
      Seeded seeded = seed(services, sessions, keys);
      seedOtp(services, keys, seeded, "000123");

      // 撤销设备（epoch 仍 1，但 revoked_at 非空）。
      try (Connection admin =
          DriverManager.getConnection(
              services.admin().jdbcUrl(), services.admin().user(), services.admin().password())) {
        setAccountContext(admin, seeded.accountId());
        try (PreparedStatement st =
            admin.prepareStatement(
                "UPDATE devices SET revoked_at = ? WHERE user_id = ? AND id = ?")) {
          st.setString(1, Instant.now().toString());
          st.setString(2, seeded.accountId());
          st.setString(3, seeded.deviceId());
          st.executeUpdate();
        }
      }
      assertThat(verify(port, seeded.token(), "000123").statusCode()).isEqualTo(401);
      assertThat(readAttempts(services, seeded)).isEqualTo(0); // 未被消耗、未计数
      assertThat(deviceApproved(services, seeded)).isFalse();
    }
  }
}
