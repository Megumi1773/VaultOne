package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.common.RedisRateLimiter;
import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.support.LocalTestServices;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.redisson.api.RedissonClient;

/** Redis 限流真实集成：多实例共享额度、按 interval 逐步补充、单键有界 TTL。只操作本次随机命名空间前缀下的键， 结束时按前缀删除，绝不 FLUSHDB/FLUSHALL。 */
class RateLimiterIntegrationIT {

  @Test
  void tokenBucketSharesQuotaRefillsAndBoundsKeys() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      RedissonClient redis = context.getBean(RedissonClient.class);
      ServerKeys keys = context.getBean(ServerKeys.class);
      String namespace = services.redisNamespace();
      VaultOneProperties properties = properties(namespace, 3, 1000);
      RedisRateLimiter first = new RedisRateLimiter(redis, keys, properties);
      RedisRateLimiter second = new RedisRateLimiter(redis, keys, properties);
      String address = "203.0.113." + (Math.abs(System.nanoTime() % 250) + 1);
      try {
        // 容量 3：跨两个实例共享同一额度。
        assertThat(first.tryAcquire("auth", address)).isTrue();
        assertThat(second.tryAcquire("auth", address)).isTrue();
        assertThat(first.tryAcquire("auth", address)).isTrue();
        assertThat(second.tryAcquire("auth", address)).isFalse();

        // 每 interval 补 1 个令牌。
        Thread.sleep(1100);
        assertThat(first.tryAcquire("auth", address)).isTrue();

        // 单键有界 TTL。
        List<String> found = new ArrayList<>();
        for (String key : redis.getKeys().getKeysByPattern(namespace + ":ratelimit:auth:*")) {
          found.add(key);
        }
        assertThat(found).isNotEmpty();
        for (String key : found) {
          assertThat(redis.<String>getBucket(key).remainTimeToLive()).isGreaterThan(0L);
        }
      } finally {
        redis.getKeys().deleteByPattern(namespace + ":ratelimit:*");
      }
    }
  }

  private static VaultOneProperties properties(String namespace, int burst, long intervalMillis) {
    return new VaultOneProperties(
        "test",
        "0123456789abcdef".repeat(4),
        new VaultOneProperties.Redis("redis://127.0.0.1:1", null, namespace),
        new VaultOneProperties.Development(true, true),
        new VaultOneProperties.Session(
            60, 3600, 120, 600, 5, intervalMillis, burst, intervalMillis, burst, 16),
        new VaultOneProperties.Mail("log", "x", "", 587, "", ""),
        new VaultOneProperties.Ops(30, Duration.ofDays(30), "100MB", "2GB", "logs", 64),
        new VaultOneProperties.Web(1048576L, 67108864L, 128, 100, 256, List.of()));
  }
}
