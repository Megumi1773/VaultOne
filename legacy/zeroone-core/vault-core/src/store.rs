//! 本地保险库存储（SQLite）。
//!
//! 设计要点：本地库只保存密文信封与非敏感元数据（条目类型、版本号、时间戳），
//! 不建明文搜索索引——搜索在解锁后于内存中完成。因此即使不使用 SQLCipher，
//! 数据库文件中也检索不到任何 URL / 用户名 / 密码（计划书 F-03 验收要点）。
//! `secure_delete` 保证删除/更新的旧页被覆写而不是残留在空闲页中。

use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::envelope::Envelope;
use crate::kdf::KdfParams;
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
  dirty       INTEGER NOT NULL DEFAULT 1,
  deleted_at  INTEGER,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_items_vault ON items(vault_id, deleted_at);
CREATE TABLE IF NOT EXISTS sync_state (
  vault_id      TEXT PRIMARY KEY,
  last_seq      INTEGER NOT NULL DEFAULT 0,
  last_sync_at  INTEGER
);
CREATE TABLE IF NOT EXISTS outbox (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id     TEXT NOT NULL,
  op          TEXT NOT NULL,
  revision    INTEGER NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"#;

/// 账户与保险库的本地元数据，除 `email_enc` 外均为非敏感信息或密文。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountRecord {
    pub account_id: String,
    pub vault_id: String,
    pub kdf: KdfParams,
    /// Vault Key 被 KeyWrapKey 封装后的密文（base64）
    pub vk_wrap: String,
    /// 封装代次，每次变更主密码 +1
    pub vk_gen: u32,
    /// Vault Key 被 Recovery Code 派生密钥封装后的密文（base64）
    pub recovery_wrap: String,
    /// 邮箱密文信封
    pub email_enc: Envelope,
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemRow {
    pub id: String,
    pub vault_id: String,
    pub kind: String,
    pub blob: Vec<u8>,
    pub revision: i64,
    pub dirty: bool,
    pub deleted_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutboxOp {
    Upsert,
    Delete,
}

impl OutboxOp {
    fn as_str(self) -> &'static str {
        match self {
            OutboxOp::Upsert => "upsert",
            OutboxOp::Delete => "delete",
        }
    }
}

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "secure_delete", "ON")?;
        // 内存库不支持 WAL，返回 "memory"，忽略即可
        let _: String = conn.query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))?;
        let version: i32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version < SCHEMA_VERSION {
            conn.execute_batch(SCHEMA_V1)?;
            conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        }
        Ok(Self { conn })
    }

    pub fn load_account(&self) -> Result<Option<AccountRecord>> {
        let raw: Option<String> = self
            .conn
            .query_row("SELECT value FROM meta WHERE key = 'account'", [], |r| r.get(0))
            .optional()?;
        raw.map(|s| serde_json::from_str(&s).map_err(Into::into)).transpose()
    }

    pub fn save_account(&self, account: &AccountRecord) -> Result<()> {
        self.conn.execute(
            "INSERT INTO meta(key, value) VALUES('account', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![serde_json::to_string(account)?],
        )?;
        Ok(())
    }

    pub fn get_item(&self, id: &str) -> Result<Option<ItemRow>> {
        Ok(self
            .conn
            .query_row(
                "SELECT id, vault_id, kind, blob, revision, dirty, deleted_at, created_at, updated_at
                 FROM items WHERE id = ?1",
                params![id],
                row_to_item,
            )
            .optional()?)
    }

    pub fn list_items(&self, vault_id: &str, deleted: bool) -> Result<Vec<ItemRow>> {
        let sql = if deleted {
            "SELECT id, vault_id, kind, blob, revision, dirty, deleted_at, created_at, updated_at
             FROM items WHERE vault_id = ?1 AND deleted_at IS NOT NULL ORDER BY updated_at DESC"
        } else {
            "SELECT id, vault_id, kind, blob, revision, dirty, deleted_at, created_at, updated_at
             FROM items WHERE vault_id = ?1 AND deleted_at IS NULL ORDER BY updated_at DESC"
        };
        let mut stmt = self.conn.prepare(sql)?;
        let rows = stmt.query_map(params![vault_id], row_to_item)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 写入条目并追加 outbox 记录（同一事务，保证离线队列与数据一致）。
    pub fn put_item(&mut self, row: &ItemRow, op: OutboxOp) -> Result<()> {
        let tx = self.conn.transaction()?;
        tx.execute(
            "INSERT INTO items(id, vault_id, kind, blob, revision, dirty, deleted_at, created_at, updated_at)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(id) DO UPDATE SET
               kind = excluded.kind, blob = excluded.blob, revision = excluded.revision,
               dirty = excluded.dirty, deleted_at = excluded.deleted_at, updated_at = excluded.updated_at",
            params![
                row.id,
                row.vault_id,
                row.kind,
                row.blob,
                row.revision,
                row.dirty,
                row.deleted_at,
                row.created_at,
                row.updated_at
            ],
        )?;
        tx.execute(
            "INSERT INTO outbox(item_id, op, revision, created_at) VALUES(?1, ?2, ?3, ?4)",
            params![row.id, op.as_str(), row.revision, row.updated_at],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn outbox_len(&self) -> Result<u64> {
        Ok(self.conn.query_row("SELECT COUNT(*) FROM outbox", [], |r| r.get::<_, i64>(0))? as u64)
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT value FROM settings WHERE key = ?1", params![key], |r| r.get(0))
            .optional()?)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO settings(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }
}

fn row_to_item(r: &rusqlite::Row<'_>) -> rusqlite::Result<ItemRow> {
    Ok(ItemRow {
        id: r.get(0)?,
        vault_id: r.get(1)?,
        kind: r.get(2)?,
        blob: r.get(3)?,
        revision: r.get(4)?,
        dirty: r.get(5)?,
        deleted_at: r.get(6)?,
        created_at: r.get(7)?,
        updated_at: r.get(8)?,
    })
}
