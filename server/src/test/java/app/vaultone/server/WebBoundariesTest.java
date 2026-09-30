package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.common.RateLimitUnavailableException;
import app.vaultone.server.common.RateLimiter;
import app.vaultone.server.config.ResourceLimits;
import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.security.SecurityConfiguration;
import app.vaultone.server.web.ApiErrors;
import app.vaultone.server.web.RateLimitWebConfiguration;
import app.vaultone.server.web.RequestIdFilter;
import app.vaultone.server.web.RequestIds;
import app.vaultone.server.web.WebSecurityHeaders;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.EnableAutoConfiguration;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * 真实 Jetty 上的 Web 边界测试（非 MockMvc）：错误分类 400/405/413/415/422/429/503、限流失败安全拒绝、统一 no-store 安全头、请求 ID
 * 受控传播与 JSON 深度上限。
 */
class WebBoundariesTest {
  enum Mode {
    ALLOW,
    DENY,
    FAIL
  }

  static final AtomicReference<Mode> MODE = new AtomicReference<>(Mode.ALLOW);

  static final class FakeRateLimiter implements RateLimiter {
    @Override
    public boolean tryAcquire(String group, String clientAddress) {
      return switch (MODE.get()) {
        case ALLOW -> true;
        case DENY -> false;
        case FAIL -> {
          throw new RateLimitUnavailableException("test", new RuntimeException("boom"));
        }
      };
    }
  }

  @RestController
  static class ProbeController {
    record Probe(String value) {}

    @PostMapping("/v1/probe")
    Map<String, String> probe(@RequestBody Probe body) {
      return Map.of("ok", "true");
    }

    @GetMapping("/v1/probe/request-id")
    Map<String, String> requestId() {
      return Map.of("requestId", String.valueOf(RequestIds.currentRequestId()));
    }
  }

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
    WebSecurityHeaders.class,
    RateLimitWebConfiguration.class,
    RequestIdFilter.class,
    ProbeController.class
  })
  static class Boundaries {
    @Bean
    VaultOneProperties vaultOneProperties() {
      return new VaultOneProperties(
          "test",
          "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
          new VaultOneProperties.Redis("redis://127.0.0.1:1", null),
          new VaultOneProperties.Development(true, false),
          new VaultOneProperties.Session(60, 3600, 120, 600, 5, 3000, 10, 100, 120, 16),
          new VaultOneProperties.Mail("log", "x", "", 587, "", ""),
          new VaultOneProperties.Ops(30, Duration.ofDays(30), "100MB", "2GB", "logs", 64),
          new VaultOneProperties.Web(1024L, 2048L, 16, 16, 256, List.of()));
    }

    @Bean
    RateLimiter rateLimiter() {
      return new FakeRateLimiter();
    }
  }

  @Test
  void errorClassificationAndRateLimitFailClosed() throws Exception {
    MODE.set(Mode.ALLOW);
    try (var context = start()) {
      int port = ((ServletWebServerApplicationContext) context).getWebServer().getPort();
      String base = "http://127.0.0.1:" + port + "/v1/probe";
      try (HttpClient client = HttpClient.newHttpClient()) {
        assertOk(client, base);
        assertError(client, base, "application/json", "{", 400, "bad_request");
        assertError(
            client, base, "application/json", "{\"value\":{\"a\":1}}", 422, "unprocessable_entity");
        assertError(client, base, "text/plain", "plain", 415, "unsupported_media_type");
        assertMethodNotAllowed(client, base);

        // JSON 深度超过应用级上限（16）：未知字段也会被解析计数，解析失败 400。
        String nested = "{\"value\":\"x\",\"deep\":" + "{".repeat(21) + "1" + "}".repeat(21) + "}";
        assertError(client, base, "application/json", nested, 400, "bad_request");

        // 超过通用 1KiB 上限：按 Content-Length 早拒绝 413。
        String big = "{\"value\":\"" + "a".repeat(2048) + "\"}";
        assertError(client, base, "application/json", big, 413, "payload_too_large");

        MODE.set(Mode.DENY);
        assertError(client, base, "application/json", "{\"value\":\"x\"}", 429, "rate_limited");

        MODE.set(Mode.FAIL);
        assertError(
            client, base, "application/json", "{\"value\":\"x\"}", 503, "service_unavailable");
      } finally {
        MODE.set(Mode.ALLOW);
      }
    }
  }

  @Test
  void requestIdIsValidatedAndPropagatedConsistently() throws Exception {
    MODE.set(Mode.ALLOW);
    try (var context = start()) {
      int port = ((ServletWebServerApplicationContext) context).getWebServer().getPort();
      try (HttpClient client = HttpClient.newHttpClient()) {
        // 合法头：原样保留并作为 response/log/audit 的同一 ID。
        assertRequestId(client, port, "abc-123_XYZ.9", "abc-123_XYZ.9");

        // 缺头：生成新 ID，响应头与业务读取值一致。
        HttpResponse<String> generated = getRequestId(client, port, null);
        String generatedId = generated.headers().firstValue("x-request-id").orElse("");
        assertThat(generatedId).isNotBlank();
        assertThat(bodyRequestId(generated)).isEqualTo(generatedId);

        // 非法字符（空格）：不回显原始值，生成新 ID 且业务读到同一受控 ID。
        HttpResponse<String> illegal = getRequestId(client, port, "bad id");
        assertThat(illegal.headers().firstValue("x-request-id").orElse("")).isNotEqualTo("bad id");
        assertThat(bodyRequestId(illegal))
            .isEqualTo(illegal.headers().firstValue("x-request-id").orElse(""));

        // 超长：同样拒绝回显。
        String overlong = "a".repeat(200);
        HttpResponse<String> longResponse = getRequestId(client, port, overlong);
        assertThat(longResponse.headers().firstValue("x-request-id").orElse(""))
            .isNotEqualTo(overlong);
        assertThat(longResponse.body()).doesNotContain(overlong);
      }
    }
  }

  private static org.springframework.context.ConfigurableApplicationContext start() {
    return new SpringApplicationBuilder(Boundaries.class)
        .run(
            "--spring.profiles.active=dev",
            "--vaultone.development.enabled=true",
            "--vaultone.server-secret=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
            "--server.port=0",
            "--management.endpoint.health.group.readiness.include=readinessState");
  }

  private static void assertOk(HttpClient client, String base) throws Exception {
    HttpResponse<String> response = post(client, base, "application/json", "{\"value\":\"x\"}");
    assertThat(response.statusCode()).isEqualTo(200);
    assertThat(response.headers().firstValue("Cache-Control").orElse("")).contains("no-store");
  }

  private static void assertMethodNotAllowed(HttpClient client, String base) throws Exception {
    HttpResponse<String> response =
        client.send(
            HttpRequest.newBuilder(URI.create(base)).GET().build(),
            HttpResponse.BodyHandlers.ofString());
    assertThat(response.statusCode()).isEqualTo(405);
    JsonNode json = JsonMapper.builder().build().readTree(response.body());
    assertThat(json.get("code").asText()).isEqualTo("method_not_allowed");
    assertThat(json.get("message").asText()).doesNotContain("接口不存在");
  }

  private static void assertError(
      HttpClient client, String base, String contentType, String body, int status, String code)
      throws Exception {
    HttpResponse<String> response = post(client, base, contentType, body);
    assertThat(response.statusCode()).as(code).isEqualTo(status);
    assertThat(response.headers().firstValue("Cache-Control").orElse("")).contains("no-store");
    JsonNode json = JsonMapper.builder().build().readTree(response.body());
    assertThat(json.get("code").asText()).isEqualTo(code);
    assertThat(json.has("message")).isTrue();
  }

  private static void assertRequestId(
      HttpClient client, int port, String sentHeader, String expected) throws Exception {
    HttpResponse<String> response = getRequestId(client, port, sentHeader);
    assertThat(response.statusCode()).isEqualTo(200);
    assertThat(response.headers().firstValue("x-request-id").orElse("")).isEqualTo(expected);
    assertThat(bodyRequestId(response)).isEqualTo(expected);
  }

  private static HttpResponse<String> getRequestId(HttpClient client, int port, String header)
      throws Exception {
    HttpRequest.Builder builder =
        HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/v1/probe/request-id"));
    if (header != null) {
      builder.header("x-request-id", header);
    }
    return client.send(builder.build(), HttpResponse.BodyHandlers.ofString());
  }

  private static String bodyRequestId(HttpResponse<String> response) throws Exception {
    JsonNode json = JsonMapper.builder().build().readTree(response.body());
    return json.get("requestId").asText();
  }

  private static HttpResponse<String> post(
      HttpClient client, String base, String contentType, String body) throws Exception {
    return client.send(
        HttpRequest.newBuilder(URI.create(base))
            .header("Content-Type", contentType)
            .POST(HttpRequest.BodyPublishers.ofString(body))
            .build(),
        HttpResponse.BodyHandlers.ofString());
  }
}
