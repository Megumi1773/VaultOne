//! E2EE 增量同步客户端（计划书 F-01 / F-06 / F-08）。
//!
//! - HTTP：`reqwest`（rustls，阻塞 API，由上层在后台线程调用）
//! - 认证：SRP-6a（`vault_crypto::srp6a`，底层为 RustCrypto `srp`）
//! - 同步：变更日志游标增量拉取 → 字段级三方合并（[`crate::merge`]）→ 推送脏条目，
//!   服务端以版本号乐观锁保证无静默覆盖；推送天然幂等（同 id+revision+密文重放返回 applied）。
//!
//! 服务端在任何环节只看到密文、版本号与时间戳。

use std::time::Duration;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::de::DeserializeOwned;
use serde::Serialize;
use vault_crypto::keys::{RecoveryCode, SecretKey};
use vault_crypto::{kdf, sealed, srp6a};
use vault_proto::*;
use zeroize::Zeroizing;

use crate::merge::merge;
use crate::store::{AccountRecord, ItemRow, RemoteRecord};
use crate::vault::{
    aad, b64d, build_credentials, build_recovery, now, validate_email, validate_master_password, Enrollment, Session, Vault,
};
use crate::{Result, VaultError};

const HTTP_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_SYNC_ROUNDS: usize = 4;

// ───────────────────────── HTTP 客户端 ─────────────────────────

pub struct ApiClient {
    base: String,
    http: reqwest::blocking::Client,
    token: Option<Zeroizing<String>>,
}

/// 只允许 HTTPS；回环地址（本地开发/测试）例外。
fn validate_server_url(url: &str) -> Result<String> {
    let parsed = url::Url::parse(url.trim()).map_err(|_| VaultError::InvalidInput("服务器地址格式不正确".into()))?;
    let loopback = matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "[::1]" | "10.0.2.2"));
    match parsed.scheme() {
        "https" => {}
        "http" if loopback => {}
        _ => return Err(VaultError::InvalidInput("同步服务必须使用 HTTPS".into())),
    }
    Ok(parsed.as_str().trim_end_matches('/').to_string())
}

impl ApiClient {
    pub fn new(base: &str) -> Result<Self> {
        let http = reqwest::blocking::Client::builder()
            .timeout(HTTP_TIMEOUT)
            .https_only(false)
            .user_agent(concat!("VaultOne/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| VaultError::Network(e.to_string()))?;
        Ok(Self { base: validate_server_url(base)?, http, token: None })
    }

    pub fn with_token(mut self, token: Zeroizing<String>) -> Self {
        self.token = Some(token);
        self
    }

    fn call<Req: Serialize, Resp: DeserializeOwned>(&self, method: reqwest::Method, path: &str, body: Option<&Req>) -> Result<Resp> {
        let mut req = self.http.request(method.clone(), format!("{}{path}", self.base));
        if let Some(t) = &self.token {
            req = req.bearer_auth(t.as_str());
        }
        if let Some(b) = body {
            req = req.json(b);
        }
        let started = std::time::Instant::now();
        let resp = req.send().map_err(|e| VaultError::Network(e.without_url().to_string()))?;
        let status = resp.status();
        // 只记录方法、路径、状态码与耗时，不记录任何请求/响应体
        tracing::debug!(target: "sync", %method, path, status = status.as_u16(), ms = started.elapsed().as_millis() as u64, "http");
        if status.is_success() {
            return resp.json().map_err(|e| VaultError::Network(format!("响应解析失败: {e}")));
        }
        let err: ErrorBody =
            resp.json().unwrap_or(ErrorBody { code: codes::INTERNAL.into(), message: format!("HTTP {}", status.as_u16()) });
        if err.code == codes::DEVICE_NOT_APPROVED {
            return Err(VaultError::DeviceNotApproved);
        }
        Err(VaultError::Server { status: status.as_u16(), code: err.code, message: err.message })
    }

    fn get<Resp: DeserializeOwned>(&self, path: &str) -> Result<Resp> {
        self.call::<(), Resp>(reqwest::Method::GET, path, None)
    }

    fn post<Req: Serialize, Resp: DeserializeOwned>(&self, path: &str, body: &Req) -> Result<Resp> {
        self.call(reqwest::Method::POST, path, Some(body))
    }

    /// SRP-6a 登录。返回 (登录结果, AuthKey 派生所用的账户信息)。
    fn srp_login(
        &self,
        email: &str,
        master_password: &str,
        sk: &SecretKey,
        device: &DeviceInfo,
    ) -> Result<(LoginFinishResponse, LoginStartResponse)> {
        let start: LoginStartResponse = self.post("/v1/auth/login/start", &LoginStartRequest { email: email.into() })?;
        let keys = kdf::derive_all(master_password, sk.as_bytes(), &start.account_id, &start.kdf)?;
        let hs = srp6a::ClientHandshake::start();
        let proof =
            hs.finish(&start.account_id, &keys.auth_key, &start.srp_salt, &start.b_pub).map_err(|_| VaultError::InvalidCredentials)?;
        let finish: LoginFinishResponse = self
            .post(
                "/v1/auth/login/finish",
                &LoginFinishRequest {
                    handshake_id: start.handshake_id.clone(),
                    a_pub: hs.a_pub.clone().into(),
                    m1: proof.m1.clone().into(),
                    device: device.clone(),
                },
            )
            .map_err(|e| match e {
                VaultError::Server { code, .. } if code == codes::AUTH_FAILED => VaultError::InvalidCredentials,
                other => other,
            })?;
        // 双向认证：服务端也必须证明持有 verifier，防止钓鱼服务器
        proof.verify_server(&finish.m2).map_err(|_| VaultError::Network("服务器身份校验失败".into()))?;
        Ok((finish, start))
    }
}

// ───────────────────────── 状态类型 ─────────────────────────

/// 新设备登录进行中（等待邮件验证码或其他设备批准）。只在内存中保存，锁定即清除。
pub struct PendingLogin {
    api: ApiClient,
    email: String,
    password: Zeroizing<String>,
    secret_key: Zeroizing<String>,
    srp_salt: Vec<u8>,
    device: DeviceInfo,
    session: SessionInfo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoginOutcome {
    Joined,
    NeedsDeviceApproval,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncReport {
    pub pulled: u32,
    pub pushed: u32,
    pub merged: u32,
    pub conflicts: u32,
    pub credentials_updated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteStatus {
    pub server_url: String,
    pub device_id: String,
    pub device_name: String,
    pub last_sync_at: Option<i64>,
    pub pending: u64,
}

fn device_info(id: String, name: &str) -> Result<DeviceInfo> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 64 {
        return Err(VaultError::InvalidInput("设备名需为 1-64 个字符".into()));
    }
    Ok(DeviceInfo { id, name: name.to_string(), platform: Platform::current() })
}

// ───────────────────────── Vault 同步能力 ─────────────────────────

impl Vault {
    fn seal_token(&self, token: &str) -> Result<String> {
        let s = self.session()?;
        Ok(B64.encode(sealed::seal(&s.vault_key, token.as_bytes(), &aad("session-token", &s.account.account_id))?))
    }

    fn remote_api(&self) -> Result<(ApiClient, RemoteRecord)> {
        let s = self.session()?;
        let remote = self.store.load_remote()?.ok_or(VaultError::NotConnected)?;
        let token = sealed::open(&s.vault_key, &b64d(&remote.token_enc)?, &aad("session-token", &s.account.account_id))?;
        let token = Zeroizing::new(String::from_utf8(token.to_vec()).map_err(|_| VaultError::Integrity)?);
        Ok((ApiClient::new(&remote.server_url)?.with_token(token), remote))
    }

    fn save_session(&self, url: &str, device: &DeviceInfo, session: &SessionInfo) -> Result<()> {
        self.store.save_remote(&RemoteRecord {
            server_url: url.to_string(),
            device_id: device.id.clone(),
            device_name: device.name.clone(),
            token_enc: self.seal_token(&session.token)?,
            expires_at: session.expires_at,
        })
    }

    pub fn remote_status(&self) -> Result<Option<RemoteStatus>> {
        let Some(remote) = self.store.load_remote()? else { return Ok(None) };
        let vault_id = self.store.load_account()?.map(|a| a.vault_id).unwrap_or_default();
        Ok(Some(RemoteStatus {
            server_url: remote.server_url,
            device_id: remote.device_id,
            device_name: remote.device_name,
            last_sync_at: self.store.last_sync_at(&vault_id)?,
            pending: self.store.pending_count()?,
        }))
    }

    /// 本地已有账户 → 在同步服务上注册（首台设备）。
    pub fn connect_register(&mut self, server_url: &str, device_name: &str) -> Result<SyncReport> {
        let s = self.session()?;
        if self.store.load_remote()?.is_some() {
            return Err(VaultError::InvalidInput("已连接同步服务".into()));
        }
        let a = &s.account;
        let device = device_info(self.store.device_id()?, device_name)?;
        let api = ApiClient::new(server_url)?;
        let req = RegisterRequest {
            email: self.email()?.to_string(),
            keys: account_keys(a)?,
            srp_salt: b64d(&a.srp_salt)?.into(),
            srp_verifier: b64d(&a.srp_verifier)?.into(),
            recovery_auth_hash: b64d(&a.recovery_auth_hash)?.into(),
            device: device.clone(),
        };
        let resp: LoginFinishResponse = api.post("/v1/auth/register", &req)?;
        self.save_session(&api.base, &device, &resp.session)?;
        self.store.mark_all_dirty()?;
        self.store.reset_sync_state()?;
        tracing::info!(target: "sync", "registered on sync server");
        self.sync_now()
    }

    /// 空设备 → 用邮箱 + 主密码 + Secret Key 登录已有账户。
    pub fn login_existing(
        &mut self,
        server_url: &str,
        email: &str,
        master_password: &str,
        secret_key: &str,
        device_name: &str,
    ) -> Result<LoginOutcome> {
        if self.is_initialized()? {
            return Err(VaultError::AlreadyInitialized);
        }
        let email = validate_email(email)?;
        let sk = SecretKey::parse(secret_key).map_err(|_| VaultError::InvalidCredentials)?;
        let device = device_info(self.store.device_id()?, device_name)?;
        let api = ApiClient::new(server_url)?;
        let (finish, start) = api.srp_login(&email, master_password, &sk, &device)?;
        let pending = PendingLogin {
            api: ApiClient::new(server_url)?.with_token(Zeroizing::new(finish.session.token.clone())),
            email,
            password: Zeroizing::new(master_password.to_string()),
            secret_key: sk.format(),
            srp_salt: start.srp_salt.0.clone(),
            device,
            session: finish.session.clone(),
        };
        match finish.keys {
            Some(keys) if finish.session.device_approved => {
                self.join(pending, keys)?;
                Ok(LoginOutcome::Joined)
            }
            _ => {
                tracing::info!(target: "sync", "device awaiting approval");
                self.pending = Some(pending);
                Ok(LoginOutcome::NeedsDeviceApproval)
            }
        }
    }

    /// 新设备输入邮件验证码完成批准。
    pub fn verify_new_device(&mut self, code: &str) -> Result<()> {
        let pending = self.pending.take().ok_or(VaultError::NotConnected)?;
        let r: std::result::Result<serde_json::Value, _> =
            pending.api.post("/v1/devices/self/verify", &VerifyDeviceRequest { code: code.trim().to_string() });
        if let Err(e) = r {
            self.pending = Some(pending);
            return Err(e);
        }
        self.finish_pending(pending)
    }

    /// 新设备在其他设备上被批准后，调用此方法继续。
    pub fn check_new_device_approved(&mut self) -> Result<bool> {
        let pending = self.pending.take().ok_or(VaultError::NotConnected)?;
        match pending.api.get::<AccountResponse>("/v1/account") {
            Ok(acc) => {
                self.join(pending, acc.keys)?;
                Ok(true)
            }
            Err(VaultError::DeviceNotApproved) => {
                self.pending = Some(pending);
                Ok(false)
            }
            Err(e) => {
                self.pending = Some(pending);
                Err(e)
            }
        }
    }

    pub fn has_pending_login(&self) -> bool {
        self.pending.is_some()
    }

    fn finish_pending(&mut self, pending: PendingLogin) -> Result<()> {
        let acc: AccountResponse = pending.api.get("/v1/account")?;
        self.join(pending, acc.keys)
    }

    fn join(&mut self, pending: PendingLogin, keys: AccountKeys) -> Result<()> {
        let sk = SecretKey::parse(&pending.secret_key)?;
        let derived = kdf::derive_all(&pending.password, sk.as_bytes(), &keys.account_id, &keys.kdf)?;
        let vault_key = sealed::unwrap_key(&derived.wrap_key, &keys.vk_wrap, &aad("vault-key", &keys.account_id))
            .map_err(|_| VaultError::InvalidCredentials)?;
        let verifier = srp6a::verifier_with_salt(&keys.account_id, &derived.auth_key, &pending.srp_salt);
        let account = AccountRecord {
            account_id: keys.account_id.clone(),
            vault_id: keys.vault_id.clone(),
            kdf: keys.kdf.clone(),
            vk_wrap: B64.encode(&keys.vk_wrap.0),
            vk_gen: keys.vk_gen,
            recovery_wrap: B64.encode(&keys.recovery_wrap.0),
            recovery_auth_hash: String::new(),
            email_enc: B64.encode(sealed::seal(&vault_key, pending.email.as_bytes(), &aad("email", &keys.account_id))?),
            srp_salt: B64.encode(&pending.srp_salt),
            srp_verifier: B64.encode(verifier),
            credentials_dirty: false,
            created_at: now(),
        };
        self.store.save_account(&account)?;
        self.session = Some(Session { account, vault_key });
        self.save_session(&pending.api.base, &pending.device, &pending.session)?;
        tracing::info!(target: "sync", "joined existing account");
        self.sync_now()?;
        Ok(())
    }

    /// 会话过期（401）后，用主密码重新建立同步会话。
    pub fn reconnect(&mut self, master_password: &str, secret_key: &str) -> Result<()> {
        let (_, remote) = self.remote_api()?;
        let email = self.email()?.to_string();
        let sk = SecretKey::parse(secret_key).map_err(|_| VaultError::InvalidCredentials)?;
        let device = device_info(remote.device_id.clone(), &remote.device_name)?;
        let api = ApiClient::new(&remote.server_url)?;
        let (finish, _) = api.srp_login(&email, master_password, &sk, &device)?;
        self.save_session(&api.base, &device, &finish.session)?;
        if !finish.session.device_approved {
            return Err(VaultError::DeviceNotApproved);
        }
        Ok(())
    }

    /// 清空设备后用 Recovery Kit 恢复（F-08 / B-07）：恢复码解封 Vault Key → 设定新主密码 → 轮换恢复码。
    pub fn recover_from_server(
        &mut self,
        server_url: &str,
        email: &str,
        recovery_code: &str,
        secret_key: &str,
        new_password: &str,
        device_name: &str,
    ) -> Result<Enrollment> {
        if self.is_initialized()? {
            return Err(VaultError::AlreadyInitialized);
        }
        validate_master_password(new_password)?;
        let email = validate_email(email)?;
        let sk = SecretKey::parse(secret_key)?;
        let rc = RecoveryCode::parse(recovery_code).map_err(|_| VaultError::InvalidRecoveryCode)?;
        let device = device_info(self.store.device_id()?, device_name)?;
        let api = ApiClient::new(server_url)?;

        let start: RecoveryStartResponse = api.post("/v1/recovery/start", &RecoveryStartRequest { email: email.clone() })?;
        let auth = rc.auth_token(&start.account_id)?;
        let fetched: AccountResponse = api
            .post("/v1/recovery/fetch", &RecoveryFetchRequest { email: email.clone(), recovery_auth: auth.as_bytes().to_vec().into() })
            .map_err(|e| match e {
                VaultError::Server { code, .. } if code == codes::AUTH_FAILED => VaultError::InvalidRecoveryCode,
                other => other,
            })?;
        let keys = fetched.keys;
        let vault_key = sealed::unwrap_key(&rc.wrap_key(&keys.account_id)?, &keys.recovery_wrap, &aad("recovery", &keys.account_id))
            .map_err(|_| VaultError::InvalidRecoveryCode)?;

        let kdf = keys.kdf.rotate_salt();
        let creds = build_credentials(&keys.account_id, new_password, &sk, &kdf, &vault_key, None)?;
        let recovery = build_recovery(&keys.account_id, &vault_key)?;
        let done: RecoveryCompleteResponse = api.post(
            "/v1/recovery/complete",
            &RecoveryCompleteRequest {
                email: email.clone(),
                recovery_auth: auth.as_bytes().to_vec().into(),
                kdf: kdf.clone(),
                srp_salt: creds.srp_salt.clone().into(),
                srp_verifier: creds.srp_verifier.clone().into(),
                vk_wrap: creds.vk_wrap.clone().into(),
                recovery_wrap: recovery.wrap.clone().into(),
                recovery_auth_hash: recovery.auth_hash.clone().into(),
                device: device.clone(),
            },
        )?;
        let account = AccountRecord {
            account_id: keys.account_id.clone(),
            vault_id: keys.vault_id.clone(),
            kdf,
            vk_wrap: B64.encode(&creds.vk_wrap),
            vk_gen: done.keys.vk_gen,
            recovery_wrap: B64.encode(&recovery.wrap),
            recovery_auth_hash: B64.encode(&recovery.auth_hash),
            email_enc: B64.encode(sealed::seal(&vault_key, email.as_bytes(), &aad("email", &keys.account_id))?),
            srp_salt: B64.encode(&creds.srp_salt),
            srp_verifier: B64.encode(&creds.srp_verifier),
            credentials_dirty: false,
            created_at: now(),
        };
        self.store.save_account(&account)?;
        self.session = Some(Session { account, vault_key });
        self.save_session(&api.base, &device, &done.session)?;
        tracing::warn!(target: "sync", "account recovered via recovery kit");
        self.sync_now()?;
        Ok(Enrollment { account_id: keys.account_id, email, secret_key: sk.format(), recovery_code: recovery.code.format() })
    }

    /// 断开同步（注销本设备会话），本地数据保留。
    pub fn disconnect(&mut self) -> Result<()> {
        if let Ok((api, _)) = self.remote_api() {
            let _: std::result::Result<serde_json::Value, _> = api.post("/v1/auth/logout", &serde_json::json!({}));
        }
        self.store.clear_remote()?;
        self.store.reset_sync_state()?;
        Ok(())
    }

    /// 注销云端账户（PIPL/GDPR 删除权）。需要主密码二次确认。
    pub fn delete_remote_account(&mut self, master_password: &str, secret_key: &str) -> Result<()> {
        self.verify_master_password(master_password, secret_key)?;
        let (api, _) = self.remote_api()?;
        api.call::<(), serde_json::Value>(reqwest::Method::DELETE, "/v1/account", None)?;
        self.store.clear_remote()?;
        self.store.reset_sync_state()?;
        tracing::warn!(target: "sync", "remote account deleted");
        Ok(())
    }

    pub fn list_devices(&self) -> Result<Vec<DeviceOut>> {
        self.remote_api()?.0.get("/v1/devices")
    }

    pub fn approve_device(&self, device_id: &str) -> Result<()> {
        let _: serde_json::Value = self.remote_api()?.0.post(&format!("/v1/devices/{device_id}/approve"), &serde_json::json!({}))?;
        Ok(())
    }

    pub fn revoke_device(&self, device_id: &str) -> Result<()> {
        let _: serde_json::Value =
            self.remote_api()?.0.call::<(), _>(reqwest::Method::DELETE, &format!("/v1/devices/{device_id}"), None)?;
        Ok(())
    }

    pub fn audit_events(&self) -> Result<Vec<AuditEventOut>> {
        self.remote_api()?.0.get("/v1/audit")
    }

    // ───────── 同步主流程 ─────────

    pub fn sync_now(&mut self) -> Result<SyncReport> {
        let (api, _) = self.remote_api()?;
        let mut report = SyncReport::default();
        self.push_credentials(&api, &mut report)?;
        for round in 0..MAX_SYNC_ROUNDS {
            self.pull_all(&api, &mut report)?;
            let conflicted = self.push_dirty(&api, &mut report)?;
            if !conflicted {
                break;
            }
            tracing::info!(target: "sync", round, "push conflict, re-pulling");
        }
        tracing::info!(
            target: "sync",
            pulled = report.pulled, pushed = report.pushed, merged = report.merged, conflicts = report.conflicts,
            "sync complete"
        );
        Ok(report)
    }

    fn push_credentials(&mut self, api: &ApiClient, report: &mut SyncReport) -> Result<()> {
        let s = self.session()?;
        if !s.account.credentials_dirty {
            return Ok(());
        }
        let a = &s.account;
        let req = ChangeCredentialsRequest {
            kdf: a.kdf.clone(),
            srp_salt: b64d(&a.srp_salt)?.into(),
            srp_verifier: b64d(&a.srp_verifier)?.into(),
            vk_wrap: b64d(&a.vk_wrap)?.into(),
            expected_vk_gen: a.vk_gen,
            recovery_wrap: Some(b64d(&a.recovery_wrap)?.into()),
            recovery_auth_hash: (!a.recovery_auth_hash.is_empty()).then(|| b64d(&a.recovery_auth_hash)).transpose()?.map(Into::into),
        };
        let resp: ChangeCredentialsResponse = api.call(reqwest::Method::PUT, "/v1/account/credentials", Some(&req))?;
        let session = self.session.as_mut().ok_or(VaultError::Locked)?;
        session.account.vk_gen = resp.vk_gen;
        session.account.credentials_dirty = false;
        self.store.save_account(&session.account)?;
        report.credentials_updated = true;
        Ok(())
    }

    /// 其他设备改了主密码：拉取新的封装数据（Vault Key 不变，因此当前会话继续可用）。
    fn adopt_remote_credentials(&mut self, api: &ApiClient) -> Result<()> {
        let acc: AccountResponse = api.get("/v1/account")?;
        let session = self.session.as_mut().ok_or(VaultError::Locked)?;
        let a = &mut session.account;
        if acc.keys.vk_gen <= a.vk_gen || a.credentials_dirty {
            return Ok(());
        }
        // 校验新封装确实封装的是同一把 Vault Key 不可行（需要新主密码）；这里只接受结构合法的数据
        a.kdf = acc.keys.kdf;
        a.vk_wrap = B64.encode(&acc.keys.vk_wrap.0);
        a.vk_gen = acc.keys.vk_gen;
        a.recovery_wrap = B64.encode(&acc.keys.recovery_wrap.0);
        self.store.save_account(a)?;
        self.store.clear_quick_unlock()?;
        tracing::warn!(target: "sync", "master password was changed on another device; adopted new key wrap");
        Ok(())
    }

    fn pull_all(&mut self, api: &ApiClient, report: &mut SyncReport) -> Result<()> {
        let vault_id = self.session()?.account.vault_id.clone();
        let mut cursor = self.store.cursor(&vault_id)?;
        loop {
            let page: PullResponse = api.get(&format!("/v1/sync/pull?cursor={cursor}&limit={PULL_PAGE_SIZE}"))?;
            for item in &page.items {
                self.apply_remote(item, report)?;
            }
            cursor = page.cursor;
            self.store.set_cursor(&vault_id, cursor, now())?;
            if let Some(gen) = page.vk_gen {
                if gen > self.session()?.account.vk_gen {
                    self.adopt_remote_credentials(api)?;
                    report.credentials_updated = true;
                }
            }
            if !page.has_more {
                break;
            }
        }
        Ok(())
    }

    fn apply_remote(&mut self, remote: &RemoteItem, report: &mut SyncReport) -> Result<()> {
        let vault_id = self.session()?.account.vault_id.clone();
        let remote_data = match self.decrypt_blob(&remote.id, remote.revision, &remote.blob) {
            Ok(d) => d,
            Err(e) => {
                tracing::error!(target: "sync", item = %remote.id, error = %e, "remote item failed integrity check, ignored");
                return Ok(());
            }
        };
        let deleted_at = remote.deleted.then_some(remote.updated_at);
        let local = self.store.get_item(&remote.id)?;
        match local {
            Some(l) if remote.revision <= l.server_rev => {}
            Some(l) if l.dirty => {
                // 双方都改了：字段级三方合并
                let local_data = self.decrypt_blob(&l.id, l.revision, &l.blob)?;
                let base = l.base_blob.as_ref().and_then(|b| self.decrypt_blob(&l.id, l.server_rev, b).ok());
                let outcome = merge(base.as_ref(), &local_data, &remote_data);
                // 删除语义：只有双方都删除才保持删除，否则保留编辑，避免丢数据
                let deleted = if l.deleted_at.is_some() && remote.deleted { deleted_at.or(l.deleted_at) } else { None };
                let revision = l.revision.max(remote.revision) + 1;
                let row = ItemRow {
                    id: l.id.clone(),
                    vault_id: vault_id.clone(),
                    kind: outcome.data.kind.as_str().into(),
                    blob: self.seal_blob(&l.id, revision, &outcome.data)?,
                    revision,
                    server_rev: remote.revision,
                    base_blob: Some(remote.blob.0.clone()),
                    dirty: true,
                    deleted_at: deleted,
                    created_at: l.created_at,
                    updated_at: outcome.data.updated_at,
                };
                self.store.put_item(&row)?;
                report.merged += 1;
                report.conflicts += outcome.conflicts.len() as u32;
                tracing::info!(target: "sync", item = %l.id, fields = ?outcome.conflicts, "merged concurrent edits");
            }
            _ => {
                self.store.put_item(&ItemRow {
                    id: remote.id.clone(),
                    vault_id,
                    kind: remote.kind.clone(),
                    blob: remote.blob.0.clone(),
                    revision: remote.revision,
                    server_rev: remote.revision,
                    base_blob: Some(remote.blob.0.clone()),
                    dirty: false,
                    deleted_at,
                    created_at: remote_data.created_at,
                    updated_at: remote_data.updated_at,
                })?;
                report.pulled += 1;
            }
        }
        Ok(())
    }

    /// 推送脏条目，返回是否有冲突（需要重新拉取合并）。
    fn push_dirty(&mut self, api: &ApiClient, report: &mut SyncReport) -> Result<bool> {
        let dirty = self.store.dirty_items()?;
        let mut conflicted = false;
        for chunk in dirty.chunks(PUSH_MAX_ITEMS) {
            let items: Vec<PushItem> = chunk
                .iter()
                .map(|r| PushItem {
                    id: r.id.clone(),
                    kind: r.kind.clone(),
                    blob: r.blob.clone().into(),
                    base_revision: r.server_rev,
                    revision: r.revision,
                    deleted: r.deleted_at.is_some(),
                    updated_at: r.updated_at,
                })
                .collect();
            let resp: PushResponse = api.post("/v1/sync/push", &PushRequest { items })?;
            for res in resp.results {
                match res.status {
                    PushStatus::Applied => {
                        let rev = chunk.iter().find(|r| r.id == res.id).map_or(res.revision, |r| r.revision);
                        self.store.mark_synced(&res.id, rev)?;
                        report.pushed += 1;
                    }
                    PushStatus::Conflict => conflicted = true,
                }
            }
        }
        Ok(conflicted)
    }
}

fn account_keys(a: &AccountRecord) -> Result<AccountKeys> {
    Ok(AccountKeys {
        account_id: a.account_id.clone(),
        vault_id: a.vault_id.clone(),
        kdf: a.kdf.clone(),
        vk_wrap: b64d(&a.vk_wrap)?.into(),
        vk_gen: a.vk_gen,
        recovery_wrap: b64d(&a.recovery_wrap)?.into(),
    })
}

/// 快速检查服务器可达（设置页"测试连接"）。
pub fn ping(server_url: &str) -> Result<()> {
    let api = ApiClient::new(server_url)?;
    let _: serde_json::Value = api.get("/healthz")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_url_policy() {
        assert!(validate_server_url("https://sync.vaultone.app/").is_ok());
        assert_eq!(validate_server_url("https://sync.vaultone.app/").unwrap(), "https://sync.vaultone.app");
        assert!(validate_server_url("http://127.0.0.1:8787").is_ok());
        assert!(validate_server_url("http://sync.vaultone.app").is_err());
        assert!(validate_server_url("ftp://x").is_err());
        assert!(validate_server_url("not a url").is_err());
    }
}
