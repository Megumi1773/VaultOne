package app.vaultone.server.security;

import app.vaultone.server.config.VaultOneProperties;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import org.redisson.api.RMap;
import org.redisson.api.RScript;
import org.redisson.api.RedissonClient;
import org.redisson.client.codec.StringCodec;
import org.springframework.stereotype.Component;

/**
 * Redis 会话主存。统一 {@link StringCodec}（显式传给每个 Map/Script，避免默认 Kryo 编码与 Lua 裸字符串字段 不一致导致读回损坏）。键 {@code
 * <namespace>session:v1:<sha256hex>}，值为 Hash 字段。
 *
 * <p>另维护按账户/设备的定向索引 {@code <namespace>session:v1:idx:<userId>:<deviceId>}（ZSET，member = token 的
 * SHA-256 十六进制，score = 到期毫秒）。索引只含摘要，不含 raw token 或额外敏感材料；单设备撤销只读本设备索引分批清理， 不扫描全站。索引键带
 * TTL（随会话到期/续期刷新），过期成员有界修剪，不留永久键。索引缺失时安全性仍由 PG 撤销/epoch 保证。
 *
 * <ul>
 *   <li>创建：单条 Lua 原子写全部字段 + {@code EXPIRE}，并写入设备索引与 TTL（不先写后设 TTL，断连不会留永久键）。
 *   <li>续期：单条 Lua 校验存在/版本/账户/设备/代次/未过期，并按节流只更新存在键的 expiresAt/lastRenewedAt 及索引；
 *       并发的旧续期不会缩短有效期（仅当新过期时间更晚才写）。
 *   <li>删除：单条 Lua 从本设备索引移除成员并删除会话键。
 * </ul>
 *
 * <p>所有 Redis 异常精确映射 {@link SessionStoreUnavailableException}（上层 503），不携带异常原文。
 */
@Component
public class RedisSessionStore implements SessionStore {
  private static final String FORMAT_VERSION = "v1";

  /** 单次定向清理读取的成员数上限；总批次数亦有界，避免无界循环。 */
  private static final int DELETE_BATCH = 100;

  private static final int DELETE_MAX_BATCHES = 100;

  private static final String PRUNE_SCRIPT =
      "local function prune(index, now) "
          + "local expired = redis.call('ZRANGEBYSCORE', index, '-inf', now, 'LIMIT', 0, 100); "
          + "if #expired > 0 then redis.call('ZREM', index, unpack(expired)) end; end; ";

  private static final String CREATE_SCRIPT =
      PRUNE_SCRIPT
          + "redis.call('HSET', KEYS[1], "
          + "'v', ARGV[1], 'userId', ARGV[2], 'deviceId', ARGV[3], "
          + "'sessionEpoch', ARGV[4], 'deviceEpoch', ARGV[5], "
          + "'issuedAt', ARGV[6], 'lastRenewedAt', ARGV[7], 'expiresAt', ARGV[8], "
          + "'deviceApproved', ARGV[9], 'expiresAtMillis', ARGV[10]); "
          + "redis.call('PEXPIREAT', KEYS[1], ARGV[10]); "
          + "local idx = ARGV[11] .. ARGV[2] .. ':' .. ARGV[3]; "
          + "redis.call('ZADD', idx, ARGV[10], ARGV[12]); "
          + "prune(idx, ARGV[13]); "
          + "local ttl = redis.call('PTTL', idx); "
          + "if ttl < 0 or (tonumber(ARGV[13]) + ttl) < tonumber(ARGV[10]) then "
          + "redis.call('PEXPIREAT', idx, ARGV[10]); end; "
          + "return 1";

  // 仅当键存在、格式版本/账户/设备/代次一致、旧 expiresAt 早于新值时：更新 expiresAt/lastRenewedAt、刷新 TTL 与设备索引。
  private static final String RENEW_SCRIPT =
      PRUNE_SCRIPT
          + "local v = redis.call('HGET', KEYS[1], 'v') "
          + "if not v or v ~= ARGV[1] then return 0 end "
          + "if redis.call('HGET', KEYS[1], 'userId') ~= ARGV[2] then return 0 end "
          + "if redis.call('HGET', KEYS[1], 'deviceId') ~= ARGV[3] then return 0 end "
          + "if redis.call('HGET', KEYS[1], 'sessionEpoch') ~= ARGV[4] then return 0 end "
          + "if redis.call('HGET', KEYS[1], 'deviceEpoch') ~= ARGV[5] then return 0 end "
          + "local cur = tonumber(redis.call('HGET', KEYS[1], 'expiresAtMillis')) "
          + "if not cur or cur >= tonumber(ARGV[9]) then return 0 end "
          + "if cur <= tonumber(ARGV[12]) then return 0 end "
          + "redis.call('HSET', KEYS[1], 'expiresAt', ARGV[6], 'lastRenewedAt', ARGV[8], 'expiresAtMillis', ARGV[9]) "
          + "redis.call('PEXPIREAT', KEYS[1], ARGV[9]) "
          + "local idx = ARGV[10] .. ARGV[2] .. ':' .. ARGV[3]; "
          + "redis.call('ZADD', idx, ARGV[9], ARGV[11]); "
          + "prune(idx, ARGV[12]); "
          + "local ttl = redis.call('PTTL', idx); "
          + "if ttl < 0 or (tonumber(ARGV[12]) + ttl) < tonumber(ARGV[9]) then "
          + "redis.call('PEXPIREAT', idx, ARGV[9]); end; "
          + "return 1";

  // 从会话 Hash 读取账户/设备，移除设备索引成员后删除会话键；键不存在时 DEL 为无操作。
  private static final String DELETE_SCRIPT =
      "local uid = redis.call('HGET', KEYS[1], 'userId'); "
          + "local did = redis.call('HGET', KEYS[1], 'deviceId'); "
          + "if uid and did then redis.call('ZREM', ARGV[1] .. uid .. ':' .. did, ARGV[2]); end; "
          + "redis.call('DEL', KEYS[1]); return 1";

  // 只读本设备索引：先修剪已过期成员，再分批删除会话键与成员；空索引删除。返回本批处理数。
  private static final String DELETE_BY_DEVICE_SCRIPT =
      PRUNE_SCRIPT
          + "prune(KEYS[1], ARGV[2]); "
          + "local members = redis.call('ZRANGE', KEYS[1], 0, tonumber(ARGV[3]) - 1); "
          + "for i = 1, #members do "
          + "  redis.call('DEL', ARGV[1] .. members[i]); "
          + "  redis.call('ZREM', KEYS[1], members[i]); "
          + "end; "
          + "if redis.call('ZCARD', KEYS[1]) == 0 then redis.call('DEL', KEYS[1]); end; "
          + "return #members";

  private final RedissonClient redis;
  private final String sessionPrefix;
  private final String indexPrefix;

  public RedisSessionStore(RedissonClient redis, VaultOneProperties properties) {
    this.redis = redis;
    String namespace = properties.redis().namespace();
    this.sessionPrefix = namespace + "session:v1:";
    this.indexPrefix = sessionPrefix + "idx:";
  }

  private String key(String tokenHashHex) {
    return sessionPrefix + tokenHashHex;
  }

  private String indexKey(String userId, String deviceId) {
    return indexPrefix + userId + ":" + deviceId;
  }

  @Override
  public void put(String tokenHashHex, SessionMetadata metadata) {
    try {
      long expiresMillis = metadata.expiresAt().toEpochMilli();
      redis
          .getScript(StringCodec.INSTANCE)
          .eval(
              RScript.Mode.READ_WRITE,
              CREATE_SCRIPT,
              RScript.ReturnType.LONG,
              List.of(key(tokenHashHex)),
              FORMAT_VERSION,
              metadata.userId(),
              metadata.deviceId(),
              Long.toString(metadata.sessionEpoch()),
              Long.toString(metadata.deviceEpoch()),
              metadata.issuedAt().toString(),
              metadata.lastRenewedAt().toString(),
              metadata.expiresAt().toString(),
              Boolean.toString(metadata.deviceApproved()),
              Long.toString(expiresMillis),
              indexPrefix,
              tokenHashHex,
              Long.toString(Instant.now().toEpochMilli()));
    } catch (RuntimeException ex) {
      throw unavailable();
    }
  }

  @Override
  public Optional<SessionMetadata> get(String tokenHashHex) {
    try {
      RMap<String, String> map = redis.getMap(key(tokenHashHex), StringCodec.INSTANCE);
      Map<String, String> value = map.readAllMap();
      return value.isEmpty() ? Optional.empty() : Optional.of(decode(value));
    } catch (RuntimeException ex) {
      throw unavailable();
    }
  }

  @Override
  public boolean renewIfPresent(String tokenHashHex, SessionMetadata expected, Renewal renewal) {
    try {
      Instant now = Instant.now();
      Long result =
          redis
              .getScript(StringCodec.INSTANCE)
              .eval(
                  RScript.Mode.READ_WRITE,
                  RENEW_SCRIPT,
                  RScript.ReturnType.LONG,
                  List.of(key(tokenHashHex)),
                  FORMAT_VERSION,
                  expected.userId(),
                  expected.deviceId(),
                  Long.toString(expected.sessionEpoch()),
                  Long.toString(expected.deviceEpoch()),
                  renewal.newExpiresAt().toString(),
                  now.toString(),
                  renewal.renewedAt().toString(),
                  Long.toString(renewal.newExpiresAt().toEpochMilli()),
                  indexPrefix,
                  tokenHashHex,
                  Long.toString(now.toEpochMilli()));
      return result != null && result == 1L;
    } catch (RuntimeException ex) {
      throw unavailable();
    }
  }

  @Override
  public void delete(String tokenHashHex) {
    try {
      redis
          .getScript(StringCodec.INSTANCE)
          .eval(
              RScript.Mode.READ_WRITE,
              DELETE_SCRIPT,
              RScript.ReturnType.LONG,
              List.of(key(tokenHashHex)),
              indexPrefix,
              tokenHashHex);
    } catch (RuntimeException ex) {
      throw unavailable();
    }
  }

  @Override
  public void deleteByDevice(String userId, String deviceId) {
    try {
      String indexKey = indexKey(userId, deviceId);
      long now = Instant.now().toEpochMilli();
      for (int batch = 0; batch < DELETE_MAX_BATCHES; batch++) {
        Long removed =
            redis
                .getScript(StringCodec.INSTANCE)
                .eval(
                    RScript.Mode.READ_WRITE,
                    DELETE_BY_DEVICE_SCRIPT,
                    RScript.ReturnType.LONG,
                    List.of(indexKey),
                    sessionPrefix,
                    Long.toString(now),
                    Integer.toString(DELETE_BATCH));
        if (removed == null || removed < DELETE_BATCH) {
          return;
        }
      }
    } catch (RuntimeException ex) {
      throw unavailable();
    }
  }

  private SessionMetadata decode(Map<String, String> value) {
    requireKeys(value);
    if (!FORMAT_VERSION.equals(value.get("v"))) {
      throw unavailable();
    }
    try {
      return new SessionMetadata(
          value.get("userId"),
          value.get("deviceId"),
          Long.parseLong(value.get("sessionEpoch")),
          Long.parseLong(value.get("deviceEpoch")),
          Instant.parse(value.get("issuedAt")),
          Instant.parse(value.get("lastRenewedAt")),
          Instant.parse(value.get("expiresAt")),
          Boolean.parseBoolean(value.get("deviceApproved")));
    } catch (RuntimeException ex) {
      throw unavailable();
    }
  }

  private void requireKeys(Map<String, String> value) {
    for (String k :
        new String[] {
          "v",
          "userId",
          "deviceId",
          "sessionEpoch",
          "deviceEpoch",
          "issuedAt",
          "lastRenewedAt",
          "expiresAt",
          "deviceApproved"
        }) {
      if (!value.containsKey(k)) {
        throw unavailable();
      }
    }
  }

  private SessionStoreUnavailableException unavailable() {
    return new SessionStoreUnavailableException("会话存储不可用");
  }
}
