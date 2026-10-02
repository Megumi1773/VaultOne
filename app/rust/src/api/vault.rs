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

#[cfg(test)]
pub(crate) fn slot_for_tests() -> MutexGuard<'static, Option<Vault>> {
    slot()
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
///
/// 同一进程内可能有多个 Flutter 引擎（Android 自动填充界面与主界面共用进程）：已打开同一文件时直接复用，
/// 不替换现有实例，因此主界面已解锁时自动填充无需再次解锁。
pub fn open_vault(path: String) -> BridgeResult<()> {
    static OPENED: Mutex<Option<String>> = Mutex::new(None);
    let mut opened = OPENED.lock().unwrap_or_else(|e| e.into_inner());
    if opened.as_deref() == Some(path.as_str()) && slot().is_some() {
        return Ok(());
    }
    let v = Vault::open(&path)?;
    *slot() = Some(v);
    *opened = Some(path);
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

/// 备份二次确认：把用户重输的 Secret Key 与本机保存的做逐字节比对（解析后 30 字节，常量时间）。
///
/// 大小写、分组连字符、空白与 I/L/O 的手抄差异被容忍，字节内容必须完全一致。成功时返回
/// 本机 Secret Key 的规范形态，供备份卡与展示使用。格式错误与内容不符返回同一个
/// `secret_key_mismatch`，不给出手抄位置信号。
pub fn verify_secret_key(stored: String, candidate: String) -> BridgeResult<String> {
    Ok(vault_crypto::keys::verify_secret_key(&stored, &candidate)?.to_string())
}

/// 恢复码规范化：本机不保存恢复码字节，只校验 Crockford Base32 格式并返回规范形态，
/// 供备份卡与恢复套件重新导出使用。内容是否属于当前账户由服务端在真正恢复时判定。
pub fn canonical_recovery_code(candidate: String) -> BridgeResult<String> {
    Ok(vault_crypto::keys::canonical_recovery_code(&candidate)?.to_string())
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

/// 从回收站彻底删除条目（本机物理抹除，不可恢复）。要求该条目的删除已同步。
pub fn purge_item(id: String) -> BridgeResult<()> {
    with_vault(|v| v.purge_item(&id))
}

/// 清空回收站：逐条抹除已同步条目，未同步的保留。返回 (已抹除, 保留)。
pub fn empty_trash() -> BridgeResult<EmptyTrashResult> {
    let (purged, kept) = with_vault(|v| v.empty_trash())?;
    Ok(EmptyTrashResult { purged: purged as u32, kept: kept as u32 })
}

#[derive(Debug, Clone)]
pub struct EmptyTrashResult {
    pub purged: u32,
    pub kept: u32,
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

#[derive(Debug, Clone)]
pub struct ImportSummary {
    /// 识别出的来源：chrome / firefox / bitwarden / lastpass / 1password / 1pif / csv
    pub format: String,
    pub added: u32,
    pub duplicates: u32,
    /// 格式不合法被拒绝的条目数 + 文件中无法转换的记录数
    pub skipped: u32,
}

/// 从其他密码管理器的导出文件导入（CSV / 1PIF，自动识别）。文件内容只在内存中解析后立即加密入库。
pub fn import_items(content: String) -> BridgeResult<ImportSummary> {
    let parsed = vault_core::import::parse(&content)?;
    let (added, duplicates, invalid) = with_vault(|v| v.import_items(parsed.items))?;
    Ok(ImportSummary {
        format: parsed.format.into(),
        added: added as u32,
        duplicates: duplicates as u32,
        skipped: (invalid + parsed.skipped) as u32,
    })
}

/// 导出加密备份包（`.wljbak`）字节流，由 Dart 侧写盘。
pub fn export_backup() -> BridgeResult<Vec<u8>> {
    with_vault(|v| v.export_backup())
}

/// 从加密备份包导入。返回 (新增, 跳过, 失败)。
pub fn import_backup(data: Vec<u8>) -> BridgeResult<ImportSummary> {
    let (added, duplicates, invalid) = with_vault(|v| v.import_backup(&data))?;
    Ok(ImportSummary { format: "wljbak".into(), added: added as u32, duplicates: duplicates as u32, skipped: invalid as u32 })
}

/// 导出为明文 CSV（迁移用，调用方须提示用户妥善保管）。
pub fn export_csv() -> BridgeResult<String> {
    with_vault(|v| v.export_csv())
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
