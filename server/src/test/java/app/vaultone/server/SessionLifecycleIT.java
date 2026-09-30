package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.security.AccountGuard;
import app.vaultone.server.security.SessionMetadata;
import app.vaultone.server.security.SessionStore;
import app.vaultone.server.support.LocalTestServices;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.time.Instant;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 会话生命周期与授权的真实 PG/Redis 验证（收口 A2）。直接用真实 Spring 上下文中的 Bean（生产路径一致）， 不手写测试专用安全实现。
 *
 * <p>覆盖：Redis 会话 Hash/StringCodec 往返与受代次约束的原子续期、不复活删除键；AccountGuard 在真实 RLS + 受限运行角色下接受当前
 * principal、拒绝过期 session_epoch / 未知设备。
 */
class SessionLifecycleIT {

  @Test
  void redisSessionStoreRoundTripRenewAndNoRebuild() {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore store = context.getBean(SessionStore.class);
      String hash = "a2" + Long.toHexString(System.nanoTime());
      Instant now = Instant.now();
      SessionMetadata meta =
          new SessionMetadata("acct-x", "dev-x", 3L, 1L, now, now, now.plusSeconds(3600), true);

      store.put(hash, meta);
      SessionMetadata read = store.get(hash).orElseThrow();
      assertThat(read.userId()).isEqualTo("acct-x");
      assertThat(read.deviceEpoch()).isEqualTo(1L);
      assertThat(read.sessionEpoch()).isEqualTo(3L);

      // 代次一致且到期更晚 → 续期生效。
      assertThat(
              store.renewIfPresent(
                  hash, meta, new SessionStore.Renewal(now.plusSeconds(7200), now.plusSeconds(5))))
          .isTrue();
      assertThat(store.get(hash).orElseThrow().expiresAt()).isAfter(now.plusSeconds(3600));

      // 代次不一致 → 拒绝续期。
      SessionMetadata wrongEpoch =
          new SessionMetadata("acct-x", "dev-x", 4L, 1L, now, now, now.plusSeconds(3600), true);
      assertThat(
              store.renewIfPresent(
                  hash, wrongEpoch, new SessionStore.Renewal(now.plusSeconds(9000), now)))
          .isFalse();

      // 更早的到期不得缩短有效期。
      assertThat(
              store.renewIfPresent(
                  hash, meta, new SessionStore.Renewal(now.plusSeconds(100), now.plusSeconds(5))))
          .isFalse();

      // 删除后不因续期复活。
      store.delete(hash);
      assertThat(store.get(hash)).isEmpty();
      assertThat(
              store.renewIfPresent(
                  hash, meta, new SessionStore.Renewal(now.plusSeconds(9000), now.plusSeconds(5))))
          .isFalse();
    }
  }

  @Test
  void accountGuardAcceptsCurrentAndRejectsStaleEpochOrUnknownDevice() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      String accountId = "44444444-4444-4444-8444-444444444444";
      String deviceId = "d-4444";
      seedUserAndDevice(services, accountId, deviceId);
      AccountGuard guard = context.getBean(AccountGuard.class);
      PlatformTransactionManager txManager = context.getBean(PlatformTransactionManager.class);
      TransactionTemplate tx = new TransactionTemplate(txManager);

      // 当前 epoch=1 且设备已批准 → 接受。
      AccountGuard.Principal ok =
          tx.execute(
              status ->
                  guard.lock(
                      new AccountGuard.PrincipalRef(accountId, deviceId, 1L, 1L, "hash-ok")));
      assertThat(ok).isNotNull();
      assertThat(ok.approved()).isTrue();

      // 过期 session_epoch → 拒绝。
      assertThatThrownBy(
              () ->
                  tx.execute(
                      status ->
                          guard.lock(
                              new AccountGuard.PrincipalRef(
                                  accountId, deviceId, 0L, 1L, "hash-old"))))
          .isInstanceOf(ApiException.class);

      // 未知设备 → 拒绝。
      assertThatThrownBy(
              () ->
                  tx.execute(
                      status ->
                          guard.lock(
                              new AccountGuard.PrincipalRef(accountId, "nope", 1L, 1L, "hash-d"))))
          .isInstanceOf(ApiException.class);
    }
  }

  @Test
  void syncRevalidatesTheCapturedPrincipalInsideEveryTransaction() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      String accountId = "77777777-7777-4777-8777-777777777777";
      String deviceId = "d-7777";
      seedUserAndDevice(services, accountId, deviceId);
      var sync = context.getBean(app.vaultone.server.sync.SyncService.class);
      var captured =
          new app.vaultone.server.security.Approved(
              new app.vaultone.server.security.Authed(
                  accountId, deviceId, true, 1L, 1L, "hash-sync"));
      var emptyPush = new app.vaultone.server.proto.PushRequest(java.util.List.of());
      assertThat(sync.pull(captured, 0, null).items()).isEmpty();

      try (var admin =
          DriverManager.getConnection(
              services.admin().jdbcUrl(), services.admin().user(), services.admin().password())) {
        try (var update =
            admin.prepareStatement("UPDATE users SET session_epoch = 2 WHERE id = ?")) {
          update.setString(1, accountId);
          assertThat(update.executeUpdate()).isEqualTo(1);
        }
        assertThatThrownBy(() -> sync.pull(captured, 0, null)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> sync.push(captured, emptyPush)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> sync.wipeAccount(captured)).isInstanceOf(ApiException.class);

        try (var update =
            admin.prepareStatement(
                "UPDATE devices SET approved_at = NULL WHERE user_id = ? AND id = ?")) {
          update.setString(1, accountId);
          update.setString(2, deviceId);
          assertThat(update.executeUpdate()).isEqualTo(1);
        }
        var noLongerApproved =
            new app.vaultone.server.security.Approved(
                new app.vaultone.server.security.Authed(
                    accountId, deviceId, true, 2L, 1L, "hash-sync"));
        assertThatThrownBy(() -> sync.push(noLongerApproved, emptyPush))
            .isInstanceOf(ApiException.class)
            .satisfies(ex -> assertThat(((ApiException) ex).status()).isEqualTo(403));
      }
    }
  }

  @Test
  void concurrentCredentialsChangeOnlyOneWins() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      String accountId = "66666666-6666-4666-8666-666666666666";
      String deviceId = "d-6666";
      seedUserAndDevice(services, accountId, deviceId);
      var persistence =
          context.getBean(app.vaultone.server.account.service.AccountPersistence.class);
      app.vaultone.server.security.Approved approved =
          new app.vaultone.server.security.Approved(
              new app.vaultone.server.security.Authed(accountId, deviceId, true, 1L, 1L, "hash-c"));

      // 同 expectedVkGen=2 并发：账户行悲观锁下只能一胜。
      int threads = 4;
      var barrier = new java.util.concurrent.CyclicBarrier(threads);
      var pool = java.util.concurrent.Executors.newFixedThreadPool(threads);
      var futures = new java.util.ArrayList<java.util.concurrent.Future<Boolean>>();
      for (int i = 0; i < threads; i++) {
        futures.add(
            pool.submit(
                () -> {
                  barrier.await();
                  // 模拟真实请求：解析器在调用业务前设置 PrincipalHolder，供审计上下文使用。
                  app.vaultone.server.security.PrincipalHolder.set(approved.authed());
                  try {
                    persistence.changeCredentials(approved, credentialsRequest(2L), true);
                    return true;
                  } catch (app.vaultone.server.common.ApiException ex) {
                    return false;
                  } finally {
                    app.vaultone.server.security.PrincipalHolder.clear();
                  }
                }));
      }
      int winners = 0;
      for (var f : futures) {
        if (f.get()) {
          winners++;
        }
      }
      pool.shutdownNow();
      assertThat(winners).isEqualTo(1);
    }
  }

  private static app.vaultone.server.proto.ChangeCredentialsRequest credentialsRequest(
      long newGen) {
    byte[] vkWrap = new byte[94];
    vkWrap[0] = 1;
    vkWrap[1] = 1;
    return new app.vaultone.server.proto.ChangeCredentialsRequest(
        new app.vaultone.server.proto.KdfParams(
            "argon2id", 8, 1, 1, java.util.Base64.getEncoder().encodeToString(new byte[16])),
        app.vaultone.server.proto.Bytes.copyOf(new byte[16]),
        app.vaultone.server.proto.Bytes.copyOf(new byte[] {1}),
        app.vaultone.server.proto.Bytes.copyOf(vkWrap),
        newGen,
        null,
        null);
  }

  private static void seedUserAndDevice(
      LocalTestServices services, String accountId, String deviceId) throws SQLException {
    try (Connection admin =
        DriverManager.getConnection(
            services.admin().jdbcUrl(), services.admin().user(), services.admin().password())) {
      try (PreparedStatement st =
          admin.prepareStatement(
              "INSERT INTO users(id, email_hash, email_enc, kdf, srp_salt, srp_verifier, vault_id,"
                  + " vk_wrap, vk_gen, recovery_wrap, recovery_auth_hash, session_epoch, created_at,"
                  + " updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 1, ?, ?)")) {
        st.setString(1, accountId);
        st.setBytes(2, (accountId + "-hash").getBytes());
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
      try (PreparedStatement st =
          admin.prepareStatement(
              "INSERT INTO devices(user_id, id, name, platform, approved_at, approved_by,"
                  + " last_seen_at, revoked_at, epoch, created_at)"
                  + " VALUES(?, ?, ?, ?, ?, ?, ?, NULL, 1, ?)")) {
        st.setString(1, accountId);
        st.setString(2, deviceId);
        st.setString(3, "IT device");
        st.setString(4, "linux");
        st.setString(5, "2026-01-01T00:00:00Z");
        st.setString(6, "registration");
        st.setString(7, "2026-01-01T00:00:00Z");
        st.setString(8, "2026-01-01T00:00:00Z");
        st.executeUpdate();
      }
    }
  }
}
