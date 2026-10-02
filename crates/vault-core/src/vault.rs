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
use crate::import::{title_key, unique_title, ImportOutcome, ImportStrategy};
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
            base_deleted: prev.and_then(|p| p.base_deleted),
            dirty: true,
            deleted_at,
            created_at: prev.map_or(data.created_at, |p| p.created_at),
            updated_at: data.updated_at,
        };
        let active = self.store.active_conflict(&row.vault_id, id)?;
        let replacement = if let Some(record) = active.as_ref().filter(|c| c.state == "resolution_pending") {
            let payload = self.open_conflict(record)?;
            let base = row.base_blob.as_ref().map(|blob| crate::conflict::StoredBase {
                revision: row.server_rev,
                blob: blob.clone(),
                deleted: row.base_deleted,
            });
            // 裁决后再编辑/删除/恢复是新候选，不能沿用旧出站决定；完整旧结果仍留档。
            Some(self.prepare_conflict(&row, &payload.remote, vec![crate::conflict::ConflictField::Resolution], base)?)
        } else {
            None
        };
        self.store.transaction(|store| {
            store.check_item(prev, id)?;
            store.check_conflict(active.as_ref(), &row.vault_id, id)?;
            store.put_item(&row)?;
            if let Some(replacement) = &replacement {
                store.retire_conflict(&active.as_ref().ok_or(VaultError::Integrity)?.id, "superseded")?;
                store.put_conflict(replacement)?;
            }
            Ok(())
        })?;
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
        // 标签与分类在写入前规范化，保证落库与同步的内容形态一致（同一标签不因大小写重复）。
        data.normalize_taxonomy();
        validate_item(&data)?;
        let id = Uuid::new_v4().to_string();
        let ts = now();
        data.created_at = ts;
        data.updated_at = ts;
        let row = self.write_item(&id, 1, &data, None, None)?;
        Ok(Item { id, vault_id: row.vault_id, revision: 1, data })
    }

    /// 批量导入（见 [`crate::import`]）。仅完整有效内容相等的条目视为重复，规则见
    /// [`ItemData::into_import_content`]。只与未删除条目及本批成功新增条目去重；不覆盖现有条目。
    /// 新条目生成独立 ID、版本和创建/更新时间，历史内容不变。返回 (新增数, 重复数, 校验失败数)。
    /// 校验失败逐条跳过；其他错误立即返回（之前成功新增的条目保留），不是整批事务。
    pub fn import_items(&mut self, items: Vec<ItemData>) -> Result<(usize, usize, usize)> {
        let r = self.import_items_with(items, ImportStrategy::Skip)?;
        Ok((r.added, r.duplicates, r.invalid))
    }

    /// 带覆盖策略的批量导入（计划书 §3.7）。返回各计数，便于界面如实展示。
    ///
    /// 同名判定用**标题不区分大小写**（去掉首尾空白）。内容完全相同的条目在任何策略下都算
    /// 重复跳过——`Overwrite` 不该把一条一模一样的记录再写一遍。
    pub fn import_items_with(&mut self, items: Vec<ItemData>, strategy: ImportStrategy) -> Result<ImportOutcome> {
        let existing = self.list_items()?;
        let mut seen: std::collections::HashSet<_> = existing.iter().map(|i| i.data.clone().into_import_content()).collect();
        // 标题 → 现有条目 ID。同名冲突按第一次出现的为准。
        let mut by_title: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        for item in &existing {
            by_title.entry(title_key(&item.data.title)).or_insert_with(|| item.id.clone());
        }
        let mut taken_titles: std::collections::HashSet<String> = by_title.keys().cloned().collect();

        let (mut added, mut updated, mut duplicates, mut invalid) = (0, 0, 0, 0);
        for data in items {
            // 先校验，避免无效条目被记为重复，或抢占后续有效条目的去重键。
            match validate_item(&data) {
                Ok(()) => {}
                Err(VaultError::InvalidInput(e)) => {
                    tracing::warn!(target: "vault", error = %e, "import: item rejected");
                    invalid += 1;
                    continue;
                }
                Err(e) => return Err(e),
            }
            let content = data.clone().into_import_content();
            if seen.contains(&content) {
                duplicates += 1;
                continue;
            }
            let key = title_key(&data.title);
            match strategy {
                ImportStrategy::Overwrite => {
                    if let Some(id) = by_title.get(&key) {
                        let id = id.clone();
                        let mut replaced = data;
                        // 覆盖的是内容，不是身份：ID 与创建时间沿用现有的。
                        if let Some(old) = existing.iter().find(|i| i.id == id) {
                            replaced.created_at = old.data.created_at;
                        }
                        self.update_item(&id, replaced)?;
                        seen.insert(content);
                        updated += 1;
                        continue;
                    }
                }
                ImportStrategy::KeepBoth => {
                    if taken_titles.contains(&key) {
                        let mut renamed = data;
                        renamed.title = unique_title(&renamed.title, &taken_titles);
                        let new_key = title_key(&renamed.title);
                        taken_titles.insert(new_key.clone());
                        by_title.insert(new_key, String::new());
                        seen.insert(renamed.clone().into_import_content());
                        self.create_item(renamed)?;
                        added += 1;
                        continue;
                    }
                }
                ImportStrategy::Skip => {}
            }
            taken_titles.insert(key.clone());
            by_title.insert(key, String::new());
            self.create_item(data)?;
            seen.insert(content);
            added += 1;
        }
        tracing::info!(target: "vault", added, updated, duplicates, invalid, "import finished");
        Ok(ImportOutcome { added, updated, duplicates, invalid })
    }

    /// 导出必须完整读取所有未删除条目，任何损坏都报错，不能像普通列表一样跳过。
    fn items_for_export(&self) -> Result<Vec<Item>> {
        let s = self.session()?;
        self.store.transaction(|store| {
            // v1 备份只含条目，不含冲突工作记录；检查与快照读取保持同一事务。
            if store.conflicts(&s.account.vault_id)?.iter().any(|c| matches!(c.state.as_str(), "pending" | "resolution_pending")) {
                return Err(VaultError::ConflictPending);
            }
            store.list_items(&s.account.vault_id, false)?.iter().map(|row| self.decrypt_row(row)).collect()
        })
    }

    /// 导出加密备份包（`.wljbak`）。载荷用 Vault Key 密封，仅同一账户可还原。
    pub fn export_backup(&self) -> Result<Vec<u8>> {
        let s = self.session()?;
        let items: Vec<ItemData> = self.items_for_export()?.into_iter().map(|i| i.data).collect();
        crate::export::backup(&s.vault_key, &s.account.account_id, &items)
    }

    /// 导入加密备份包。重复条目按 [`Self::import_items`] 的规则跳过。
    /// 返回 (新增数, 跳过的重复数, 校验失败数)。
    pub fn import_backup(&mut self, data: &[u8]) -> Result<(usize, usize, usize)> {
        let items = {
            let s = self.session()?;
            crate::export::restore(&s.vault_key, &s.account.account_id, data)?
        };
        self.import_items(items)
    }

    /// 导出为明文 CSV（迁移用）。调用方须提示用户妥善保管。
    pub fn export_csv(&self) -> Result<String> {
        Ok(crate::export::to_csv(&self.items_for_export()?))
    }

    // ---------- 标签与分类的批量管理（§3.6）----------

    /// 把标签 `from` 改名成 `to`，返回受影响的条目数。
    ///
    /// 匹配**不区分大小写**，与 `normalize_tags` 的去重口径一致——否则 `Work` 会漏掉。
    /// 改成已存在的标签等于合并（同一条目上重复的会被规范化去重）。
    pub fn rename_tag(&mut self, from: &str, to: &str) -> Result<usize> {
        let target = to.trim();
        if target.is_empty() {
            return Err(VaultError::InvalidInput("新标签不能为空".into()));
        }
        let key = from.trim().to_lowercase();
        if key.is_empty() {
            return Err(VaultError::InvalidInput("要改名的标签不能为空".into()));
        }
        self.rewrite_items(|data| {
            if !data.tags.iter().any(|t| t.to_lowercase() == key) {
                return false;
            }
            for tag in &mut data.tags {
                if tag.to_lowercase() == key {
                    *tag = target.to_string();
                }
            }
            true
        })
    }

    /// 删除标签，返回受影响的条目数。条目本身不受影响。
    pub fn delete_tag(&mut self, tag: &str) -> Result<usize> {
        let key = tag.trim().to_lowercase();
        if key.is_empty() {
            return Err(VaultError::InvalidInput("要删除的标签不能为空".into()));
        }
        self.rewrite_items(|data| {
            let before = data.tags.len();
            data.tags.retain(|t| t.to_lowercase() != key);
            data.tags.len() != before
        })
    }

    /// 把分类路径 `from`（含其全部子分类）改名为 `to`，返回受影响的条目数。
    ///
    /// 这是**前缀改写**：`工作` → `职业` 会把 `工作/生产/服务器` 一并变成 `职业/生产/服务器`，
    /// 否则子分类会变成孤儿。改成已存在的路径等于合并。
    pub fn rename_category(&mut self, from: &str, to: &str) -> Result<usize> {
        let source = ItemData::normalize_category(Some(from)).ok_or_else(|| VaultError::InvalidInput("要改名的分类不能为空".into()))?;
        let target = ItemData::normalize_category(Some(to)).ok_or_else(|| VaultError::InvalidInput("新分类不能为空".into()))?;
        if target == source {
            return Ok(0);
        }
        // 移到自己的子分类下会把树变成环（`工作` → `工作/子`），直接拒绝。
        if target.starts_with(&format!("{source}/")) {
            return Err(VaultError::InvalidInput("不能把分类移动到它自己的子分类下".into()));
        }
        let prefix = format!("{source}/");
        self.rewrite_items(|data| {
            let Some(current) = data.category.as_deref() else { return false };
            let next = if current == source {
                target.clone()
            } else if let Some(rest) = current.strip_prefix(&prefix) {
                format!("{target}/{rest}")
            } else {
                return false;
            };
            data.category = Some(next);
            true
        })
    }

    /// 清空分类 `path`（含其子分类）下的分类归属，返回受影响的条目数。
    ///
    /// 只清分类，**不删条目**——用户说「删掉这个分类」时想删的是分类，不是里面的密码。
    pub fn clear_category(&mut self, path: &str) -> Result<usize> {
        let source = ItemData::normalize_category(Some(path)).ok_or_else(|| VaultError::InvalidInput("要清空的分类不能为空".into()))?;
        let prefix = format!("{source}/");
        self.rewrite_items(|data| {
            let Some(current) = data.category.as_deref() else { return false };
            if current != source && !current.starts_with(&prefix) {
                return false;
            }
            data.category = None;
            true
        })
    }

    /// 逐条重写条目：`mutate` 返回 false 表示这条不需要改，跳过（不产生新版本）。
    ///
    /// 全部走 [`Self::update_item`]，因此版本号、`updated_at` 与同步语义与手动编辑完全一致；
    /// 批量管理不应该有第二条写路径。
    fn rewrite_items(&mut self, mut mutate: impl FnMut(&mut ItemData) -> bool) -> Result<usize> {
        let items = self.list_items()?;
        let mut affected = 0;
        for item in items {
            let mut data = item.data.clone();
            if !mutate(&mut data) {
                continue;
            }
            self.update_item(&item.id, data)?;
            affected += 1;
        }
        Ok(affected)
    }

    /// 更新条目。密码变化时旧密码自动进入 `passwordHistory`。
    pub fn update_item(&mut self, id: &str, mut data: ItemData) -> Result<Item> {
        data.normalize_taxonomy();
        validate_item(&data)?;
        let row = self.store.get_item(id)?.ok_or(VaultError::ItemNotFound)?;
        if row.deleted_at.is_some() {
            return Err(VaultError::ItemNotFound);
        }
        let old = self.decrypt_row(&row)?;
        let ts = now().max(old.data.updated_at.checked_add(1).ok_or(VaultError::Integrity)?);
        data.created_at = old.data.created_at;
        data.updated_at = ts;
        data.password_history = old.data.password_history.clone();
        if let Some(prev) = old.data.password.as_deref().filter(|p| !p.is_empty()) {
            if data.password.as_deref() != Some(prev) {
                data.password_history.insert(0, PasswordHistoryEntry { p: prev.to_string(), t: ts });
                data.password_history.truncate(PASSWORD_HISTORY_LIMIT);
            }
        }
        let revision = row.revision.checked_add(1).ok_or(VaultError::Integrity)?;
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

    /// 从回收站彻底删除条目：物理抹除本机密文行，不可恢复。
    ///
    /// 仅接受回收站条目，且要求其删除已同步（`dirty == 0`）：未同步的墓碑直接抹除会连同本机
    /// 未推送的修改一起丢弃，下次同步还可能把服务端旧内容重新拉回。本操作只作用于本机，
    /// 不通知服务端抹除已同步的数据。
    pub fn purge_item(&mut self, id: &str) -> Result<()> {
        self.session()?;
        let row = self.store.get_item(id)?.ok_or(VaultError::ItemNotFound)?;
        if row.deleted_at.is_none() {
            return Err(VaultError::ItemNotFound);
        }
        if row.dirty {
            return Err(VaultError::ItemUnsynced);
        }
        self.store.transaction(|store| {
            store.check_item(Some(&row), id)?;
            if !store.purge_item(id)? {
                return Err(VaultError::ItemNotFound);
            }
            Ok(())
        })
    }

    /// 清空回收站：逐条抹除已同步的回收站条目，未同步的保留。返回 (已抹除, 保留)。
    pub fn empty_trash(&mut self) -> Result<(usize, usize)> {
        let s = self.session()?;
        let rows = self.store.list_items(&s.account.vault_id, true)?;
        let (mut purged, mut kept) = (0usize, 0usize);
        for row in rows {
            if row.dirty {
                kept += 1;
                continue;
            }
            self.store.transaction(|store| {
                store.check_item(Some(&row), &row.id)?;
                store.purge_item(&row.id)?;
                Ok(())
            })?;
            purged += 1;
        }
        Ok((purged, kept))
    }

    fn set_deleted(&mut self, id: &str, deleted: bool) -> Result<()> {
        let row = self.store.get_item(id)?.ok_or(VaultError::ItemNotFound)?;
        let mut item = self.decrypt_row(&row)?;
        let ts = now().max(item.data.updated_at.checked_add(1).ok_or(VaultError::Integrity)?);
        item.data.updated_at = ts;
        // 版本号变化后必须重新加密，否则 AAD 不再匹配
        self.write_item(id, row.revision.checked_add(1).ok_or(VaultError::Integrity)?, &item.data, Some(&row), deleted.then_some(ts))?;
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

pub(crate) fn validate_item(data: &ItemData) -> Result<()> {
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
    if data.tags.len() > crate::item::TAG_LIMIT {
        return Err(VaultError::InvalidInput(format!("标签数量上限 {}", crate::item::TAG_LIMIT)));
    }
    if data.tags.iter().any(|t| t.trim().is_empty() || t.chars().count() > 64) {
        return Err(VaultError::InvalidInput("标签不能为空或超过 64 字符".into()));
    }
    if let Some(c) = &data.category {
        if c.trim().is_empty() || c.chars().count() > crate::item::CATEGORY_LIMIT {
            return Err(VaultError::InvalidInput(format!("分类名不能为空或超过 {} 字符", crate::item::CATEGORY_LIMIT)));
        }
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
    fn backup_roundtrip_and_cross_account_rejected() {
        let (mut v, _) = new_vault();
        let a = v.create_item(login("A", "p1")).unwrap();
        let b = v.create_item(login("B", "p2")).unwrap();
        let blob = v.export_backup().unwrap();
        assert_eq!(&blob[..7], crate::export::MAGIC);

        // 删到回收站后，备份可完整还原
        v.delete_item(&a.id).unwrap();
        v.delete_item(&b.id).unwrap();
        assert_eq!(v.list_items().unwrap().len(), 0);
        assert_eq!(v.import_backup(&blob).unwrap(), (2, 0, 0));
        assert_eq!(v.list_items().unwrap().len(), 2);

        // 另一账户的 Vault Key 不同，无法解开
        let mut other = Vault::open_in_memory().unwrap();
        other.create_account("x@y.z", PW, KdfParams::insecure_for_tests()).unwrap();
        assert!(other.import_backup(&blob).is_err());

        // CSV 行数 = 表头 + 2 条
        assert_eq!(v.export_csv().unwrap().lines().count(), 3);
    }

    /// 每次只改变一个有效字段，确保不再依赖原来的四字段指纹。
    fn import_content_variants() -> Vec<ItemData> {
        use serde_json::json;
        let base = json!({
            "type": "login", "title": "同名条目", "username": "u", "password": "p",
            "urls": [{"url": "https://a.example", "match": "domain"},
                     {"url": "https://b.example", "match": "host"}],
            "totp": {"secret": "JBSWY3DPEHPK3PXP", "alg": "SHA1", "digits": 6, "period": 30},
            "notes": "笔记甲", "favorite": false,
            "card": {"cardholder": "甲", "number": "4111111111111111", "expiry": "12/30", "cvv": "123", "pin": "4567"},
            "identity": {"fullName": "甲", "email": "a@example.com", "phone": "123", "idNumber": "ID1", "address": "地址甲", "company": "公司甲"},
            "customFields": [{"label": "字段甲", "value": "值甲", "sensitive": true},
                             {"label": "字段乙", "value": "值乙", "sensitive": false}],
            "passwordHistory": [{"p": "旧密码", "t": 123}], "createdAt": 10, "updatedAt": 20
        });
        let mut items = vec![serde_json::from_value(base.clone()).unwrap()];
        for (path, value) in [
            ("/type", json!("note")),
            ("/type", json!("card")),
            ("/type", json!("identity")),
            ("/title", json!("另一个标题")),
            ("/username", json!("u2")),
            ("/password", json!("p2")),
            ("/notes", json!("笔记乙")),
            ("/favorite", json!(true)),
            ("/urls/0/url", json!("https://c.example")),
            ("/urls/1/url", json!("https://d.example")),
            ("/urls/0/match", json!("never")),
            ("/urls/1/match", json!("exact")),
            ("/totp/secret", json!("GEZDGNBVGY3TQOJQ")),
            ("/totp/alg", json!("SHA256")),
            ("/totp/digits", json!(8)),
            ("/totp/period", json!(60)),
            ("/card/cardholder", json!("乙")),
            ("/card/number", json!("5555555555554444")),
            ("/card/expiry", json!("01/31")),
            ("/card/cvv", json!("456")),
            ("/card/pin", json!("8901")),
            ("/identity/fullName", json!("乙")),
            ("/identity/email", json!("b@example.com")),
            ("/identity/phone", json!("456")),
            ("/identity/idNumber", json!("ID2")),
            ("/identity/address", json!("地址乙")),
            ("/identity/company", json!("公司乙")),
            ("/customFields/0/label", json!("新字段")),
            ("/customFields/0/value", json!("新值")),
            ("/customFields/0/sensitive", json!(false)),
            ("/customFields/1/value", json!("新值乙")),
            ("/passwordHistory/0/p", json!("另一旧密码")),
            ("/passwordHistory/0/t", json!(456)),
            ("/notes", json!(null)),
            ("/notes", json!("")),
        ] {
            let mut value_json = base.clone();
            *value_json.pointer_mut(path).unwrap() = value;
            items.push(serde_json::from_value(value_json).unwrap());
        }
        // 数组顺序影响首选 URL 和自定义字段展示，不擅自排序或归一化。
        let mut reordered: ItemData = serde_json::from_value(base).unwrap();
        reordered.urls.reverse();
        items.push(reordered.clone());
        reordered.custom_fields.reverse();
        items.push(reordered);
        // 实际笔记/卡片/身份：同标题、空凭据，也不能丢掉第二条。
        for kind in [ItemKind::Note, ItemKind::Card, ItemKind::Identity] {
            for value in ["甲", "乙"] {
                let mut d = ItemData::new(kind, "同名条目");
                match kind {
                    ItemKind::Note => d.notes = Some(value.into()),
                    ItemKind::Card => {
                        let mut card = crate::item::CardData::default();
                        card.number = value.into();
                        d.card = Some(card);
                    }
                    ItemKind::Identity => {
                        let mut identity = crate::item::IdentityData::default();
                        identity.id_number = value.into();
                        d.identity = Some(identity);
                    }
                    _ => unreachable!(),
                }
                items.push(d);
            }
        }
        items
    }

    fn assert_imported_contents(v: &Vault, expected: &[ItemData]) {
        let actual: std::collections::HashSet<_> = v.list_items().unwrap().into_iter().map(|i| i.data.into_import_content()).collect();
        let expected: std::collections::HashSet<_> = expected.iter().cloned().map(ItemData::into_import_content).collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn import_compares_all_content_and_ignores_storage_metadata() {
        let (mut v, _) = new_vault();
        let items = import_content_variants();
        let count = items.len();
        let existing = v.create_item(items[0].clone()).unwrap();
        let mut batch = items.clone();
        batch.extend(items.clone());
        assert_eq!(v.import_items(batch).unwrap(), (count - 1, count + 1, 0));
        assert_imported_contents(&v, &items);
        // 重复导入既不覆盖 ID/版本，也不更新时间/历史。
        assert_eq!(v.get_item(&existing.id).unwrap(), existing);
        let mut with_other_times = items.clone();
        for d in &mut with_other_times {
            d.created_at = 999;
            d.updated_at = 1000;
        }
        assert_eq!(v.import_items(with_other_times).unwrap(), (0, count, 0));
        assert_eq!(v.item_count().unwrap(), count as u64);
        assert_eq!(v.get_item(&existing.id).unwrap(), existing);
    }

    #[test]
    fn backup_restore_preserves_distinct_content_and_is_idempotent() {
        let (mut v, _) = new_vault();
        let items = import_content_variants();
        let originals: Vec<_> = items.iter().cloned().map(|d| v.create_item(d).unwrap()).collect();
        let backup = v.export_backup().unwrap();
        assert_eq!(v.import_backup(&backup).unwrap(), (0, items.len(), 0));
        for original in &originals {
            v.delete_item(&original.id).unwrap();
        }
        // 回收站不阻止恢复，恢复为新 ID，不改写墓碑或现有条目。
        let trash = v.list_trash().unwrap();
        assert_eq!(v.import_backup(&backup).unwrap(), (items.len(), 0, 0));
        assert_imported_contents(&v, &items);
        for restored in v.list_items().unwrap() {
            assert_eq!(restored.revision, 1);
            assert!(!originals.iter().any(|old| old.id == restored.id));
        }
        assert_eq!(v.import_backup(&backup).unwrap(), (0, items.len(), 0));
        assert_eq!(v.list_trash().unwrap(), trash);
    }

    #[test]
    fn invalid_imports_do_not_poison_duplicates_or_modify_existing_items() {
        let (mut v, _) = new_vault();
        let existing = v.create_item(login("已有", "p")).unwrap();
        let valid = login("新增", "p");
        let mut invalid = valid.clone();
        invalid.totp = Some(TotpConfig { secret: "!!!".into(), alg: "SHA1".into(), digits: 6, period: 30 });
        let batch = vec![invalid.clone(), invalid, valid.clone(), valid];
        assert_eq!(v.import_items(batch).unwrap(), (1, 1, 2));
        assert_eq!(v.get_item(&existing.id).unwrap(), existing);
        assert_eq!(v.item_count().unwrap(), 2);
    }

    /// 标签与分类的批量管理（计划书 §3.6）。
    #[test]
    fn rename_tag_is_case_insensitive_and_merges() {
        let (mut v, _) = new_vault();
        let mut a = login("A", "p");
        a.tags = vec!["Work".into(), "个人".into()];
        let mut b = login("B", "p");
        b.tags = vec!["work".into()];
        let mut c = login("C", "p");
        c.tags = vec!["其他".into()];
        let a = v.create_item(a).unwrap();
        let b = v.create_item(b).unwrap();
        let c = v.create_item(c).unwrap();

        // `Work` 与 `work` 是同一个标签，改名要一起改到。
        assert_eq!(v.rename_tag("WORK", "工作").unwrap(), 2);
        assert_eq!(v.get_item(&a.id).unwrap().data.tags, vec!["工作", "个人"]);
        assert_eq!(v.get_item(&b.id).unwrap().data.tags, vec!["工作"]);
        assert_eq!(v.get_item(&c.id).unwrap().data.tags, vec!["其他"], "无关条目不能被碰");

        // 改成已存在的标签 = 合并，同一条目上不会留下两份。
        assert_eq!(v.rename_tag("个人", "工作").unwrap(), 1);
        assert_eq!(v.get_item(&a.id).unwrap().data.tags, vec!["工作"]);
    }

    #[test]
    fn rename_tag_rejects_empty_target() {
        let (mut v, _) = new_vault();
        let mut a = login("A", "p");
        a.tags = vec!["工作".into()];
        v.create_item(a).unwrap();
        assert!(matches!(v.rename_tag("工作", "   "), Err(VaultError::InvalidInput(_))));
        assert!(matches!(v.rename_tag("  ", "新"), Err(VaultError::InvalidInput(_))));
        // 改名失败不能留下半成品。
        assert_eq!(v.list_items().unwrap()[0].data.tags, vec!["工作"]);
    }

    #[test]
    fn delete_tag_keeps_the_item() {
        let (mut v, _) = new_vault();
        let mut a = login("A", "p");
        a.tags = vec!["工作".into(), "个人".into()];
        let a = v.create_item(a).unwrap();
        let mut b = login("B", "p");
        b.tags = vec!["其他".into()];
        v.create_item(b).unwrap();

        assert_eq!(v.delete_tag("工作").unwrap(), 1);
        assert_eq!(v.get_item(&a.id).unwrap().data.tags, vec!["个人"]);
        assert_eq!(v.item_count().unwrap(), 2, "删标签不能删条目");
        assert_eq!(v.delete_tag("不存在的标签").unwrap(), 0);
    }

    #[test]
    fn rename_category_rewrites_the_whole_subtree() {
        let (mut v, _) = new_vault();
        let mut root = login("root", "p");
        root.category = Some("工作".into());
        let mut child = login("child", "p");
        child.category = Some("工作/生产/服务器".into());
        let mut sibling = login("sibling", "p");
        sibling.category = Some("工作台".into());
        let mut other = login("other", "p");
        other.category = Some("个人".into());
        let root = v.create_item(root).unwrap();
        let child = v.create_item(child).unwrap();
        let sibling = v.create_item(sibling).unwrap();
        let other = v.create_item(other).unwrap();

        assert_eq!(v.rename_category("工作", "职业").unwrap(), 2, "只应命中自身与后代");
        assert_eq!(v.get_item(&root.id).unwrap().data.category.as_deref(), Some("职业"));
        assert_eq!(v.get_item(&child.id).unwrap().data.category.as_deref(), Some("职业/生产/服务器"));
        // `工作台` 是另一个分类，前缀相似但不是子分类。
        assert_eq!(v.get_item(&sibling.id).unwrap().data.category.as_deref(), Some("工作台"));
        assert_eq!(v.get_item(&other.id).unwrap().data.category.as_deref(), Some("个人"));

        // 改成已存在的路径 = 合并。
        assert_eq!(v.rename_category("职业", "个人").unwrap(), 2);
        assert_eq!(v.get_item(&child.id).unwrap().data.category.as_deref(), Some("个人/生产/服务器"));
    }

    #[test]
    fn rename_category_refuses_to_move_into_its_own_subtree() {
        let (mut v, _) = new_vault();
        let mut a = login("A", "p");
        a.category = Some("工作/生产".into());
        let a = v.create_item(a).unwrap();
        assert!(matches!(v.rename_category("工作", "工作/子"), Err(VaultError::InvalidInput(_))));
        assert_eq!(v.get_item(&a.id).unwrap().data.category.as_deref(), Some("工作/生产"));

        // 原地改名是空操作，不是错误。
        assert_eq!(v.rename_category("工作", "工作").unwrap(), 0);
        // 规范化后相同也算原地：`工作/` 与 `工作` 是同一个分类。
        assert_eq!(v.rename_category("工作/", " 工作 ").unwrap(), 0);
    }

    #[test]
    fn clear_category_clears_the_subtree_but_keeps_items() {
        let (mut v, _) = new_vault();
        let mut root = login("root", "p");
        root.category = Some("工作".into());
        let mut child = login("child", "p");
        child.category = Some("工作/生产".into());
        let mut other = login("other", "p");
        other.category = Some("个人".into());
        let root = v.create_item(root).unwrap();
        let child = v.create_item(child).unwrap();
        let other = v.create_item(other).unwrap();

        assert_eq!(v.clear_category("工作").unwrap(), 2);
        assert_eq!(v.get_item(&root.id).unwrap().data.category, None);
        assert_eq!(v.get_item(&child.id).unwrap().data.category, None);
        assert_eq!(v.get_item(&other.id).unwrap().data.category.as_deref(), Some("个人"));
        assert_eq!(v.item_count().unwrap(), 3, "清分类不能删条目");
    }

    #[test]
    fn taxonomy_rewrites_bump_revision_and_skip_untouched_items() {
        let (mut v, _) = new_vault();
        let mut a = login("A", "p");
        a.tags = vec!["工作".into()];
        let a = v.create_item(a).unwrap();
        let untouched = v.create_item(login("B", "p")).unwrap();

        assert_eq!(v.rename_tag("工作", "职业").unwrap(), 1);
        let after = v.get_item(&a.id).unwrap();
        assert_eq!(after.revision, a.revision + 1, "批量改写要走 update_item，产生新版本");
        assert!(after.data.updated_at > a.data.updated_at, "更新时间必须推进，否则同步会漏掉");
        assert_eq!(v.get_item(&untouched.id).unwrap(), untouched, "没命中的条目一个字节都不该动");
    }

    #[test]
    fn taxonomy_rewrites_require_an_unlocked_vault() {
        let (mut v, _) = new_vault();
        v.lock();
        assert!(matches!(v.rename_tag("a", "b"), Err(VaultError::Locked)));
        assert!(matches!(v.delete_tag("a"), Err(VaultError::Locked)));
        assert!(matches!(v.rename_category("a", "b"), Err(VaultError::Locked)));
        assert!(matches!(v.clear_category("a"), Err(VaultError::Locked)));
    }

    /// 同名条目在三种策略下的行为（计划书 §3.7）。
    #[test]
    fn import_strategies_handle_same_title_differently() {
        // Skip：只按内容去重，不按标题去重——同名但内容不同的条目照常新增。
        let (mut v, _) = new_vault();
        let existing = v.create_item(login("GitHub", "old")).unwrap();
        let r = v.import_items_with(vec![login("GitHub", "new")], ImportStrategy::Skip).unwrap();
        assert_eq!((r.added, r.updated, r.duplicates), (1, 0, 0), "Skip 不按标题去重，只按内容");
        assert_eq!(v.item_count().unwrap(), 2);
        assert_eq!(v.get_item(&existing.id).unwrap(), existing, "Skip 不修改现有条目");

        // Overwrite：覆盖同名条目，但保留它的 ID 与创建时间。
        let (mut v, _) = new_vault();
        let existing = v.create_item(login("GitHub", "old")).unwrap();
        let r = v.import_items_with(vec![login("github", "new")], ImportStrategy::Overwrite).unwrap();
        assert_eq!((r.added, r.updated), (0, 1));
        let after = v.get_item(&existing.id).unwrap();
        assert_eq!(after.data.password.as_deref(), Some("new"), "内容应被覆盖");
        assert_eq!(after.id, existing.id, "覆盖的是内容，不是身份");
        assert_eq!(after.data.created_at, existing.data.created_at, "创建时间要沿用");
        assert_eq!(v.item_count().unwrap(), 1, "覆盖不应新增条目");

        // KeepBoth：两条都留，同名的那条加后缀。
        let (mut v, _) = new_vault();
        v.create_item(login("GitHub", "old")).unwrap();
        let r = v.import_items_with(vec![login("GitHub", "new"), login("GitHub", "third")], ImportStrategy::KeepBoth).unwrap();
        assert_eq!(r.added, 2);
        let mut titles: Vec<String> = v.list_items().unwrap().into_iter().map(|i| i.data.title.clone()).collect();
        titles.sort();
        assert_eq!(titles, vec!["GitHub", "GitHub (2)", "GitHub (3)"]);
    }

    #[test]
    fn identical_content_is_a_duplicate_under_every_strategy() {
        for strategy in [ImportStrategy::Skip, ImportStrategy::Overwrite, ImportStrategy::KeepBoth] {
            let (mut v, _) = new_vault();
            let item = login("GitHub", "pw");
            v.create_item(item.clone()).unwrap();
            let r = v.import_items_with(vec![item], strategy).unwrap();
            assert_eq!(r.duplicates, 1, "{strategy:?} 下完全相同的条目仍应算重复");
            assert_eq!((r.added, r.updated), (0, 0), "{strategy:?} 不该把一模一样的记录再写一遍");
            assert_eq!(v.item_count().unwrap(), 1);
        }
    }

    #[test]
    fn overwrite_only_touches_same_title_and_counts_the_rest_as_added() {
        let (mut v, _) = new_vault();
        let keep = v.create_item(login("Keep", "old")).unwrap();
        v.create_item(login("Replace", "old")).unwrap();
        let r = v.import_items_with(vec![login("Replace", "new"), login("Brand", "pw")], ImportStrategy::Overwrite).unwrap();
        assert_eq!((r.added, r.updated, r.duplicates, r.invalid), (1, 1, 0, 0));
        assert_eq!(v.get_item(&keep.id).unwrap(), keep, "无关条目不能被碰");
        let titles: std::collections::HashSet<String> = v.list_items().unwrap().into_iter().map(|i| i.data.title.clone()).collect();
        assert_eq!(titles.len(), 3, "覆盖不应改变条目总数以外的结构");
        assert!(titles.contains("Brand"));
    }

    #[test]
    fn invalid_items_are_counted_not_imported_under_overwrite() {
        let (mut v, _) = new_vault();
        v.create_item(login("GitHub", "old")).unwrap();
        let mut invalid = login("GitHub", "new");
        invalid.totp = Some(TotpConfig { secret: "!!!".into(), alg: "SHA1".into(), digits: 6, period: 30 });
        let r = v.import_items_with(vec![invalid], ImportStrategy::Overwrite).unwrap();
        assert_eq!((r.added, r.updated, r.invalid), (0, 0, 1));
        assert_eq!(v.list_items().unwrap()[0].data.password.as_deref(), Some("old"), "无效条目不该覆盖有效数据");
    }

    #[test]
    fn failed_backup_restores_leave_vault_unchanged() {
        let (mut v, enrollment) = new_vault();
        v.create_item(login("已有", "p")).unwrap();
        let before = v.list_items().unwrap();
        let pending = v.pending_changes().unwrap();
        let backup = v.export_backup().unwrap();
        let mut tampered = backup.clone();
        *tampered.last_mut().unwrap() ^= 1;
        let (other, _) = new_vault();
        let foreign = other.export_backup().unwrap();
        for bad in [tampered, foreign, b"not a backup".to_vec(), backup[..10].to_vec()] {
            assert!(v.import_backup(&bad).is_err());
            assert_eq!(v.list_items().unwrap(), before);
            assert_eq!(v.pending_changes().unwrap(), pending);
        }
        v.lock();
        assert!(matches!(v.import_backup(&backup), Err(VaultError::Locked)));
        assert!(matches!(v.import_items(vec![login("新增", "p")]), Err(VaultError::Locked)));
        v.unlock(PW, &enrollment.secret_key).unwrap();
        assert_eq!(v.list_items().unwrap(), before);
    }

    #[test]
    fn recovered_account_on_fresh_store_can_restore_backup() {
        let (mut source, enrollment) = new_vault();
        let items = import_content_variants();
        assert_eq!(source.import_items(items.clone()).unwrap(), (items.len(), 0, 0));
        let backup = source.export_backup().unwrap();
        // 模拟重装后取回账户恢复材料；新库没有任何条目，也不复制解锁会话。
        let mut target = Vault::open_in_memory().unwrap();
        target.store.save_account(&source.account().unwrap()).unwrap();
        target.recover(&enrollment.recovery_code, &enrollment.secret_key, "new recovered master password").unwrap();
        assert_eq!(target.item_count().unwrap(), 0);
        assert_eq!(target.import_backup(&backup).unwrap(), (items.len(), 0, 0));
        assert_imported_contents(&target, &items);
        assert_eq!(target.import_backup(&backup).unwrap(), (0, items.len(), 0));
        let before = target.list_items().unwrap();
        assert!(target.import_backup(&backup[..backup.len() - 1]).is_err());
        let mut tampered = backup;
        *tampered.last_mut().unwrap() ^= 1;
        assert!(target.import_backup(&tampered).is_err());
        assert_eq!(target.list_items().unwrap(), before);
    }

    #[test]
    fn export_fails_closed_on_corrupt_active_items_but_listing_still_works() {
        let (mut v, _) = new_vault();
        let healthy = v.create_item(login("正常", "p")).unwrap();
        let damaged = v.create_item(login("损坏", "q")).unwrap();
        let mut row = v.store.get_item(&damaged.id).unwrap().unwrap();
        *row.blob.last_mut().unwrap() ^= 1;
        v.store.put_item(&row).unwrap();
        assert_eq!(v.list_items().unwrap(), vec![healthy]);
        let pending = v.pending_changes().unwrap();
        assert!(v.export_backup().is_err());
        assert!(v.export_csv().is_err());
        assert_eq!(v.store.get_item(&damaged.id).unwrap().unwrap().blob, row.blob);
        assert_eq!(v.pending_changes().unwrap(), pending);
        // 导出的范围仍为未删除条目，回收站损坏不影响此范围的完整性。
        row.deleted_at = Some(now());
        v.store.put_item(&row).unwrap();
        assert!(v.export_backup().is_ok());
        assert!(v.export_csv().is_ok());
        v.lock();
        assert!(matches!(v.export_backup(), Err(VaultError::Locked)));
        assert!(matches!(v.export_csv(), Err(VaultError::Locked)));
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

    /// 把当前行标记为已同步（模拟一次成功推送），使 `dirty` 归零。
    fn sync_row(v: &mut Vault, id: &str) {
        let row = v.store.get_item(id).unwrap().unwrap();
        assert!(v.store.mark_synced_snapshot(&row).unwrap());
    }

    #[test]
    fn purge_rejects_active_and_unsynced_items() {
        let (mut v, _) = new_vault();
        let item = v.create_item(login("A", "p")).unwrap();
        // 活动条目不能彻底删除
        assert!(matches!(v.purge_item(&item.id), Err(VaultError::ItemNotFound)));
        // 回收站中未同步（dirty=1）的条目须先同步
        v.delete_item(&item.id).unwrap();
        assert!(matches!(v.purge_item(&item.id), Err(VaultError::ItemUnsynced)));
        assert_eq!(v.list_trash().unwrap().len(), 1);
        // 同步墓碑后可抹除
        sync_row(&mut v, &item.id);
        v.purge_item(&item.id).unwrap();
        assert!(v.list_trash().unwrap().is_empty());
        assert!(v.store.get_item(&item.id).unwrap().is_none());
        // 已抹除的 ID 再次操作按不存在处理
        assert!(matches!(v.purge_item(&item.id), Err(VaultError::ItemNotFound)));
        assert!(matches!(v.restore_item(&item.id), Err(VaultError::ItemNotFound)));
    }

    #[test]
    fn empty_trash_purges_synced_and_keeps_unsynced() {
        let (mut v, _) = new_vault();
        let a = v.create_item(login("A", "p1")).unwrap();
        let b = v.create_item(login("B", "p2")).unwrap();
        v.delete_item(&a.id).unwrap();
        v.delete_item(&b.id).unwrap();
        // 只同步 A 的墓碑
        sync_row(&mut v, &a.id);
        assert_eq!(v.empty_trash().unwrap(), (1, 1));
        let trash = v.list_trash().unwrap();
        assert_eq!(trash.len(), 1);
        assert_eq!(trash[0].id, b.id);
        assert!(v.store.get_item(&a.id).unwrap().is_none());
        // 全部同步后可清空到 0
        sync_row(&mut v, &b.id);
        assert_eq!(v.empty_trash().unwrap(), (1, 0));
        assert!(v.list_trash().unwrap().is_empty());
        assert_eq!(v.empty_trash().unwrap(), (0, 0));
    }

    #[test]
    fn purge_is_local_only_and_survives_service_side_vault() {
        let (mut v, _) = new_vault();
        let item = v.create_item(login("A", "p")).unwrap();
        v.delete_item(&item.id).unwrap();
        sync_row(&mut v, &item.id);
        v.purge_item(&item.id).unwrap();
        // 条目已从本机彻底消失，且不产生任何待推送的删除
        assert!(v.list_items().unwrap().is_empty());
        assert!(v.list_trash().unwrap().is_empty());
        assert_eq!(v.pending_changes().unwrap(), 0);
        assert!(v.store.get_item(&item.id).unwrap().is_none());
        v.lock();
        assert!(matches!(v.purge_item(&item.id), Err(VaultError::Locked)));
        assert!(matches!(v.empty_trash(), Err(VaultError::Locked)));
    }
}
