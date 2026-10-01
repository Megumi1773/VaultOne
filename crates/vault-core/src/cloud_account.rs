//! 云账户编排。候选凭据先持久化，云端确认后才切换本机账户；条目同步独立执行。

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use vault_crypto::keys::{RecoveryCode, SecretKey};
use vault_crypto::{kdf, sealed, Key32};
use vault_proto::*;
use zeroize::Zeroizing;

use crate::store::{AccountRecord, RemoteRecord};
use crate::sync::{account_keys, device_info, validate_server_url, ApiClient};
use crate::vault::{aad, b64d, build_credentials, build_recovery, now, validate_email, validate_master_password, Enrollment, Session};
use crate::{Result, Vault, VaultError};

const OPERATION: &str = "cloud_account_operation";
const KIT: &str = "cloud_enrollment";

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Operation {
    kind: String,
    server: String,
    device: DeviceInfo,
    base: Option<AccountRecord>,
    candidate: AccountRecord,
    source: Option<AccountKeys>,
    kit: Option<String>,
}

fn conflict(message: &str) -> VaultError {
    VaultError::InvalidInput(message.into())
}

fn encode_kit(enrollment: &Enrollment, key: &Key32) -> Result<String> {
    let bytes = Zeroizing::new(serde_json::to_vec(&(enrollment.secret_key.as_str(), enrollment.recovery_code.as_str()))?);
    Ok(B64.encode(sealed::seal(key, &bytes, &aad("cloud-enrollment", &enrollment.account_id))?))
}

fn open_kit(account: &AccountRecord, blob: &str, key: &Key32) -> Result<Enrollment> {
    let bytes = sealed::open(key, &b64d(blob)?, &aad("cloud-enrollment", &account.account_id))?;
    let (sk, rc): (String, String) = serde_json::from_slice(&bytes).map_err(|_| VaultError::Integrity)?;
    let email = sealed::open(key, &b64d(&account.email_enc)?, &aad("email", &account.account_id))?;
    Ok(Enrollment {
        account_id: account.account_id.clone(),
        email: String::from_utf8(email.to_vec()).map_err(|_| VaultError::Integrity)?,
        secret_key: Zeroizing::new(sk),
        recovery_code: Zeroizing::new(rc),
    })
}

fn unlock_candidate(account: &AccountRecord, password: &str, sk: &SecretKey) -> Result<Key32> {
    let derived = kdf::derive_all(password, sk.as_bytes(), &account.account_id, &account.kdf)?;
    sealed::unwrap_key(&derived.wrap_key, &b64d(&account.vk_wrap)?, &aad("vault-key", &account.account_id))
        .map_err(|_| VaultError::InvalidCredentials)
}

fn same_keys(account: &AccountRecord, keys: &AccountKeys) -> Result<bool> {
    Ok(account.account_id == keys.account_id
        && account.vault_id == keys.vault_id
        && account.vk_gen == keys.vk_gen
        && b64d(&account.vk_wrap)? == keys.vk_wrap.0
        && account.kdf == keys.kdf
        && b64d(&account.recovery_wrap)? == keys.recovery_wrap.0)
}

fn remote_record(server: &str, device: &DeviceInfo, session: &SessionInfo, account: &AccountRecord, key: &Key32) -> Result<RemoteRecord> {
    if session.device_id != device.id || !session.device_approved {
        return Err(VaultError::DeviceNotApproved);
    }
    Ok(RemoteRecord {
        server_url: server.into(),
        device_id: device.id.clone(),
        device_name: device.name.clone(),
        token_enc: B64.encode(sealed::seal(key, session.token.as_bytes(), &aad("session-token", &account.account_id))?),
        expires_at: session.expires_at,
    })
}

impl Vault {
    pub fn pending_cloud_operation(&self) -> Result<Option<String>> {
        Ok(self.store.get_meta::<Operation>(OPERATION)?.map(|p| p.kind))
    }

    pub fn pending_cloud_enrollment(&self) -> Result<Option<Enrollment>> {
        let Some(blob) = self.store.get_meta::<String>(KIT)? else {
            return Ok(None);
        };
        let session = self.session()?;
        open_kit(&session.account, &blob, &session.vault_key).map(Some)
    }

    pub fn confirm_cloud_enrollment(&self) -> Result<()> {
        self.session()?;
        self.store.delete_meta(KIT)
    }

    /// 本地只是云注册草稿；调用者先把 Secret Key 写入系统安全存储，再发送注册请求。
    pub fn prepare_cloud_registration(
        &mut self,
        server: &str,
        email: &str,
        password: &str,
        device_name: &str,
        params: KdfParams,
    ) -> Result<Enrollment> {
        if self.is_initialized()? || self.pending_cloud_operation()?.is_some() {
            return Err(VaultError::AlreadyInitialized);
        }
        let server = validate_server_url(server)?;
        let device = device_info(self.store.device_id()?, device_name)?;
        let mut draft = Vault::open_in_memory()?;
        let enrollment = draft.create_account(email, password, params)?;
        let session = draft.session.take().ok_or(VaultError::Locked)?;
        let op = Operation {
            kind: "register".into(),
            server,
            device,
            base: Some(session.account.clone()),
            candidate: session.account.clone(),
            source: None,
            kit: Some(encode_kit(&enrollment, &session.vault_key)?),
        };
        self.store.transaction(|store| {
            if store.load_account()?.is_some() {
                return Err(VaultError::AlreadyInitialized);
            }
            store.save_account(&session.account)?;
            store.put_meta(OPERATION, &op)
        })?;
        self.session = Some(session);
        Ok(enrollment)
    }

    /// 新注册或旧纯本地库升级：邮箱冲突时必须以 SRP 证明同一账户，绝不静默合并。
    pub fn complete_cloud_registration(
        &mut self,
        server: &str,
        password: &str,
        secret_key: &str,
        device_name: &str,
    ) -> Result<Option<Enrollment>> {
        let server = validate_server_url(server)?;
        self.verify_master_password(password, secret_key)?;
        let key = self.session()?.vault_key.try_clone()?;
        let sk = SecretKey::parse(secret_key)?;
        if self.store.load_remote()?.is_some() {
            return self.pending_cloud_enrollment();
        }
        let op = if let Some(op) = self.store.get_meta::<Operation>(OPERATION)? {
            if op.kind != "register" || op.server != server {
                return Err(conflict("请先完成原服务器上的账户操作"));
            }
            op
        } else {
            let account = self.session()?.account.clone();
            let op = Operation {
                kind: "register".into(),
                server: server.clone(),
                device: device_info(self.store.device_id()?, device_name)?,
                base: Some(account.clone()),
                candidate: account,
                source: None,
                kit: None,
            };
            self.store.put_meta(OPERATION, &op)?;
            op
        };
        let email = self.email()?.to_string();
        let api = ApiClient::new(&op.server)?;
        let a = &op.candidate;
        let request = RegisterRequest {
            email: email.clone(),
            keys: account_keys(a)?,
            srp_salt: b64d(&a.srp_salt)?.into(),
            srp_verifier: b64d(&a.srp_verifier)?.into(),
            recovery_auth_hash: b64d(&a.recovery_auth_hash)?.into(),
            device: op.device.clone(),
        };
        let finish: LoginFinishResponse = match api.post("/v1/auth/register", &request) {
            Ok(response) => response,
            Err(VaultError::Server { code, .. }) if code == codes::EMAIL_TAKEN => api.srp_login(&email, password, &sk, &op.device)?.0,
            Err(error) => return Err(error),
        };
        let keys = finish.keys.as_ref().ok_or(VaultError::DeviceNotApproved)?;
        if !same_keys(a, keys)? {
            return Err(conflict("云账户与本机注册材料不一致，已保留本机数据"));
        }
        let remote = remote_record(&op.server, &op.device, &finish.session, a, &key)?;
        self.commit_cloud_operation(&op, key, remote)?;
        self.pending_cloud_enrollment()
    }

    fn commit_cloud_operation(&mut self, op: &Operation, key: Key32, remote: RemoteRecord) -> Result<()> {
        self.store.transaction(|store| {
            if store.load_account()? != op.base || store.get_meta::<Operation>(OPERATION)?.as_ref() != Some(op) {
                return Err(conflict("本机账户已变化，请重新核对账户操作"));
            }
            store.save_account(&op.candidate)?;
            store.save_remote(&remote)?;
            store.clear_quick_unlock()?;
            if op.kind == "register" {
                store.mark_all_dirty()?;
                store.reset_sync_state()?;
            }
            if let Some(kit) = &op.kit {
                store.put_meta(KIT, kit)?;
            }
            store.delete_meta(OPERATION)
        })?;
        self.session = Some(Session { account: op.candidate.clone(), vault_key: key });
        Ok(())
    }

    /// 显式更换端点或重新登录。先核对账户/保险库与 Vault Key，成功后才保存新 token。
    pub fn reconnect_cloud(&mut self, server: &str, password: &str, secret_key: &str) -> Result<()> {
        if self.pending_cloud_operation()?.is_some() {
            return Err(conflict("请先重试并完成待确认的账户操作"));
        }
        let server = validate_server_url(server)?;
        let account = self.session()?.account.clone();
        let key = self.session()?.vault_key.try_clone()?;
        let old_remote = self.store.load_remote()?.ok_or(VaultError::NotConnected)?;
        let sk = SecretKey::parse(secret_key).map_err(|_| VaultError::InvalidCredentials)?;
        let device = device_info(old_remote.device_id.clone(), &old_remote.device_name)?;
        let api = ApiClient::new(&server)?;
        let (finish, start) = api.srp_login(&self.email()?, password, &sk, &device)?;
        let keys = finish.keys.as_ref().ok_or(VaultError::DeviceNotApproved)?;
        if keys.account_id != account.account_id || keys.vault_id != account.vault_id || !finish.session.device_approved {
            return Err(conflict("目标服务不属于本机账户，未切换服务器"));
        }
        let mut updated = account.clone();
        updated.kdf = keys.kdf.clone();
        updated.vk_wrap = B64.encode(&keys.vk_wrap.0);
        if unlock_candidate(&updated, password, &sk)? != key {
            return Err(VaultError::Integrity);
        }
        updated.vk_gen = keys.vk_gen;
        updated.recovery_wrap = B64.encode(&keys.recovery_wrap.0);
        updated.srp_salt = B64.encode(&start.srp_salt.0);
        let derived = kdf::derive_all(password, sk.as_bytes(), &account.account_id, &keys.kdf)?;
        updated.srp_verifier = B64.encode(vault_crypto::srp6a::verifier_with_salt(&account.account_id, &derived.auth_key, &start.srp_salt));
        updated.credentials_dirty = false;
        let remote = remote_record(&server, &device, &finish.session, &updated, &key)?;
        self.store.transaction(|store| {
            if store.load_account()?.as_ref() != Some(&account) {
                return Err(VaultError::ConflictStale);
            }
            if old_remote.server_url != server {
                store.reset_sync_state()?;
                store.mark_all_dirty()?;
            }
            store.save_account(&updated)?;
            store.save_remote(&remote)?;
            store.clear_quick_unlock()
        })?;
        self.session = Some(Session { account: updated, vault_key: key });
        Ok(())
    }

    /// 云退出须由服务端确认；保留服务器绑定、条目与游标，不能转成纯本地账户。
    pub fn logout_cloud(&mut self) -> Result<()> {
        if self.pending_cloud_operation()?.is_some() {
            return Err(conflict("请先完成待确认的账户操作"));
        }
        let (api, mut remote) = self.remote_api()?;
        let result: Result<serde_json::Value> = api.post("/v1/auth/logout", &serde_json::json!({}));
        match result {
            Ok(_) | Err(VaultError::Server { status: 401, .. }) => {}
            Err(error) => return Err(error),
        }
        let session = self.session()?;
        remote.token_enc = B64.encode(sealed::seal(&session.vault_key, b"", &aad("session-token", &session.account.account_id))?);
        remote.expires_at = 0;
        self.store.save_remote(&remote)?;
        self.lock();
        Ok(())
    }

    /// 改密在线完成；失败时旧本地密码仍有效，候选密文保留以对账后重试。
    pub fn change_cloud_password(&mut self, current: &str, secret_key: &str, next: &str) -> Result<()> {
        validate_master_password(next)?;
        self.verify_master_password(current, secret_key)?;
        let (mut api, mut remote) = self.remote_api()?;
        let key = self.session()?.vault_key.try_clone()?;
        let sk = SecretKey::parse(secret_key)?;
        let op = if let Some(op) = self.store.get_meta::<Operation>(OPERATION)? {
            if op.kind != "password" || op.server != remote.server_url {
                return Err(conflict("请先完成待确认的账户操作"));
            }
            if unlock_candidate(&op.candidate, next, &sk)? != key {
                return Err(VaultError::InvalidCredentials);
            }
            op
        } else {
            let base = self.session()?.account.clone();
            let mut candidate = base.clone();
            let kdf = base.kdf.rotate_salt();
            let creds = build_credentials(&base.account_id, next, &sk, &kdf, &key, None)?;
            candidate.kdf = kdf;
            candidate.vk_wrap = B64.encode(creds.vk_wrap);
            candidate.srp_salt = B64.encode(creds.srp_salt);
            candidate.srp_verifier = B64.encode(creds.srp_verifier);
            candidate.vk_gen += 1;
            candidate.credentials_dirty = false;
            let op = Operation {
                kind: "password".into(),
                server: remote.server_url.clone(),
                device: device_info(remote.device_id.clone(), &remote.device_name)?,
                base: Some(base),
                candidate,
                source: None,
                kit: None,
            };
            self.store.put_meta(OPERATION, &op)?;
            op
        };
        let cloud: AccountResponse = match api.get("/v1/account") {
            Ok(cloud) => cloud,
            Err(VaultError::Server { status: 401, .. }) => {
                let login = ApiClient::new(&op.server)?;
                let email = self.email()?.to_string();
                let (finish, _) = match login.srp_login(&email, next, &sk, &op.device) {
                    Ok(finish) => finish,
                    Err(VaultError::InvalidCredentials) => login.srp_login(&email, current, &sk, &op.device)?,
                    Err(error) => return Err(error),
                };
                let keys = finish.keys.ok_or(VaultError::DeviceNotApproved)?;
                if !same_keys(&op.candidate, &keys)? && !same_keys(op.base.as_ref().ok_or(VaultError::Integrity)?, &keys)? {
                    return Err(conflict("云端凭据已变化，请使用恢复流程"));
                }
                remote = remote_record(&op.server, &op.device, &finish.session, &op.candidate, &key)?;
                api = ApiClient::new(&op.server)?.with_token(Zeroizing::new(finish.session.token));
                AccountResponse { email, keys }
            }
            Err(error) => return Err(error),
        };
        if !same_keys(&op.candidate, &cloud.keys)? {
            if !same_keys(op.base.as_ref().ok_or(VaultError::Integrity)?, &cloud.keys)? {
                return Err(conflict("云端凭据已变化，未覆盖；请使用云端恢复流程"));
            }
            let a = &op.candidate;
            let result: ChangeCredentialsResponse = api.call(
                reqwest::Method::PUT,
                "/v1/account/credentials",
                Some(&ChangeCredentialsRequest {
                    kdf: a.kdf.clone(),
                    srp_salt: b64d(&a.srp_salt)?.into(),
                    srp_verifier: b64d(&a.srp_verifier)?.into(),
                    vk_wrap: b64d(&a.vk_wrap)?.into(),
                    expected_vk_gen: a.vk_gen,
                    recovery_wrap: None,
                    recovery_auth_hash: None,
                }),
            )?;
            if result.vk_gen != a.vk_gen {
                return Err(VaultError::Integrity);
            }
        }
        self.commit_cloud_operation(&op, key, remote)
    }

    /// 空设备或同账户原地云恢复；不删除条目，重试使用已密封暂存的新恢复套件。
    pub fn recover_cloud_account(
        &mut self,
        server: &str,
        email: &str,
        recovery_code: &str,
        secret_key: &str,
        password: &str,
        device_name: &str,
    ) -> Result<Enrollment> {
        validate_master_password(password)?;
        let server = validate_server_url(server)?;
        let email = validate_email(email)?;
        let sk = SecretKey::parse(secret_key)?;
        let rc = RecoveryCode::parse(recovery_code).map_err(|_| VaultError::InvalidRecoveryCode)?;
        let api = ApiClient::new(&server)?;
        let pending = self.store.get_meta::<Operation>(OPERATION)?.filter(|op| op.kind != "password");
        let retry = pending.is_some();
        let op = if let Some(op) = pending {
            if op.kind != "recovery" || op.server != server {
                return Err(conflict("请先完成待确认的账户操作"));
            }
            op
        } else {
            let start: RecoveryStartResponse = api.post("/v1/recovery/start", &RecoveryStartRequest { email: email.clone() })?;
            let auth = rc.auth_token(&start.account_id)?;
            let fetched: AccountResponse = api.post(
                "/v1/recovery/fetch",
                &RecoveryFetchRequest { email: email.clone(), recovery_auth: auth.as_bytes().to_vec().into() },
            )?;
            let source = fetched.keys;
            if source.account_id != start.account_id {
                return Err(VaultError::Integrity);
            }
            let key = sealed::unwrap_key(&rc.wrap_key(&source.account_id)?, &source.recovery_wrap, &aad("recovery", &source.account_id))
                .map_err(|_| VaultError::InvalidRecoveryCode)?;
            let base = self.store.load_account()?;
            if let Some(old) = &base {
                if old.account_id != source.account_id || old.vault_id != source.vault_id {
                    return Err(conflict("云恢复账户与本机保险库不同，未修改本机数据"));
                }
                sealed::open(&key, &b64d(&old.email_enc)?, &aad("email", &old.account_id)).map_err(|_| VaultError::Integrity)?;
            }
            let kdf = source.kdf.rotate_salt();
            let creds = build_credentials(&source.account_id, password, &sk, &kdf, &key, None)?;
            let recovery = build_recovery(&source.account_id, &key)?;
            let enrollment = Enrollment {
                account_id: source.account_id.clone(),
                email: email.clone(),
                secret_key: sk.format(),
                recovery_code: recovery.code.format(),
            };
            let candidate = AccountRecord {
                account_id: source.account_id.clone(),
                vault_id: source.vault_id.clone(),
                kdf,
                vk_wrap: B64.encode(creds.vk_wrap),
                srp_salt: B64.encode(creds.srp_salt),
                srp_verifier: B64.encode(creds.srp_verifier),
                vk_gen: source.vk_gen + 1,
                recovery_wrap: B64.encode(recovery.wrap),
                recovery_auth_hash: B64.encode(recovery.auth_hash),
                email_enc: B64.encode(sealed::seal(&key, email.as_bytes(), &aad("email", &source.account_id))?),
                credentials_dirty: false,
                created_at: base.as_ref().map_or_else(now, |a| a.created_at),
            };
            let op = Operation {
                kind: "recovery".into(),
                server: server.clone(),
                device: device_info(self.store.device_id()?, device_name)?,
                base,
                candidate,
                source: Some(source),
                kit: Some(encode_kit(&enrollment, &key)?),
            };
            self.store.put_meta(OPERATION, &op)?;
            op
        };
        let source = op.source.as_ref().ok_or(VaultError::Integrity)?;
        let key = sealed::unwrap_key(&rc.wrap_key(&source.account_id)?, &source.recovery_wrap, &aad("recovery", &source.account_id))
            .map_err(|_| VaultError::InvalidRecoveryCode)?;
        if unlock_candidate(&op.candidate, password, &sk)? != key {
            return Err(VaultError::InvalidCredentials);
        }
        let kit = open_kit(&op.candidate, op.kit.as_deref().ok_or(VaultError::Integrity)?, &key)?;
        if kit.email != email || SecretKey::parse(&kit.secret_key)?.as_bytes() != sk.as_bytes() {
            return Err(VaultError::InvalidCredentials);
        }
        let confirmed = if retry {
            match api.srp_login(&email, password, &sk, &op.device) {
                Ok((finish, _)) => {
                    let keys = finish.keys.as_ref().ok_or(VaultError::DeviceNotApproved)?;
                    if !same_keys(&op.candidate, keys)? {
                        return Err(conflict("云端恢复材料已变化，未覆盖本机数据"));
                    }
                    Some(finish.session)
                }
                Err(VaultError::InvalidCredentials) => None,
                Err(error) => return Err(error),
            }
        } else {
            None
        };
        let session = match confirmed {
            Some(session) => session,
            None => {
                let a = &op.candidate;
                let auth = rc.auth_token(&a.account_id)?;
                let done: RecoveryCompleteResponse = api.post(
                    "/v1/recovery/complete",
                    &RecoveryCompleteRequest {
                        email,
                        recovery_auth: auth.as_bytes().to_vec().into(),
                        kdf: a.kdf.clone(),
                        srp_salt: b64d(&a.srp_salt)?.into(),
                        srp_verifier: b64d(&a.srp_verifier)?.into(),
                        vk_wrap: b64d(&a.vk_wrap)?.into(),
                        recovery_wrap: b64d(&a.recovery_wrap)?.into(),
                        recovery_auth_hash: b64d(&a.recovery_auth_hash)?.into(),
                        device: op.device.clone(),
                    },
                )?;
                if !same_keys(a, &done.keys)? {
                    return Err(VaultError::Integrity);
                }
                done.session
            }
        };
        let remote = remote_record(&op.server, &op.device, &session, &op.candidate, &key)?;
        self.commit_cloud_operation(&op, key, remote)?;
        Ok(kit)
    }
}
