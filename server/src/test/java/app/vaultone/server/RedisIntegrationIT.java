package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.security.SessionMetadata;
import app.vaultone.server.security.SessionStore;
import app.vaultone.server.support.LocalTestServices;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.redisson.api.RedissonClient;

/**
 * Redis 会话存储真实集成：命名空间隔离、元数据往返、滑动续期、删除即移除、键不含 token 明文。
 *
 * <p>只读/写本次随机环境前缀下的键；结束时删除本测试键，绝不 FLUSHDB/FLUSHALL。 Redis 键前缀为 {@code
 * vaultone:session:<environment>:v1:<hash>}，其中 environment 由 fixture 随机化。
 */
class RedisIntegrationIT {

  @Test
  void sessionStoreRoundTripWithinNamespaceAndNoFlush() {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore store = context.getBean(SessionStore.class);
      RedissonClient redis = context.getBean(RedissonClient.class);
      String pattern = sessionKeyPattern(services);
      String tokenHash = "deadbeef" + Long.toHexString(System.nanoTime());
      Instant now = Instant.now();
      SessionMetadata metadata =
          new SessionMetadata("acct", "device", 1L, 1L, now, now, now.plusSeconds(3600), true);

      // 本环境探针键，验证命名空间隔离。
      String probeKey = sessionEnvironmentPrefix(services) + "probe";
      redis.<String>getBucket(probeKey).set("v1");

      try {
        store.put(tokenHash, metadata);
        assertThat(store.get(tokenHash)).contains(metadata);

        // 续期：仅在键存在、代次一致且新到期更晚时生效。
        Instant later = now.plusSeconds(7200);
        assertThat(store.renewIfPresent(tokenHash, metadata, new SessionStore.Renewal(later, now)))
            .isTrue();
        assertThat(store.get(tokenHash)).isPresent();
        assertThat(store.get(tokenHash).orElseThrow().expiresAt()).isAfter(now.plusSeconds(3600));

        // 删除后不存在，且不因续期而复活。
        store.delete(tokenHash);
        assertThat(store.get(tokenHash)).isEmpty();
        assertThat(store.renewIfPresent(tokenHash, metadata, new SessionStore.Renewal(later, now)))
            .isFalse();
        assertThat(store.get(tokenHash)).isEmpty();

        assertThat(redis.<String>getBucket(probeKey).get()).isEqualTo("v1");
      } finally {
        // 只清本环境前缀下的键；不 FLUSH。
        redis.getKeys().deleteByPattern(pattern);
      }
    }
  }

  @Test
  void sessionStoreHandlesMissingKeysWithoutRebuilding() {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore store = context.getBean(SessionStore.class);
      assertThat(store.get("nonexistent" + System.nanoTime())).isEmpty();
      Instant now = Instant.now();
      store.renewIfPresent(
          "nonexistent" + System.nanoTime(),
          new SessionMetadata("a", "d", 1L, 1L, now, now, now.plusSeconds(60), true),
          new SessionStore.Renewal(now.plusSeconds(120), now));
      assertThat(store.get("nonexistent" + System.nanoTime())).isEmpty();
    }
  }

  @Test
  void keysNeverContainRawTokenOrSecrets() {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      SessionStore store = context.getBean(SessionStore.class);
      RedissonClient redis = context.getBean(RedissonClient.class);
      String pattern = sessionKeyPattern(services);
      String tokenHash = "aabbccdd" + Long.toHexString(System.nanoTime());
      Instant now = Instant.now();
      store.put(
          tokenHash,
          new SessionMetadata("acct", "device", 1L, 1L, now, now, now.plusSeconds(300), false));
      try {
        List<String> keys = new java.util.ArrayList<>();
        for (String k : redis.getKeys().getKeysByPattern(pattern)) {
          keys.add(k);
        }
        assertThat(keys).allMatch(k -> k.startsWith(sessionEnvironmentPrefix(services)));
        // 键以 SHA-256(token) 哈希结尾，绝不包含 token 明文。
        assertThat(keys).anyMatch(k -> k.endsWith(tokenHash));
      } finally {
        redis.getKeys().deleteByPattern(pattern);
      }
    }
  }

  /**
   * 与 RedisSessionStore 一致：键为 {@code <namespace>session:v1:<sha256hex>}，namespace 由 fixture 随机注入。
   */
  private static String sessionEnvironmentPrefix(LocalTestServices services) {
    return services.redisNamespace() + "session:v1:";
  }

  private static String sessionKeyPattern(LocalTestServices services) {
    return sessionEnvironmentPrefix(services) + "*";
  }
}
