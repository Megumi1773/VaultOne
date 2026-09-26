//! 端到端测试：真实启动 vault-server（SQLite 临时库），用 vault-core 客户端走完整业务流程。
//! 覆盖计划书验收项：A-03/A-05（同步与离线）、B-01（服务端零明文）、B-03（主密码不出端）、
//! B-07（Recovery Kit 灾难恢复）、F-01（新设备二次验证）、F-06（冲突合并）。

use std::sync::{Arc, Mutex};

use vault_core::item::{ItemData, ItemKind, ItemUrl};
use vault_core::sync::LoginOutcome;
use vault_core::{KdfParams, Vault, VaultError};
use vault_server::config::Config;
use vault_server::mail::{Mail, Mailer};
use vault_server::AppState;

const PW: &str = "correct horse battery staple";

struct TestServer {
    url: String,
    mails: Arc<Mutex<Vec<Mail>>>,
    db_path: std::path::PathBuf,
    _dir: tempfile::TempDir,
    rt: tokio::runtime::Runtime,
}

impl TestServer {
    fn start() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("server.db");
        let cfg = Config {
            database_url: format!("sqlite:{}?mode=rwc", db_path.display().to_string().replace('\\', "/")),
            server_secret: Some("0123456789abcdef".repeat(4)),
            auth_rate_ms: 1,
            auth_burst: 10_000,
            api_rate_ms: 1,
            api_burst: 10_000,
            ..Config::default()
        };
        cfg.validate().unwrap();
        let mails = Arc::new(Mutex::new(Vec::new()));
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
        let mailer = Mailer::Memory(mails.clone());
        let url = rt.block_on(async {
            let state = AppState::new(cfg, mailer, true).await.unwrap();
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            tokio::spawn(vault_server::serve(state, listener));
            format!("http://{addr}")
        });
        Self { url, mails, db_path, _dir: dir, rt }
    }

    fn last_otp(&self) -> String {
        let mails = self.mails.lock().unwrap();
        let body = &mails.iter().rev().find(|m| m.subject.contains("验证码")).expect("otp mail").body;
        let idx = body.find("验证码：").unwrap() + "验证码：".len();
        body[idx..].chars().take(6).collect()
    }

    fn raw_db(&self) -> String {
        let mut raw = Vec::new();
        for suffix in ["", "-wal", "-shm"] {
            let p = format!("{}{suffix}", self.db_path.display());
            if let Ok(b) = std::fs::read(p) {
                raw.extend(b);
            }
        }
        String::from_utf8_lossy(&raw).into_owned()
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        // 让服务端任务随运行时一起结束
        let rt = std::mem::replace(&mut self.rt, tokio::runtime::Builder::new_current_thread().build().unwrap());
        rt.shutdown_background();
    }
}

fn login(title: &str, user: &str, pw: &str) -> ItemData {
    let mut d = ItemData::new(ItemKind::Login, title);
    d.username = Some(user.into());
    d.password = Some(pw.into());
    d.urls.push(ItemUrl { url: format!("https://{}.example.com", title.to_lowercase()), ..Default::default() });
    d
}

fn new_device(srv: &TestServer, email: &str, sk: &str, name: &str) -> Vault {
    let mut v = Vault::open_in_memory().unwrap();
    match v.login_existing(&srv.url, email, PW, sk, name).unwrap() {
        LoginOutcome::NeedsDeviceApproval => v.verify_new_device(&srv.last_otp()).unwrap(),
        LoginOutcome::Joined => panic!("new device must need approval"),
    }
    v
}

#[test]
fn full_lifecycle() {
    let srv = TestServer::start();

    // ── 设备 A：本地建号 → 注册到服务端 ──
    let mut a = Vault::open_in_memory().unwrap();
    let kit = a.create_account("alice@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
    let gh = a.create_item(login("GitHub", "alice", "gh-secret-password-1")).unwrap();
    a.create_item(login("Bank", "alice-bank", "bank-secret-password-2")).unwrap();
    let report = a.connect_register(&srv.url, "Alice Laptop").unwrap();
    assert_eq!(report.pushed, 2);
    assert_eq!(a.pending_changes().unwrap(), 0);

    // ── 错误凭据：错误主密码、未注册邮箱 → 同一错误（防枚举） ──
    let mut x = Vault::open_in_memory().unwrap();
    assert!(matches!(
        x.login_existing(&srv.url, "alice@example.com", "wrong password!!", &kit.secret_key, "X"),
        Err(VaultError::InvalidCredentials)
    ));
    assert!(matches!(x.login_existing(&srv.url, "nobody@example.com", PW, &kit.secret_key, "X"), Err(VaultError::InvalidCredentials)));

    // ── 设备 B：新设备必须二次验证（F-01） ──
    let mut b = Vault::open_in_memory().unwrap();
    assert_eq!(
        b.login_existing(&srv.url, "alice@example.com", PW, &kit.secret_key, "Alice Phone").unwrap(),
        LoginOutcome::NeedsDeviceApproval
    );
    assert!(b.verify_new_device("000000").is_err() || srv.last_otp() == "000000");
    b.verify_new_device(&srv.last_otp()).unwrap();
    assert_eq!(b.list_items().unwrap().len(), 2);
    assert_eq!(&*b.email().unwrap(), "alice@example.com");

    // ── 并发编辑同一条目的不同字段 → 字段级合并，双方修改都保留（F-06） ──
    let mut on_a = a.get_item(&gh.id).unwrap().data;
    on_a.username = Some("alice-renamed".into());
    a.update_item(&gh.id, on_a).unwrap();
    let mut on_b = b.get_item(&gh.id).unwrap().data;
    on_b.notes = Some("note from phone".into());
    b.update_item(&gh.id, on_b).unwrap();
    a.sync_now().unwrap();
    let rb = b.sync_now().unwrap();
    assert_eq!(rb.merged, 1);
    a.sync_now().unwrap();
    for v in [&a, &b] {
        let it = v.get_item(&gh.id).unwrap();
        assert_eq!(it.data.username.as_deref(), Some("alice-renamed"));
        assert_eq!(it.data.notes.as_deref(), Some("note from phone"));
    }

    // ── 离线积压 200 条 → 联网补传，零丢失零重复（A-05） ──
    for i in 0..200 {
        b.create_item(login(&format!("Offline{i}"), "u", &format!("offline-pw-{i}"))).unwrap();
    }
    assert_eq!(b.pending_changes().unwrap(), 200);
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    assert_eq!(a.list_items().unwrap().len(), 202);
    assert_eq!(b.list_items().unwrap().len(), 202);
    // 重复同步是幂等的
    assert_eq!(a.sync_now().unwrap().pulled, 0);

    // ── 删除同步 ──
    let bank_id = a.list_items().unwrap().into_iter().find(|i| i.data.title == "Bank").unwrap().id;
    a.delete_item(&bank_id).unwrap();
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    assert!(b.list_items().unwrap().iter().all(|i| i.id != bank_id));
    assert_eq!(b.list_trash().unwrap().len(), 1);

    // ── 设备管理与审计 ──
    let devices = a.list_devices().unwrap();
    assert_eq!(devices.len(), 2);
    assert!(devices.iter().all(|d| d.approved));
    let events: Vec<String> = a.audit_events().unwrap().into_iter().map(|e| e.event).collect();
    assert!(events.contains(&"login_fail".to_string()));
    assert!(events.contains(&"device_approved".to_string()));

    // ── 设备 A 改主密码 → 设备 B 同步后采用新封装，新密码可解锁 ──
    a.change_master_password(PW, &kit.secret_key, "a brand new master password").unwrap();
    assert!(a.sync_now().unwrap().credentials_updated);
    assert!(b.sync_now().unwrap().credentials_updated);
    b.lock();
    assert!(b.unlock(PW, &kit.secret_key).is_err());
    b.unlock("a brand new master password", &kit.secret_key).unwrap();
    assert_eq!(b.list_items().unwrap().len(), 201);

    // ── B-01：服务端数据库中检索不到任何明文 ──
    let raw = srv.raw_db();
    for marker in [
        "alice@example.com",
        "gh-secret-password-1",
        "bank-secret-password-2",
        "GitHub",
        "alice-renamed",
        "note from phone",
        "offline-pw-7",
        PW,
    ] {
        assert!(!raw.contains(marker), "服务端明文泄露: {marker}");
    }
}

#[test]
fn recovery_kit_restores_everything_after_all_devices_lost() {
    let srv = TestServer::start();
    let mut a = Vault::open_in_memory().unwrap();
    let kit = a.create_account("bob@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
    for i in 0..5 {
        a.create_item(login(&format!("Site{i}"), "bob", &format!("pw-{i}"))).unwrap();
    }
    a.connect_register(&srv.url, "Bob PC").unwrap();
    drop(a); // 所有设备丢失

    let mut c = Vault::open_in_memory().unwrap();
    // 错误恢复码
    let bad = vault_crypto::keys::RecoveryCode::generate().format();
    assert!(matches!(
        c.recover_from_server(&srv.url, "bob@example.com", &bad, &kit.secret_key, "new master password", "Bob New PC"),
        Err(VaultError::InvalidRecoveryCode)
    ));
    let new_kit = c
        .recover_from_server(&srv.url, "bob@example.com", &kit.recovery_code, &kit.secret_key, "new master password", "Bob New PC")
        .unwrap();
    assert_eq!(c.list_items().unwrap().len(), 5);
    assert_ne!(*new_kit.recovery_code, *kit.recovery_code);

    // 旧主密码失效，新主密码可在另一台新设备登录
    let mut d = Vault::open_in_memory().unwrap();
    assert!(d.login_existing(&srv.url, "bob@example.com", PW, &kit.secret_key, "D").is_err());
    let mut d = Vault::open_in_memory().unwrap();
    assert_eq!(
        d.login_existing(&srv.url, "bob@example.com", "new master password", &kit.secret_key, "D").unwrap(),
        LoginOutcome::NeedsDeviceApproval
    );
    // 由已批准设备 C 批准 D
    let pending = c.list_devices().unwrap().into_iter().find(|x| !x.approved).unwrap();
    c.approve_device(&pending.id).unwrap();
    assert!(d.check_new_device_approved().unwrap());
    assert_eq!(d.list_items().unwrap().len(), 5);

    // 旧恢复码作废
    let mut e = Vault::open_in_memory().unwrap();
    assert!(e.recover_from_server(&srv.url, "bob@example.com", &kit.recovery_code, &kit.secret_key, "another password!", "E").is_err());

    // 撤销设备 D 后其会话失效
    let d_id = c.list_devices().unwrap().into_iter().find(|x| x.name == "D").unwrap().id;
    c.revoke_device(&d_id).unwrap();
    assert!(matches!(d.sync_now(), Err(VaultError::Server { status: 401, .. })));
}

#[test]
fn account_deletion_and_email_uniqueness() {
    let srv = TestServer::start();
    let mut a = Vault::open_in_memory().unwrap();
    let kit = a.create_account("carol@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
    a.create_item(login("X", "c", "p")).unwrap();
    a.connect_register(&srv.url, "Carol").unwrap();

    let mut dup = Vault::open_in_memory().unwrap();
    dup.create_account("carol@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
    assert!(matches!(dup.connect_register(&srv.url, "Dup"), Err(VaultError::Server { status: 409, .. })));

    assert!(a.delete_remote_account("wrong password!!", &kit.secret_key).is_err());
    a.delete_remote_account(PW, &kit.secret_key).unwrap();
    assert!(a.remote_status().unwrap().is_none());
    // 本地数据保留
    assert_eq!(a.list_items().unwrap().len(), 1);
    let mut b = Vault::open_in_memory().unwrap();
    assert!(b.login_existing(&srv.url, "carol@example.com", PW, &kit.secret_key, "B").is_err());
    // 删除后邮箱可重新注册
    dup.connect_register(&srv.url, "Dup").unwrap();
}

#[test]
fn second_device_multiple_new_device_logins_use_new_otp() {
    let srv = TestServer::start();
    let mut a = Vault::open_in_memory().unwrap();
    let kit = a.create_account("dave@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
    a.connect_register(&srv.url, "Dave").unwrap();
    let b = new_device(&srv, "dave@example.com", &kit.secret_key, "Dave Phone");
    assert!(b.remote_status().unwrap().is_some());
}
