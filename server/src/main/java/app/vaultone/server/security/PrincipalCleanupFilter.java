package app.vaultone.server.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * 在请求结束时清理 {@link PrincipalHolder}，避免线程本地认证主体泄漏到后续请求（虚拟线程虽通常不复用， 仍显式清理）。order 排在请求 ID 过滤器之后、业务之前，保证
 * finally 覆盖整个链路。
 */
@Configuration(proxyBeanMethods = false)
public class PrincipalCleanupFilter {
  @Bean
  FilterRegistrationBean<OncePerRequestFilter> principalCleanupRegistration() {
    var filter =
        new OncePerRequestFilter() {
          @Override
          protected void doFilterInternal(
              HttpServletRequest request, HttpServletResponse response, FilterChain chain)
              throws ServletException, IOException {
            try {
              chain.doFilter(request, response);
            } finally {
              PrincipalHolder.clear();
            }
          }
        };
    var registration = new FilterRegistrationBean<OncePerRequestFilter>(filter);
    registration.setOrder(-249);
    return registration;
  }
}
