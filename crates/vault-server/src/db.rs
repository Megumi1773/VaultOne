//! 数据库访问层：`sqlx` Any 驱动，同一套代码同时支持 SQLite（单机/内测）与 PostgreSQL 16（生产）。
//! 迁移脚本见 `migrations/{sqlite,postgres}`，启动时自动执行。

use std::time::Duration;

use sqlx::any::{AnyPoolOptions, AnyRow};
use sqlx::migrate::Migrator;
use sqlx::{AnyPool, Executor, Row};

use crate::config::Config;

static SQLITE_MIGRATOR: Migrator = sqlx::migrate!("./migrations/sqlite");
static POSTGRES_MIGRATOR: Migrator = sqlx::migrate!("./migrations/postgres");

pub async fn connect(cfg: &Config) -> anyhow::Result<AnyPool> {
    sqlx::any::install_default_drivers();
    let sqlite = cfg.is_sqlite();
    let pool = AnyPoolOptions::new()
        .max_connections(if sqlite { 8 } else { 32 })
        .acquire_timeout(Duration::from_secs(10))
        .after_connect(move |conn, _| {
            Box::pin(async move {
                if sqlite {
                    conn.execute(
                        "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000; PRAGMA secure_delete = ON;",
                    )
                    .await?;
                }
                Ok(())
            })
        })
        .connect(&cfg.database_url)
        .await?;
    if sqlite {
        SQLITE_MIGRATOR.run(&pool).await?;
    } else {
        POSTGRES_MIGRATOR.run(&pool).await?;
    }
    tracing::info!(backend = if sqlite { "sqlite" } else { "postgres" }, "database ready");
    Ok(pool)
}

// ───────── 行映射 ─────────

pub struct UserRow {
    pub id: String,
    pub email_enc: Vec<u8>,
    pub kdf: String,
    pub srp_salt: Vec<u8>,
    pub srp_verifier: Vec<u8>,
    pub vault_id: String,
    pub vk_wrap: Vec<u8>,
    pub vk_gen: i64,
    pub recovery_wrap: Vec<u8>,
    pub recovery_auth_hash: Vec<u8>,
}

pub const USER_COLS: &str = "id, email_enc, kdf, srp_salt, srp_verifier, vault_id, vk_wrap, vk_gen, recovery_wrap, recovery_auth_hash";

impl UserRow {
    pub fn from_row(r: &AnyRow) -> sqlx::Result<Self> {
        Ok(Self {
            id: r.try_get("id")?,
            email_enc: r.try_get("email_enc")?,
            kdf: r.try_get("kdf")?,
            srp_salt: r.try_get("srp_salt")?,
            srp_verifier: r.try_get("srp_verifier")?,
            vault_id: r.try_get("vault_id")?,
            vk_wrap: r.try_get("vk_wrap")?,
            vk_gen: r.try_get("vk_gen")?,
            recovery_wrap: r.try_get("recovery_wrap")?,
            recovery_auth_hash: r.try_get("recovery_auth_hash")?,
        })
    }

    pub fn keys(&self) -> anyhow::Result<vault_proto::AccountKeys> {
        Ok(vault_proto::AccountKeys {
            account_id: self.id.clone(),
            vault_id: self.vault_id.clone(),
            kdf: serde_json::from_str(&self.kdf)?,
            vk_wrap: self.vk_wrap.clone().into(),
            vk_gen: self.vk_gen,
            recovery_wrap: self.recovery_wrap.clone().into(),
        })
    }
}

pub async fn user_by_email_hash(db: &AnyPool, hash: &[u8]) -> sqlx::Result<Option<UserRow>> {
    let row = sqlx::query(&format!("SELECT {USER_COLS} FROM users WHERE email_hash = $1")).bind(hash.to_vec()).fetch_optional(db).await?;
    row.as_ref().map(UserRow::from_row).transpose()
}

pub async fn user_by_id(db: &AnyPool, id: &str) -> sqlx::Result<Option<UserRow>> {
    let row = sqlx::query(&format!("SELECT {USER_COLS} FROM users WHERE id = $1")).bind(id.to_string()).fetch_optional(db).await?;
    row.as_ref().map(UserRow::from_row).transpose()
}

pub struct DeviceRow {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub approved_at: Option<i64>,
    pub last_seen_at: Option<i64>,
    pub revoked_at: Option<i64>,
    pub created_at: i64,
}

impl DeviceRow {
    pub fn from_row(r: &AnyRow) -> sqlx::Result<Self> {
        Ok(Self {
            id: r.try_get("id")?,
            name: r.try_get("name")?,
            platform: r.try_get("platform")?,
            approved_at: r.try_get("approved_at")?,
            last_seen_at: r.try_get("last_seen_at")?,
            revoked_at: r.try_get("revoked_at")?,
            created_at: r.try_get("created_at")?,
        })
    }
}

pub async fn device(db: &AnyPool, user_id: &str, device_id: &str) -> sqlx::Result<Option<DeviceRow>> {
    let row = sqlx::query(
        "SELECT id, name, platform, approved_at, last_seen_at, revoked_at, created_at FROM devices WHERE user_id = $1 AND id = $2",
    )
    .bind(user_id.to_string())
    .bind(device_id.to_string())
    .fetch_optional(db)
    .await?;
    row.as_ref().map(DeviceRow::from_row).transpose()
}

pub async fn audit(db: &AnyPool, user_id: &str, device_id: Option<&str>, event: &str, ip_hash: Option<Vec<u8>>) {
    let r = sqlx::query("INSERT INTO audit_events(user_id, device_id, event, ip_hash, created_at) VALUES($1, $2, $3, $4, $5)")
        .bind(user_id.to_string())
        .bind(device_id.map(str::to_string))
        .bind(event.to_string())
        .bind(ip_hash)
        .bind(crate::now())
        .execute(db)
        .await;
    if let Err(e) = r {
        tracing::error!(error = %e, "audit write failed");
    }
}

/// 周期清理：过期握手、验证码、会话，以及超出保留期的条目历史版本。
pub async fn gc(db: &AnyPool, version_retention_days: i64) -> sqlx::Result<()> {
    let now = crate::now();
    db.execute(sqlx::query("DELETE FROM handshakes WHERE expires_at < $1").bind(now)).await?;
    db.execute(sqlx::query("DELETE FROM device_otps WHERE expires_at < $1").bind(now)).await?;
    db.execute(sqlx::query("DELETE FROM sessions WHERE expires_at < $1").bind(now)).await?;
    db.execute(sqlx::query("DELETE FROM item_versions WHERE created_at < $1").bind(now - version_retention_days * 86400)).await?;
    Ok(())
}
