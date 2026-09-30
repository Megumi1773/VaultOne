package app.vaultone.server.support;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 集成测试驱动解析：只接受严格回环地址，允许空口令但要求 URL/用户显式提供；不使用 contains 判回环。
 *
 * <p>外部模式（{@code VAULTONE_IT_MODE=external}）读取本机 PG/Redis；默认模式由 Testcontainers 提供地址，
 * 在此同样按严格解析构造连接信息。
 */
public final class ItConnection {

  private static final List<String> LOOPBACK_HOSTS = List.of("127.0.0.1", "::1", "localhost");

  private final URI jdbcUri;
  private final String jdbcUrl;
  private final String host;
  private final int port;
  private final String database;
  private final String user;
  private final String password;

  private ItConnection(
      URI jdbcUri,
      String jdbcUrl,
      String host,
      int port,
      String database,
      String user,
      String password) {
    this.jdbcUri = jdbcUri;
    this.jdbcUrl = jdbcUrl;
    this.host = host;
    this.port = port;
    this.database = database;
    this.user = user;
    this.password = password;
  }

  public URI uri() {
    return jdbcUri;
  }

  public String jdbcUrl() {
    return jdbcUrl;
  }

  public String host() {
    return host;
  }

  public int port() {
    return port;
  }

  public String database() {
    return database;
  }

  public String user() {
    return user;
  }

  public String password() {
    return password;
  }

  /** 用另一 database 覆盖当前 URL，保持 host/port 与查询参数不变。 */
  public String jdbcUrlFor(String database) {
    StringBuilder sb =
        new StringBuilder("jdbc:postgresql://")
            .append(host)
            .append(':')
            .append(port)
            .append('/')
            .append(database);
    String query = jdbcUri.getRawQuery();
    if (query != null) {
      sb.append('?').append(query);
    }
    return sb.toString();
  }

  /**
   * 严格解析并校验 JDBC PostgreSQL URL：scheme 必须为 {@code jdbc:postgresql}，主机必须是回环，端口显式， 不允许 userinfo
   * 内嵌口令，database 必须显式。
   */
  public static ItConnection jdbc(String jdbcUrl, String user, String password) {
    if (!jdbcUrl.startsWith("jdbc:postgresql://")) {
      throw new IllegalArgumentException("只允许 jdbc:postgresql:// 地址");
    }
    URI uri;
    try {
      uri = new URI(jdbcUrl.substring("jdbc:".length()));
    } catch (URISyntaxException ex) {
      throw new IllegalArgumentException("JDBC 地址无法解析");
    }
    if (uri.getUserInfo() != null) {
      throw new IllegalArgumentException("JDBC URL 不得内嵌用户/口令，口令请用独立变量");
    }
    if (uri.getFragment() != null) {
      throw new IllegalArgumentException("JDBC URL 不得包含 fragment");
    }
    String host = uri.getHost();
    if (host == null || !LOOPBACK_HOSTS.contains(host)) {
      throw new IllegalArgumentException("集成测试只允许回环 PG 主机，收到: " + host);
    }
    if (uri.getPort() <= 0 || uri.getPort() > 65535) {
      throw new IllegalArgumentException("JDBC URL 必须显式指定有效端口");
    }
    String path = uri.getPath();
    String database = path == null ? "" : path.replaceFirst("^/", "");
    if (database.isBlank() || database.contains("/")) {
      throw new IllegalArgumentException("JDBC URL 必须指定单一数据库");
    }
    if (user == null || user.isBlank()) {
      throw new IllegalArgumentException("必须显式提供管理用户");
    }
    return new ItConnection(
        uri, jdbcUrl, host, uri.getPort(), database, user, password == null ? "" : password);
  }

  /** 严格解析 Redis 地址：scheme 必须为 redis/rediss，主机回环，不允许 userinfo（口令用独立变量）。 */
  public static RedisConn redis(String address, String password) {
    if (address == null || address.isBlank()) {
      throw new IllegalArgumentException("必须显式提供 Redis 地址");
    }
    URI uri;
    try {
      uri = new URI(address.trim());
    } catch (URISyntaxException ex) {
      throw new IllegalArgumentException("Redis 地址无法解析");
    }
    String scheme = uri.getScheme();
    if (!"redis".equals(scheme) && !"rediss".equals(scheme)) {
      throw new IllegalArgumentException("Redis 地址协议非法: " + scheme);
    }
    if (uri.getUserInfo() != null) {
      throw new IllegalArgumentException("Redis 地址不得内嵌口令，口令请用独立变量");
    }
    String host = uri.getHost();
    if (host == null || !LOOPBACK_HOSTS.contains(host)) {
      throw new IllegalArgumentException("集成测试只允许回环 Redis 主机，收到: " + host);
    }
    if (uri.getPort() <= 0 || uri.getPort() > 65535) {
      throw new IllegalArgumentException("Redis 地址必须显式指定端口");
    }
    if (uri.getPath() != null && !uri.getPath().isEmpty() && !"/".equals(uri.getPath())) {
      throw new IllegalArgumentException("Redis 地址不得包含路径");
    }
    return new RedisConn(address.trim(), host, uri.getPort(), password == null ? "" : password);
  }

  /** Redis 连接（口令可为空）。 */
  public record RedisConn(String address, String host, int port, String password) {
    @Override
    public String toString() {
      return "RedisConn[address=" + address + ", password=<redacted>]";
    }
  }

  /** 计数字符串中出现的裸标识符（用于基本校验，不用于安全判定）。 */
  static Map<String, Integer> countOccurrences(String haystack, String needle) {
    Map<String, Integer> out = new LinkedHashMap<>();
    int idx = 0;
    int count = 0;
    while ((idx = haystack.indexOf(needle, idx)) >= 0) {
      count++;
      idx += needle.length();
    }
    out.put(needle, count);
    return out;
  }

  static List<String> loopbackHosts() {
    return new ArrayList<>(LOOPBACK_HOSTS);
  }
}
