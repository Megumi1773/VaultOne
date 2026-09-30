package app.vaultone.server.web;

import app.vaultone.server.config.VaultOneProperties;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.UUID;
import org.slf4j.MDC;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * 请求关联 ID：不盲信外部头——只接受受限长度（配置上界 8..128）与字符集的 {@code x-request-id}，否则生成新的。
 *
 * <p>最终 ID 同时写入受控请求属性、MDC 与响应头，业务审计只读受控属性，保证 response/log/audit 同 ID；MDC 在 {@code finally} 清理。Bean
 * 方法名与配置类名区分，避免 Spring 自引用工厂 Bean 冲突。
 */
@Configuration(proxyBeanMethods = false)
public class RequestIdFilter {
  @Bean
  FilterRegistrationBean<OncePerRequestFilter> requestIdFilterRegistration(
      VaultOneProperties properties) {
    int maxLength = properties.ops().requestIdMaxLength();
    var filter =
        new OncePerRequestFilter() {
          @Override
          protected void doFilterInternal(
              HttpServletRequest request, HttpServletResponse response, FilterChain chain)
              throws ServletException, IOException {
            String requestId = sanitize(request.getHeader(RequestIds.HEADER), maxLength);
            request.setAttribute(RequestIds.ATTRIBUTE, requestId);
            MDC.put(RequestIds.MDC_KEY, requestId);
            response.setHeader(RequestIds.HEADER, requestId);
            try {
              chain.doFilter(request, response);
            } finally {
              MDC.remove(RequestIds.MDC_KEY);
            }
          }
        };
    var registration = new FilterRegistrationBean<OncePerRequestFilter>(filter);
    registration.setOrder(-250);
    return registration;
  }

  private static String sanitize(String value, int maxLength) {
    if (value == null) {
      return UUID.randomUUID().toString();
    }
    String trimmed = value.trim();
    if (trimmed.isEmpty() || trimmed.length() > maxLength) {
      return UUID.randomUUID().toString();
    }
    for (int i = 0; i < trimmed.length(); i++) {
      char c = trimmed.charAt(i);
      boolean ok =
          (c >= 'a' && c <= 'z')
              || (c >= 'A' && c <= 'Z')
              || (c >= '0' && c <= '9')
              || c == '-'
              || c == '_'
              || c == '.';
      if (!ok) {
        return UUID.randomUUID().toString();
      }
    }
    return trimmed;
  }
}
