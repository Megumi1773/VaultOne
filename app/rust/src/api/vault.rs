//! 保险库生命周期与条目 CRUD。全局只有一个保险库实例，受互斥锁保护。

use std::sync::{Mutex, MutexGuard, OnceLock};

use vault_core::item::ItemData;
use vault_core::{security, KdfParams, Vault, VaultError};

use super::{BridgeError, BridgeResult};

static VAULT: OnceLock<Mutex<Option<Vault>>> = OnceLock::new();

fn slot() -> MutexGuard<'static, Option<Vault>> {
    // 某次调用 panic 导致锁中毒时，保险库状态仍一致（写入都在事务内），继续使用
    VAULT.get_or_init(|| Mutex::new(None)).lock().unwrap_or_else(|e| e.into_inner())
}

pub(crate) fn with_vault<T>(f: impl FnOnce(&mut Vault) -> Result<T, VaultError>) -> BridgeResult<T> {
    let mut guard = slot();
    let v = guard.as_mut().ok_or_else(|| BridgeError { code: "not_open".into(), message: "保险库尚未打开".into() })?;
    Ok(f(v)?)
}

#[derive(Debug, Clone)]
pub struct EnrollmentDto {
    pub account_id: String,
    pub email: String,
    pub secret_key: String,
    pub recovery_code: String,
}

impl From<vault_core::vault::Enrollment> for EnrollmentDto {
    fn from(e: vault_core::vault::Enrollment) -> Self {
        Self { account_id: e.account_id, email: e.email, secret_key: e.secret_key.to_string(), recovery_code: e.recovery_code.to_string() }
    }
}

#[derive(Debug, Clone)]
pub struct VaultStatus {
    pub initialized: bool,
    pub unlocked: bool,
    pub account_id: Option<String>,
    pub quick_unlock_enabled: bool,
    pub pending_login: bool,
}

#[derive(Debug, Clone)]
pub struct AccountInfo {
    pub account_id: String,
    pub email: String,
    pub kdf_summary: String,
    pub pending_changes: u64,
    pub item_count: u64,
}

#[derive(Debug, Clone)]
pub struct AuditFindingDto {
    pub item_id: String,
    pub weak: bool,
    pub score: u8,
    pub reused_with: u32,
}

/// 打开（不存在则创建）本地保险库文件。
pub fn open_vault(path: String) -> BridgeResult<()> {
    let v = Vault::open(&path)?;
    *slot() = Some(v);
    tracing::info!(target: "bridge", "vault opened");
    Ok(())
}

pub fn status() -> BridgeResult<VaultStatus> {
    with_vault(|v| {
        let initialized = v.is_initialized()?;
        Ok(VaultStatus {
            initialized,
            unlocked: v.is_unlocked(),
            account_id: if initialized { Some(v.account_id()?) } else { None },
            quick_unlock_enabled: v.quick_unlock_enabled()?,
            pending_login: v.has_pending_login(),
        })
    })
}

/// 创建本地账户（Argon2id m=64MiB,t=3,p=4，32 字节随机盐）。
pub fn create_account(email: String, password: String) -> BridgeResult<EnrollmentDto> {
    with_vault(|v| v.create_account(&email, &password, KdfParams::recommended()).map(Into::into))
}

pub fn unlock(password: String, secret_key: String) -> BridgeResult<()> {
    with_vault(|v| v.unlock(&password, &secret_key))
}

pub fn unlock_with_quick_key(key: Vec<u8>) -> BridgeResult<()> {
    with_vault(|v| v.unlock_with_quick_key(&key))
}

/// 返回的快速解锁密钥应立即写入系统钥匙串（受生物识别保护），Dart 侧不得另存。
pub fn enable_quick_unlock() -> BridgeResult<Vec<u8>> {
    with_vault(|v| v.enable_quick_unlock().map(|k| k.to_vec()))
}

pub fn disable_quick_unlock() -> BridgeResult<()> {
    with_vault(|v| v.disable_quick_unlock())
}

pub fn verify_master_password(password: String, secret_key: String) -> BridgeResult<()> {
    with_vault(|v| v.verify_master_password(&password, &secret_key))
}

pub fn lock() -> BridgeResult<()> {
    with_vault(|v| {
        v.lock();
        Ok(())
    })
}

pub fn account_info() -> BridgeResult<AccountInfo> {
    with_vault(|v| {
        let kdf = v.kdf_params()?;
        Ok(AccountInfo {
            account_id: v.account_id()?,
            email: v.email()?.to_string(),
            kdf_summary: format!("Argon2id · {} MiB · t={} · p={}", kdf.m / 1024, kdf.t, kdf.p),
            pending_changes: v.pending_changes()?,
            item_count: v.item_count()?,
        })
    })
}

pub fn change_password(current: String, secret_key: String, new_password: String) -> BridgeResult<()> {
    with_vault(|v| v.change_master_password(&current, &secret_key, &new_password))
}

pub fn recover_local(recovery_code: String, secret_key: String, new_password: String) -> BridgeResult<EnrollmentDto> {
    with_vault(|v| v.recover(&recovery_code, &secret_key, &new_password).map(Into::into))
}

fn items_json(items: Vec<vault_core::item::Item>) -> BridgeResult<String> {
    let arr: Vec<serde_json::Value> = items.iter().map(item_value).collect();
    Ok(serde_json::to_string(&arr)?)
}

fn item_value(i: &vault_core::item::Item) -> serde_json::Value {
    serde_json::json!({ "id": i.id, "vaultId": i.vault_id, "revision": i.revision, "data": i.data })
}

/// 全部未删除条目（JSON 数组）。
pub fn list_items() -> BridgeResult<String> {
    items_json(with_vault(|v| v.list_items())?)
}

pub fn list_trash() -> BridgeResult<String> {
    items_json(with_vault(|v| v.list_trash())?)
}

pub fn create_item(data_json: String) -> BridgeResult<String> {
    let data: ItemData = serde_json::from_str(&data_json)?;
    let item = with_vault(|v| v.create_item(data))?;
    Ok(serde_json::to_string(&item_value(&item))?)
}

pub fn update_item(id: String, data_json: String) -> BridgeResult<String> {
    let data: ItemData = serde_json::from_str(&data_json)?;
    let item = with_vault(|v| v.update_item(&id, data))?;
    Ok(serde_json::to_string(&item_value(&item))?)
}

pub fn delete_item(id: String) -> BridgeResult<()> {
    with_vault(|v| v.delete_item(&id))
}

pub fn restore_item(id: String) -> BridgeResult<()> {
    with_vault(|v| v.restore_item(&id))
}

/// 本地弱密码 / 重复密码审计。
pub fn audit_local() -> BridgeResult<Vec<AuditFindingDto>> {
    let items = with_vault(|v| v.list_items())?;
    Ok(security::audit(&items)
        .into_iter()
        .map(|f| AuditFindingDto { item_id: f.item_id, weak: f.weak, score: f.score, reused_with: f.reused_with })
        .collect())
}

/// 对指定条目做 HIBP 泄露检测（k-匿名：只发送 SHA-1 前 5 位），返回 (条目 ID, 泄露次数)。
pub fn check_breaches(item_ids: Vec<String>) -> BridgeResult<Vec<BreachResult>> {
    let items = with_vault(|v| v.list_items())?;
    let mut out = Vec::new();
    for item in items.iter().filter(|i| item_ids.contains(&i.id)) {
        if let Some(pw) = item.data.password.as_deref().filter(|p| !p.is_empty()) {
            let count = security::check_breach(pw)?;
            out.push(BreachResult { item_id: item.id.clone(), count });
        }
    }
    Ok(out)
}

#[derive(Debug, Clone)]
pub struct BreachResult {
    pub item_id: String,
    pub count: u64,
}

/// 对页面 URL 做防钓鱼匹配，返回按匹配质量排序的条目 ID。
pub fn match_items(page_url: String) -> BridgeResult<Vec<String>> {
    let items = with_vault(|v| v.list_items())?;
    Ok(vault_core::urlmatch::find_matches(&items, &page_url).into_iter().map(|(i, _)| i.id.clone()).collect())
}

pub fn get_setting(key: String) -> BridgeResult<Option<String>> {
    with_vault(|v| v.get_setting(&key))
}

pub fn set_setting(key: String, value: String) -> BridgeResult<()> {
    with_vault(|v| v.set_setting(&key, &value))
}

/// 清空本机保险库（注销本机 / 重置应用）。
pub fn wipe_local() -> BridgeResult<()> {
    with_vault(|v| v.wipe_local())
}
