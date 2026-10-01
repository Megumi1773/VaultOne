package app.vaultone.server.web;

import app.vaultone.server.config.DevelopmentNetworkPolicy;
import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.proto.ErrorBody;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.filter.OncePerRequestFilter;
import tools.jackson.databind.ObjectMapper;

/** dev 监听所有网卡时仍按真实对端地址限制访问，不能用 X-Forwarded-For 伪装成私网。 */
@Configuration(proxyBeanMethods = false)
public class DevelopmentNetworkFilter {
  @Bean
  FilterRegistrationBean<OncePerRequestFilter> developmentNetworkFilterRegistration(
      VaultOneProperties properties, ObjectMapper json) {
    var filter =
        new OncePerRequestFilter() {
          @Override
          protected void doFilterInternal(
              HttpServletRequest request, HttpServletResponse response, FilterChain chain)
              throws ServletException, IOException {
            if (properties.development().enabled()
                && !DevelopmentNetworkPolicy.permitsPeer(
                    request.getRemoteAddr(), properties.development().allowLan())) {
              response.setStatus(403);
              response.setContentType("application/json");
              response.setCharacterEncoding("UTF-8");
              response.setHeader("Cache-Control", "no-store");
              json.writeValue(
                  response.getOutputStream(),
                  new ErrorBody("development_network_denied", "开发服务仅接受本机或已启用的私有局域网访问"));
              return;
            }
            chain.doFilter(request, response);
          }
        };
    var registration = new FilterRegistrationBean<OncePerRequestFilter>(filter);
    registration.setOrder(-240);
    return registration;
  }
}
