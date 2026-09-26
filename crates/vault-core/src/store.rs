//! 本地保险库存储（SQLite，rusqlite bundled）。
//!
//! 本地库是"唯一真相源"（计划书 §1.2）。设计要点：
//! - 只保存密文信封与非敏感元数据（条目类型、版本号、时间戳）；邮箱、会话 token 等也以
//!   AES-256-GCM 密封盒存储。不建明文搜索索引——搜索在解锁后于内存中完成，
//!   因此数据库文件中检索不到任何 URL / 用户名 / 密码（F-03 验收要点，见 vault 测试）。
//! - `secure_delete=ON` 保证删除/更新的旧页被覆写，不会残留在空闲页中。
//! - `dirty=1` 的条目即离线队列（outbox）：联网后按版本号幂等补传。

use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use vault_crypto::kdf::KdfParams;

use crate::Result;

const SCHEMA_VERSION: i32 = 1;

const SCHEMA_V1: &str = r#"
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS items (
  id          TEXT PRIMARY KEY,
  vault_id    TEXT NOT NULL,
  kind        TEXT NOT NULL,
  blob        BLOB NOT NULL,
  revision    INTEGER NOT NULL,
  server_rev  INTEGER NOT NULL DEFAULT 0,
  base_blob   BLOB,
  dirty       INTEGER NOT NULL DEFAULT 1,
  deleted_at  INTEGER,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_items_vault ON items(vault_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_items_dirty ON items(dirty);
CREATE TABLE IF NOT EXISTS sync_state (
  vault_id      TEXT PRIMARY KEY,
  cursor        INTEGER NOT NULL DEFAULT 0,
  last_sync_at  INTEGER
);
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"#;

/// 账户与保险库的本地元数据。除注明外均为公开参数或密封盒密文（base64）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountRecord {
    pub account_id: String,
    pub vault_id: String,
    pub kdf: KdfParams,
    /// Vault Key ← WrapKey 密封盒
    pub vk_wrap: String,
    pub vk_gen: i64,
    /// Vault Key ← RecoveryCode 密封盒
    pub recovery_wrap: String,
    /// SHA-256(恢复认证 token)，不可逆，用于服务端恢复校验
    pub recovery_auth_hash: String,
    /// 邮箱 ← Vault Key 密封盒
    pub email_enc: String,
    /// SRP-6a 注册数据（verifier 由 256-bit AuthKey 计算，不可离线爆破）
    pub srp_salt: String,
    pub srp_verifier: String,
    /// 本地凭据（主密码/恢复码）已变更但尚未推送到服务端
    #[serde(default)]
    pub credentials_dirty: bool,
    pub created_at: i64,
}

/// 同步服务连接信息。token 以 Vault Key 密封，未解锁时无法使用。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteRecord {
    pub server_url: String,
    pub device_id: String,
    pub device_name: String,
    /// 会话 token ← Vault Key 密封盒
    pub token_enc: String,
    pub expires_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemRow {
    pub id: String,
    pub vault_id: String,
    pub kind: String,
    pub blob: Vec<u8>,
    pub revision: i64,
    /// 最后一次与服务端一致的版本号（0 = 从未同步）
    pub server_rev: i64,
    /// 最后一次与服务端一致的密文（三方合并的 base）
    pub base_blob: Option<Vec<u8>>,
    pub dirty: bool,
    pub deleted_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

pub struct Store {
    conn: Connection,
}

const ITEM_COLS: &str = "id, vault_id, kind, blob, revision, server_rev, base_blob, dirty, deleted_at, created_at, updated_at";

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "secure_delete", "ON")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        // 内存库不支持 WAL，返回 "memory"，忽略即可
        let _: String = conn.query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))?;
        let version: i32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version < SCHEMA_VERSION {
            conn.execute_batch(SCHEMA_V1)?;
            conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        }
        Ok(Self { conn })
    }

    // ───────── meta ─────────

    fn get_meta<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        let raw: Option<String> = self.conn.query_row("SELECT value FROM meta WHERE key = ?1", params![key], |r| r.get(0)).optional()?;
        raw.map(|s| serde_json::from_str(&s).map_err(Into::into)).transpose()
    }

    fn put_meta<T: Serialize>(&self, key: &str, value: &T) -> Result<()> {
        self.conn.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, serde_json::to_string(value)?],
        )?;
        Ok(())
    }

    fn delete_meta(&self, key: &str) -> Result<()> {
        self.conn.execute("DELETE FROM meta WHERE key = ?1", params![key])?;
        Ok(())
    }

    pub fn load_account(&self) -> Result<Option<AccountRecord>> {
        self.get_meta("account")
    }

    pub fn save_account(&self, account: &AccountRecord) -> Result<()> {
        self.put_meta("account", account)
    }

    pub fn load_remote(&self) -> Result<Option<RemoteRecord>> {
        self.get_meta("remote")
    }

    pub fn save_remote(&self, remote: &RemoteRecord) -> Result<()> {
        self.put_meta("remote", remote)
    }

    pub fn clear_remote(&self) -> Result<()> {
        self.delete_meta("remote")
    }

    /// 快速解锁（生物识别）用的 Vault Key 密封盒，base64。
    pub fn load_quick_unlock(&self) -> Result<Option<String>> {
        self.get_meta("quick_unlock")
    }

    pub fn save_quick_unlock(&self, blob: &str) -> Result<()> {
        self.put_meta("quick_unlock", &blob)
    }

    pub fn clear_quick_unlock(&self) -> Result<()> {
        self.delete_meta("quick_unlock")
    }

    /// 本设备 ID（首次需要时生成，与账户无关，长期不变）。
    pub fn device_id(&self) -> Result<String> {
        if let Some(id) = self.get_meta::<String>("device_id")? {
            return Ok(id);
        }
        let id = uuid::Uuid::new_v4().to_string();
        self.put_meta("device_id", &id)?;
        Ok(id)
    }

    // ───────── items ─────────

    pub fn get_item(&self, id: &str) -> Result<Option<ItemRow>> {
        Ok(self.conn.query_row(&format!("SELECT {ITEM_COLS} FROM items WHERE id = ?1"), params![id], row_to_item).optional()?)
    }

    pub fn list_items(&self, vault_id: &str, deleted: bool) -> Result<Vec<ItemRow>> {
        let filter = if deleted { "IS NOT NULL" } else { "IS NULL" };
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {ITEM_COLS} FROM items WHERE vault_id = ?1 AND deleted_at {filter} ORDER BY updated_at DESC"))?;
        let rows = stmt.query_map(params![vault_id], row_to_item)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn dirty_items(&self) -> Result<Vec<ItemRow>> {
        let mut stmt = self.conn.prepare(&format!("SELECT {ITEM_COLS} FROM items WHERE dirty = 1 ORDER BY updated_at"))?;
        let rows = stmt.query_map([], row_to_item)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn put_item(&self, row: &ItemRow) -> Result<()> {
        self.conn.execute(
            &format!(
                "INSERT INTO items({ITEM_COLS}) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                 ON CONFLICT(id) DO UPDATE SET
                   kind = excluded.kind, blob = excluded.blob, revision = excluded.revision,
                   server_rev = excluded.server_rev, base_blob = excluded.base_blob, dirty = excluded.dirty,
                   deleted_at = excluded.deleted_at, updated_at = excluded.updated_at"
            ),
            params![
                row.id,
                row.vault_id,
                row.kind,
                row.blob,
                row.revision,
                row.server_rev,
                row.base_blob,
                row.dirty,
                row.deleted_at,
                row.created_at,
                row.updated_at
            ],
        )?;
        Ok(())
    }

    /// 推送成功后标记已同步：仅当本地版本未在推送期间再次变化时才清除 dirty。
    pub fn mark_synced(&self, id: &str, revision: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE items SET dirty = 0, server_rev = revision, base_blob = blob WHERE id = ?1 AND revision = ?2",
            params![id, revision],
        )?;
        Ok(())
    }

    pub fn pending_count(&self) -> Result<u64> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM items WHERE dirty = 1", [], |r| r.get::<_, i64>(0))? as u64)
    }

    pub fn item_count(&self) -> Result<u64> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM items WHERE deleted_at IS NULL", [], |r| r.get::<_, i64>(0))? as u64)
    }

    /// 将所有条目重新标记为待推送（换绑服务器时使用）。
    pub fn mark_all_dirty(&self) -> Result<()> {
        self.conn.execute("UPDATE items SET dirty = 1, server_rev = 0, base_blob = NULL", [])?;
        Ok(())
    }

    // ───────── sync state ─────────

    pub fn cursor(&self, vault_id: &str) -> Result<i64> {
        Ok(self
            .conn
            .query_row("SELECT cursor FROM sync_state WHERE vault_id = ?1", params![vault_id], |r| r.get(0))
            .optional()?
            .unwrap_or(0))
    }

    pub fn set_cursor(&self, vault_id: &str, cursor: i64, now: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO sync_state(vault_id, cursor, last_sync_at) VALUES(?1, ?2, ?3)
             ON CONFLICT(vault_id) DO UPDATE SET cursor = excluded.cursor, last_sync_at = excluded.last_sync_at",
            params![vault_id, cursor, now],
        )?;
        Ok(())
    }

    pub fn last_sync_at(&self, vault_id: &str) -> Result<Option<i64>> {
        Ok(self
            .conn
            .query_row("SELECT last_sync_at FROM sync_state WHERE vault_id = ?1", params![vault_id], |r| r.get(0))
            .optional()?
            .flatten())
    }

    pub fn reset_sync_state(&self) -> Result<()> {
        self.conn.execute("DELETE FROM sync_state", [])?;
        Ok(())
    }

    // ───────── settings（非敏感偏好） ─────────

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        Ok(self.conn.query_row("SELECT value FROM settings WHERE key = ?1", params![key], |r| r.get(0)).optional()?)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO settings(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    /// 彻底清除本地保险库（用户注销/重置设备）。
    pub fn wipe(&self) -> Result<()> {
        self.conn.execute_batch(
            "DELETE FROM items; DELETE FROM sync_state; DELETE FROM settings; DELETE FROM meta WHERE key <> 'device_id'; VACUUM;",
        )?;
        Ok(())
    }

    pub fn transaction<T>(&mut self, f: impl FnOnce(&Store) -> Result<T>) -> Result<T> {
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        match f(self) {
            Ok(v) => {
                self.conn.execute_batch("COMMIT")?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }
}

fn row_to_item(r: &rusqlite::Row<'_>) -> rusqlite::Result<ItemRow> {
    Ok(ItemRow {
        id: r.get(0)?,
        vault_id: r.get(1)?,
        kind: r.get(2)?,
        blob: r.get(3)?,
        revision: r.get(4)?,
        server_rev: r.get(5)?,
        base_blob: r.get(6)?,
        dirty: r.get(7)?,
        deleted_at: r.get(8)?,
        created_at: r.get(9)?,
        updated_at: r.get(10)?,
    })
}
