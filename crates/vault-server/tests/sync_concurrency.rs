//! 同步 CAS 的真实 HTTP 回归：SQLite 临时文件；PG 仅显式授权的本机专用库和随机 schema。
//! PG CI：设置 VAULTONE_SYNC_TEST_PG_ALLOW=1 与 VAULTONE_SYNC_TEST_PG_URL，
//! 然后 cargo test -p vault-server --test sync_concurrency postgres_ -- --ignored。

use std::{
    net::SocketAddr,
    str::FromStr,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sqlx::{any::AnyPoolOptions, postgres::PgConnectOptions, AnyPool, Executor, Row};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use vault_server::{config::Config, db, keys::ServerKeys, mail::Mailer, AppState, Inner};

const USER: &str = "10000000-0000-4000-8000-000000000001";
const DEVICE: &str = "20000000-0000-4000-8000-000000000001";

fn config(url: String) -> Config {
    Config {
        database_url: url,
        server_secret: Some("0123456789abcdef".repeat(4)),
        api_rate_ms: 1,
        api_burst: 10_000,
        auth_rate_ms: 1,
        auth_burst: 10_000,
        ..Config::default()
    }
}

fn item(id: &str, base: i64, revision: i64) -> Result<Value> {
    // 使用真实 AES-GCM 信封，服务端只能见密文，不能绕过结构校验。
    let key = vault_crypto::Key32::random()?;
    let wrapped = vault_crypto::sealed::wrap_key(&key, &key, b"")?;
    let ct = vault_crypto::sealed::seal(&key, &[42; 256], b"")?;
    let blob = serde_json::to_vec(&json!({"v":2,"alg":"aes-256-gcm","wrappedKey":STANDARD.encode(wrapped),"ct":STANDARD.encode(ct)}))?;
    Ok(
        json!({"id":id,"kind":"login","blob":STANDARD.encode(blob),"base_revision":base,"revision":revision,"deleted":false,"updated_at":1709164800}),
    )
}

async fn http(addr: SocketAddr, token: &str, method: &str, path: &str, body: &Value) -> Result<(u16, Value)> {
    let bytes = serde_json::to_vec(body)?;
    let mut stream = tokio::net::TcpStream::connect(addr).await?;
    let request = format!("{method} {path} HTTP/1.1\r\nHost: {addr}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", bytes.len());
    stream.write_all(request.as_bytes()).await?;
    stream.write_all(&bytes).await?;
    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(15), stream.read_to_end(&mut response)).await??;
    let split = response.windows(4).position(|w| w == b"\r\n\r\n").context("HTTP 响应没有头部")?;
    let header = std::str::from_utf8(&response[..split])?;
    let status = header.split_whitespace().nth(1).context("HTTP 响应没有状态码")?.parse()?;
    Ok((status, serde_json::from_slice(&response[split + 4..])?))
}

async fn push(addr: SocketAddr, token: &str, items: Vec<Value>) -> Result<Value> {
    let (status, response) = http(addr, token, "POST", "/v1/sync/push", &json!({"items":items})).await?;
    ensure!(status == 200, "push HTTP {status}: {response}");
    Ok(response)
}

async fn pull(addr: SocketAddr, token: &str, cursor: i64) -> Result<Value> {
    let (status, response) = http(addr, token, "GET", &format!("/v1/sync/pull?cursor={cursor}&limit=1000"), &Value::Null).await?;
    ensure!(status == 200, "pull HTTP {status}: {response}");
    Ok(response)
}

async fn count(pool: &AnyPool, table: &str, id: &str) -> Result<i64> {
    let column = if table == "items" { "id" } else { "item_id" };
    Ok(sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {table} WHERE user_id=$1 AND {column}=$2"))
        .bind(USER)
        .bind(id)
        .fetch_one(pool)
        .await?)
}

async fn fixture(pool: &AnyPool, cfg: Config) -> Result<(AppState, String)> {
    let t = db::ts(vault_server::now());
    sqlx::query("INSERT INTO users(id,email_hash,email_enc,kdf,srp_salt,srp_verifier,vault_id,vk_wrap,recovery_wrap,recovery_auth_hash,created_at,updated_at) VALUES($1,$2,$2,'{}',$2,$2,$1,$2,$2,$2,$3,$3)")
        .bind(USER).bind(vec![7_u8; 32]).bind(t.clone()).execute(pool).await?;
    sqlx::query("INSERT INTO devices(user_id,id,name,platform,approved_at,created_at) VALUES($1,$2,'测试设备','windows',$3,$3)")
        .bind(USER)
        .bind(DEVICE)
        .bind(t)
        .execute(pool)
        .await?;
    let state = AppState(Arc::new(Inner {
        db: pool.clone(),
        keys: ServerKeys::new(&cfg.secret_bytes()?)?,
        cfg,
        mailer: Mailer::Memory(Arc::new(Mutex::new(Vec::new()))),
        allow_test_kdf: true,
    }));
    let session =
        vault_server::auth::issue_session(&state, USER, DEVICE, true).await.map_err(|e| anyhow::anyhow!("签发测试会话: {}", e.message))?;
    Ok((state, session.token))
}

async fn semantics(pool: &AnyPool, addr: SocketAddr, token: &str) -> Result<()> {
    let id = uuid::Uuid::new_v4().to_string();
    let original = item(&id, 0, 1)?;
    ensure!(push(addr, token, vec![original.clone()]).await?["results"][0]["status"] == "applied", "首次推送失败");
    let before = pull(addr, token, 0).await?;
    let cursor = before["cursor"].as_i64().context("缺少 cursor")?;
    // 模拟历史 GC；响应丢失后原封不动重试仍需幂等，不重建历史也不移动游标。
    sqlx::query("DELETE FROM item_versions WHERE user_id=$1 AND item_id=$2").bind(USER).bind(&id).execute(pool).await?;
    ensure!(push(addr, token, vec![original.clone()]).await?["results"][0]["status"] == "applied", "旧base合法重试不兼容");
    ensure!(count(pool, "item_versions", &id).await? == 0, "重试重新制造历史");
    ensure!(pull(addr, token, 0).await?["cursor"] == cursor, "重试移动了cursor");
    for (field, value) in [("kind", json!("note")), ("deleted", json!(true)), ("updated_at", json!(1709164801))] {
        let mut changed = original.clone();
        changed[field] = value;
        ensure!(push(addr, token, vec![changed]).await?["results"][0]["status"] == "conflict", "重放吞掉 {field} 变更");
    }
    ensure!(pull(addr, token, 0).await? == before, "冲突请求改写了远端数据");
    let next = item(&id, 1, 4)?;
    ensure!(push(addr, token, vec![next.clone()]).await?["results"][0]["status"] == "applied", "合法跳版本不兼容");
    ensure!(count(pool, "item_versions", &id).await? == 1, "一次新写入必须恰好一份历史");
    ensure!(count(pool, "change_log", &id).await? == 1, "日志应只保留最新条目版本");
    // 已发布协议允许远端缺失时非零base创建，本次只修竞态，不改变此兼容行为。
    let absent = uuid::Uuid::new_v4().to_string();
    ensure!(push(addr, token, vec![item(&absent, 7, 9)?]).await?["results"][0]["status"] == "applied", "缺失条目旧协议兼容性回归");
    // 整批先校验，尾部非法条目不能使前面合法条目落库。
    let fresh = uuid::Uuid::new_v4().to_string();
    let mut invalid = next;
    invalid["kind"] = json!("invalid");
    let (status, _) = http(addr, token, "POST", "/v1/sync/push", &json!({"items":[item(&fresh,0,1)?,invalid]})).await?;
    ensure!(status == 400 && count(pool, "items", &fresh).await? == 0, "批校验未保持原子性");
    Ok(())
}

async fn race(pool: &AnyPool, addr: SocketAddr, token: &str, existing: bool) -> Result<()> {
    let id = uuid::Uuid::new_v4().to_string();
    if existing {
        push(addr, token, vec![item(&id, 0, 1)?]).await?;
    }
    let base = i64::from(existing);
    let a = item(&id, base, base + 1)?;
    let b = item(&id, base, base + 2)?;
    let (ra, rb) = tokio::join!(push(addr, token, vec![a.clone()]), push(addr, token, vec![b.clone()]));
    let (ra, rb) = (ra?, rb?);
    let statuses = [&ra["results"][0]["status"], &rb["results"][0]["status"]];
    ensure!(statuses.iter().filter(|v| **v == "applied").count() == 1, "同base不同revision同时应用: {ra} / {rb}");
    ensure!(statuses.iter().filter(|v| **v == "conflict").count() == 1, "竞争失败者必须返回协议级conflict");
    let winner = if ra["results"][0]["status"] == "applied" { a } else { b };
    let row = sqlx::query("SELECT revision,blob FROM items WHERE user_id=$1 AND id=$2").bind(USER).bind(&id).fetch_one(pool).await?;
    ensure!(row.try_get::<i64, _>("revision")? == winner["revision"].as_i64().unwrap(), "最终版本不是胜者");
    ensure!(STANDARD.encode(row.try_get::<Vec<u8>, _>("blob")?) == winner["blob"], "密文被败者覆盖");
    ensure!(count(pool, "item_versions", &id).await? == 1 + base, "历史出现败者或重复行");
    ensure!(count(pool, "change_log", &id).await? == 1, "变更日志数量错误");
    let pulled = pull(addr, token, 0).await?;
    let remote = pulled["items"].as_array().unwrap().iter().find(|v| v["id"] == id).context("pull丢失胜者")?;
    ensure!(remote["revision"] == winner["revision"] && remote["blob"] == winner["blob"], "pull与提交结果不一致");
    Ok(())
}

async fn pg_commit_order(pool: &AnyPool, addr: SocketAddr, token: &str, same_item: bool) -> Result<()> {
    // 在 A 分配change_log序号后、提交前阻塞：不同条目验证cursor，同条目验证旧快照不能覆盖。
    let a_id = uuid::Uuid::new_v4().to_string();
    let b_id = if same_item { a_id.clone() } else { uuid::Uuid::new_v4().to_string() };
    let base = i64::from(same_item);
    if same_item {
        push(addr, token, vec![item(&a_id, 0, 1)?]).await?;
    }
    let lock = i64::from(uuid::Uuid::new_v4().as_fields().0);
    let mut gate = pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock($1)").bind(lock).execute(&mut *gate).await?;
    pool.execute(format!("CREATE FUNCTION hold_sync_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.item_id = '{a_id}' THEN PERFORM pg_advisory_xact_lock({lock}); END IF; RETURN NEW; END; $$; CREATE TRIGGER hold_sync_commit AFTER INSERT ON change_log FOR EACH ROW EXECUTE FUNCTION hold_sync_commit()").as_str()).await?;
    let a_item = item(&a_id, base, base + 1)?;
    let owned_token = token.to_owned();
    let first = tokio::spawn(async move { push(addr, &owned_token, vec![a_item]).await });
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let waiting: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM pg_locks WHERE locktype='advisory' AND objid::bigint=$1 AND NOT granted")
                    .bind(lock)
                    .fetch_one(pool)
                    .await?;
            if waiting > 0 {
                return Ok::<_, sqlx::Error>(());
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .context("A未到达提交前阻塞点")??;
    let b_item = item(&b_id, base, base + 2)?;
    let owned_token = token.to_owned();
    let second = tokio::spawn(async move { push(addr, &owned_token, vec![b_item]).await });
    let overtook = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if second.is_finished() { return Ok::<_, sqlx::Error>(true); }
            let waiting: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE l.locktype='transactionid' AND NOT l.granted AND a.datname=current_database() AND a.application_name=current_setting('application_name')")
                .fetch_one(pool).await?;
            if waiting > 0 { return Ok(false); }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await.context("B未进入数据库锁等待，无法证明提交顺序")??;
    gate.commit().await?;
    let ra = first.await??;
    let rb = second.await??;
    pool.execute("DROP TRIGGER hold_sync_commit ON change_log; DROP FUNCTION hold_sync_commit()").await?;
    ensure!(!overtook, "B在A低序号提交前已提交，高cursor会跳过A");
    if same_item {
        ensure!(
            ra["results"][0]["status"] == "applied" && rb["results"][0]["status"] == "conflict",
            "确定性交错下同base不同revision被同时应用"
        );
        ensure!(rb["results"][0]["revision"] == 2, "冲突必须携带已提交版本");
        ensure!(count(pool, "item_versions", &a_id).await? == 2 && count(pool, "change_log", &a_id).await? == 1, "败者污染历史或游标");
        return Ok(());
    }
    ensure!(ra["results"][0]["status"] == "applied" && rb["results"][0]["status"] == "applied", "串行的不同条目应全部应用");
    let seqs = sqlx::query("SELECT item_id,seq FROM change_log WHERE item_id=$1 OR item_id=$2 ORDER BY seq")
        .bind(&a_id)
        .bind(&b_id)
        .fetch_all(pool)
        .await?;
    ensure!(
        seqs.len() == 2 && seqs[0].try_get::<String, _>(0)? == a_id && seqs[1].try_get::<String, _>(0)? == b_id,
        "游标未保持账户提交顺序"
    );
    Ok(())
}

async fn atomicity(pool: &AnyPool, addr: SocketAddr, token: &str, postgres: bool) -> Result<()> {
    let id = uuid::Uuid::new_v4().to_string();
    let trigger = if postgres {
        format!("CREATE FUNCTION reject_sync_log() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.item_id='{id}' THEN RAISE EXCEPTION '测试日志写入失败'; END IF; RETURN NEW; END; $$; CREATE TRIGGER reject_sync_log BEFORE INSERT ON change_log FOR EACH ROW EXECUTE FUNCTION reject_sync_log()")
    } else {
        format!("CREATE TRIGGER reject_sync_log BEFORE INSERT ON change_log WHEN NEW.item_id='{id}' BEGIN SELECT RAISE(ABORT, '测试日志写入失败'); END")
    };
    pool.execute(trigger.as_str()).await?;
    let result = async {
        let (status, _) = http(addr, token, "POST", "/v1/sync/push", &json!({"items":[item(&id,0,1)?]})).await?;
        ensure!(status == 500, "注入日志故障未触发失败");
        for table in ["items", "item_versions", "change_log"] {
            ensure!(count(pool, table, &id).await? == 0, "日志失败留下 {table} 半提交数据");
        }
        Ok::<_, anyhow::Error>(())
    }
    .await;
    pool.execute(if postgres {
        "DROP TRIGGER reject_sync_log ON change_log; DROP FUNCTION reject_sync_log()"
    } else {
        "DROP TRIGGER reject_sync_log"
    })
    .await?;
    result?;
    // 相同密文同版本并发重试：两个Applied，但只有一次真正写入。
    let value = item(&id, 0, 1)?;
    let (a, b) = tokio::join!(push(addr, token, vec![value.clone()]), push(addr, token, vec![value]));
    ensure!(a?["results"][0]["status"] == "applied" && b?["results"][0]["status"] == "applied", "并发合法重试失败");
    for table in ["items", "item_versions", "change_log"] {
        ensure!(count(pool, table, &id).await? == 1, "并发重试重复写入 {table}");
    }
    Ok(())
}

async fn suite(pool: &AnyPool, cfg: Config, postgres: bool) -> Result<()> {
    let (state, token) = fixture(pool, cfg).await?;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let server = tokio::spawn(vault_server::serve(state, listener));
    let result = async {
        semantics(pool, addr, &token).await?;
        atomicity(pool, addr, &token, postgres).await?;
        for _ in 0..8 {
            race(pool, addr, &token, true).await?;
            race(pool, addr, &token, false).await?;
        }
        if postgres {
            pg_commit_order(pool, addr, &token, false).await?;
            pg_commit_order(pool, addr, &token, true).await?;
        }
        Ok(())
    }
    .await;
    server.abort();
    let _ = server.await;
    result
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sqlite_sync_cas_http() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let cfg = config(format!("sqlite:{}?mode=rwc", dir.path().join("sync.db").to_string_lossy().replace('\\', "/")));
    let pool = db::connect(&cfg).await?;
    let result = suite(&pool, cfg, false).await;
    pool.close().await;
    result
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "需要显式授权的本机PG专用测试库；CI单独 --ignored 运行，缺环境报错"]
async fn postgres_sync_cas_http() -> Result<()> {
    ensure!(std::env::var("VAULTONE_SYNC_TEST_PG_ALLOW").as_deref() == Ok("1"), "必须显式VAULTONE_SYNC_TEST_PG_ALLOW=1");
    let url = std::env::var("VAULTONE_SYNC_TEST_PG_URL").context("缺少VAULTONE_SYNC_TEST_PG_URL，PG测试未执行")?;
    let options = PgConnectOptions::from_str(&url)?;
    ensure!(["localhost", "127.0.0.1", "::1"].contains(&options.get_host()), "拒绝非loopback PG");
    ensure!(options.get_database() == Some("vaultone_sync_test"), "只允许vaultone_sync_test专用库");
    sqlx::any::install_default_drivers();
    let admin = AnyPoolOptions::new().max_connections(1).acquire_timeout(Duration::from_secs(5)).connect(&url).await?;
    let schema = format!("sync_{}", uuid::Uuid::new_v4().simple());
    admin.execute(format!("CREATE SCHEMA {schema}").as_str()).await?;
    let search = format!("SET search_path TO {schema}; SET application_name TO '{schema}'; SET statement_timeout TO '10s'");
    let result = async {
        let pool = AnyPoolOptions::new()
            .max_connections(12)
            .acquire_timeout(Duration::from_secs(5))
            .after_connect(move |conn, _| {
                let search = search.clone();
                Box::pin(async move {
                    conn.execute(search.as_str()).await?;
                    Ok(())
                })
            })
            .connect(&url)
            .await?;
        let result = async {
            db::migrate(&pool, false).await?;
            suite(&pool, config(url.clone()), true).await
        }
        .await;
        pool.close().await;
        result
    }
    .await;
    let cleanup = admin.execute(format!("DROP SCHEMA {schema} CASCADE").as_str()).await;
    admin.close().await;
    cleanup?;
    result
}
