package app.vaultone.server.config;

import org.redisson.Redisson;
import org.redisson.api.RedissonClient;
import org.redisson.config.Config;
import org.redisson.config.SslVerificationMode;
import org.springframework.boot.health.contributor.Health;
import org.springframework.boot.health.contributor.HealthIndicator;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;

@Configuration(proxyBeanMethods = false)
public class RedisConfiguration {
  /** 全进程唯一客户端；池有界，销毁时关闭线程，不采用每请求new client。 */
  @Bean(destroyMethod = "shutdown")
  RedissonClient redissonClient(Environment env) {
    Config config = new Config();
    config.setThreads(2).setNettyThreads(4);
    var single =
        config
            .useSingleServer()
            .setAddress(env.getRequiredProperty("vaultone.redis.address"))
            .setConnectionMinimumIdleSize(2)
            .setConnectionPoolSize(8)
            .setSubscriptionConnectionMinimumIdleSize(1)
            .setSubscriptionConnectionPoolSize(2)
            .setConnectTimeout(3000)
            .setTimeout(3000)
            .setRetryAttempts(1)
            .setSslVerificationMode(SslVerificationMode.STRICT);
    String password = env.getProperty("vaultone.redis.password", "");
    if (!password.isBlank()) single.setPassword(password);
    return Redisson.create(config);
  }

  @Bean
  HealthIndicator redisConnectivity(RedissonClient redis) {
    return () -> {
      try {
        return redis
                .getRedisNodes(org.redisson.api.redisnode.RedisNodes.SINGLE)
                .getInstance()
                .ping(3, java.util.concurrent.TimeUnit.SECONDS)
            ? Health.up().build()
            : Health.down().build();
      } catch (RuntimeException ex) {
        // 不把异常对象或连接串放入health响应。
        return Health.down().build();
      }
    };
  }
}
