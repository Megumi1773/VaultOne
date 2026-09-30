package app.vaultone.server.sync.repository;

import app.vaultone.server.common.DbDialect;
import java.util.List;
import java.util.Optional;
import javax.sql.DataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

/**
 * 同步域的原生 SQL 访问：账户行锁、条目当前态读取、写入、版本历史与 change_log 游标。逐条对齐 {@code
 * crates/vault-server/src/routes_sync.rs}。
 *
 * <p>所有时间列为 ISO-8601 UTC 文本（字典序即时间序），由 {@link app.vaultone.server.common.InstantText#format(long)}
 * 生成；blob/blob_hash 是客户端密封盒材料，服务端不解密。
 */
@Repository
public class SyncRepository {
  private final JdbcTemplate jdbc;
  private final DbDialect dialect;

  public SyncRepository(DataSource dataSource, DbDialect dialect) {
    this.jdbc = new JdbcTemplate(dataSource);
    this.dialect = dialect;
  }

  /** 条目当前态（不含 blob）：版本、哈希、类型、删除标记、更新时间。 */
  public record ItemRow(
      long revision, byte[] blobHash, String kind, long deleted, String updatedAt) {}

  /** change_log 连接 items 的拉取行。 */
  public record PullRow(
      long seq,
      String id,
      String kind,
      byte[] blob,
      long revision,
      long deleted,
      String updatedAt) {}

  /** 读取条目当前态；不存在返回空。 */
  public Optional<ItemRow> currentItem(String userId, String itemId) {
    List<ItemRow> rows =
        jdbc.query(
            "SELECT revision, blob_hash, kind, deleted, updated_at FROM items WHERE user_id = ? AND id = ?",
            (rs, i) ->
                new ItemRow(
                    rs.getLong("revision"),
                    rs.getBytes("blob_hash"),
                    rs.getString("kind"),
                    rs.getLong("deleted"),
                    rs.getString("updated_at")),
            userId,
            itemId);
    return rows.isEmpty() ? Optional.empty() : Optional.of(rows.get(0));
  }

  /** 已有行则按 {@code (user_id, id)} 更新，否则插入新行；语义与 Rust 的两分支一致。 */
  public void upsertItem(
      String userId,
      String itemId,
      String kind,
      byte[] blob,
      byte[] blobHash,
      long revision,
      long deleted,
      String updatedAt,
      String deviceId,
      String createdAt) {
    int updated =
        jdbc.update(
            "UPDATE items SET kind = ?, blob = ?, blob_hash = ?, revision = ?, deleted = ?,"
                + " updated_at = ?, device_id = ? WHERE user_id = ? AND id = ?",
            kind,
            blob,
            blobHash,
            revision,
            deleted,
            updatedAt,
            deviceId,
            userId,
            itemId);
    if (updated == 0) {
      jdbc.update(
          "INSERT INTO items(user_id, id, kind, blob, blob_hash, revision, deleted, updated_at,"
              + " device_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          userId,
          itemId,
          kind,
          blob,
          blobHash,
          revision,
          deleted,
          updatedAt,
          deviceId,
          createdAt);
    }
  }

  /** 追加一条版本历史。 */
  public void insertVersion(
      String userId, String itemId, long revision, byte[] blob, String deviceId, String createdAt) {
    jdbc.update(
        "INSERT INTO item_versions(user_id, item_id, revision, blob, device_id, created_at)"
            + " VALUES(?, ?, ?, ?, ?, ?)",
        userId,
        itemId,
        revision,
        blob,
        deviceId,
        createdAt);
  }

  /** 每条目仅保留最新一行 change_log：先删后插。 */
  public void replaceChangeLog(String userId, String itemId, long revision, String createdAt) {
    jdbc.update("DELETE FROM change_log WHERE user_id = ? AND item_id = ?", userId, itemId);
    jdbc.update(
        "INSERT INTO change_log(user_id, item_id, revision, created_at) VALUES(?, ?, ?, ?)",
        userId,
        itemId,
        revision,
        createdAt);
  }

  /** 按 change_log.seq 拉取当前用户 {@code seq > cursor} 的条目，最多 {@code limitPlusOne} 行。 */
  public List<PullRow> pull(String userId, long cursor, int limitPlusOne) {
    return jdbc.query(
        "SELECT c.seq, i.id, i.kind, i.blob, i.revision, i.deleted, i.updated_at"
            + " FROM change_log c JOIN items i ON i.user_id = c.user_id AND i.id = c.item_id"
            + " WHERE c.user_id = ? AND c.seq > ? ORDER BY c.seq LIMIT ?",
        (rs, i) ->
            new PullRow(
                rs.getLong("seq"),
                rs.getString("id"),
                rs.getString("kind"),
                rs.getBytes("blob"),
                rs.getLong("revision"),
                rs.getLong("deleted"),
                rs.getString("updated_at")),
        userId,
        cursor,
        limitPlusOne);
  }

  /** 当前 vk_gen；账户不存在时由查询异常上抛（对齐 Rust fetch_one 语义）。 */
  public long currentVkGen(String userId) {
    Long vkGen = jdbc.queryForObject("SELECT vk_gen FROM users WHERE id = ?", Long.class, userId);
    return vkGen == null ? 0L : vkGen;
  }

  /** 注销账户时清理该账户的条目版本历史。 */
  public int deleteItemVersions(String userId) {
    return jdbc.update("DELETE FROM item_versions WHERE user_id = ?", userId);
  }

  /** 注销账户时清理该账户的 change_log。 */
  public int deleteChangeLog(String userId) {
    return jdbc.update("DELETE FROM change_log WHERE user_id = ?", userId);
  }

  /** 注销账户时清理该账户的条目。 */
  public int deleteItems(String userId) {
    return jdbc.update("DELETE FROM items WHERE user_id = ?", userId);
  }
}
