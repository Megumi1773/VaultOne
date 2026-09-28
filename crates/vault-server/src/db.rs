//! 数据库访问层：`sqlx` Any 驱动，同一套代码同时支持 SQLite（单机/内测）与 PostgreSQL 16（生产）。
//! 迁移脚本见 `migrations/{sqlite,postgres}`，启动时自动执行。

use std::time::Duration;

use sqlx::any::{AnyPoolOptions, AnyRow};
use sqlx::migrate::Migrator;
use sqlx::{AnyPool, Executor, Row};

use crate::config::Config;

static SQLITE_MIGRATOR: Migrator = sqlx::migrate!("./migrations/sqlite");
static POSTGRES_MIGRATOR: Migrator = sqlx::migrate!("./migrations/postgres");

// ───────── 时间存取助手 ─────────
//
// 数据库中所有时间列统一为 TEXT，存放 ISO-8601 UTC 字符串（如 `2026-09-28T08:01:33Z`），
// 字典序即时间序，可直接比较/排序。API 边界仍以 Unix 秒（i64）收发，仅在此处转换。
// 之所以不用原生时间类型：sqlx Any 驱动不支持任何时间类型（仅 int/str/blob/bool/float）。

/// Unix 秒（i64）→ ISO-8601 UTC 文本，用于绑定 SQL 参数。
pub fn ts(secs: i64) -> String {
    format_iso8601(secs)
}

/// ISO-8601 UTC 文本 → Unix 秒（i64），用于读取行；解析失败返回 0。
pub fn parse_ts(s: &str) -> i64 {
    parse_iso8601(s).unwrap_or(0)
}

/// 读取可空时间列：NULL → None。
pub fn parse_ts_opt(s: Option<&str>) -> Option<i64> {
    s.and_then(parse_iso8601)
}

/// 把 Unix 秒格式化为 `YYYY-MM-DDTHH:MM:SSZ`（纯 UTC，无闰秒，恒定 20 字节）。
fn format_iso8601(secs: i64) -> String {
    // 以民用历算法（Howard Hinnant days_from_civil 的逆运算）拆分年月日，避免引入时间库。
    let days = secs.div_euclid(86400);
    let secs_of_day = secs.rem_euclid(86400);
    let (y, m, d) = civil_from_days(days);
    let (hh, mm, ss) = (secs_of_day / 3600, (secs_of_day % 3600) / 60, secs_of_day % 60);
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

/// 解析 `YYYY-MM-DDTHH:MM:SSZ`（容忍末尾 `+00:00`）；非法输入返回 None。
fn parse_iso8601(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let num = |a: usize, z: usize| s.get(a..z)?.parse::<i64>().ok();
    let (y, m, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (hh, mm, ss) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || hh > 23 || mm > 59 || ss > 60 {
        return None;
    }
    Some(days_from_civil(y, m, d) * 86400 + hh * 3600 + mm * 60 + ss)
}

/// 天数（相对 1970-01-01）→ (year, month, day)，Howard Hinnant 算法。
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (y + i64::from(m <= 2), m as u32, d as u32)
}

/// (year, month, day) → 天数（相对 1970-01-01），Howard Hinnant 算法。
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

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
            approved_at: parse_ts_opt(r.try_get::<Option<String>, _>("approved_at")?.as_deref()),
            last_seen_at: parse_ts_opt(r.try_get::<Option<String>, _>("last_seen_at")?.as_deref()),
            revoked_at: parse_ts_opt(r.try_get::<Option<String>, _>("revoked_at")?.as_deref()),
            created_at: parse_ts(&r.try_get::<String, _>("created_at")?),
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
        .bind(ts(crate::now()))
        .execute(db)
        .await;
    if let Err(e) = r {
        tracing::error!(error = %e, "audit write failed");
    }
}

/// 统计某账户自 `since` 起某类审计事件的次数（用于异常登录告警）。
pub async fn count_events_since(db: &AnyPool, user_id: &str, event: &str, since: i64) -> sqlx::Result<i64> {
    sqlx::query("SELECT COUNT(*) AS n FROM audit_events WHERE user_id = $1 AND event = $2 AND created_at >= $3")
        .bind(user_id.to_string())
        .bind(event.to_string())
        .bind(ts(since))
        .fetch_one(db)
        .await?
        .try_get("n")
}

/// 周期清理：过期握手、验证码、会话，以及超出保留期的条目历史版本。
pub async fn gc(db: &AnyPool, version_retention_days: i64) -> sqlx::Result<()> {
    let now = crate::now();
    db.execute(sqlx::query("DELETE FROM handshakes WHERE expires_at < $1").bind(ts(now))).await?;
    db.execute(sqlx::query("DELETE FROM device_otps WHERE expires_at < $1").bind(ts(now))).await?;
    db.execute(sqlx::query("DELETE FROM sessions WHERE expires_at < $1").bind(ts(now))).await?;
    db.execute(sqlx::query("DELETE FROM item_versions WHERE created_at < $1").bind(ts(now - version_retention_days * 86400))).await?;
    Ok(())
}
