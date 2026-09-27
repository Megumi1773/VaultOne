//! 保险库高层 API：建号、解锁、快速解锁、条目增删改查、变更主密码、本地恢复。
//!
//! 密钥层级（全部封装均为 AES-256-GCM 密封盒，见 vault_crypto::sealed）：
//!
//! ```text
//! 主密码 + Secret Key ──Argon2id/HKDF──> WrapKey ──封装──> Vault Key（随机 256-bit）
//! Recovery Code ─────────HKDF─────────> RecoveryKey ─封装─> Vault Key
//! 生物识别快速解锁密钥（系统钥匙串）───────────────────封装─> Vault Key
//! Vault Key ──封装──> Item Key（每条目、每版本随机） ──加密──> 条目 JSON
//! Vault Key ──加密──> 邮箱、同步会话 token
//! ```
//!
//! 解锁后 Vault Key 只存在于 [`Session`] 中（mlock 受保护内存），锁定即清零。

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use sha2::{Digest, Sha256};
use uuid::Uuid;
use vault_crypto::kdf::{derive_all, KdfParams, MIN_MASTER_PASSWORD_LEN};
use vault_crypto::keys::{RecoveryCode, SecretKey};
use vault_crypto::{sealed, srp6a, Key32};
use zeroize::Zeroizing;

use crate::envelope::Envelope;
use crate::item::{Item, ItemData, ItemKind, PasswordHistoryEntry};
use crate::merge::PASSWORD_HISTORY_LIMIT;
use crate::store::{AccountRecord, ItemRow, Store};
use crate::{Result, VaultError};

/// 注册 / 恢复后需要展示给用户、写入 Recovery Kit 的信息。仅在此刻出现一次。
pub struct Enrollment {
    pub account_id: String,
    pub email: String,
    pub secret_key: Zeroizing<String>,
    pub recovery_code: Zeroizing<String>,
}

pub(crate) struct Session {
    pub(crate) account: AccountRecord,
    pub(crate) vault_key: Key32,
}

pub struct Vault {
    pub(crate) store: Store,
    pub(crate) session: Option<Session>,
    pub(crate) pending: Option<crate::sync::PendingLogin>,
}

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub(crate) fn aad(label: &str, account_id: &str) -> Vec<u8> {
    format!("vaultone/{label}|{account_id}").into_bytes()
}

pub(crate) fn b64d(s: &str) -> Result<Vec<u8>> {
    B64.decode(s).map_err(|_| VaultError::Integrity)
}

/// 用主密码 + Secret Key 生成的全部"凭据派生物"。
pub(crate) struct Credentials {
    pub vk_wrap: Vec<u8>,
    pub srp_salt: Vec<u8>,
    pub srp_verifier: Vec<u8>,
}

pub(crate) fn build_credentials(
    account_id: &str,
    master_password: &str,
    sk: &SecretKey,
    kdf: &KdfParams,
    vault_key: &Key32,
    srp_salt: Option<&[u8]>,
) -> Result<Credentials> {
    let keys = derive_all(master_password, sk.as_bytes(), account_id, kdf)?;
    let vk_wrap = sealed::wrap_key(&keys.wrap_key, vault_key, &aad("vault-key", account_id))?;
    let (srp_salt, srp_verifier) = match srp_salt {
        Some(salt) => (salt.to_vec(), srp6a::verifier_with_salt(account_id, &keys.auth_key, salt)),
        None => {
            let r = srp6a::register(account_id, &keys.auth_key);
            (r.salt, r.verifier)
        }
    };
    Ok(Credentials { vk_wrap, srp_salt, srp_verifier })
}

pub(crate) struct RecoveryMaterial {
    pub code: RecoveryCode,
    pub wrap: Vec<u8>,
    pub auth_hash: Vec<u8>,
}

pub(crate) fn build_recovery(account_id: &str, vault_key: &Key32) -> Result<RecoveryMaterial> {
    let code = RecoveryCode::generate();
    let wrap = sealed::wrap_key(&code.wrap_key(account_id)?, vault_key, &aad("recovery", account_id))?;
    let auth_hash = Sha256::digest(code.auth_token(account_id)?.as_bytes()).to_vec();
    Ok(RecoveryMaterial { code, wrap, auth_hash })
}

pub(crate) fn validate_master_password(pw: &str) -> Result<()> {
    if pw.chars().count() < MIN_MASTER_PASSWORD_LEN {
        return Err(VaultError::InvalidInput(format!("主密码至少 {MIN_MASTER_PASSWORD_LEN} 个字符")));
    }
    Ok(())
}

pub(crate) fn validate_email(email: &str) -> Result<String> {
    let email = email.trim().to_lowercase();
    let valid = email.len() <= 254 && email.split_once('@').is_some_and(|(l, d)| !l.is_empty() && d.contains('.') && !d.starts_with('.'));
    if !valid {
        return Err(VaultError::InvalidInput("邮箱格式不正确".into()));
    }
    Ok(email)
}

impl Vault {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Ok(Self { store: Store::open(path)?, session: None, pending: None })
    }

    pub fn open_in_memory() -> Result<Self> {
        Ok(Self { store: Store::open_in_memory()?, session: None, pending: None })
    }

    pub fn is_initialized(&self) -> Result<bool> {
        Ok(self.store.load_account()?.is_some())
    }

    pub fn is_unlocked(&self) -> bool {
        self.session.is_some()
    }

    pub(crate) fn session(&self) -> Result<&Session> {
        self.session.as_ref().ok_or(VaultError::Locked)
    }

    fn account(&self) -> Result<AccountRecord> {
        self.store.load_account()?.ok_or(VaultError::NotInitialized)
    }

    pub fn account_id(&self) -> Result<String> {
        Ok(self.account()?.account_id)
    }

    /// 创建本地账户：生成 Secret Key、Vault Key、Recovery Code，完成后保持解锁状态。
    pub fn create_account(&mut self, email: &str, master_password: &str, kdf: KdfParams) -> Result<Enrollment> {
        if self.is_initialized()? {
            return Err(VaultError::AlreadyInitialized);
        }
        let email = validate_email(email)?;
        validate_master_password(master_password)?;

        let account_id = Uuid::new_v4().to_string();
        let sk = SecretKey::generate();
        let vault_key = Key32::random()?;
        let creds = build_credentials(&account_id, master_password, &sk, &kdf, &vault_key, None)?;
        let recovery = build_recovery(&account_id, &vault_key)?;

        let account = AccountRecord {
            account_id: account_id.clone(),
            vault_id: Uuid::new_v4().to_string(),
            kdf,
            vk_wrap: B64.encode(&creds.vk_wrap),
            vk_gen: 1,
            recovery_wrap: B64.encode(&recovery.wrap),
            recovery_auth_hash: B64.encode(&recovery.auth_hash),
            email_enc: B64.encode(sealed::seal(&vault_key, email.as_bytes(), &aad("email", &account_id))?),
            srp_salt: B64.encode(&creds.srp_salt),
            srp_verifier: B64.encode(&creds.srp_verifier),
            credentials_dirty: false,
            created_at: now(),
        };
        self.store.save_account(&account)?;
        tracing::info!(target: "vault", "account created");
        self.session = Some(Session { account, vault_key });

        Ok(Enrollment { account_id, email, secret_key: sk.format(), recovery_code: recovery.code.format() })
    }

    /// 用主密码 + Secret Key 解锁。任一错误都返回同一个 [`VaultError::InvalidCredentials`]。
    pub fn unlock(&mut self, master_password: &str, secret_key: &str) -> Result<()> {
        let account = self.account()?;
        let sk = SecretKey::parse(secret_key).map_err(|_| VaultError::InvalidCredentials)?;
        let vault_key = unwrap_with_password(&account, master_password, &sk)?;
        self.session = Some(Session { account, vault_key });
        tracing::info!(target: "vault", "unlocked");
        Ok(())
    }

    pub fn lock(&mut self) {
        if self.session.take().is_some() {
            tracing::info!(target: "vault", "locked");
        }
        self.pending = None;
    }

    /// 校验主密码（敏感操作前的二次确认），不改变锁定状态。
    pub fn verify_master_password(&self, master_password: &str, secret_key: &str) -> Result<()> {
        let account = self.account()?;
        let sk = SecretKey::parse(secret_key).map_err(|_| VaultError::InvalidCredentials)?;
        unwrap_with_password(&account, master_password, &sk).map(|_| ())
    }

    // ───────── 快速解锁（生物识别） ─────────

    /// 启用快速解锁：生成随机快速解锁密钥 QK，返回给调用方存入系统钥匙串（受生物识别保护），
    /// 本地库只保存 `seal(QK, VaultKey)`。两者缺一不可。
    pub fn enable_quick_unlock(&self) -> Result<Zeroizing<Vec<u8>>> {
        let s = self.session()?;
        let qk = Key32::random()?;
        let blob = sealed::wrap_key(&qk, &s.vault_key, &aad("quick-unlock", &s.account.account_id))?;
        self.store.save_quick_unlock(&B64.encode(blob))?;
        Ok(Zeroizing::new(qk.as_bytes().to_vec()))
    }

    pub fn disable_quick_unlock(&self) -> Result<()> {
        self.store.clear_quick_unlock()
    }

    pub fn quick_unlock_enabled(&self) -> Result<bool> {
        Ok(self.store.load_quick_unlock()?.is_some())
    }

    pub fn unlock_with_quick_key(&mut self, quick_key: &[u8]) -> Result<()> {
        let account = self.account()?;
        let blob = self.store.load_quick_unlock()?.ok_or(VaultError::InvalidCredentials)?;
        let qk = Key32::from_slice(quick_key).map_err(|_| VaultError::InvalidCredentials)?;
        let vault_key = sealed::unwrap_key(&qk, &b64d(&blob)?, &aad("quick-unlock", &account.account_id))
            .map_err(|_| VaultError::InvalidCredentials)?;
        self.session = Some(Session { account, vault_key });
        tracing::info!(target: "vault", "unlocked via quick unlock");
        Ok(())
    }

    // ───────── 账户信息 ─────────

    pub fn email(&self) -> Result<Zeroizing<String>> {
        let s = self.session()?;
        let id = &s.account.account_id;
        let bytes = sealed::open(&s.vault_key, &b64d(&s.account.email_enc)?, &aad("email", id))?;
        String::from_utf8(bytes.to_vec()).map(Zeroizing::new).map_err(|_| VaultError::Integrity)
    }

    pub fn kdf_params(&self) -> Result<KdfParams> {
        Ok(self.account()?.kdf)
    }

    /// 变更主密码：换新 KDF 盐、重新封装 Vault Key、重算 SRP verifier；条目密文不动（计划书 S-08）。
    pub fn change_master_password(&mut self, current: &str, secret_key: &str, new_password: &str) -> Result<()> {
        validate_master_password(new_password)?;
        let mut account = self.account()?;
        let sk = SecretKey::parse(secret_key).map_err(|_| VaultError::InvalidCredentials)?;
        let vault_key = unwrap_with_password(&account, current, &sk)?;
        let kdf = account.kdf.rotate_salt();
        let creds = build_credentials(&account.account_id, new_password, &sk, &kdf, &vault_key, None)?;
        account.kdf = kdf;
        account.vk_wrap = B64.encode(&creds.vk_wrap);
        account.srp_salt = B64.encode(&creds.srp_salt);
        account.srp_verifier = B64.encode(&creds.srp_verifier);
        account.vk_gen += 1;
        account.credentials_dirty = self.store.load_remote()?.is_some();
        self.store.save_account(&account)?;
        // 主密码变更后，旧的生物识别快速解锁一并失效
        self.store.clear_quick_unlock()?;
        tracing::info!(target: "vault", "master password changed");
        self.session = Some(Session { account, vault_key });
        Ok(())
    }

    /// 忘记主密码时，用 Recovery Kit（恢复码 + Secret Key）在本机重设。旧恢复码随即作废。
    pub fn recover(&mut self, recovery_code: &str, secret_key: &str, new_password: &str) -> Result<Enrollment> {
        validate_master_password(new_password)?;
        let mut account = self.account()?;
        let sk = SecretKey::parse(secret_key)?;
        let rc = RecoveryCode::parse(recovery_code).map_err(|_| VaultError::InvalidRecoveryCode)?;
        let vault_key =
            sealed::unwrap_key(&rc.wrap_key(&account.account_id)?, &b64d(&account.recovery_wrap)?, &aad("recovery", &account.account_id))
                .map_err(|_| VaultError::InvalidRecoveryCode)?;

        let recovery = build_recovery(&account.account_id, &vault_key)?;
        let kdf = account.kdf.rotate_salt();
        let creds = build_credentials(&account.account_id, new_password, &sk, &kdf, &vault_key, None)?;
        account.kdf = kdf;
        account.vk_wrap = B64.encode(&creds.vk_wrap);
        account.srp_salt = B64.encode(&creds.srp_salt);
        account.srp_verifier = B64.encode(&creds.srp_verifier);
        account.recovery_wrap = B64.encode(&recovery.wrap);
        account.recovery_auth_hash = B64.encode(&recovery.auth_hash);
        account.vk_gen += 1;
        account.credentials_dirty = self.store.load_remote()?.is_some();
        self.store.save_account(&account)?;
        self.store.clear_quick_unlock()?;
        tracing::warn!(target: "vault", "vault recovered with recovery code");
        let account_id = account.account_id.clone();
        self.session = Some(Session { account, vault_key });
        Ok(Enrollment { account_id, email: self.email()?.to_string(), secret_key: sk.format(), recovery_code: recovery.code.format() })
    }

    // ───────── 条目 ─────────

    pub(crate) fn decrypt_blob(&self, id: &str, revision: i64, blob: &[u8]) -> Result<ItemData> {
        let s = self.session()?;
        let env = Envelope::from_bytes(blob)?;
        let plain = env.open(&s.vault_key, id, &s.account.vault_id, revision)?;
        serde_json::from_slice(&plain).map_err(|_| VaultError::Integrity)
    }

    fn decrypt_row(&self, row: &ItemRow) -> Result<Item> {
        let data = self.decrypt_blob(&row.id, row.revision, &row.blob)?;
        Ok(Item { id: row.id.clone(), vault_id: row.vault_id.clone(), revision: row.revision, data })
    }

    pub(crate) fn seal_blob(&self, id: &str, revision: i64, data: &ItemData) -> Result<Vec<u8>> {
        let s = self.session()?;
        let plain = Zeroizing::new(serde_json::to_vec(data)?);
        Envelope::seal(&s.vault_key, id, &s.account.vault_id, revision, &plain)?.to_bytes()
    }

    fn write_item(&self, id: &str, revision: i64, data: &ItemData, prev: Option<&ItemRow>, deleted_at: Option<i64>) -> Result<ItemRow> {
        let s = self.session()?;
        let row = ItemRow {
            id: id.to_string(),
            vault_id: s.account.vault_id.clone(),
            kind: data.kind.as_str().to_string(),
            blob: self.seal_blob(id, revision, data)?,
            revision,
            server_rev: prev.map_or(0, |p| p.server_rev),
            base_blob: prev.and_then(|p| p.base_blob.clone()),
            dirty: true,
            deleted_at,
            created_at: prev.map_or(data.created_at, |p| p.created_at),
            updated_at: data.updated_at,
        };
        self.store.put_item(&row)?;
        Ok(row)
    }

    fn decrypt_rows(&self, rows: Vec<ItemRow>) -> Vec<Item> {
        rows.iter()
            .filter_map(|r| match self.decrypt_row(r) {
                Ok(item) => Some(item),
                Err(e) => {
                    // 单条损坏不应导致整个保险库不可用
                    tracing::error!(target: "vault", item = %r.id, error = %e, "item failed integrity check, skipped");
                    None
                }
            })
            .collect()
    }

    pub fn list_items(&self) -> Result<Vec<Item>> {
        let s = self.session()?;
        Ok(self.decrypt_rows(self.store.list_items(&s.account.vault_id, false)?))
    }

    pub fn list_trash(&self) -> Result<Vec<Item>> {
        let s = self.session()?;
        Ok(self.decrypt_rows(self.store.list_items(&s.account.vault_id, true)?))
    }

    pub fn get_item(&self, id: &str) -> Result<Item> {
        self.session()?;
        let row = self.store.get_item(id)?.ok_or(VaultError::ItemNotFound)?;
        self.decrypt_row(&row)
    }

    pub fn create_item(&mut self, mut data: ItemData) -> Result<Item> {
        validate_item(&data)?;
        let id = Uuid::new_v4().to_string();
        let ts = now();
        data.created_at = ts;
        data.updated_at = ts;
        let row = self.write_item(&id, 1, &data, None, None)?;
        Ok(Item { id, vault_id: row.vault_id, revision: 1, data })
    }

    /// 批量导入（见 [`crate::import`]）。与现有条目"标题 + 用户名 + 密码 + 首个网址"完全相同的视为重复并跳过，
    /// 因此重复导入同一文件是幂等的。返回 (新增数, 跳过的重复数, 校验失败数)。
    pub fn import_items(&mut self, items: Vec<ItemData>) -> Result<(usize, usize, usize)> {
        fn fingerprint(d: &ItemData) -> (String, String, String, String) {
            (
                d.title.clone(),
                d.username.clone().unwrap_or_default(),
                d.password.clone().unwrap_or_default(),
                d.urls.first().map(|u| u.url.clone()).unwrap_or_default(),
            )
        }
        let mut seen: std::collections::HashSet<_> = self.list_items()?.iter().map(|i| fingerprint(&i.data)).collect();
        let (mut added, mut duplicates, mut invalid) = (0, 0, 0);
        for data in items {
            if !seen.insert(fingerprint(&data)) {
                duplicates += 1;
                continue;
            }
            match self.create_item(data) {
                Ok(_) => added += 1,
                Err(VaultError::InvalidInput(e)) => {
                    tracing::warn!(target: "vault", error = %e, "import: item rejected");
                    invalid += 1;
                }
                Err(e) => return Err(e),
            }
        }
        tracing::info!(target: "vault", added, duplicates, invalid, "import finished");
        Ok((added, duplicates, invalid))
    }

    /// 更新条目。密码变化时旧密码自动进入 `passwordHistory`。
    pub fn update_item(&mut self, id: &str, mut data: ItemData) -> Result<Item> {
        validate_item(&data)?;
        let row = self.store.get_item(id)?.ok_or(VaultError::ItemNotFound)?;
        if row.deleted_at.is_some() {
            return Err(VaultError::ItemNotFound);
        }
        let old = self.decrypt_row(&row)?;
        let ts = now().max(old.data.updated_at + 1);
        data.created_at = old.data.created_at;
        data.updated_at = ts;
        data.password_history = old.data.password_history.clone();
        if let Some(prev) = old.data.password.as_deref().filter(|p| !p.is_empty()) {
            if data.password.as_deref() != Some(prev) {
                data.password_history.insert(0, PasswordHistoryEntry { p: prev.to_string(), t: ts });
                data.password_history.truncate(PASSWORD_HISTORY_LIMIT);
            }
        }
        let revision = row.revision + 1;
        let new_row = self.write_item(id, revision, &data, Some(&row), None)?;
        Ok(Item { id: id.to_string(), vault_id: new_row.vault_id, revision, data })
    }

    /// 移入回收站（软删除，保留墓碑供同步）。
    pub fn delete_item(&mut self, id: &str) -> Result<()> {
        self.set_deleted(id, true)
    }

    pub fn restore_item(&mut self, id: &str) -> Result<()> {
        self.set_deleted(id, false)
    }

    fn set_deleted(&mut self, id: &str, deleted: bool) -> Result<()> {
        let row = self.store.get_item(id)?.ok_or(VaultError::ItemNotFound)?;
        let mut item = self.decrypt_row(&row)?;
        let ts = now().max(item.data.updated_at + 1);
        item.data.updated_at = ts;
        // 版本号变化后必须重新加密，否则 AAD 不再匹配
        self.write_item(id, row.revision + 1, &item.data, Some(&row), deleted.then_some(ts))?;
        Ok(())
    }

    pub fn pending_changes(&self) -> Result<u64> {
        self.store.pending_count()
    }

    pub fn item_count(&self) -> Result<u64> {
        self.store.item_count()
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        self.store.get_setting(key)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.store.set_setting(key, value)
    }

    /// 需要保密的本机设置（如浏览器扩展配对密钥）：以 Vault Key 密封后存入 settings 表，锁定时不可读。
    pub fn get_sealed_setting(&self, key: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        let s = self.session()?;
        let Some(v) = self.store.get_setting(&format!("sealed:{key}"))? else { return Ok(None) };
        let plain = sealed::open(&s.vault_key, &b64d(&v)?, &aad(&format!("setting/{key}"), &s.account.account_id))?;
        Ok(Some(plain))
    }

    pub fn set_sealed_setting(&self, key: &str, value: &[u8]) -> Result<()> {
        let s = self.session()?;
        let ct = sealed::seal(&s.vault_key, value, &aad(&format!("setting/{key}"), &s.account.account_id))?;
        self.store.set_setting(&format!("sealed:{key}"), &B64.encode(ct))
    }

    /// 清空本机保险库（不影响服务端数据）。
    pub fn wipe_local(&mut self) -> Result<()> {
        self.lock();
        self.store.wipe()
    }
}

fn unwrap_with_password(account: &AccountRecord, master_password: &str, sk: &SecretKey) -> Result<Key32> {
    let keys = derive_all(master_password, sk.as_bytes(), &account.account_id, &account.kdf)?;
    sealed::unwrap_key(&keys.wrap_key, &b64d(&account.vk_wrap)?, &aad("vault-key", &account.account_id))
        .map_err(|_| VaultError::InvalidCredentials)
}

fn validate_item(data: &ItemData) -> Result<()> {
    if data.title.trim().is_empty() {
        return Err(VaultError::InvalidInput("标题不能为空".into()));
    }
    if data.title.chars().count() > 200 {
        return Err(VaultError::InvalidInput("标题过长".into()));
    }
    if let Some(totp) = &data.totp {
        crate::totp::validate(totp)?;
    }
    if data.kind == ItemKind::Card && data.card.is_none() {
        return Err(VaultError::InvalidInput("信用卡条目缺少卡片信息".into()));
    }
    let size = serde_json::to_vec(data)?.len();
    if size > 256 * 1024 {
        return Err(VaultError::InvalidInput("条目内容过大（上限 256 KB）".into()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{ItemUrl, TotpConfig};

    const PW: &str = "correct horse battery";

    fn new_vault() -> (Vault, Enrollment) {
        let mut v = Vault::open_in_memory().unwrap();
        let e = v.create_account("Me@Example.com", PW, KdfParams::insecure_for_tests()).unwrap();
        (v, e)
    }

    fn login(title: &str, pw: &str) -> ItemData {
        let mut d = ItemData::new(ItemKind::Login, title);
        d.username = Some("alice@example.com".into());
        d.password = Some(pw.into());
        d
    }

    #[test]
    fn import_is_idempotent() {
        let (mut v, _) = new_vault();
        let csv = "name,url,username,password,note\nA,https://a.example,u,p1,\nB,https://b.example,u,p2,\nA,https://a.example,u,p1,\n";
        let parsed = crate::import::parse(csv).unwrap();
        assert_eq!(v.import_items(parsed.items).unwrap(), (2, 1, 0));
        let again = crate::import::parse(csv).unwrap();
        assert_eq!(v.import_items(again.items).unwrap(), (0, 3, 0));
        assert_eq!(v.list_items().unwrap().len(), 2);
    }

    #[test]
    fn create_lock_unlock() {
        let (mut v, e) = new_vault();
        assert!(v.is_unlocked());
        assert_eq!(&*v.email().unwrap(), "me@example.com");
        v.lock();
        assert!(matches!(v.list_items(), Err(VaultError::Locked)));
        assert!(matches!(v.unlock("wrong password!", &e.secret_key), Err(VaultError::InvalidCredentials)));
        let other_sk = SecretKey::generate().format();
        assert!(matches!(v.unlock(PW, &other_sk), Err(VaultError::InvalidCredentials)));
        assert!(matches!(v.unlock(PW, "garbage"), Err(VaultError::InvalidCredentials)));
        v.unlock(PW, &e.secret_key).unwrap();
        assert!(v.is_unlocked());
        v.verify_master_password(PW, &e.secret_key).unwrap();
    }

    #[test]
    fn input_validation() {
        let mut v = Vault::open_in_memory().unwrap();
        assert!(v.create_account("a@b.c", "short", KdfParams::insecure_for_tests()).is_err());
        assert!(v.create_account("not-an-email", PW, KdfParams::insecure_for_tests()).is_err());
        let (mut v, _) = new_vault();
        assert!(matches!(v.create_account("x@y.z", PW, KdfParams::insecure_for_tests()), Err(VaultError::AlreadyInitialized)));
        assert!(v.create_item(ItemData::new(ItemKind::Login, "  ")).is_err());
        let mut bad = login("x", "y");
        bad.totp = Some(TotpConfig { secret: "!!!".into(), alg: "SHA1".into(), digits: 6, period: 30 });
        assert!(v.create_item(bad).is_err());
        assert!(v.create_item(ItemData::new(ItemKind::Card, "Visa")).is_err());
    }

    #[test]
    fn item_crud_and_history() {
        let (mut v, _) = new_vault();
        let created = v.create_item(login("GitHub", "old-password-1")).unwrap();
        assert_eq!(created.revision, 1);
        let updated = v.update_item(&created.id, login("GitHub", "new-password-2")).unwrap();
        assert_eq!(updated.revision, 2);
        assert_eq!(updated.data.password_history[0].p, "old-password-1");
        assert_eq!(v.get_item(&created.id).unwrap().data.password.as_deref(), Some("new-password-2"));

        v.delete_item(&created.id).unwrap();
        assert!(v.list_items().unwrap().is_empty());
        assert_eq!(v.list_trash().unwrap().len(), 1);
        assert!(v.update_item(&created.id, login("x", "y")).is_err());
        v.restore_item(&created.id).unwrap();
        assert_eq!(v.list_items().unwrap().len(), 1);
        assert_eq!(v.get_item(&created.id).unwrap().revision, 4);
        assert_eq!(v.pending_changes().unwrap(), 1);
    }

    #[test]
    fn change_master_password_keeps_items_and_rotates_salt() {
        let (mut v, e) = new_vault();
        v.create_item(login("A", "pw-a-123")).unwrap();
        let old_salt = v.kdf_params().unwrap().salt;
        v.change_master_password(PW, &e.secret_key, "brand new master pw").unwrap();
        assert_ne!(v.kdf_params().unwrap().salt, old_salt);
        v.lock();
        assert!(v.unlock(PW, &e.secret_key).is_err());
        v.unlock("brand new master pw", &e.secret_key).unwrap();
        assert_eq!(v.list_items().unwrap()[0].data.title, "A");
        assert!(v.change_master_password("wrong-current-pw", &e.secret_key, "whatever-long-pw").is_err());
    }

    #[test]
    fn recovery_resets_password_and_rotates_code() {
        let (mut v, e) = new_vault();
        v.create_item(login("A", "pw-a-123")).unwrap();
        v.lock();
        assert!(matches!(
            v.recover(&RecoveryCode::generate().format(), &e.secret_key, "recovered-password"),
            Err(VaultError::InvalidRecoveryCode)
        ));
        let kit = v.recover(&e.recovery_code, &e.secret_key, "recovered-password").unwrap();
        assert_ne!(*kit.recovery_code, *e.recovery_code);
        assert_eq!(v.list_items().unwrap().len(), 1);
        v.lock();
        v.unlock("recovered-password", &e.secret_key).unwrap();
        v.lock();
        assert!(v.recover(&e.recovery_code, &e.secret_key, "another-password").is_err());
        assert!(v.recover(&kit.recovery_code, &e.secret_key, "another-password").is_ok());
    }

    #[test]
    fn quick_unlock_requires_both_halves() {
        let (mut v, e) = new_vault();
        v.create_item(login("A", "pw")).unwrap();
        let qk = v.enable_quick_unlock().unwrap();
        v.lock();
        assert!(v.unlock_with_quick_key(&[0u8; 32]).is_err());
        v.unlock_with_quick_key(&qk).unwrap();
        assert_eq!(v.list_items().unwrap().len(), 1);
        // 改主密码后快速解锁失效
        v.change_master_password(PW, &e.secret_key, "another long pw").unwrap();
        v.lock();
        assert!(v.unlock_with_quick_key(&qk).is_err());
    }

    #[test]
    fn tampered_or_replayed_blob_is_skipped_not_fatal() {
        let (mut v, _) = new_vault();
        let a = v.create_item(login("A", "pw")).unwrap();
        let b = v.create_item(login("B", "pw2")).unwrap();
        let mut row = v.store.get_item(&a.id).unwrap().unwrap();
        row.blob = v.store.get_item(&b.id).unwrap().unwrap().blob;
        v.store.put_item(&row).unwrap();
        assert!(matches!(v.get_item(&a.id), Err(VaultError::Integrity)));
        let list = v.list_items().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, b.id);
    }

    #[test]
    fn database_file_has_no_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let markers = ["alice@example.com", "super-secret-pass", "ebank.example.com", "me@example.com", "JBSWY3DPEHPK3PXP", "UniqueTitle"];
        {
            let mut v = Vault::open(&path).unwrap();
            let e = v.create_account("me@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
            let mut d = login("UniqueTitle", "super-secret-pass");
            d.urls.push(ItemUrl { url: "https://ebank.example.com".into(), ..Default::default() });
            d.totp = Some(TotpConfig { secret: "JBSWY3DPEHPK3PXP".into(), alg: "SHA1".into(), digits: 6, period: 30 });
            let item = v.create_item(d).unwrap();
            v.update_item(&item.id, login("UniqueTitle", "super-secret-pass-2")).unwrap();
            v.enable_quick_unlock().unwrap();
            v.lock();
            v.unlock(PW, &e.secret_key).unwrap();
        }
        let mut raw = Vec::new();
        for entry in std::fs::read_dir(dir.path()).unwrap() {
            raw.extend(std::fs::read(entry.unwrap().path()).unwrap());
        }
        let hay = String::from_utf8_lossy(&raw);
        for m in markers {
            assert!(!hay.contains(m), "明文泄露: {m}");
        }
    }

    #[test]
    fn reopen_from_disk() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let sk = {
            let mut v = Vault::open(&path).unwrap();
            let e = v.create_account("me@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
            v.create_item(login("Persisted", "pw-123")).unwrap();
            v.set_setting("auto_lock_minutes", "5").unwrap();
            e.secret_key
        };
        let mut v = Vault::open(&path).unwrap();
        assert!(v.is_initialized().unwrap());
        assert!(!v.is_unlocked());
        v.unlock(PW, &sk).unwrap();
        assert_eq!(v.list_items().unwrap()[0].data.title, "Persisted");
        assert_eq!(v.get_setting("auto_lock_minutes").unwrap().as_deref(), Some("5"));
    }
}
