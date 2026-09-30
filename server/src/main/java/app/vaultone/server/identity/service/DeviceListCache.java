package app.vaultone.server.identity.service;

import app.vaultone.server.config.VaultOneProperties;
import java.time.Duration;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.ThreadLocalRandom;
import org.redisson.api.RBucket;
import org.redisson.api.RedissonClient;
import org.redisson.client.codec.StringCodec;
import org.springframework.stereotype.Component;
import tools.jackson.databind.JavaType;
import tools.jackson.databind.json.JsonMapper;

/**
 * 设备列表展示元数据的非敏感缓存（可重建白名单：id/name/platform/approved/时间），cache-aside、非权威、短 TTL。
 *
 * <p><b>不缓存请求相关的 {@code current} 标记</b>：缓存按账户存放与请求者无关的条目，返回时由调用方按实际 deviceId 映射 current，避免 A 设备命中 B
 * 设备的 current。命名空间直连配置；读写失败保守回源/忽略， 不阻断非缓存读或已提交的安全操作。授权永不来自缓存：调用方每次先用 PG 权威状态验证。
 */
@Component
public class DeviceListCache {
  /** 显式短 TTL：展示缓存可重建，最终一致窗口有界。 */
  private static final Duration TTL = Duration.ofSeconds(45);

  /** 单账户缓存条目上限：超过则不缓存，避免无界值。 */
  private static final int MAX_ENTRIES = 1000;

  private static final int MAX_JSON_LENGTH = 524288;
  private static final JsonMapper JSON = JsonMapper.builder().build();
  private static final JavaType ENTRY_LIST =
      JSON.getTypeFactory().constructCollectionType(List.class, Entry.class);

  /** 缓存条目：不含 current。 */
  public record Entry(
      String id,
      String name,
      String platform,
      boolean approved,
      long createdAt,
      Long lastSeenAt,
      Long revokedAt) {}

  private final RedissonClient redis;
  private final String namespace;

  public DeviceListCache(RedissonClient redis, VaultOneProperties properties) {
    this.redis = redis;
    this.namespace = properties.redis().namespace();
  }

  private String key(String userId) {
    return namespace + "cache:devices:v1:" + userId;
  }

  /** 读取展示缓存；Redis 故障保守返回空（调用方回源），不冒充命中。 */
  public Optional<List<Entry>> get(String userId) {
    try {
      RBucket<String> bucket = redis.getBucket(key(userId), StringCodec.INSTANCE);
      String value = bucket.get();
      if (value == null || value.length() > MAX_JSON_LENGTH) {
        return Optional.empty();
      }
      List<Entry> entries = JSON.readValue(value, ENTRY_LIST);
      return entries.size() > MAX_ENTRIES ? Optional.empty() : Optional.of(List.copyOf(entries));
    } catch (RuntimeException ex) {
      return Optional.empty();
    }
  }

  /** 写入展示缓存；空列表或超容量不缓存，写失败忽略（下次回源）。 */
  public void put(String userId, List<Entry> devices) {
    if (devices == null || devices.isEmpty() || devices.size() > MAX_ENTRIES) {
      return;
    }
    try {
      String value = JSON.writeValueAsString(List.copyOf(devices));
      if (value.length() <= MAX_JSON_LENGTH) {
        Duration ttl = TTL.minusSeconds(ThreadLocalRandom.current().nextLong(16));
        redis.getBucket(key(userId), StringCodec.INSTANCE).set(value, ttl);
      }
    } catch (RuntimeException ignored) {
      // 缓存写失败不影响主流程（下次回源）。
    }
  }

  /** 失效某账户的展示缓存；调用方须在**提交后**调用，避免提交前删除导致并发旧值回填。失败由 TTL 兜底。 */
  public void invalidate(String userId) {
    try {
      redis.getBucket(key(userId), StringCodec.INSTANCE).delete();
    } catch (RuntimeException ignored) {
      // 失效失败由 TTL 兜底。
    }
  }
}
