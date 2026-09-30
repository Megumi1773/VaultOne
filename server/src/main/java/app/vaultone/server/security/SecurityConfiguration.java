package app.vaultone.server.security;

import app.vaultone.server.common.ErrorCatalog;
import jakarta.servlet.DispatcherType;
import java.io.IOException;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpHeaders;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import tools.jackson.databind.ObjectMapper;

/**
 * 无状态安全边界：禁用 Basic/表单/登出/请求缓存，不产生容器会话或 Cookie。
 *
 * <p>{@code /v1/**} 放行到 MVC（业务身份由 {@link AuthArgumentResolver} 解析并做对象级授权）；
 * 健康探针公开；其余路径默认拒绝。认证/拒绝响应统一为 {@code {code,message}}。
 */
@Configuration(proxyBeanMethods = false)
public class SecurityConfiguration {
  @Bean
  org.springframework.security.authentication.AuthenticationManager authenticationManager() {
    // 阻止默认用户/随机密码自动配置；身份由 Bearer 会话解析器提供，不使用 AuthenticationManager。
    return authentication -> {
      throw new org.springframework.security.authentication.BadCredentialsException("认证尚未接入");
    };
  }

  @Bean
  SecurityFilterChain securityFilterChain(HttpSecurity http, ObjectMapper json) throws Exception {
    http.httpBasic(AbstractHttpConfigurer::disable)
        .formLogin(AbstractHttpConfigurer::disable)
        .logout(AbstractHttpConfigurer::disable)
        .csrf(AbstractHttpConfigurer::disable)
        .requestCache(AbstractHttpConfigurer::disable)
        .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
        .exceptionHandling(
            e ->
                e.authenticationEntryPoint((req, res, ex) -> write(json, res, 401))
                    .accessDeniedHandler((req, res, ex) -> write(json, res, 403)))
        .authorizeHttpRequests(
            a ->
                a.dispatcherTypeMatchers(DispatcherType.ERROR)
                    .permitAll()
                    .requestMatchers(
                        "/actuator/health/liveness",
                        "/actuator/health/readiness",
                        "/healthz",
                        "/readyz")
                    .permitAll()
                    .requestMatchers("/v1/**")
                    .permitAll()
                    .anyRequest()
                    .denyAll());
    return http.build();
  }

  private static void write(
      ObjectMapper json, jakarta.servlet.http.HttpServletResponse res, int status)
      throws IOException {
    res.setStatus(status);
    res.setContentType("application/json");
    res.setCharacterEncoding("UTF-8");
    res.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
    json.writeValue(res.getOutputStream(), ErrorCatalog.body(status));
  }
}
