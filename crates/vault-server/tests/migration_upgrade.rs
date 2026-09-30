//! 旧库升级回归：先由真实 0001 建库并写入样本，再由完整 Migrator 升级。
//! PostgreSQL 默认 ignored；仅使用显式授权的本机临时库，绝不读取 DATABASE_URL。
//! CI 必须单独运行：cargo test -p vault-server --test migration_upgrade postgres_ -- --ignored
//! 并设置 VAULTONE_MIGRATION_TEST_PG_URL 与 VAULTONE_MIGRATION_TEST_PG_ALLOW=1。

use std::{borrow::Cow, str::FromStr, time::Duration};

use anyhow::{ensure, Context, Result};
use sqlx::{any::AnyPoolOptions, migrate::Migrator, postgres::PgConnectOptions, AnyPool, Executor, Row};

struct Table {
    name: &'static str,
    text: &'static [&'static str],
    bytes: &'static [&'static str],
    numbers: &'static [&'static str],
    dates: &'static [&'static str],
    nullable: &'static [&'static str],
}

const TABLES: &[Table] = &[
    Table {
        name: "users",
        text: &["id", "kdf", "vault_id"],
        bytes: &["email_hash", "email_enc", "srp_salt", "srp_verifier", "vk_wrap", "recovery_wrap", "recovery_auth_hash"],
        numbers: &["vk_gen"],
        dates: &["created_at", "updated_at"],
        nullable: &[],
    },
    Table {
        name: "devices",
        text: &["user_id", "id", "name", "platform", "approved_by"],
        bytes: &[],
        numbers: &[],
        dates: &["approved_at", "last_seen_at", "revoked_at", "created_at"],
        nullable: &["approved_at", "last_seen_at", "revoked_at", "approved_by"],
    },
    Table {
        name: "sessions",
        text: &["user_id", "device_id"],
        bytes: &["token_hash"],
        numbers: &[],
        dates: &["expires_at", "revoked_at", "created_at"],
        nullable: &["revoked_at"],
    },
    Table { name: "handshakes", text: &["id", "user_id"], bytes: &["b_enc"], numbers: &[], dates: &["expires_at"], nullable: &["user_id"] },
    Table {
        name: "device_otps",
        text: &["user_id", "device_id"],
        bytes: &["code_hash"],
        numbers: &["attempts"],
        dates: &["expires_at"],
        nullable: &[],
    },
    Table {
        name: "items",
        text: &["user_id", "id", "kind", "device_id"],
        bytes: &["blob", "blob_hash"],
        numbers: &["revision", "deleted"],
        dates: &["updated_at", "created_at"],
        nullable: &[],
    },
    Table {
        name: "item_versions",
        text: &["user_id", "item_id", "device_id"],
        bytes: &["blob"],
        numbers: &["id", "revision"],
        dates: &["created_at"],
        nullable: &[],
    },
    Table {
        name: "change_log",
        text: &["user_id", "item_id"],
        bytes: &[],
        numbers: &["seq", "revision"],
        dates: &["created_at"],
        nullable: &[],
    },
    Table {
        name: "audit_events",
        text: &["user_id", "device_id", "event"],
        bytes: &["ip_hash"],
        numbers: &["id"],
        dates: &["created_at"],
        nullable: &["device_id", "ip_hash"],
    },
];

// 闰日 UTC 午夜两侧，三行分别为已过期、边界仍有效、未来有效。
const NOW: i64 = 1_709_164_800;
const ISO: [&str; 3] = ["2024-02-28T23:59:59Z", "2024-02-29T00:00:00Z", "2024-02-29T00:00:01Z"];

fn migrator(postgres: bool, old_only: bool) -> Migrator {
    let mut m = if postgres { sqlx::migrate!("./migrations/postgres") } else { sqlx::migrate!("./migrations/sqlite") };
    if old_only {
        m.migrations = Cow::Owned(m.iter().filter(|m| m.version == 1).cloned().collect());
    }
    m
}

async fn seed(pool: &AnyPool) -> Result<()> {
    for t in TABLES {
        for i in 0..3_i64 {
            let columns: Vec<_> = t.text.iter().chain(t.bytes).chain(t.numbers).chain(t.dates).copied().collect();
            let params = (1..=columns.len()).map(|n| format!("${n}")).collect::<Vec<_>>().join(",");
            let sql = format!("INSERT INTO {} ({}) VALUES ({params})", t.name, columns.join(","));
            let mut q = sqlx::query(&sql);
            for c in t.text {
                let value = match *c {
                    "user_id" | "id" | "device_id" | "item_id" => format!("fixture-{i}"),
                    "kdf" => r#"{"algorithm":"argon2id","memory":32}"#.to_owned(),
                    "kind" => "login".to_owned(),
                    "platform" => "windows".to_owned(),
                    _ => format!("升级样本-{}-{c}-{i}", t.name),
                };
                q = q.bind(if i == 0 && t.nullable.contains(c) { None } else { Some(value) });
            }
            for (n, c) in t.bytes.iter().enumerate() {
                // 不解密的合成密文/哈希，包括零字节和非 UTF-8，检测字节级保真。
                q = q.bind(if i == 0 && t.nullable.contains(c) { None } else { Some(vec![0, 255, 128, i as u8, n as u8, 13, 10]) });
            }
            for c in t.numbers {
                q = q.bind(match *c {
                    "id" | "seq" => i + 1,
                    "deleted" => i % 2,
                    "attempts" => i,
                    _ => i + 7,
                });
            }
            for c in t.dates {
                q = q.bind(if i == 0 && t.nullable.contains(c) { None } else { Some(NOW + i - 1) });
            }
            q.execute(pool).await.with_context(|| format!("旧库样本 {} 第{i}行", t.name))?;
        }
    }
    Ok(())
}

fn row_key(t: &Table) -> &'static str {
    match t.name {
        "sessions" => "token_hash",
        "device_otps" => "device_id",
        "change_log" => "seq",
        _ => "id",
    }
}

// 按字段名称比较，而不是 SELECT * 的列序：SQLite 会把转换后的列移到末尾。
async fn payload(pool: &AnyPool) -> Result<Vec<String>> {
    let mut result = Vec::new();
    for t in TABLES {
        for c in t.text.iter().chain(t.bytes).chain(t.numbers) {
            let key = row_key(t);
            let rows = sqlx::query(&format!("SELECT {c} FROM {} ORDER BY {key}", t.name)).fetch_all(pool).await?;
            ensure!(rows.len() == 3, "{} 丢行", t.name);
            for r in rows {
                let value = if t.text.contains(c) {
                    format!("{:?}", r.try_get::<Option<String>, _>(0)?)
                } else if t.bytes.contains(c) {
                    format!("{:?}", r.try_get::<Option<Vec<u8>>, _>(0)?)
                } else {
                    format!("{:?}", r.try_get::<Option<i64>, _>(0)?)
                };
                result.push(format!("{}.{c}={value}", t.name));
            }
        }
    }
    Ok(result)
}

async fn indexes(pool: &AnyPool, postgres: bool) -> Result<Vec<(String, String)>> {
    let sql = if postgres {
        "SELECT indexname::text AS indexname, indexdef::text AS indexdef FROM pg_indexes WHERE schemaname = current_schema() AND tablename <> '_sqlx_migrations' ORDER BY indexname"
    } else {
        "SELECT name, COALESCE(sql, '') FROM sqlite_master WHERE type = 'index' AND tbl_name <> '_sqlx_migrations' ORDER BY name"
    };
    Ok(sqlx::query(sql).fetch_all(pool).await?.iter().map(|r| Ok((r.try_get(0)?, r.try_get(1)?))).collect::<sqlx::Result<_>>()?)
}

async fn check_dates(pool: &AnyPool) -> Result<()> {
    for t in TABLES {
        for c in t.dates {
            let key = row_key(t);
            let rows = sqlx::query(&format!("SELECT {c} FROM {} ORDER BY {key}", t.name)).fetch_all(pool).await?;
            let actual = rows.iter().map(|r| r.try_get::<Option<String>, _>(0)).collect::<sqlx::Result<Vec<_>>>()?;
            let mut expected: Vec<_> = ISO.iter().map(|s| Some(s.to_string())).collect();
            if t.nullable.contains(c) {
                expected[0] = None;
            }
            ensure!(actual == expected, "{}.{} UTC/NULL 转换错误: {actual:?}，预期 {expected:?}", t.name, c);
            for value in actual.into_iter().flatten() {
                ensure!(vault_server::db::ts(vault_server::db::parse_ts(&value)) == value, "时间不能经 API 存取层往返");
            }
        }
    }
    Ok(())
}

async fn check_expiry(pool: &AnyPool) -> Result<()> {
    for table in ["sessions", "handshakes", "device_otps"] {
        let rows = sqlx::query(&format!("SELECT expires_at FROM {table} ORDER BY expires_at")).fetch_all(pool).await?;
        let actual =
            rows.iter().map(|r| Ok(vault_server::db::parse_ts(&r.try_get::<String, _>(0)?) < NOW)).collect::<sqlx::Result<Vec<_>>>()?;
        ensure!(actual == [true, false, false], "{table} 认证层过期判定错误");
        let deleted = sqlx::query(&format!("DELETE FROM {table} WHERE expires_at < $1"))
            .bind(vault_server::db::ts(NOW))
            .execute(pool)
            .await?
            .rows_affected();
        ensure!(deleted == 1, "{table} GC 必须仅删已过期行，边界保留");
        let remaining: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {table} WHERE expires_at >= $1"))
            .bind(vault_server::db::ts(NOW))
            .fetch_one(pool)
            .await?;
        ensure!(remaining == 2, "{table} GC 与认证判定不一致");
    }
    Ok(())
}

async fn check_not_null(pool: &AnyPool, postgres: bool) -> Result<()> {
    let mut lost = Vec::new();
    for t in TABLES {
        for c in t.dates.iter().filter(|c| !t.nullable.contains(c)) {
            let required = if postgres {
                let value: String = sqlx::query_scalar("SELECT is_nullable::text FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2").bind(t.name).bind(*c).fetch_one(pool).await?;
                value == "NO"
            } else {
                let value: i64 = sqlx::query_scalar(&format!("SELECT \"notnull\" FROM pragma_table_info('{}') WHERE name = $1", t.name))
                    .bind(*c)
                    .fetch_one(pool)
                    .await?;
                value == 1
            };
            if !required {
                lost.push(format!("{}.{c}", t.name));
            }
        }
    }
    ensure!(lost.is_empty(), "0002 丢失旧库 NOT NULL 约束: {}", lost.join(", "));
    Ok(())
}

async fn check_column_types(pool: &AnyPool, postgres: bool, upgraded: bool) -> Result<()> {
    for t in TABLES {
        for c in t.dates {
            let ty: String = if postgres {
                sqlx::query_scalar("SELECT data_type::text FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2")
                    .bind(t.name).bind(*c).fetch_one(pool).await?
            } else {
                sqlx::query_scalar(&format!("SELECT type FROM pragma_table_info('{}') WHERE name = $1", t.name))
                    .bind(*c)
                    .fetch_one(pool)
                    .await?
            };
            let expected = if upgraded { "text" } else { "bigint" };
            ensure!(ty.eq_ignore_ascii_case(expected), "{}.{} 类型应为 {expected}，实际 {ty}", t.name, c);
        }
    }
    Ok(())
}

async fn upgrade(pool: &AnyPool, postgres: bool, constraints: bool) -> Result<()> {
    migrator(postgres, true).run(pool).await?;
    check_column_types(pool, postgres, false).await?;
    check_not_null(pool, postgres).await?;
    seed(pool).await?;
    if !postgres {
        for (table, key) in [("item_versions", "id"), ("change_log", "seq"), ("audit_events", "id")] {
            let t = TABLES.iter().find(|t| t.name == table).unwrap();
            let columns: Vec<_> = t.text.iter().chain(t.bytes).chain(t.numbers).chain(t.dates).copied().collect();
            let values = columns.iter().map(|c| if *c == key { "100" } else { c }).collect::<Vec<_>>().join(",");
            pool.execute(format!("INSERT INTO {table} ({}) SELECT {values} FROM {table} LIMIT 1", columns.join(",")).as_str()).await?;
            pool.execute(format!("DELETE FROM {table} WHERE {key} = 100").as_str()).await?;
        }
    }
    let before = payload(pool).await?;
    let before_indexes = indexes(pool, postgres).await?;
    ensure!(before_indexes.iter().any(|(name, _)| name == "idx_changelog_user_seq"), "未创建真实0001索引");
    let versions: Vec<i64> = sqlx::query_scalar("SELECT version FROM _sqlx_migrations ORDER BY version").fetch_all(pool).await?;
    ensure!(versions == [1], "必须从已记录0001的旧库升级");
    vault_server::db::migrate(pool, !postgres).await?;
    ensure!(payload(pool).await? == before, "升级破坏非时间字段、密文或行数");
    check_column_types(pool, postgres, true).await?;
    ensure!(indexes(pool, postgres).await? == before_indexes, "升级破坏索引/唯一键定义");
    let versions: Vec<i64> =
        sqlx::query_scalar("SELECT version FROM _sqlx_migrations WHERE success = TRUE ORDER BY version").fetch_all(pool).await?;
    let expected: &[i64] = if postgres { &[1, 2] } else { &[1, 2, 3] };
    ensure!(versions == expected, "迁移记录不完整");
    // 再次启动不得重放迁移；验证 SQLx 校验和及幂等性。
    vault_server::db::migrate(pool, !postgres).await?;
    if !postgres {
        for (table, key) in [("item_versions", "id"), ("change_log", "seq"), ("audit_events", "id")] {
            let high: i64 = sqlx::query_scalar("SELECT seq FROM sqlite_sequence WHERE name = $1").bind(table).fetch_one(pool).await?;
            ensure!(high == 100, "{table} 自增高水位在迁移后倒退");
            let t = TABLES.iter().find(|t| t.name == table).unwrap();
            let columns =
                t.text.iter().chain(t.bytes).chain(t.numbers).chain(t.dates).copied().filter(|c| *c != key).collect::<Vec<_>>().join(",");
            pool.execute(format!("INSERT INTO {table} ({columns}) SELECT {columns} FROM {table} LIMIT 1").as_str()).await?;
            let next: i64 = sqlx::query_scalar(&format!("SELECT MAX({key}) FROM {table}")).fetch_one(pool).await?;
            ensure!(next == 101, "{table} 重用了旧 ID/游标");
            pool.execute(format!("DELETE FROM {table} WHERE {key} = 101").as_str()).await?;
        }
    }
    if constraints {
        return check_not_null(pool, postgres).await;
    }
    check_dates(pool).await?;
    check_expiry(pool).await?;
    if !postgres {
        let enabled: i64 = sqlx::query_scalar("PRAGMA foreign_keys").fetch_one(pool).await?;
        ensure!(enabled == 1, "升级关闭了外键");
        ensure!(sqlx::query("PRAGMA foreign_key_check").fetch_all(pool).await?.is_empty(), "升级留下悬空外键");
    }
    Ok(())
}

async fn sqlite(constraints: bool) -> Result<()> {
    sqlx::any::install_default_drivers();
    let dir = tempfile::tempdir()?;
    let url = format!("sqlite:{}?mode=rwc", dir.path().join("upgrade.db").to_string_lossy().replace('\\', "/"));
    let pool = AnyPoolOptions::new()
        .max_connections(1)
        .after_connect(|conn, _| {
            Box::pin(async move {
                conn.execute("PRAGMA foreign_keys = ON").await?;
                Ok(())
            })
        })
        .connect(&url)
        .await?;
    let result = upgrade(&pool, false, constraints).await;
    pool.close().await;
    result
}

#[tokio::test]
async fn sqlite_upgrade_preserves_rows_dates_indexes_and_expiry() -> Result<()> {
    sqlite(false).await
}

#[tokio::test]
async fn sqlite_upgrade_preserves_not_null() -> Result<()> {
    sqlite(true).await
}

#[tokio::test]
async fn sqlite_invalid_old_data_rolls_back_without_loss() -> Result<()> {
    sqlx::any::install_default_drivers();
    let pool = AnyPoolOptions::new()
        .max_connections(1)
        .after_connect(|conn, _| {
            Box::pin(async move {
                conn.execute("PRAGMA foreign_keys = ON").await?;
                Ok(())
            })
        })
        .connect("sqlite::memory:")
        .await?;
    migrator(false, true).run(&pool).await?;
    seed(&pool).await?;
    let mut v2 = migrator(false, false);
    v2.migrations = Cow::Owned(v2.iter().filter(|m| m.version <= 2).cloned().collect());
    v2.run(&pool).await?;
    pool.execute("UPDATE users SET created_at = NULL WHERE id = 'fixture-1'").await?;
    let before = payload(&pool).await?;
    ensure!(vault_server::db::migrate(&pool, true).await.is_err(), "缺失历史时间必须拒绝迁移");
    ensure!(payload(&pool).await? == before, "失败迁移破坏了已有行或密文");
    let missing: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE created_at IS NULL").fetch_one(&pool).await?;
    ensure!(missing == 1, "失败时不得猜测填补历史时间");
    let debris: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '%_v3'").fetch_one(&pool).await?;
    ensure!(debris == 0, "失败迁移留下部分新表");
    let versions: Vec<i64> = sqlx::query_scalar("SELECT version FROM _sqlx_migrations ORDER BY version").fetch_all(&pool).await?;
    ensure!(versions == [1, 2], "失败迁移不应登记成功");
    ensure!(sqlx::query("PRAGMA foreign_key_check").fetch_all(&pool).await?.is_empty(), "失败后外键被破坏");
    pool.close().await;
    Ok(())
}

async fn postgres(timezone: &'static str) -> Result<()> {
    ensure!(
        std::env::var("VAULTONE_MIGRATION_TEST_PG_ALLOW").as_deref() == Ok("1"),
        "必须显式设置 VAULTONE_MIGRATION_TEST_PG_ALLOW=1，仅授权本机专用临时测试库"
    );
    let url = std::env::var("VAULTONE_MIGRATION_TEST_PG_URL").context("缺少 VAULTONE_MIGRATION_TEST_PG_URL；PG 测试未执行，不能算通过")?;
    let options = PgConnectOptions::from_str(&url).context("测试 PG URL 无效")?;
    ensure!(["localhost", "127.0.0.1", "::1"].contains(&options.get_host()), "拒绝非本机 PostgreSQL");
    ensure!(options.get_database() == Some("vaultone_migration_test"), "拒绝非专用数据库：必须为 vaultone_migration_test");
    sqlx::any::install_default_drivers();
    let schema = format!("migration_{}", uuid::Uuid::new_v4().simple());
    let settings = format!("SET search_path TO {schema}; SET TIME ZONE '{timezone}'");
    let pool = AnyPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(Duration::from_secs(5))
        .after_connect(move |conn, _| {
            let settings = settings.clone();
            Box::pin(async move {
                conn.execute(settings.as_str()).await?;
                Ok(())
            })
        })
        .connect(&url)
        .await
        .context("连接本机专用测试 PG 失败")?;
    pool.execute(format!("CREATE SCHEMA {schema}").as_str()).await?;
    // 每个连接都指定随机 schema 和时区；迁移专用连接关闭后重连也不能回落到 public。
    let result = async {
        let actual: String = sqlx::query_scalar("SHOW TIME ZONE").fetch_one(&pool).await?;
        ensure!(actual == timezone, "未应用指定会话时区");
        upgrade(&pool, true, false).await?;
        let actual: String = sqlx::query_scalar("SHOW TIME ZONE").fetch_one(&pool).await?;
        ensure!(actual == timezone, "迁移影响了后续业务连接时区");
        check_not_null(&pool, true).await
    }
    .await;
    // 断言全部使用 Result，失败时也清理本次随机 schema，不碰其他测试及 public。
    let cleanup = pool.execute(format!("DROP SCHEMA {schema} CASCADE").as_str()).await;
    pool.close().await;
    cleanup.context("清理测试 schema 失败")?;
    result
}

#[tokio::test]
#[ignore = "需要显式授权的本机 PostgreSQL 专用测试库；CI 用 --ignored 单独运行"]
async fn postgres_upgrade_utc() -> Result<()> {
    postgres("UTC").await
}

#[tokio::test]
#[ignore = "需要显式授权的本机 PostgreSQL 专用测试库；CI 用 --ignored 单独运行"]
async fn postgres_upgrade_non_utc() -> Result<()> {
    postgres("Asia/Shanghai").await
}
