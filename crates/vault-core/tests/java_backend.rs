//! Java 服务端黑盒互通测试：Rust 生产客户端（`vault_core::Vault` / `vault_core::sync`）→ Java 后端。
//!
//! 这些用例显式 `#[ignore]`，由未来 Java Testcontainers 驱动在临时 PG / Redis / Jetty 就绪后调用：
//!
//! ```text
//! VAULTONE_JAVA_TEST_URL=http://127.0.0.1:<随机端口>
//! VAULTONE_JAVA_TEST_ALLOW=1
//! cargo test --locked -p vault-core --test java_backend -- --ignored --nocapture
//! ```
//!
//! 约定（与测试驱动的契约）：
//! - 只允许显式声明的回环 HTTP 地址；缺少环境变量直接失败，不跳过、不假装成功。
//! - 只使用随机新账户（`example.test` 邮箱）与内存 SQLite；结束时仅删除本测试新建的账户，
//!   不清空服务端；失败日志不输出密钥 / token / 密码 / 原始响应。
//! - 客户端为阻塞式 `reqwest`（见 `vault_core::sync::ApiClient`），因此用同步 `#[test]`；
//!   把阻塞客户端放进 tokio 运行时会 panic，故这里刻意不写 `#[tokio::test]`。
//! - KDF 统一用 `KdfParams::insecure_for_tests()`；要求 Java 后端以测试配置放行低成本参数
//!   （Rust 服务端对应 `AppState::new(..., allow_test_kdf=true)`，Java 见 `vaultone.development.enabled`）。
//! - 驱动还需为临时后端放开认证 / API 限流（Rust e2e 用 `auth_rate_ms=1`、`auth_burst=10000` 等），
//!   并保证 `/healthz` 可用；本测试不读取邮件 OTP，走「另一台已批准设备批准」路径。

use vault_core::item::{ItemData, ItemKind, ItemUrl};
use vault_core::sync::{ping, LoginOutcome};
use vault_core::{KdfParams, Vault, VaultError};

// ───────────────────────── 安全 fixture ─────────────────────────

/// 校验并返回测试后端地址。
///
/// 只接受 `http://` 回环地址，且必须显式设置 `VAULTONE_JAVA_TEST_ALLOW=1`；任何缺失或不合规
/// 都 panic 使测试失败（不是 return 成功）。
fn loopback_test_url() -> String {
    let raw = std::env::var("VAULTONE_JAVA_TEST_URL")
        .unwrap_or_else(|_| panic!("缺少 VAULTONE_JAVA_TEST_URL；本用例只能由 Java Testcontainers 驱动显式提供回环地址"));
    assert_eq!(
        std::env::var("VAULTONE_JAVA_TEST_ALLOW").ok().as_deref(),
        Some("1"),
        "必须显式设置 VAULTONE_JAVA_TEST_ALLOW=1 才允许连接回环 HTTP 后端"
    );

    let rest = raw.trim().strip_prefix("http://").unwrap_or_else(|| panic!("只允许 http:// 回环地址（收到非 http 或不含 scheme 的地址）"));
    assert!(!rest.contains('@'), "地址不得包含 userinfo");
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..end];
    let tail = &rest[end..];
    assert!(tail.is_empty() || tail == "/", "地址不得包含 path / query / fragment");
    let (host, port) = authority.rsplit_once(':').expect("地址必须显式指定端口");
    assert!(matches!(host, "127.0.0.1" | "localhost" | "[::1]"), "只允许回环主机");
    let port: u16 = port.parse().expect("端口无效");
    assert!(port != 0, "端口不能为 0");
    format!("http://{host}:{port}")
}

/// 每次生成唯一的新账户邮箱（`example.test` 域）。
fn unique_email() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("interop-{nanos:x}-{n}@example.test")
}

fn login_item(title: &str, user: &str, pw: &str) -> ItemData {
    let mut d = ItemData::new(ItemKind::Login, title);
    d.username = Some(user.into());
    d.password = Some(pw.into());
    d.urls.push(ItemUrl { url: format!("https://{}.example.test", title.to_lowercase()), ..Default::default() });
    d
}

/// 服务端必须已就绪；未就绪直接失败，不把不可达当成通过。
fn require_ready(base: &str) {
    assert!(ping(base).is_ok(), "Java 后端未就绪：/healthz 不可达");
}

/// 结束时只删除本测试新建的账户；失败只打印稳定错误码，不带密钥 / token / 原始响应。
fn delete_own_account(v: &mut Vault, master_password: &str, secret_key: &str) {
    if let Err(e) = v.delete_remote_account(master_password, secret_key) {
        eprintln!("清理本测试账户失败（{}），请由测试驱动回收临时后端", e.code());
    }
}

// ───────────────────────── 主线 1-3：注册 / 批准 / 同步 ─────────────────────────

/// 覆盖：本地建号 → register（会话可用、首台设备已批准）→ 第二设备真实 SRP 登录（未批准不下发
/// keys）→ 第一设备批准后可取账户并解锁 → 加密条目 CRUD / 冲突合并 / 幂等 / 墓碑恢复 / 分页。
#[test]
#[ignore = "需要隔离 Java 后端"]
fn register_approval_sync_conflict_and_pagination() {
    let base = loopback_test_url();
    require_ready(&base);
    let email = unique_email();
    let pw = "interop master password one";

    // 1. 本地建号 → 注册。返回会话可用；首台设备已批准且为当前设备。
    let mut a = Vault::open_in_memory().unwrap();
    let kit = a.create_account(&email, pw, KdfParams::insecure_for_tests()).unwrap();
    let gh = a.create_item(login_item("GitHub", "alice", "gh-secret-1")).unwrap();
    let bank = a.create_item(login_item("Bank", "alice-bank", "bank-secret-2")).unwrap();
    let report = a.connect_register(&base, "Interop A").unwrap();
    assert!(report.pushed >= 2, "注册后应至少推送 2 条本地条目");
    assert!(a.remote_status().unwrap().is_some(), "注册后应保存会话");
    let devices = a.list_devices().unwrap();
    assert_eq!(devices.len(), 1, "注册应产生首台设备");
    assert!(devices[0].approved && devices[0].current, "首台设备应为已批准且当前设备");

    // 2. 第二临时保险库：真实 SRP 登录，未批准不下发可用 keys。
    let mut b = Vault::open_in_memory().unwrap();
    assert_eq!(b.login_existing(&base, &email, pw, &kit.secret_key, "Interop B").unwrap(), LoginOutcome::NeedsDeviceApproval);
    assert!(b.list_items().is_err(), "未批准设备不得持有可用 keys");

    // 第一设备批准 B：B 取回账户并解锁（间接证明 register 下发的 keys 与服务端一致）。
    let pending = a.list_devices().unwrap().into_iter().find(|d| !d.approved).expect("待批准设备");
    a.approve_device(&pending.id).unwrap();
    assert!(b.check_new_device_approved().unwrap(), "批准后应可加入账户");
    assert_eq!(b.list_items().unwrap().len(), 2);
    assert_eq!(&*b.email().unwrap(), &email);
    let devices = a.list_devices().unwrap();
    assert_eq!(devices.len(), 2);
    assert!(devices.iter().all(|d| d.approved), "设备列表应显示两台已批准设备");

    // 3. 冲突合并：双方改同一条目的不同字段，字段级合并后双方修改都保留。
    let mut on_a = a.get_item(&gh.id).unwrap().data;
    on_a.username = Some("alice-renamed".into());
    a.update_item(&gh.id, on_a).unwrap();
    let mut on_b = b.get_item(&gh.id).unwrap().data;
    on_b.notes = Some("note-from-b".into());
    b.update_item(&gh.id, on_b).unwrap();
    a.sync_now().unwrap();
    let rb = b.sync_now().unwrap();
    assert_eq!(rb.merged, 1, "同一条目不同字段应触发一次合并");
    a.sync_now().unwrap();
    for v in [&a, &b] {
        let it = v.get_item(&gh.id).unwrap();
        assert_eq!(it.data.username.as_deref(), Some("alice-renamed"));
        assert_eq!(it.data.notes.as_deref(), Some("note-from-b"));
    }

    // 重复同步幂等：无新变更时不应重复拉取。
    assert_eq!(a.sync_now().unwrap().pulled, 0);

    // 墓碑：删除同步 → 回收站可见 → 恢复同步。
    a.delete_item(&bank.id).unwrap();
    a.sync_now().unwrap();
    b.sync_now().unwrap();
    assert!(b.list_items().unwrap().iter().all(|i| i.id != bank.id));
    assert_eq!(b.list_trash().unwrap().len(), 1);
    b.restore_item(&bank.id).unwrap();
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    assert!(a.list_items().unwrap().iter().any(|i| i.id == bank.id), "恢复墓碑后条目应回到双方");

    // 4. 分页：一次制造超过 pull 单页上限的变更，验证多页拉取不漏项。
    let extra = 505usize;
    for i in 0..extra {
        b.create_item(login_item(&format!("Bulk{i}"), "u", &format!("bulk-pw-{i}"))).unwrap();
    }
    b.sync_now().unwrap();
    a.sync_now().unwrap();
    let a_count = a.list_items().unwrap().len();
    let b_count = b.list_items().unwrap().len();
    assert_eq!(a_count, b_count, "跨页拉取后双方条目数应一致");
    assert_eq!(a_count, 2 + extra, "条目总数应为初始 2 条 + 批量 {extra} 条");
    assert!(a.list_items().unwrap().iter().any(|i| i.id == gh.id));

    delete_own_account(&mut a, pw, &kit.secret_key);
}

// ───────────────────────── 主线 4：改主密码 ─────────────────────────

/// 覆盖：真实改主密码 → 推送新凭据（vk_gen 递增）→ 另一设备拉取并采用新封装 → 旧密码失效、
/// 新密码可用 → 全新设备旧密码登录失败、新密码登录需批准。
#[test]
#[ignore = "需要隔离 Java 后端"]
fn change_master_password_new_login_old_fails() {
    let base = loopback_test_url();
    require_ready(&base);
    let email = unique_email();
    let old_pw = "interop master password old";
    let new_pw = "interop master password new";

    let mut a = Vault::open_in_memory().unwrap();
    let kit = a.create_account(&email, old_pw, KdfParams::insecure_for_tests()).unwrap();
    a.create_item(login_item("Mail", "alice", "mail-secret-1")).unwrap();
    a.connect_register(&base, "Interop PW A").unwrap();

    // 已加入的另一台设备先持有旧凭据。
    let mut b = Vault::open_in_memory().unwrap();
    assert_eq!(b.login_existing(&base, &email, old_pw, &kit.secret_key, "Interop PW B").unwrap(), LoginOutcome::NeedsDeviceApproval);
    let pending = a.list_devices().unwrap().into_iter().find(|d| !d.approved).unwrap();
    a.approve_device(&pending.id).unwrap();
    assert!(b.check_new_device_approved().unwrap());

    // 改主密码 → 推送新凭据。
    a.change_master_password(old_pw, &kit.secret_key, new_pw).unwrap();
    assert!(a.sync_now().unwrap().credentials_updated, "改密后应推送新凭据");

    // B 拉取到新 vk_gen 并采用新封装；旧密码失效、新密码可用。
    assert!(b.sync_now().unwrap().credentials_updated, "另一设备应拉取到新 vk_gen 并采用新封装");
    b.lock();
    assert!(b.unlock(old_pw, &kit.secret_key).is_err(), "旧主密码应失效");
    b.unlock(new_pw, &kit.secret_key).unwrap();
    assert_eq!(b.list_items().unwrap().len(), 1);

    // 全新设备：旧密码登录失败，新密码登录需批准。
    let mut c = Vault::open_in_memory().unwrap();
    assert!(matches!(c.login_existing(&base, &email, old_pw, &kit.secret_key, "Interop PW C"), Err(VaultError::InvalidCredentials)));
    let mut d = Vault::open_in_memory().unwrap();
    assert_eq!(d.login_existing(&base, &email, new_pw, &kit.secret_key, "Interop PW D").unwrap(), LoginOutcome::NeedsDeviceApproval);
    let pending = a.list_devices().unwrap().into_iter().find(|x| x.name == "Interop PW D").unwrap();
    a.approve_device(&pending.id).unwrap();
    assert!(d.check_new_device_approved().unwrap());
    assert_eq!(d.list_items().unwrap().len(), 1);

    delete_own_account(&mut a, new_pw, &kit.secret_key);
}

// ───────────────────────── 主线 5：恢复 ─────────────────────────

/// 覆盖：recovery start/fetch/complete → 老会话被撤销、恢复材料轮换、旧恢复凭据不可再用、
/// 轮换后的新恢复码可用、旧主密码失效。
#[test]
#[ignore = "需要隔离 Java 后端"]
fn recovery_rotates_material_and_revokes_sessions() {
    let base = loopback_test_url();
    require_ready(&base);
    let email = unique_email();
    let pw = "interop master password rec";
    let rec_pw = "interop recovered password 1";
    let rec_pw2 = "interop recovered password 2";

    let mut a = Vault::open_in_memory().unwrap();
    let kit = a.create_account(&email, pw, KdfParams::insecure_for_tests()).unwrap();
    for i in 0..3 {
        a.create_item(login_item(&format!("Site{i}"), "bob", &format!("site-pw-{i}"))).unwrap();
    }
    a.connect_register(&base, "Interop Rec A").unwrap();

    // 新设备用恢复套件取回账户。
    let mut c = Vault::open_in_memory().unwrap();
    let kit2 = c.recover_from_server(&base, &email, &kit.recovery_code, &kit.secret_key, rec_pw, "Interop Rec C").unwrap();
    assert_eq!(c.list_items().unwrap().len(), 3);
    assert_ne!(*kit2.recovery_code, *kit.recovery_code, "恢复后恢复码应轮换");

    // 老会话被撤销。
    assert!(matches!(a.sync_now(), Err(VaultError::Server { status: 401, .. })), "恢复应撤销既有会话");

    // 旧恢复码不可再次使用。
    let mut e = Vault::open_in_memory().unwrap();
    assert!(matches!(
        e.recover_from_server(&base, &email, &kit.recovery_code, &kit.secret_key, rec_pw, "Interop Rec E"),
        Err(VaultError::InvalidRecoveryCode)
    ));

    // 旧主密码登录失败。
    let mut d = Vault::open_in_memory().unwrap();
    assert!(d.login_existing(&base, &email, pw, &kit.secret_key, "Interop Rec D").is_err());

    // 轮换后的新恢复码可用（再次恢复会再轮换一次），旧一轮恢复码随即作废。
    let mut f = Vault::open_in_memory().unwrap();
    let kit3 = f.recover_from_server(&base, &email, &kit2.recovery_code, &kit2.secret_key, rec_pw2, "Interop Rec F").unwrap();
    assert_eq!(f.list_items().unwrap().len(), 3);
    assert_ne!(*kit3.recovery_code, *kit2.recovery_code);
    let mut g = Vault::open_in_memory().unwrap();
    assert!(g.recover_from_server(&base, &email, &kit2.recovery_code, &kit2.secret_key, rec_pw2, "Interop Rec G").is_err());

    delete_own_account(&mut f, rec_pw2, &kit3.secret_key);
}

// ───────────────────────── 主线 6a：设备撤销 / 审计 / 注销 ─────────────────────────

/// 覆盖：设备撤销立即拒绝其会话、审计返回、重复邮箱注册 409、注销账户后无法再登录。
#[test]
#[ignore = "需要隔离 Java 后端"]
fn device_revoke_audit_and_account_deletion() {
    let base = loopback_test_url();
    require_ready(&base);
    let email = unique_email();
    let pw = "interop master password rev";

    let mut a = Vault::open_in_memory().unwrap();
    let kit = a.create_account(&email, pw, KdfParams::insecure_for_tests()).unwrap();
    a.create_item(login_item("X", "u", "x-pw")).unwrap();
    a.connect_register(&base, "Interop Rev A").unwrap();

    // 重复邮箱注册 → 409 email_taken（稳定错误码，不依赖 message 文本）。
    let mut dup = Vault::open_in_memory().unwrap();
    dup.create_account(&email, pw, KdfParams::insecure_for_tests()).unwrap();
    match dup.connect_register(&base, "Interop Rev Dup") {
        Err(VaultError::Server { status: 409, code, .. }) => assert_eq!(code, "email_taken"),
        _ => panic!("重复邮箱应返回 409 email_taken"),
    }

    // 第二设备加入后撤销 → 其会话立即被拒。
    let mut b = Vault::open_in_memory().unwrap();
    assert_eq!(b.login_existing(&base, &email, pw, &kit.secret_key, "Interop Rev B").unwrap(), LoginOutcome::NeedsDeviceApproval);
    let pending = a.list_devices().unwrap().into_iter().find(|d| !d.approved).unwrap();
    a.approve_device(&pending.id).unwrap();
    assert!(b.check_new_device_approved().unwrap());

    let b_id = a.list_devices().unwrap().into_iter().find(|d| !d.current).expect("另一台设备").id;
    a.revoke_device(&b_id).unwrap();
    assert!(matches!(b.sync_now(), Err(VaultError::Server { status: 401, .. })), "撤销后设备会话应立即失效");

    // 审计返回事件。
    let events = a.audit_events().unwrap();
    assert!(!events.is_empty(), "审计应至少返回设备相关事件");
    assert!(events.iter().any(|e| e.event == "device_approved"), "审计应含设备批准事件");

    // 注销账户 → 本地数据保留、远端清除、重新登录失败。
    let local_items = a.list_items().unwrap().len();
    a.delete_remote_account(pw, &kit.secret_key).unwrap();
    assert!(a.remote_status().unwrap().is_none(), "注销后应清除远端会话");
    assert_eq!(a.list_items().unwrap().len(), local_items, "注销仅删除云端账户，本地数据保留");
    let mut n = Vault::open_in_memory().unwrap();
    assert!(n.login_existing(&base, &email, pw, &kit.secret_key, "Interop Rev N").is_err(), "注销后应无法登录");
}

// ───────────────────────── 主线 6b：退出登录 ─────────────────────────

/// 覆盖：退出（logout）清除本机会话、后续同步不可用，但本地数据保留、账户仍在，
/// 另一台已批准设备仍可操作并最终注销。
#[test]
#[ignore = "需要隔离 Java 后端"]
fn logout_clears_session_but_other_device_can_operate() {
    let base = loopback_test_url();
    require_ready(&base);
    let email = unique_email();
    let pw = "interop master password out";

    let mut a = Vault::open_in_memory().unwrap();
    let kit = a.create_account(&email, pw, KdfParams::insecure_for_tests()).unwrap();
    a.connect_register(&base, "Interop Out A").unwrap();

    let mut b = Vault::open_in_memory().unwrap();
    assert_eq!(b.login_existing(&base, &email, pw, &kit.secret_key, "Interop Out B").unwrap(), LoginOutcome::NeedsDeviceApproval);
    let pending = a.list_devices().unwrap().into_iter().find(|d| !d.approved).unwrap();
    a.approve_device(&pending.id).unwrap();
    assert!(b.check_new_device_approved().unwrap());

    // A 退出登录：远端会话清除，同步不再可用，本地数据仍可用。
    a.disconnect().unwrap();
    assert!(a.remote_status().unwrap().is_none(), "退出后不应保留远端会话");
    assert!(matches!(a.sync_now(), Err(VaultError::NotConnected)));
    assert!(a.list_items().is_ok(), "退出仅断开同步，本地数据仍可用");

    // 账户仍存在，另一台已批准设备可正常操作并最终注销。
    assert!(!b.list_devices().unwrap().is_empty());
    delete_own_account(&mut b, pw, &kit.secret_key);
}
