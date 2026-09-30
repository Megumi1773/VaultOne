package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.service.IdentityService;
import app.vaultone.server.proto.AccountKeys;
import app.vaultone.server.proto.Bytes;
import app.vaultone.server.proto.DeviceInfo;
import app.vaultone.server.proto.KdfParams;
import app.vaultone.server.proto.Platform;
import app.vaultone.server.proto.RecoveryCompleteRequest;
import app.vaultone.server.proto.RecoveryFetchRequest;
import app.vaultone.server.proto.RegisterRequest;
import app.vaultone.server.security.SessionStoreUnavailableException;
import app.vaultone.server.support.LocalTestServices;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.ArrayList;
import java.util.Base64;
import java.util.UUID;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.Test;
import org.redisson.api.RedissonClient;

class IdentityTransactionIT {
  private static final byte[] RECOVERY_AUTH = new byte[] {1, 2, 3, 4};

  @Test
  void redisPreparationFailureCannotCreateAnAccount() throws Exception {
    try (var services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      var request = registration();
      context.getBean(RedissonClient.class).shutdown();
      assertThatThrownBy(
              () -> context.getBean(IdentityService.class).register(request, null, "redis-failure"))
          .isInstanceOf(SessionStoreUnavailableException.class);
      assertThat(
              count(
                  services, "SELECT count(*) FROM users WHERE id = ?", request.keys().accountId()))
          .isZero();
    }
  }

  @Test
  void failedRegistrationAuditRollsBackAccountAndPreparedSession() throws Exception {
    try (var services = LocalTestServices.start();
        var context = services.startServerApplication();
        var connection = connect(services)) {
      try (var statement = connection.createStatement()) {
        statement.execute(
            """
            CREATE FUNCTION reject_registration_audit() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'test audit rejection'; END $$;
            CREATE TRIGGER reject_registration_audit BEFORE INSERT ON audit_events
              FOR EACH ROW EXECUTE FUNCTION reject_registration_audit();
            """);
      }
      var request = registration();
      assertThatThrownBy(
              () -> context.getBean(IdentityService.class).register(request, null, "audit-failure"))
          .isInstanceOf(RuntimeException.class);
      assertThat(
              count(
                  services, "SELECT count(*) FROM users WHERE id = ?", request.keys().accountId()))
          .isZero();
      assertThat(
              count(
                  services,
                  "SELECT count(*) FROM devices WHERE user_id = ?",
                  request.keys().accountId()))
          .isZero();
      var keys =
          context
              .getBean(RedissonClient.class)
              .getKeys()
              .getKeysByPattern(services.redisNamespace() + "session:*");
      assertThat(keys.iterator().hasNext()).isFalse();
    }
  }

  @Test
  void concurrentRecoveryWithOneOldCredentialHasExactlyOneWinner() throws Exception {
    try (var services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      var identity = context.getBean(IdentityService.class);
      var registration = registration();
      identity.register(registration, null, "register");
      int threads = 4;
      var start = new CyclicBarrier(threads);
      var executor = Executors.newFixedThreadPool(threads);
      try {
        ArrayList<Future<Boolean>> results = new ArrayList<>();
        for (int i = 0; i < threads; i++) {
          int attempt = i;
          results.add(
              executor.submit(
                  () -> {
                    start.await();
                    var request =
                        new RecoveryCompleteRequest(
                            registration.email(),
                            Bytes.copyOf(RECOVERY_AUTH),
                            kdf(),
                            Bytes.copyOf(new byte[16]),
                            Bytes.copyOf(new byte[] {1}),
                            wrapped(),
                            wrapped(),
                            Bytes.copyOf(ServerKeys.sha256(new byte[] {(byte) (10 + attempt)})),
                            device());
                    try {
                      identity.recoveryComplete(request, null, "recover-" + attempt);
                      return true;
                    } catch (ApiException ex) {
                      assertThat(ex.code()).isEqualTo("auth_failed");
                      return false;
                    }
                  }));
        }
        int winners = 0;
        for (Future<Boolean> result : results) {
          if (result.get()) winners++;
        }
        assertThat(winners).isEqualTo(1);
      } finally {
        executor.shutdownNow();
      }
      assertThat(
              count(
                  services,
                  "SELECT count(*) FROM audit_events WHERE user_id = ? AND event = 'recovery_used'",
                  registration.keys().accountId()))
          .isEqualTo(1);
      assertThatThrownBy(
              () ->
                  identity.recoveryFetch(
                      new RecoveryFetchRequest(registration.email(), Bytes.copyOf(RECOVERY_AUTH)),
                      null))
          .isInstanceOf(ApiException.class);
    }
  }

  private static RegisterRequest registration() {
    String id = UUID.randomUUID().toString();
    var keys = new AccountKeys(id, UUID.randomUUID().toString(), kdf(), wrapped(), 1, wrapped());
    return new RegisterRequest(
        id + "@example.test",
        keys,
        Bytes.copyOf(new byte[16]),
        Bytes.copyOf(new byte[] {1}),
        Bytes.copyOf(ServerKeys.sha256(RECOVERY_AUTH)),
        device());
  }

  private static DeviceInfo device() {
    return new DeviceInfo(UUID.randomUUID().toString(), "transaction-test", Platform.LINUX);
  }

  private static KdfParams kdf() {
    return new KdfParams("argon2id", 8, 1, 1, Base64.getEncoder().encodeToString(new byte[16]));
  }

  private static Bytes wrapped() {
    byte[] value = new byte[94];
    value[0] = 1;
    value[1] = 1;
    return Bytes.copyOf(value);
  }

  private static Connection connect(LocalTestServices services) throws Exception {
    var migrator = services.migrator();
    return DriverManager.getConnection(migrator.jdbcUrl(), migrator.user(), migrator.password());
  }

  private static long count(LocalTestServices services, String sql, String id) throws Exception {
    try (var connection = connect(services);
        var statement = connection.prepareStatement(sql)) {
      connection.setAutoCommit(false);
      try (var scope =
          connection.prepareStatement("SELECT set_config('vaultone.account_id', ?, true)")) {
        scope.setString(1, id);
        scope.execute();
      }
      statement.setString(1, id);
      try (var rows = statement.executeQuery()) {
        rows.next();
        return rows.getLong(1);
      }
    }
  }
}
