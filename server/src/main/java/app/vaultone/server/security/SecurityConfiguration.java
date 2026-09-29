package app.vaultone.server.security;

import app.vaultone.server.web.ErrorBody;
import jakarta.servlet.DispatcherType;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpHeaders;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.AnonymousAuthenticationFilter;
import org.springframework.web.filter.OncePerRequestFilter;
import tools.jackson.databind.ObjectMapper;

@Configuration(proxyBeanMethods = false)
public class SecurityConfiguration {
  @Bean
  org.springframework.security.authentication.AuthenticationManager authenticationManager() {
    // 阻止默认用户/随机密码自动配置；没有S2会话服务时不接受任何身份。
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
                    .requestMatchers("/actuator/health/liveness", "/actuator/health/readiness")
                    .permitAll()
                    .anyRequest()
                    .denyAll())
        .addFilterBefore(new BearerBoundary(json), AnonymousAuthenticationFilter.class);
    return http.build();
  }

  private static void write(ObjectMapper json, HttpServletResponse res, int status)
      throws IOException {
    res.setStatus(status);
    res.setContentType("application/json");
    res.setCharacterEncoding("UTF-8");
    res.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
    json.writeValue(res.getOutputStream(), ErrorBody.forStatus(status));
  }

  /** S1不签发或验证token。任何凭据均拒绝，绝不伪装S2认证成功。 */
  private static final class BearerBoundary extends OncePerRequestFilter {
    private final ObjectMapper json;

    BearerBoundary(ObjectMapper json) {
      this.json = json;
    }

    @Override
    protected void doFilterInternal(
        HttpServletRequest request, HttpServletResponse response, FilterChain chain)
        throws ServletException, IOException {
      String header = request.getHeader(HttpHeaders.AUTHORIZATION);
      if (header != null) {
        // 保留Bearer扩展边界；S2将接入真实会话哈希查验，S1没有测试后门token。
        write(json, response, 401);
        return;
      }
      chain.doFilter(request, response);
    }
  }
}
