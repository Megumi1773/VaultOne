package app.vaultone.server.web;

import app.vaultone.server.config.VaultOneProperties;
import java.util.List;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.CorsRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/** CORS 只按显式白名单开放；默认空（原生客户端不需要跨域）。拒绝通配 {@code *}，不全局开放 Origin。 */
@Configuration(proxyBeanMethods = false)
public class CorsWebConfiguration implements WebMvcConfigurer {
  private final List<String> allowedOrigins;

  public CorsWebConfiguration(VaultOneProperties properties) {
    this.allowedOrigins = properties.web().allowedOrigins();
    if (allowedOrigins.contains("*")) {
      throw new IllegalStateException("CORS 不允许通配来源，请显式配置白名单");
    }
  }

  @Override
  public void addCorsMappings(CorsRegistry registry) {
    if (allowedOrigins.isEmpty()) {
      return;
    }
    registry
        .addMapping("/v1/**")
        .allowedOrigins(allowedOrigins.toArray(String[]::new))
        .allowedMethods("GET", "POST", "PUT", "DELETE", "OPTIONS")
        .allowedHeaders("authorization", "content-type", "x-request-id")
        .allowCredentials(false)
        .maxAge(600);
  }
}
