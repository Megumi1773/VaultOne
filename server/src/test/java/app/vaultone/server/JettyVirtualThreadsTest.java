package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.config.ResourceLimits;
import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.security.SecurityConfiguration;
import app.vaultone.server.web.ApiErrors;
import app.vaultone.server.web.WebSecurityHeaders;
import jakarta.servlet.Filter;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.core.env.Environment;
import tools.jackson.databind.json.JsonMapper;

/**
 * 真正启动短生命周期 Jetty 并发 HTTP 请求验证实际执行线程；不是 MockMvc。
 *
 * <p>同时验证安全边界仍然默认拒绝：非 {@code /v1}、非健康探针的未知路径被 Security 拒绝（不放行）， 且响应无 Cookie、无 WWW-Authenticate、带
 * no-store；未知 {@code /v1} 路径保持统一 JSON 外形。
 */
class JettyVirtualThreadsTest {
  @TestConfiguration(proxyBeanMethods = false)
  @EnableAutoConfiguration(
      excludeName = {
        "org.springframework.boot.jdbc.autoconfigure.DataSourceAutoConfiguration",
        "org.springframework.boot.hibernate.autoconfigure.HibernateJpaAutoConfiguration",
        "org.springframework.boot.flyway.autoconfigure.FlywayAutoConfiguration",
        "org.springframework.boot.webmvc.autoconfigure.error.ErrorMvcAutoConfiguration"
      })
  @Import({
    SecurityConfiguration.class,
    ResourceLimits.class,
    ApiErrors.class,
    WebSecurityHeaders.class
  })
  static class TransportOnly {
    @Bean
    AtomicBoolean servletWasVirtual() {
      return new AtomicBoolean();
    }

    @Bean
    VaultOneProperties vaultOneProperties(Environment env) {
      return new VaultOneProperties(
          "test",
          env.getProperty("vaultone.server-secret", ""),
          new VaultOneProperties.Redis("redis://127.0.0.1:1", null),
          new VaultOneProperties.Development(true, false),
          new VaultOneProperties.Session(60, 3600, 120, 600, 5, 3000, 10, 100, 120, 16),
          new VaultOneProperties.Mail("log", "x", "", 587, "", ""),
          new VaultOneProperties.Ops(30, Duration.ofDays(30), "100MB", "2GB", "logs", 64),
          new VaultOneProperties.Web(1048576L, 67108864L, 16, 100, 256, List.of()));
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
                "--spring.profiles.active=dev",
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

        var denied =
            client.send(
                HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/secret")).build(),
                HttpResponse.BodyHandlers.ofString());
        assertThat(denied.statusCode()).isIn(401, 403);
        assertThat(denied.headers().firstValue("Set-Cookie")).isEmpty();
        assertThat(denied.headers().firstValue("WWW-Authenticate")).isEmpty();
        assertThat(denied.headers().firstValue("Cache-Control").orElse("")).contains("no-store");

        // /v1 前缀被放行到 MVC；本传输层测试未装配控制器，未知 /v1 路径应为 404 且保持统一 JSON 外形。
        var notFound =
            client.send(
                HttpRequest.newBuilder(
                        URI.create("http://127.0.0.1:" + port + "/v1/does-not-exist"))
                    .build(),
                HttpResponse.BodyHandlers.ofString());
        assertThat(notFound.statusCode()).isEqualTo(404);
        assertThat(notFound.headers().firstValue("Set-Cookie")).isEmpty();
        assertThat(notFound.headers().firstValue("WWW-Authenticate")).isEmpty();
        assertThat(notFound.headers().firstValue("Cache-Control").orElse("")).contains("no-store");
        var json = JsonMapper.builder().build().readTree(notFound.body());
        assertThat(json.size()).isEqualTo(2);
        assertThat(json.get("code").asText()).isEqualTo("not_found");
        assertThat(json.has("message")).isTrue();
      }
    }
  }
}
