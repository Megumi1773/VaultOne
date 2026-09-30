package app.vaultone.server.common;

import javax.sql.DataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** 数据方言探测：Java 服务生产只跑 PostgreSQL，但单元测试可能用内存或其它；据此在少数需要 {@code RETURNING} 的原子语句上选择实现。探测在启动后只做一次。 */
@Component
public class DbDialect {
  private final boolean postgres;

  public DbDialect(DataSource dataSource) {
    boolean pg;
    try (var connection = dataSource.getConnection()) {
      pg = connection.getMetaData().getDatabaseProductName().toLowerCase().contains("postgresql");
    } catch (Exception ex) {
      pg = false;
    }
    this.postgres = pg;
  }

  public boolean isPostgres() {
    return postgres;
  }

  public JdbcTemplate jdbc(DataSource dataSource) {
    return new JdbcTemplate(dataSource);
  }
}
