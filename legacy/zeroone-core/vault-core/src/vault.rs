//! 保险库高层 API：建号、解锁、条目增删改查、变更主密码、恢复。
//!
//! 解锁后 Vault Key 只存在于 [`Session`] 中（受保护内存），锁定即清零。

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::crypto::{unwrap_key, wrap_key};
use crate::envelope::{item_aad, Envelope};
use crate::item::{Item, ItemData, ItemKind, PasswordHistoryEntry};
use crate::kdf::{derive_muk, derive_wrap_key, KdfParams, MIN_MASTER_PASSWORD_LEN};
use crate::keys::{RecoveryCode, SecretKey};
use crate::secret::Key32;
use crate::store::{AccountRecord, ItemRow, OutboxOp, Store};
use crate::{Result, VaultError};

const PASSWORD_HISTORY_LIMIT: usize = 20;

/// 注册 / 恢复后需要展示给用户、写入 Recovery Kit 的信息。仅在此刻出现一次。
pub struct Enrollment {
    pub account_id: String,
    pub email: String,
    pub secret_key: Zeroizing<String>,
    pub recovery_code: Zeroizing<String>,
}

struct Session {
    account: AccountRecord,
    vault_key: Key32,
}

pub struct Vault {
    store: Store,
    session: Option<Session>,
}

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn email_aad(account_id: &str) -> String {
    format!("account|{account_id}|email")
}

impl Vault {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Ok(Self { store: Store::open(path)?, session: None })
    }

    pub fn open_in_memory() -> Result<Self> {
        Ok(Self { store: Store::open_in_memory()?, session: None })
    }

    pub fn is_initialized(&self) -> Result<bool> {
        Ok(self.store.load_account()?.is_some())
    }

    pub fn is_unlocked(&self) -> bool {
        self.session.is_some()
    }

    fn session(&self) -> Result<&Session> {
        self.session.as_ref().ok_or(VaultError::Locked)
    }

    fn account(&self) -> Result<AccountRecord> {
        self.store.load_account()?.ok_or(VaultError::NotInitialized)
    }

    /// 创建账户：生成 Secret Key、Vault Key、Recovery Code，完成后保持解锁状态。
    pub fn create_account(&mut self, email: &str, master_password: &str, kdf: KdfParams) -> Result<Enrollment> {
        if self.is_initialized()? {
            return Err(VaultError::AlreadyInitialized);
        }
        let email = email.trim();
        if !email.contains('@') {
            return Err(VaultError::InvalidInput("邮箱格式不正确".into()));
        }
        if master_password.chars().count() < MIN_MASTER_PASSWORD_LEN {
            return Err(VaultError::InvalidInput(format!("主密码至少 {MIN_MASTER_PASSWORD_LEN} 个字符")));
        }

        let account_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let secret_key = SecretKey::generate();
        let recovery = RecoveryCode::generate();
        let vault_key = Key32::random()?;

        let muk = derive_muk(master_password, secret_key.as_bytes(), &account_id, &kdf)?;
        let wrap = derive_wrap_key(&muk, &account_id)?;
        let recovery_key = recovery.derive_wrap_key(&account_id)?;

        let account = AccountRecord {
            account_id: account_id.clone(),
            vault_id,
            kdf,
            vk_wrap: B64.encode(wrap_key(&wrap, &vault_key)?),
            vk_gen: 1,
            recovery_wrap: B64.encode(wrap_key(&recovery_key, &vault_key)?),
            email_enc: Envelope::seal(&vault_key, &account_id, &email_aad(&account_id), email.as_bytes())?,
            created_at: now(),
        };
        self.store.save_account(&account)?;
        self.session = Some(Session { account, vault_key });

        Ok(Enrollment {
            account_id,
            email: email.to_string(),
            secret_key: secret_key.format(),
            recovery_code: recovery.format(),
        })
    }

    /// 用主密码 + Secret Key 解锁。任一错误都返回同一个 [`VaultError::InvalidCredentials`]。
    pub fn unlock(&mut self, master_password: &str, secret_key: &str) -> Result<()> {
        let account = self.account()?;
        let sk = SecretKey::parse(secret_key).map_err(|_| VaultError::InvalidCredentials)?;
        let vault_key = Self::unwrap_with_password(&account, master_password, &sk)?;
        self.session = Some(Session { account, vault_key });
        Ok(())
    }

    fn unwrap_with_password(account: &AccountRecord, master_password: &str, sk: &SecretKey) -> Result<Key32> {
        let muk = derive_muk(master_password, sk.as_bytes(), &account.account_id, &account.kdf)?;
        let wrap = derive_wrap_key(&muk, &account.account_id)?;
        let wrapped = B64.decode(&account.vk_wrap).map_err(|_| VaultError::Integrity)?;
        unwrap_key(&wrap, &wrapped).map_err(|_| VaultError::InvalidCredentials)
    }

    pub fn lock(&mut self) {
        self.session = None;
    }

    pub fn account_id(&self) -> Result<String> {
        Ok(self.account()?.account_id)
    }

    pub fn email(&self) -> Result<Zeroizing<String>> {
        let s = self.session()?;
        let id = &s.account.account_id;
        let bytes = s.account.email_enc.open(&s.vault_key, &email_aad(id))?;
        String::from_utf8(bytes.to_vec()).map(Zeroizing::new).map_err(|_| VaultError::Integrity)
    }

    pub fn kdf_params(&self) -> Result<KdfParams> {
        Ok(self.account()?.kdf)
    }

    /// 变更主密码：只重新封装 Vault Key，条目密文不动（计划书 S-08）。
    pub fn change_master_password(&mut self, current: &str, secret_key: &str, new_password: &str) -> Result<()> {
        let account = self.account()?;
        let sk = SecretKey::parse(secret_key).map_err(|_| VaultError::InvalidCredentials)?;
        let vault_key = Self::unwrap_with_password(&account, current, &sk)?;
        self.rewrap(account, vault_key, &sk, new_password)?;
        Ok(())
    }

    /// 忘记主密码时用 Recovery Code 重设。旧恢复码随即作废，返回新的 Recovery Kit 信息。
    pub fn recover(&mut self, recovery_code: &str, secret_key: &str, new_password: &str) -> Result<Enrollment> {
        let mut account = self.account()?;
        let sk = SecretKey::parse(secret_key)?;
        let rc = RecoveryCode::parse(recovery_code)?;
        let recovery_key = rc.derive_wrap_key(&account.account_id)?;
        let wrapped = B64.decode(&account.recovery_wrap).map_err(|_| VaultError::Integrity)?;
        let vault_key = unwrap_key(&recovery_key, &wrapped).map_err(|_| VaultError::InvalidRecoveryCode)?;

        let new_rc = RecoveryCode::generate();
        account.recovery_wrap = B64.encode(wrap_key(&new_rc.derive_wrap_key(&account.account_id)?, &vault_key)?);
        self.rewrap(account, vault_key, &sk, new_password)?;
        Ok(Enrollment {
            account_id: self.account_id()?,
            email: self.email()?.to_string(),
            secret_key: sk.format(),
            recovery_code: new_rc.format(),
        })
    }

    fn rewrap(&mut self, mut account: AccountRecord, vault_key: Key32, sk: &SecretKey, new_password: &str) -> Result<()> {
        if new_password.chars().count() < MIN_MASTER_PASSWORD_LEN {
            return Err(VaultError::InvalidInput(format!("主密码至少 {MIN_MASTER_PASSWORD_LEN} 个字符")));
        }
        let kdf = KdfParams::with_cost(account.kdf.m, account.kdf.t, account.kdf.p);
        let muk = derive_muk(new_password, sk.as_bytes(), &account.account_id, &kdf)?;
        let wrap = derive_wrap_key(&muk, &account.account_id)?;
        account.kdf = kdf;
        account.vk_wrap = B64.encode(wrap_key(&wrap, &vault_key)?);
        account.vk_gen += 1;
        self.store.save_account(&account)?;
        self.session = Some(Session { account, vault_key });
        Ok(())
    }

    fn decrypt_row(&self, row: &ItemRow) -> Result<Item> {
        let s = self.session()?;
        let env = Envelope::from_bytes(&row.blob)?;
        let plain = env.open(&s.vault_key, &item_aad(&row.id, &row.vault_id, row.revision))?;
        let data: ItemData = serde_json::from_slice(&plain).map_err(|_| VaultError::Integrity)?;
        Ok(Item { id: row.id.clone(), vault_id: row.vault_id.clone(), revision: row.revision, data })
    }

    fn seal_row(&self, id: &str, revision: i64, data: &ItemData, created_at: i64, deleted_at: Option<i64>) -> Result<ItemRow> {
        let s = self.session()?;
        let vault_id = &s.account.vault_id;
        let plain = Zeroizing::new(serde_json::to_vec(data)?);
        let env = Envelope::seal(&s.vault_key, vault_id, &item_aad(id, vault_id, revision), &plain)?;
        Ok(ItemRow {
            id: id.to_string(),
            vault_id: vault_id.clone(),
            kind: data.kind.as_str().to_string(),
            blob: env.to_bytes()?,
            revision,
            dirty: true,
            deleted_at,
            created_at,
            updated_at: data.updated_at,
        })
    }

    pub fn list_items(&self) -> Result<Vec<Item>> {
        let s = self.session()?;
        self.store.list_items(&s.account.vault_id, false)?.iter().map(|r| self.decrypt_row(r)).collect()
    }

    pub fn list_trash(&self) -> Result<Vec<Item>> {
        let s = self.session()?;
        self.store.list_items(&s.account.vault_id, true)?.iter().map(|r| self.decrypt_row(r)).collect()
    }

    pub fn get_item(&self, id: &str) -> Result<Item> {
        self.session()?;
        let row = self.store.get_item(id)?.ok_or_else(|| VaultError::ItemNotFound(id.into()))?;
        self.decrypt_row(&row)
    }

    pub fn create_item(&mut self, mut data: ItemData) -> Result<Item> {
        validate_item(&data)?;
        let id = Uuid::new_v4().to_string();
        let ts = now();
        data.created_at = ts;
        data.updated_at = ts;
        let row = self.seal_row(&id, 1, &data, ts, None)?;
        self.store.put_item(&row, OutboxOp::Upsert)?;
        Ok(Item { id, vault_id: row.vault_id, revision: 1, data })
    }

    /// 更新条目。密码变化时旧密码自动进入 `passwordHistory`。
    pub fn update_item(&mut self, id: &str, mut data: ItemData) -> Result<Item> {
        validate_item(&data)?;
        let row = self.store.get_item(id)?.ok_or_else(|| VaultError::ItemNotFound(id.into()))?;
        if row.deleted_at.is_some() {
            return Err(VaultError::ItemNotFound(id.into()));
        }
        let old = self.decrypt_row(&row)?;
        let ts = now();
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
        let new_row = self.seal_row(id, revision, &data, row.created_at, None)?;
        self.store.put_item(&new_row, OutboxOp::Upsert)?;
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
        let row = self.store.get_item(id)?.ok_or_else(|| VaultError::ItemNotFound(id.into()))?;
        let mut item = self.decrypt_row(&row)?;
        let ts = now();
        item.data.updated_at = ts;
        // 版本号变化后必须重新加密，否则 AAD 不再匹配
        let new_row = self.seal_row(id, row.revision + 1, &item.data, row.created_at, deleted.then_some(ts))?;
        let op = if deleted { OutboxOp::Delete } else { OutboxOp::Upsert };
        self.store.put_item(&new_row, op)?;
        Ok(())
    }

    pub fn pending_changes(&self) -> Result<u64> {
        self.store.outbox_len()
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>> {
        self.store.get_setting(key)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.store.set_setting(key, value)
    }
}

fn validate_item(data: &ItemData) -> Result<()> {
    if data.title.trim().is_empty() {
        return Err(VaultError::InvalidInput("标题不能为空".into()));
    }
    if let Some(totp) = &data.totp {
        crate::totp::generate(totp, 0)?;
    }
    if data.kind == ItemKind::Card && data.card.is_none() {
        return Err(VaultError::InvalidInput("信用卡条目缺少卡片信息".into()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::TotpConfig;
    use crate::kdf::test_params;

    const PW: &str = "correct horse battery";

    fn new_vault() -> (Vault, Enrollment) {
        let mut v = Vault::open_in_memory().unwrap();
        let e = v.create_account("me@example.com", PW, test_params()).unwrap();
        (v, e)
    }

    fn login(title: &str, pw: &str) -> ItemData {
        let mut d = ItemData::new(ItemKind::Login, title);
        d.username = Some("alice@example.com".into());
        d.password = Some(pw.into());
        d
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
    }

    #[test]
    fn cannot_create_twice() {
        let (mut v, _) = new_vault();
        assert!(matches!(
            v.create_account("x@y.z", PW, test_params()),
            Err(VaultError::AlreadyInitialized)
        ));
    }

    #[test]
    fn rejects_short_master_password() {
        let mut v = Vault::open_in_memory().unwrap();
        assert!(v.create_account("a@b.c", "short", test_params()).is_err());
    }

    #[test]
    fn item_crud_and_history() {
        let (mut v, _) = new_vault();
        let created = v.create_item(login("GitHub", "old-password-1")).unwrap();
        assert_eq!(created.revision, 1);
        assert_eq!(v.list_items().unwrap().len(), 1);

        let updated = v.update_item(&created.id, login("GitHub", "new-password-2")).unwrap();
        assert_eq!(updated.revision, 2);
        assert_eq!(updated.data.password_history.len(), 1);
        assert_eq!(updated.data.password_history[0].p, "old-password-1");
        assert_eq!(updated.data.created_at, created.data.created_at);

        let fetched = v.get_item(&created.id).unwrap();
        assert_eq!(fetched.data.password.as_deref(), Some("new-password-2"));

        v.delete_item(&created.id).unwrap();
        assert!(v.list_items().unwrap().is_empty());
        assert_eq!(v.list_trash().unwrap().len(), 1);
        v.restore_item(&created.id).unwrap();
        assert_eq!(v.list_items().unwrap().len(), 1);
        assert_eq!(v.get_item(&created.id).unwrap().revision, 4);

        // create + update + delete + restore
        assert_eq!(v.pending_changes().unwrap(), 4);
    }

    #[test]
    fn validates_items() {
        let (mut v, _) = new_vault();
        assert!(v.create_item(ItemData::new(ItemKind::Login, "  ")).is_err());
        let mut bad = login("x", "y");
        bad.totp = Some(TotpConfig { secret: "!!!".into(), alg: "SHA1".into(), digits: 6, period: 30 });
        assert!(v.create_item(bad).is_err());
        assert!(v.create_item(ItemData::new(ItemKind::Card, "Visa")).is_err());
    }

    #[test]
    fn change_master_password_keeps_items() {
        let (mut v, e) = new_vault();
        v.create_item(login("A", "pw-a-123")).unwrap();
        v.change_master_password(PW, &e.secret_key, "brand new master pw").unwrap();
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
        // 旧恢复码作废
        v.lock();
        assert!(v.recover(&e.recovery_code, &e.secret_key, "another-password").is_err());
        assert!(v.recover(&kit.recovery_code, &e.secret_key, "another-password").is_ok());
    }

    #[test]
    fn tampered_blob_is_rejected() {
        let (mut v, _) = new_vault();
        let item = v.create_item(login("A", "pw")).unwrap();
        let mut row = v.store.get_item(&item.id).unwrap().unwrap();
        // 把另一个条目的密文搬过来（跨条目重放）
        let other = v.create_item(login("B", "pw2")).unwrap();
        row.blob = v.store.get_item(&other.id).unwrap().unwrap().blob;
        v.store.put_item(&row, OutboxOp::Upsert).unwrap();
        assert!(matches!(v.get_item(&item.id), Err(VaultError::Integrity)));
    }

    #[test]
    fn database_file_has_no_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let secret_markers = ["alice@example.com", "super-secret-pass", "ebank.example.com", "me@example.com", "JBSWY3DPEHPK3PXP", "UniqueTitle"];
        {
            let mut v = Vault::open(&path).unwrap();
            let e = v.create_account("me@example.com", PW, test_params()).unwrap();
            let mut d = login("UniqueTitle", "super-secret-pass");
            d.urls.push(crate::item::ItemUrl { url: "https://ebank.example.com".into(), ..Default::default() });
            d.totp = Some(TotpConfig { secret: "JBSWY3DPEHPK3PXP".into(), alg: "SHA1".into(), digits: 6, period: 30 });
            let item = v.create_item(d).unwrap();
            v.update_item(&item.id, login("UniqueTitle", "super-secret-pass-2")).unwrap();
            v.lock();
            v.unlock(PW, &e.secret_key).unwrap();
        }
        let mut raw = Vec::new();
        for entry in std::fs::read_dir(dir.path()).unwrap() {
            raw.extend(std::fs::read(entry.unwrap().path()).unwrap());
        }
        let hay = String::from_utf8_lossy(&raw);
        for marker in secret_markers {
            assert!(!hay.contains(marker), "明文泄露: {marker}");
        }
    }

    #[test]
    fn reopen_from_disk() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.db");
        let sk = {
            let mut v = Vault::open(&path).unwrap();
            let e = v.create_account("me@example.com", PW, test_params()).unwrap();
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
