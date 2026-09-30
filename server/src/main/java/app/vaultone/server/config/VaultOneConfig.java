package app.vaultone.server.config;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Configuration;

/** 注册强类型配置；部署安全门禁仍由 DeploymentGuard 在 bean 创建前执行。 */
@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(VaultOneProperties.class)
public class VaultOneConfig {}
