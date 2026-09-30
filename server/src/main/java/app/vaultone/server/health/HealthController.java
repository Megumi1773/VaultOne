package app.vaultone.server.health;

import java.util.Map;
import javax.sql.DataSource;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 健康探针，逐字对齐 Rust {@code /healthz} 与 {@code /readyz} 的响应体： {@code {"status":"ok","version":"<版本>"}}
 * 与 {@code {"status":"ready"}}；DB 不可达时 readyz 返回 503 {@code {"status":"unavailable"}}。不泄露内部错误细节。
 */
@RestController
public class HealthController {
  private final JdbcTemplate jdbc;
  private final String version;

  public HealthController(
      DataSource dataSource, @Value("${vaultone.api-version:1.0.0}") String version) {
    this.jdbc = new JdbcTemplate(dataSource);
    this.version = version;
  }

  @GetMapping("/healthz")
  public Map<String, String> healthz() {
    return Map.of("status", "ok", "version", version);
  }

  @GetMapping("/readyz")
  public ResponseEntity<Map<String, String>> readyz() {
    try {
      jdbc.queryForObject("SELECT 1", Integer.class);
      return ResponseEntity.ok(Map.of("status", "ready"));
    } catch (RuntimeException ex) {
      return ResponseEntity.status(503).body(Map.of("status", "unavailable"));
    }
  }
}
