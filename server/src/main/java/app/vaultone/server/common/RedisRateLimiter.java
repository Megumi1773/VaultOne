package app.vaultone.server.common;

import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.crypto.ServerKeys;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import org.redisson.api.RScript;
import org.redisson.api.RedissonClient;
import org.redisson.client.codec.StringCodec;

/**
 * 基于 Redis 的令牌桶限流：容量 = burst，每个 interval（{@code *RateMillis}）补 1 个令牌。
 *
 * <p>短小原子 Lua，使用 Redis 服务器时间（{@code TIME}）避免多实例时钟漂移；每个分组+来源摘要只有一个键， TTL
 * 有界并在命中时刷新，拒绝时不产生无界键。客户端地址先经服务端密钥 HMAC 摘要，不保存原始 IP。
 *
 * <p>显式使用 {@link StringCodec}，确保 Lua 的 ARGV 为字符串而非默认二进制编解码。只使用唯一的受控 {@link RedissonClient}；后端故障抛
 * {@link RateLimitUnavailableException}。
 */
public class RedisRateLimiter implements RateLimiter {
  private static final String SCRIPT =
      "local capacity = tonumber(ARGV[1]); "
          + "local interval = tonumber(ARGV[2]); "
          + "local ttl = tonumber(ARGV[3]); "
          + "local t = redis.call('TIME'); "
          + "local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000); "
          + "local data = redis.call('HMGET', KEYS[1], 'tokens', 'ts'); "
          + "local tokens = tonumber(data[1]); "
          + "local ts = tonumber(data[2]); "
          + "if tokens == nil then tokens = capacity; ts = now; end; "
          + "local delta = now - ts; "
          + "if delta > 0 then "
          + "  local refill = math.floor(delta / interval); "
          + "  if refill > 0 then tokens = math.min(capacity, tokens + refill); ts = ts + refill * interval; end; "
          + "end; "
          + "local allowed = 0; "
          + "if tokens > 0 then tokens = tokens - 1; allowed = 1; end; "
          + "redis.call('HSET', KEYS[1], 'tokens', tokens, 'ts', ts); "
          + "redis.call('PEXPIRE', KEYS[1], ttl); "
          + "return allowed;";

  private final RedissonClient redis;
  private final ServerKeys keys;
  private final String namespace;
  private final Map<String, Bucket> buckets;

  public RedisRateLimiter(RedissonClient redis, ServerKeys keys, VaultOneProperties properties) {
    this.redis = redis;
    this.keys = keys;
    this.namespace = properties.redis().namespace();
    this.buckets =
        Map.of(
            "auth",
            new Bucket(properties.session().authRateMillis(), properties.session().authBurst()),
            "api",
            new Bucket(properties.session().apiRateMillis(), properties.session().apiBurst()));
  }

  @Override
  public boolean tryAcquire(String group, String clientAddress) {
    Bucket bucket = buckets.get(group);
    if (bucket == null) {
      throw new IllegalArgumentException("未知限流分组");
    }
    String digest =
        HexFormat.of()
            .formatHex(
                keys.decoy(clientAddress == null ? "unknown" : clientAddress, "rate-ip", 16));
    String key = namespace + ":ratelimit:" + group + ":" + digest;
    long ttlMillis = Math.max(60_000L, (long) bucket.capacity() * bucket.intervalMillis() * 2L);
    try {
      Object result =
          redis
              .getScript(StringCodec.INSTANCE)
              .eval(
                  RScript.Mode.READ_WRITE,
                  SCRIPT,
                  RScript.ReturnType.LONG,
                  List.of(key),
                  Integer.toString(bucket.capacity()),
                  Long.toString(bucket.intervalMillis()),
                  Long.toString(ttlMillis));
      return result instanceof Number n && n.longValue() == 1L;
    } catch (RuntimeException ex) {
      throw new RateLimitUnavailableException("限流后端不可用", ex);
    }
  }

  private record Bucket(long intervalMillis, int capacity) {}
}
