package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.account.service.AccountPersistence;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.common.ApiException;
import app.vaultone.server.common.MailSender;
import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.service.DeviceListCache;
import app.vaultone.server.identity.service.DevicePersistence;
import app.vaultone.server.identity.service.DeviceService;
import app.vaultone.server.proto.DeviceOut;
import app.vaultone.server.security.Approved;
import app.vaultone.server.security.Authed;
import app.vaultone.server.security.PrincipalHolder;
import app.vaultone.server.security.SessionMetadata;
import app.vaultone.server.security.SessionStore;
import app.vaultone.server.support.LocalTestServices;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.redisson.api.RScoredSortedSet;
import org.redisson.api.RedissonClient;
import org.redisson.client.codec.StringCodec;

/**
 * 设备展示缓存与按设备会话索引的真实 PG/Redis 验证（收口 C3）。
 *
 * <p>覆盖：cache-aside（第二次命中缓存但仍新鲜 PG 授权）、current 按请求设备映射、批准/撤销提交后失效、缓存故障保守回源；
 * 以及按账户/设备摘要索引的定向清理（不误删其他设备/账户）、创建/续期 TTL、删除与过期成员有界清理。绝不 FLUSH。
 */
class DeviceCacheSessionIT {

  // ───────────────────────── 设备展示缓存 ─────────────────────────

  @Test
  void listServesFromCacheButRevalidatesAuthorization() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      String acct = "a1111111-1111-4111-8111-111111111111";
      seedUser(services, acct);
      seedDevice(services, acct, "d1", "Device One", "linux", true, 1);
      seedDevice(services, acct, "d2", "Device Two", "windows", true, 1);
      DeviceService devices = context.getBean(DeviceService.class);
      RedissonClient redis = context.getBean(RedissonClient.class);
      String ns = services.redisNamespace();
      Approved asD1 = approved(acct, "d1");
      try {
        List<DeviceOut> first = devices.listDevices(asD1);
        assertThat(first).extracting(DeviceOut::id).containsExactlyInAnyOrder("d1", "d2");
        assertThat(first)
            .filteredOn(d -> d.id().equals("d1"))
            .singleElement()
            .satisfies(d -> assertThat(d.current()).isTrue());
        assertThat(first)
            .filteredOn(d -> d.id().equals("d2"))
            .singleElement()
            .satisfies(d -> assertThat(d.current()).isFalse());
        assertThat(keys(redis, ns + "cache:devices:*")).isNotEmpty();

        // 直接改库（绕过服务）：第二次仍返回缓存旧名，证明命中缓存未读整表。
        renameDeviceDirect(services, acct, "d2", "Renamed In DB");
        List<DeviceOut> second = devices.listDevices(asD1);
        assertThat(second)
            .filteredOn(d -> d.id().equals("d2"))
            .singleElement()
            .satisfies(d -> assertThat(d.name()).isEqualTo("Device Two"));

        // 直接撤销调用者设备：新鲜 PG 授权必须拒绝，证明授权不来自缓存。
        revokeDeviceDirect(services, acct, "d1");
        assertThatThrownBy(() -> devices.listDevices(asD1)).isInstanceOf(ApiException.class);
      } finally {
        redis.getKeys().deleteByPattern(ns + "cache:devices:*");
      }
    }
  }

  @Test
  void currentMarkerIsPerRequestDevice() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      String acct = "a2222222-2222-4222-8222-222222222222";
      seedUser(services, acct);
      seedDevice(services, acct, "d1", "One", "linux", true, 1);
      seedDevice(services, acct, "d2", "Two", "windows", true, 1);
      DeviceService devices = context.getBean(DeviceService.class);
      RedissonClient redis = context.getBean(RedissonClient.class);
      String ns = services.redisNamespace();
      try {
        List<DeviceOut> asD1 = devices.listDevices(approved(acct, "d1"));
        assertThat(currentOf(asD1, "d1")).isTrue();
        assertThat(currentOf(asD1, "d2")).isFalse();

        // 第二次以 d2 请求：缓存条目与请求者无关，current 必须映射到 d2。
        List<DeviceOut> asD2 = devices.listDevices(approved(acct, "d2"));
        assertThat(currentOf(asD2, "d2")).isTrue();
        assertThat(currentOf(asD2, "d1")).isFalse();
      } finally {
        redis.getKeys().deleteByPattern(ns + "cache:devices:*");
      }
    }
  }

  @Test
  void approveAndRevokeInvalidateCacheAfterCommit() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      String acct = "a3333333-3333-4333-8333-333333333333";
      seedUser(services, acct);
      seedDevice(services, acct, "d1", "One", "linux", true, 1);
      seedDevice(services, acct, "d2", "Two", "windows", false, 1);
      DeviceService devices = context.getBean(DeviceService.class);
      RedissonClient redis = context.getBean(RedissonClient.class);
      String ns = services.redisNamespace();
      Approved asD1 = approved(acct, "d1");
      PrincipalHolder.set(asD1.authed());
      try {
        List<DeviceOut> before = devices.listDevices(asD1);
        assertThat(approvedOf(before, "d2")).isFalse();

        devices.approveDevice(asD1, "d2", new byte[] {1}, "req-approve");
        List<DeviceOut> afterApprove = devices.listDevices(asD1);
        assertThat(approvedOf(afterApprove, "d2")).isTrue();

        devices.revokeDevice(asD1, "d2", new byte[] {1}, "req-revoke");
        List<DeviceOut> afterRevoke = devices.listDevices(asD1);
        assertThat(afterRevoke)
            .filteredOn(d -> d.id().equals("d2"))
            .singleElement()
            .satisfies(d -> assertThat(d.revokedAt()).isNotNull());
      } finally {
        PrincipalHolder.clear();
        redis.getKeys().deleteByPattern(ns + "cache:devices:*");
      }
    }
  }

  @Test
  void cacheFailureFallsBackToSource() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      String acct = "a4444444-4444-4444-8444-444444444444";
      seedUser(services, acct);
      seedDevice(services, acct, "d1", "One", "linux", true, 1);
      seedDevice(services, acct, "d2", "Two", "windows", true, 1);

      RedissonClient broken =
          (RedissonClient)
              Proxy.newProxyInstance(
                  RedissonClient.class.getClassLoader(),
                  new Class<?>[] {RedissonClient.class},
                  (proxy, method, args) -> {
                    throw new RuntimeException("redis down");
                  });
      DeviceListCache failingCache =
          new DeviceListCache(broken, context.getBean(VaultOneProperties.class));
      // 缓存读失败保守返回空，不冒充命中。
      assertThat(failingCache.get(acct)).isEmpty();

      DeviceService devices =
          new DeviceService(
              context.getBean(DevicePersistence.class),
              context.getBean(AccountPersistence.class),
              context.getBean(SessionStore.class),
              context.getBean(AuditService.class),
              context.getBean(MailSender.class),
              context.getBean(ServerKeys.class),
              failingCache);
      List<DeviceOut> list = devices.listDevices(approved(acct, "d1"));
      assertThat(list).extracting(DeviceOut::id).containsExactlyInAnyOrder("d1", "d2");
    }
  }

  // ───────────────────────── 按设备会话索引 ─────────────────────────

  @Test
  void sameSecondRenewalAndExpiredIndexPruningAreCorrect() {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore store = context.getBean(SessionStore.class);
      RedissonClient redis = context.getBean(RedissonClient.class);
      String userId = "time-" + System.nanoTime();
      String first = "a1" + Long.toHexString(System.nanoTime());
      String second = "a2" + Long.toHexString(System.nanoTime());
      Instant now = Instant.now();
      Instant wholeSecond =
          now.plusSeconds(3600).truncatedTo(java.time.temporal.ChronoUnit.SECONDS);
      SessionMetadata original = meta(userId, "device", wholeSecond);
      store.put(first, original);
      try {
        Instant laterInTheSameSecond = wholeSecond.plusMillis(500);
        assertThat(
                store.renewIfPresent(
                    first, original, new SessionStore.Renewal(laterInTheSameSecond, now)))
            .isTrue();
        assertThat(store.get(first).orElseThrow().expiresAt()).isEqualTo(laterInTheSameSecond);

        var deviceIndex = index(redis, services.redisNamespace(), userId, "device");
        for (int i = 0; i < 150; i++) {
          deviceIndex.add(now.minusSeconds(60).toEpochMilli(), "expired-" + i);
        }
        store.put(second, meta(userId, "device", wholeSecond.plusSeconds(60)));
        assertThat(deviceIndex.size()).isEqualTo(52);
        assertThat(deviceIndex.remainTimeToLive()).isPositive();
      } finally {
        store.deleteByDevice(userId, "device");
      }
      assertThat(store.get(first)).isEmpty();
      assertThat(store.get(second)).isEmpty();
    }
  }

  @Test
  void perDeviceSessionIndexTargetsOnlyThatDeviceAndBoundsTtl() {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore store = context.getBean(SessionStore.class);
      RedissonClient redis = context.getBean(RedissonClient.class);
      String ns = services.redisNamespace();
      String acctA = "acct-a-" + System.nanoTime();
      String acctB = "acct-b-" + System.nanoTime();
      Instant now = Instant.now();
      String a1 = "aa" + Long.toHexString(System.nanoTime());
      String a2 = "ab" + Long.toHexString(System.nanoTime());
      String b1 = "ba" + Long.toHexString(System.nanoTime());
      try {
        store.put(a1, meta(acctA, "devA", now.plusSeconds(3600)));
        store.put(a2, meta(acctA, "devA", now.plusSeconds(3600)));
        store.put(b1, meta(acctB, "devB", now.plusSeconds(3600)));

        RScoredSortedSet<String> idxA = index(redis, ns, acctA, "devA");
        RScoredSortedSet<String> idxB = index(redis, ns, acctB, "devB");
        assertThat(idxA.size()).isEqualTo(2);
        // 索引成员为 token 摘要，不含 raw token。
        assertThat(idxA.contains(a1)).isTrue();
        assertThat(idxB.size()).isEqualTo(1);
        assertThat(idxA.remainTimeToLive()).isGreaterThan(0L);

        // 续期：索引 score 与 TTL 随新到期时间刷新。
        Instant later = now.plusSeconds(7200);
        SessionMetadata storedA1 = store.get(a1).orElseThrow();
        assertThat(store.renewIfPresent(a1, storedA1, new SessionStore.Renewal(later, now)))
            .isTrue();
        assertThat(idxA.getScore(a1)).isEqualTo((double) later.toEpochMilli());
        assertThat(idxA.remainTimeToLive()).isGreaterThan(0L);

        // 定向清理 devA：只删 devA 会话，devB 与其他账户不受影响。
        store.deleteByDevice(acctA, "devA");
        assertThat(store.get(a1)).isEmpty();
        assertThat(store.get(a2)).isEmpty();
        assertThat(store.get(b1)).isPresent();
        assertThat(keys(redis, ns + "session:v1:idx:" + acctA + ":devA")).isEmpty();
        assertThat(keys(redis, ns + "session:v1:idx:" + acctB + ":devB")).isNotEmpty();

        // 过期成员有界清理：直接塞入一个已过期成员，定向清理时一并修剪。
        String acctC = "acct-c-" + System.nanoTime();
        String c1 = "cc" + Long.toHexString(System.nanoTime());
        store.put(c1, meta(acctC, "devC", now.plusSeconds(3600)));
        RScoredSortedSet<String> idxC = index(redis, ns, acctC, "devC");
        idxC.add(now.minusSeconds(60).toEpochMilli(), "expired-member");
        assertThat(idxC.size()).isEqualTo(2);
        store.deleteByDevice(acctC, "devC");
        assertThat(store.get(c1)).isEmpty();
        assertThat(keys(redis, ns + "session:v1:idx:" + acctC + ":devC")).isEmpty();
      } finally {
        redis.getKeys().deleteByPattern(ns + "session:*");
      }
    }
  }

  // ───────────────────────── helpers ─────────────────────────

  private static boolean currentOf(List<DeviceOut> list, String deviceId) {
    return list.stream().filter(d -> d.id().equals(deviceId)).findFirst().orElseThrow().current();
  }

  private static boolean approvedOf(List<DeviceOut> list, String deviceId) {
    return list.stream().filter(d -> d.id().equals(deviceId)).findFirst().orElseThrow().approved();
  }

  private static Approved approved(String accountId, String deviceId) {
    return new Approved(new Authed(accountId, deviceId, true, 1L, 1L, "hash-" + deviceId));
  }

  private static SessionMetadata meta(String userId, String deviceId, Instant expiresAt) {
    Instant now = Instant.now();
    return new SessionMetadata(userId, deviceId, 1L, 1L, now, now, expiresAt, true);
  }

  private static RScoredSortedSet<String> index(
      RedissonClient redis, String ns, String accountId, String deviceId) {
    return redis.getScoredSortedSet(
        ns + "session:v1:idx:" + accountId + ":" + deviceId, StringCodec.INSTANCE);
  }

  private static List<String> keys(RedissonClient redis, String pattern) {
    List<String> out = new ArrayList<>();
    for (String key : redis.getKeys().getKeysByPattern(pattern)) {
      out.add(key);
    }
    return out;
  }

  private static Connection admin(LocalTestServices services) throws SQLException {
    return DriverManager.getConnection(
        services.admin().jdbcUrl(), services.admin().user(), services.admin().password());
  }

  private static void seedUser(LocalTestServices services, String accountId) throws SQLException {
    try (Connection connection = admin(services);
        PreparedStatement st =
            connection.prepareStatement(
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
  }

  private static void seedDevice(
      LocalTestServices services,
      String accountId,
      String deviceId,
      String name,
      String platform,
      boolean approved,
      long epoch)
      throws SQLException {
    try (Connection connection = admin(services);
        PreparedStatement st =
            connection.prepareStatement(
                "INSERT INTO devices(user_id, id, name, platform, approved_at, approved_by,"
                    + " last_seen_at, revoked_at, epoch, created_at)"
                    + " VALUES(?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)")) {
      st.setString(1, accountId);
      st.setString(2, deviceId);
      st.setString(3, name);
      st.setString(4, platform);
      if (approved) {
        st.setString(5, "2026-01-01T00:00:00Z");
        st.setString(6, "registration");
      } else {
        st.setString(5, null);
        st.setString(6, null);
      }
      st.setString(7, "2026-01-01T00:00:00Z");
      st.setLong(8, epoch);
      st.setString(9, "2026-01-01T00:00:00Z");
      st.executeUpdate();
    }
  }

  private static void renameDeviceDirect(
      LocalTestServices services, String accountId, String deviceId, String name)
      throws SQLException {
    try (Connection connection = admin(services);
        PreparedStatement st =
            connection.prepareStatement(
                "UPDATE devices SET name = ? WHERE user_id = ? AND id = ?")) {
      st.setString(1, name);
      st.setString(2, accountId);
      st.setString(3, deviceId);
      st.executeUpdate();
    }
  }

  private static void revokeDeviceDirect(
      LocalTestServices services, String accountId, String deviceId) throws SQLException {
    try (Connection connection = admin(services);
        PreparedStatement st =
            connection.prepareStatement(
                "UPDATE devices SET revoked_at = ?, epoch = epoch + 1 WHERE user_id = ? AND id = ?")) {
      st.setString(1, "2026-01-02T00:00:00Z");
      st.setString(2, accountId);
      st.setString(3, deviceId);
      st.executeUpdate();
    }
  }
}
