package app.vaultone.server.common;

import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.crypto.ServerKeys;
import java.lang.reflect.Proxy;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.redisson.api.RScript;
import org.redisson.api.RedissonClient;

/** Redis 不可用时限流必须安全拒绝（抛 RateLimitUnavailableException），不无限放行。 */
class RedisRateLimiterUnavailableTest {
  @Test
  void redisFailureFailsClosed() {
    Object scriptProxy =
        Proxy.newProxyInstance(
            RScript.class.getClassLoader(),
            new Class<?>[] {RScript.class},
            (proxy, method, args) -> {
              throw new RuntimeException("redis down");
            });
    RedissonClient client =
        (RedissonClient)
            Proxy.newProxyInstance(
                RedissonClient.class.getClassLoader(),
                new Class<?>[] {RedissonClient.class},
                (proxy, method, args) -> method.getName().equals("getScript") ? scriptProxy : null);
    var limiter = new RedisRateLimiter(client, new ServerKeys(new byte[32]), properties());
    assertThatThrownBy(() -> limiter.tryAcquire("auth", "203.0.113.7"))
        .isInstanceOf(RateLimitUnavailableException.class);
  }

  private static VaultOneProperties properties() {
    return new VaultOneProperties(
        "test",
        "00".repeat(32),
        new VaultOneProperties.Redis("redis://127.0.0.1:1", null),
        new VaultOneProperties.Development(true, true),
        new VaultOneProperties.Session(60, 3600, 120, 600, 5, 1000, 3, 1000, 3, 16),
        new VaultOneProperties.Mail("log", "x", "", 587, "", ""),
        new VaultOneProperties.Ops(30, Duration.ofDays(30), "100MB", "2GB", "logs", 64));
  }
}
