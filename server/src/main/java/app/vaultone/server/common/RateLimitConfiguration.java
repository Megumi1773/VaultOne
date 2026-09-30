package app.vaultone.server.common;

import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.crypto.ServerKeys;
import org.redisson.api.RedissonClient;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** 生产限流实现装配：唯一 Redisson 客户端 + 服务端密钥派生摘要。 */
@Configuration(proxyBeanMethods = false)
public class RateLimitConfiguration {
  @Bean
  RateLimiter rateLimiter(RedissonClient redis, ServerKeys keys, VaultOneProperties properties) {
    return new RedisRateLimiter(redis, keys, properties);
  }
}
