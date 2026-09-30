package app.vaultone.server.web;

import app.vaultone.server.security.AuthArgumentResolver;
import java.util.List;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.method.support.HandlerMethodArgumentResolver;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/** 注册认证主体参数解析器（{@code Authed} / {@code Approved}）。 */
@Configuration(proxyBeanMethods = false)
public class WebMvcConfiguration implements WebMvcConfigurer {
  private final AuthArgumentResolver authArgumentResolver;

  public WebMvcConfiguration(AuthArgumentResolver authArgumentResolver) {
    this.authArgumentResolver = authArgumentResolver;
  }

  @Override
  public void addArgumentResolvers(List<HandlerMethodArgumentResolver> resolvers) {
    resolvers.add(authArgumentResolver);
  }
}
