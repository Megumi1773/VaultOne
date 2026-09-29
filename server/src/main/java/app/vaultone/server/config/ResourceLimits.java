package app.vaultone.server.config;

import app.vaultone.server.web.ErrorBody;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.concurrent.Semaphore;
import org.eclipse.jetty.server.NetworkConnectionLimit;
import org.springframework.boot.jetty.servlet.JettyServletWebServerFactory;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.filter.OncePerRequestFilter;
import tools.jackson.databind.ObjectMapper;

@Configuration(proxyBeanMethods = false)
public class ResourceLimits {
  @Bean
  WebServerFactoryCustomizer<JettyServletWebServerFactory> jettyLimits() {
    return factory ->
        factory.addServerCustomizers(
            server -> server.addBean(new NetworkConnectionLimit(256, server)));
  }

  /** 虚拟线程不等于无限并发；超过执行预算立即429，不积累无界等待队列。 */
  @Bean
  FilterRegistrationBean<OncePerRequestFilter> concurrentRequests(ObjectMapper json) {
    Semaphore slots = new Semaphore(128);
    var filter =
        new OncePerRequestFilter() {
          @Override
          protected void doFilterInternal(
              HttpServletRequest req, HttpServletResponse res, FilterChain chain)
              throws ServletException, IOException {
            res.setHeader("Cache-Control", "no-store");
            if (!slots.tryAcquire()) {
              res.setStatus(429);
              res.setContentType("application/json");
              res.setCharacterEncoding("UTF-8");
              json.writeValue(res.getOutputStream(), ErrorBody.forStatus(429));
              return;
            }
            try {
              chain.doFilter(req, res);
            } finally {
              slots.release();
            }
          }
        };
    var registration = new FilterRegistrationBean<OncePerRequestFilter>(filter);
    registration.setOrder(-200);
    return registration;
  }
}
