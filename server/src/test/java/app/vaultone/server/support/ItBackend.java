package app.vaultone.server.support;

import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.UUID;

/**
 * 真实后端资源的创建/清理契约。实现负责：
 *
 * <ul>
 *   <li>提供一个隔离数据库（随机新库），其 owner 是<b>专用非 superuser、非 BYPASSRLS 的 migrator 角色</b>。
 *   <li>{@link #migrator()}：Flyway 迁移与 DDL 用；也是 SECURITY DEFINER 函数 owner（受 FORCE RLS 约束）。
 *   <li>{@link #runtime()}：业务运行角色，非 owner、非 superuser、非 BYPASSRLS；无上下文时 RLS 默认拒绝。
 *   <li>提供 Redis 地址与唯一命名空间前缀。
 *   <li>清理只删除本次创建的资源；清理失败必须上抛（不吞错），并保留原始失败。
 * </ul>
 */
public interface ItBackend extends AutoCloseable {
  /** 迁移/DDL 连接：库 owner，非 superuser/非 BYPASSRLS。 */
  ItConnection migrator();

  /** 业务运行连接：非 owner、非 superuser、非 BYPASSRLS。 */
  ItConnection runtime();

  /** Redis 地址与口令（口令可空）。 */
  ItConnection.RedisConn redis();

  /** 本次测试独占的 Redis 前缀，形如 {@code vaultone:it:<uuid>:}。 */
  String redisNamespace();

  /** 释放连接池/上下文；只删本次创建资源。清理失败上抛。 */
  @Override
  void close();

  static String randomSuffix() {
    return UUID.randomUUID().toString().replace("-", "").substring(0, 20);
  }

  /** 生成安全标识符：字母开头 + 小写/数字/下划线，长度受 PostgreSQL 的 63 字节限制。 */
  static String safeIdentifier(String prefix, String suffix) {
    String raw = (prefix + "_" + suffix).toLowerCase().replaceAll("[^a-z0-9_]", "_");
    if (!Character.isLetter(raw.charAt(0))) {
      raw = "x" + raw;
    }
    return raw.length() > 63 ? raw.substring(0, 63) : raw;
  }

  static void execQuietly(Connection connection, String sql) {
    try (Statement statement = connection.createStatement()) {
      statement.execute(sql);
    } catch (SQLException ignored) {
      // 清理路径 best-effort：调用方决定是否上抛。
    }
  }
}
