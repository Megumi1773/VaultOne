//! 本地保险库存储（SQLite，rusqlite bundled）。
//!
//! 本地库是条目的本地读写真相源；账户权限及云会话以服务端为准。设计要点：
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

use crate::conflict::ConflictRow;
use crate::{Result, VaultError};

const SCHEMA_VERSION: i32 = 2;

const SCHEMA_V2: &str = r#"
ALTER TABLE items ADD COLUMN base_deleted INTEGER;
UPDATE items SET base_deleted = (deleted_at IS NOT NULL) WHERE dirty = 0;
CREATE TABLE item_conflicts (
  id TEXT PRIMARY KEY,
  vault_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','resolution_pending','resolved','superseded')),
  blob BLOB NOT NULL
);
CREATE UNIQUE INDEX idx_conflict_active ON item_conflicts(vault_id, item_id)
  WHERE state IN ('pending','resolution_pending');
"#;

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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    /// None 表示旧库脏条目的基线墓碑未知，不可猜测。
    pub base_deleted: Option<bool>,
    pub dirty: bool,
    pub deleted_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

pub struct Store {
    conn: Connection,
}

const ITEM_COLS: &str =
    "id, vault_id, kind, blob, revision, server_rev, base_blob, dirty, deleted_at, created_at, updated_at, base_deleted";

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
        if version > SCHEMA_VERSION {
            return Err(VaultError::InvalidInput("本地数据库版本过新".into()));
        }
        if version < SCHEMA_VERSION {
            let tx = conn.unchecked_transaction()?;
            if version < 1 {
                tx.execute_batch(SCHEMA_V1)?;
            }
            if version < 2 {
                tx.execute_batch(SCHEMA_V2)?;
            }
            tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
            tx.commit()?;
        }
        Ok(Self { conn })
    }

    // ───────── meta ─────────

    pub(crate) fn get_meta<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        let raw: Option<String> = self.conn.query_row("SELECT value FROM meta WHERE key = ?1", params![key], |r| r.get(0)).optional()?;
        raw.map(|s| serde_json::from_str(&s).map_err(Into::into)).transpose()
    }

    pub(crate) fn put_meta<T: Serialize>(&self, key: &str, value: &T) -> Result<()> {
        self.conn.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, serde_json::to_string(value)?],
        )?;
        Ok(())
    }

    pub(crate) fn delete_meta(&self, key: &str) -> Result<()> {
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
        let mut stmt = self.conn.prepare(&format!("SELECT {ITEM_COLS} FROM items WHERE dirty = 1 AND NOT EXISTS (SELECT 1 FROM item_conflicts c WHERE c.item_id = items.id AND c.vault_id = items.vault_id AND c.state = 'pending') ORDER BY updated_at"))?;
        let rows = stmt.query_map([], row_to_item)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn put_item(&self, row: &ItemRow) -> Result<()> {
        self.conn.execute(
            &format!(
                "INSERT INTO items({ITEM_COLS}) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                 ON CONFLICT(id) DO UPDATE SET
                   kind = excluded.kind, blob = excluded.blob, revision = excluded.revision,
                   server_rev = excluded.server_rev, base_blob = excluded.base_blob, dirty = excluded.dirty,
                   deleted_at = excluded.deleted_at, updated_at = excluded.updated_at, base_deleted = excluded.base_deleted"
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
                row.updated_at,
                row.base_deleted
            ],
        )?;
        Ok(())
    }

    /// 物理抹除回收站中某一行的整条记录（含密文与墓碑）。活动条目不会被删除。
    /// `secure_delete=ON` 会覆写旧页，不留残留。返回是否确实删除了一行。
    pub fn purge_item(&self, id: &str) -> Result<bool> {
        Ok(self.conn.execute("DELETE FROM items WHERE id = ?1 AND deleted_at IS NOT NULL", params![id])? == 1)
    }

    /// 完整行 CAS：核对密文、版本、墓碑、基线和 dirty，不能仅凭 revision 判定头未改变。
    pub(crate) fn check_item(&self, expected: Option<&ItemRow>, id: &str) -> Result<()> {
        if self.get_item(id)?.as_ref() != expected {
            return Err(VaultError::ConflictStale);
        }
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn mark_synced_snapshot(&mut self, sent: &ItemRow) -> Result<bool> {
        self.acknowledge_snapshot(sent, None)
    }

    /// 调用方已解密并验证裁决结果；事务内再次核对精确活动记录，不能按 item_id 批量完成旧决定。
    pub(crate) fn acknowledge_snapshot(&self, sent: &ItemRow, expected_conflict: Option<&ConflictRow>) -> Result<bool> {
        self.transaction(|s| {
            if s.get_item(&sent.id)?.as_ref() != Some(sent)
                || s.active_conflict(&sent.vault_id, &sent.id)?.as_ref() != expected_conflict
                || expected_conflict.is_some_and(|c| c.state != "resolution_pending")
            {
                return Ok(false);
            }
            let mut row = sent.clone();
            row.dirty = false;
            row.server_rev = row.revision;
            row.base_blob = Some(row.blob.clone());
            row.base_deleted = Some(row.deleted_at.is_some());
            s.put_item(&row)?;
            if let Some(record) = expected_conflict {
                s.retire_conflict(&record.id, "resolved")?;
            }
            Ok(true)
        })
    }

    pub(crate) fn active_conflict(&self, vault: &str, item: &str) -> Result<Option<ConflictRow>> {
        Ok(self.conn.query_row("SELECT id,vault_id,item_id,state,blob FROM item_conflicts WHERE vault_id=?1 AND item_id=?2 AND state IN ('pending','resolution_pending')", params![vault,item], conflict_row).optional()?)
    }
    pub(crate) fn conflict(&self, id: &str) -> Result<Option<ConflictRow>> {
        Ok(self.conn.query_row("SELECT id,vault_id,item_id,state,blob FROM item_conflicts WHERE id=?1", [id], conflict_row).optional()?)
    }
    pub(crate) fn conflicts(&self, vault: &str) -> Result<Vec<ConflictRow>> {
        let mut stmt = self.conn.prepare("SELECT id,vault_id,item_id,state,blob FROM item_conflicts WHERE vault_id=?1 ORDER BY id")?;
        let rows = stmt.query_map([vault], conflict_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }
    pub(crate) fn check_conflict(&self, expected: Option<&ConflictRow>, vault: &str, item: &str) -> Result<()> {
        if self.active_conflict(vault, item)?.as_ref() != expected {
            return Err(VaultError::ConflictStale);
        }
        Ok(())
    }
    pub(crate) fn put_conflict(&self, row: &ConflictRow) -> Result<()> {
        self.conn.execute("INSERT INTO item_conflicts(id,vault_id,item_id,state,blob) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET state=excluded.state,blob=excluded.blob", params![row.id,row.vault_id,row.item_id,row.state,row.blob])?;
        Ok(())
    }
    pub(crate) fn retire_conflict(&self, id: &str, state: &str) -> Result<()> {
        self.conn.execute("UPDATE item_conflicts SET state=?2 WHERE id=?1", params![id, state])?;
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
        let active: i64 =
            self.conn.query_row("SELECT COUNT(*) FROM item_conflicts WHERE state IN ('pending','resolution_pending')", [], |r| r.get(0))?;
        if active != 0 {
            return Err(VaultError::ConflictStale);
        }
        self.conn.execute("UPDATE items SET dirty = 1, server_rev = 0, base_blob = NULL, base_deleted = NULL", [])?;
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
            "DELETE FROM item_conflicts; DELETE FROM items; DELETE FROM sync_state; DELETE FROM settings; DELETE FROM meta WHERE key <> 'device_id'; VACUUM;",
        )?;
        Ok(())
    }

    pub fn transaction<T>(&self, f: impl FnOnce(&Store) -> Result<T>) -> Result<T> {
        // RAII 在闭包失败、提交失败或展开时回滚，写事务内完成完整快照 CAS。
        let tx = rusqlite::Transaction::new_unchecked(&self.conn, rusqlite::TransactionBehavior::Immediate)?;
        let result = f(self)?;
        tx.commit()?;
        Ok(result)
    }
}

fn conflict_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<ConflictRow> {
    Ok(ConflictRow { id: r.get(0)?, vault_id: r.get(1)?, item_id: r.get(2)?, state: r.get(3)?, blob: r.get(4)? })
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
        base_deleted: r.get(11)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v1_migration_preserves_dirty_unknown_baseline_and_is_repeatable() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("v1.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(SCHEMA_V1).unwrap();
        conn.pragma_update(None, "user_version", 1).unwrap();
        for (id, dirty, deleted) in [("clean", 0, None), ("trash", 0, Some(42)), ("dirty", 1, None)] {
            conn.execute("INSERT INTO items(id,vault_id,kind,blob,revision,server_rev,base_blob,dirty,deleted_at,created_at,updated_at) VALUES(?1,'v','note',X'0102',2,1,X'03',?2,?3,1,2)",params![id,dirty,deleted]).unwrap();
        }
        drop(conn);
        let store = Store::open(&path).unwrap();
        assert_eq!(store.get_item("clean").unwrap().unwrap().base_deleted, Some(false));
        assert_eq!(store.get_item("trash").unwrap().unwrap().base_deleted, Some(true));
        let dirty = store.get_item("dirty").unwrap().unwrap();
        assert_eq!(dirty.base_deleted, None);
        assert_eq!(dirty.blob, vec![1, 2]);
        assert_eq!(dirty.base_blob, Some(vec![3]));
        assert_eq!(store.conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i32>(0)).unwrap(), 2);
        drop(store);
        assert_eq!(Store::open(&path).unwrap().get_item("dirty").unwrap().unwrap(), dirty);
    }

    #[test]
    fn transaction_error_and_unwind_leave_no_partial_writes() {
        let store = Store::open_in_memory().unwrap();
        let result: Result<()> = store.transaction(|s| {
            s.set_setting("x", "partial")?;
            Err(VaultError::Integrity)
        });
        assert!(result.is_err());
        assert_eq!(store.get_setting("x").unwrap(), None);
        let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _: Result<()> = store.transaction(|s| {
                s.set_setting("x", "panic")?;
                panic!("injected")
            });
        }));
        assert!(panic.is_err());
        assert_eq!(store.get_setting("x").unwrap(), None);
        store.transaction(|s| s.set_setting("x", "committed")).unwrap();
        assert_eq!(store.get_setting("x").unwrap().as_deref(), Some("committed"));
    }
}
