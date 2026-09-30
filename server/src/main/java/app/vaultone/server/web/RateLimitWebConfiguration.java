package app.vaultone.server.web;

import app.vaultone.server.common.ErrorCatalog;
import app.vaultone.server.common.RateLimitUnavailableException;
import app.vaultone.server.common.RateLimiter;
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

/**
 * 真实请求限流接入：防滥用入口（认证/恢复/设备自助验证）用 auth 组，其余 {@code /v1/**} 用 api 组（含 logout）。
 *
 * <p>分组用明确路径集而非宽泛前缀；键取自可信连接地址（不信任 Forwarded 头）。非 {@code /v1} 路径交给 Security 默认拒绝，不由本过滤器放行。超限
 * 429；限流后端不可用 503（安全拒绝，不无限放行）。健康探针与 CORS 预检不参与。
 */
@Configuration(proxyBeanMethods = false)
public class RateLimitWebConfiguration {
  @Bean
  FilterRegistrationBean<OncePerRequestFilter> rateLimitFilter(
      RateLimiter limiter, ObjectMapper json) {
    var filter =
        new OncePerRequestFilter() {
          @Override
          protected boolean shouldNotFilter(HttpServletRequest request) {
            return !request.getRequestURI().startsWith("/v1/")
                || "OPTIONS".equalsIgnoreCase(request.getMethod());
          }

          @Override
          protected void doFilterInternal(
              HttpServletRequest request, HttpServletResponse response, FilterChain chain)
              throws ServletException, IOException {
            String group = isAbuseProne(request.getRequestURI()) ? "auth" : "api";
            try {
              if (!limiter.tryAcquire(group, request.getRemoteAddr())) {
                write(json, response, 429);
                return;
              }
            } catch (RateLimitUnavailableException ex) {
              write(json, response, 503);
              return;
            }
            chain.doFilter(request, response);
          }
        };
    var registration = new FilterRegistrationBean<OncePerRequestFilter>(filter);
    registration.setOrder(-180);
    return registration;
  }

  /** 防滥用分组：认证、恢复、设备自助验证；logout 明确归 API 组。 */
  static boolean isAbuseProne(String uri) {
    if ("/v1/auth/logout".equals(uri)) {
      return false;
    }
    return uri.startsWith("/v1/auth/")
        || uri.startsWith("/v1/recovery/")
        || "/v1/devices/self".equals(uri)
        || uri.startsWith("/v1/devices/self/");
  }

  private static void write(ObjectMapper json, HttpServletResponse response, int status)
      throws IOException {
    response.setStatus(status);
    response.setContentType("application/json");
    response.setCharacterEncoding("UTF-8");
    response.setHeader("Cache-Control", "no-store");
    json.writeValue(response.getOutputStream(), ErrorCatalog.body(status));
  }
}
