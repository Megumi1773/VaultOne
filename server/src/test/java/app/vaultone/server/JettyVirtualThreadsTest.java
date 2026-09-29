package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.config.ResourceLimits;
import app.vaultone.server.security.SecurityConfiguration;
import app.vaultone.server.web.ApiErrors;
import jakarta.servlet.Filter;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import tools.jackson.databind.json.JsonMapper;

/** 真正启动短生命周期Jetty，发HTTP请求验证实际执行线程；不是MockMvc。 */
class JettyVirtualThreadsTest {
  @TestConfiguration(proxyBeanMethods = false)
  @EnableAutoConfiguration(
      excludeName = {
        "org.springframework.boot.jdbc.autoconfigure.DataSourceAutoConfiguration",
        "org.springframework.boot.hibernate.autoconfigure.HibernateJpaAutoConfiguration",
        "org.springframework.boot.flyway.autoconfigure.FlywayAutoConfiguration"
      })
  @Import({SecurityConfiguration.class, ResourceLimits.class, ApiErrors.class})
  static class TransportOnly {
    @Bean
    AtomicBoolean servletWasVirtual() {
      return new AtomicBoolean();
    }

    @Bean
    FilterRegistrationBean<Filter> captureThread(AtomicBoolean observed) {
      var registration =
          new FilterRegistrationBean<Filter>(
              (req, res, chain) -> {
                observed.set(Thread.currentThread().isVirtual());
                chain.doFilter(req, res);
              });
      registration.setOrder(-300);
      return registration;
    }
  }

  @Test
  void jettyUsesVirtualThreadsAndSecurityFailsClosed() throws Exception {
    try (var context =
        new SpringApplicationBuilder(TransportOnly.class)
            .run(
                "--spring.profiles.active=local",
                "--vaultone.development.enabled=true",
                "--vaultone.server-secret=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                "--spring.datasource.url=jdbc:postgresql://127.0.0.1:1/unused",
                "--vaultone.redis.address=redis://127.0.0.1:1",
                "--server.port=0",
                "--management.endpoint.health.group.readiness.include=readinessState")) {
      var web = (ServletWebServerApplicationContext) context;
      assertThat(web.getWebServer().getClass().getName()).contains("Jetty");
      int port = web.getWebServer().getPort();
      try (HttpClient client = HttpClient.newHttpClient()) {
        var live =
            client.send(
                HttpRequest.newBuilder(
                        URI.create("http://127.0.0.1:" + port + "/actuator/health/liveness"))
                    .build(),
                HttpResponse.BodyHandlers.ofString());
        assertThat(live.statusCode()).isEqualTo(200);
        assertThat(context.getBean(AtomicBoolean.class)).isTrue();
        for (String authorization :
            new String[] {"", "Basic dGVzdDp0ZXN0", "Bearer not-a-real-session"}) {
          var request =
              HttpRequest.newBuilder(
                  URI.create("http://127.0.0.1:" + port + "/v1/not-implemented"));
          if (!authorization.isEmpty()) request.header("Authorization", authorization);
          var response = client.send(request.build(), HttpResponse.BodyHandlers.ofString());
          assertThat(response.statusCode()).isEqualTo(401);
          assertThat(response.headers().firstValue("Set-Cookie")).isEmpty();
          assertThat(response.headers().firstValue("WWW-Authenticate")).isEmpty();
          assertThat(response.headers().firstValue("Cache-Control").orElse(""))
              .contains("no-store");
          var json = JsonMapper.builder().build().readTree(response.body());
          assertThat(json.size()).isEqualTo(2);
          assertThat(json.get("code").asText()).isEqualTo("unauthorized");
          assertThat(json.has("message")).isTrue();
        }
      }
    }
  }
}
