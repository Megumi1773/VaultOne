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

static DEVELOPMENT_HTTP_SERVER: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// 只为调试构建登记一个明确的私网 HTTP 端点；发布构建不能启用。
pub fn configure_development_http_server(server: Option<&str>) -> Result<()> {
    let configured = match server {
        None => None,
        Some(value) if cfg!(debug_assertions) => {
            let parsed = url::Url::parse(value).map_err(|_| VaultError::InvalidInput("调试服务器地址无效".into()))?;
            if parsed.scheme() != "http"
                || !private_ipv4_host(&parsed)
                || parsed.path() != "/"
                || parsed.port() == Some(0)
                || !parsed.username().is_empty()
                || parsed.password().is_some()
                || parsed.query().is_some()
                || parsed.fragment().is_some()
            {
                return Err(VaultError::InvalidInput("局域网调试仅允许指定私网 IPv4 的 HTTP 根地址".into()));
            }
            Some(parsed.as_str().trim_end_matches('/').to_string())
        }
        Some(_) => return Err(VaultError::InvalidInput("发布构建不允许局域网 HTTP 调试".into())),
    };
    *DEVELOPMENT_HTTP_SERVER.lock().map_err(|_| VaultError::InvalidInput("调试网络配置不可用".into()))? = configured;
    Ok(())
}

fn private_ipv4_host(url: &url::Url) -> bool {
    matches!(url.host(), Some(url::Host::Ipv4(ip)) if ip.is_private())
}

/// HTTPS 为默认；回环保留既有开发例外，私网 HTTP 还需调试构建及精确端点登记。
pub(crate) fn validate_server_url(url: &str) -> Result<String> {
    let configured = DEVELOPMENT_HTTP_SERVER.lock().map_err(|_| VaultError::InvalidInput("调试网络配置不可用".into()))?;
    validate_server_url_with_override(url, configured.as_deref(), cfg!(debug_assertions))
}

fn validate_server_url_with_override(url: &str, configured: Option<&str>, debug: bool) -> Result<String> {
    let parsed = url::Url::parse(url.trim()).map_err(|_| VaultError::InvalidInput("服务器地址格式不正确".into()))?;
    if !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || parsed.port() == Some(0)
    {
        return Err(VaultError::InvalidInput("服务器地址不得包含凭据、查询参数或片段".into()));
    }
    let normalized = parsed.as_str().trim_end_matches('/').to_string();
    let loopback = matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "[::1]" | "10.0.2.2"));
    let approved_lan = debug && private_ipv4_host(&parsed) && configured == Some(normalized.as_str());
    match parsed.scheme() {
        "https" => {}
        "http" if loopback || approved_lan => {}
        _ => return Err(VaultError::InvalidInput("同步服务必须使用 HTTPS；真机 HTTP 调试需显式登记私网端点".into())),
    }
    Ok(normalized)
}

impl ApiClient {
    pub fn new(base: &str) -> Result<Self> {
        let base = validate_server_url(base)?;
        let builder = reqwest::blocking::Client::builder()
            .timeout(HTTP_TIMEOUT)
            .https_only(false)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("VaultOne/", env!("CARGO_PKG_VERSION")));
        // 开发 HTTP 仅通往本机/已批准私网，避免经环境变量代理传出会话令牌。
        let builder = if base.starts_with("http://") { builder.no_proxy() } else { builder };
        let http = builder.build().map_err(|e| VaultError::Network(e.to_string()))?;
        Ok(Self { base, http, token: None })
    }

    pub fn with_token(mut self, token: Zeroizing<String>) -> Self {
        self.token = Some(token);
        self
    }

    pub(crate) fn call<Req: Serialize, Resp: DeserializeOwned>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&Req>,
    ) -> Result<Resp> {
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

    pub(crate) fn get<Resp: DeserializeOwned>(&self, path: &str) -> Result<Resp> {
        self.call::<(), Resp>(reqwest::Method::GET, path, None)
    }

    pub(crate) fn post<Req: Serialize, Resp: DeserializeOwned>(&self, path: &str, body: &Req) -> Result<Resp> {
        self.call(reqwest::Method::POST, path, Some(body))
    }

    /// SRP-6a 登录。返回 (登录结果, AuthKey 派生所用的账户信息)。
    pub(crate) fn srp_login(
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

pub(crate) fn device_info(id: String, name: &str) -> Result<DeviceInfo> {
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

    pub(crate) fn remote_api(&self) -> Result<(ApiClient, RemoteRecord)> {
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
        if self.store.conflicts(&s.account.vault_id)?.iter().any(|c| matches!(c.state.as_str(), "pending" | "resolution_pending")) {
            return Err(VaultError::ConflictStale);
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
        self.store.transaction(|store| {
            store.mark_all_dirty()?;
            store.reset_sync_state()?;
            self.save_session(&api.base, &device, &resp.session)
        })?;
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
        let remote = RemoteRecord {
            server_url: pending.api.base.clone(),
            device_id: pending.device.id.clone(),
            device_name: pending.device.name.clone(),
            token_enc: B64.encode(sealed::seal(&vault_key, pending.session.token.as_bytes(), &aad("session-token", &account.account_id))?),
            expires_at: pending.session.expires_at,
        };
        self.store.transaction(|store| {
            if store.load_account()?.is_some() {
                return Err(VaultError::AlreadyInitialized);
            }
            store.save_account(&account)?;
            store.save_remote(&remote)
        })?;
        self.session = Some(Session { account, vault_key });
        tracing::info!(target: "sync", "joined existing account");
        if let Err(error) = self.sync_now() {
            tracing::warn!(target: "sync", code = error.code(), "initial item sync deferred after login");
        }
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

    fn ensure_remote_removal_allowed(&self) -> Result<()> {
        if let Some(account) = self.store.load_account()? {
            if self.store.conflicts(&account.vault_id)?.iter().any(|c| matches!(c.state.as_str(), "pending" | "resolution_pending")) {
                return Err(VaultError::ConflictPending);
            }
        }
        Ok(())
    }

    /// 断开同步（注销本设备会话），本地数据保留。活动冲突必须先完成，不能切断其 ACK 通道。
    pub fn disconnect(&mut self) -> Result<()> {
        // 主动断连属于低频维护操作：锁住写入直到远端/本机清理结束，避免另一连接在检查后创建冲突。
        self.store.transaction(|store| {
            self.ensure_remote_removal_allowed()?;
            // 无活动冲突时维持本地优先：过期会话或离线不阻止本机断开，远端注销尽力。
            if let Ok((api, _)) = self.remote_api() {
                let _: Result<serde_json::Value> = api.post("/v1/auth/logout", &serde_json::json!({}));
            }
            store.clear_remote()?;
            store.reset_sync_state()
        })
    }

    /// 注销云端账户（PIPL/GDPR 删除权）。需要主密码二次确认。
    pub fn delete_remote_account(&mut self, master_password: &str, secret_key: &str) -> Result<()> {
        self.ensure_remote_removal_allowed()?;
        self.verify_master_password(master_password, secret_key)?;
        self.store.transaction(|store| {
            self.ensure_remote_removal_allowed()?;
            let (api, _) = self.remote_api()?;
            api.call::<(), serde_json::Value>(reqwest::Method::DELETE, "/v1/account", None)?;
            store.clear_remote()?;
            store.reset_sync_state()
        })?;
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
        if self.pending_cloud_operation()?.is_some() {
            return Err(VaultError::InvalidInput("账户操作尚未确认，请先原样重试；本机条目已保留".into()));
        }
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
            self.apply_pull_page(&page, cursor, report)?;
            cursor = page.cursor;
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

    /// 每条提交都是可重放的原子操作；全页成功后才推进游标，重启可重复应用已提交前缀。
    pub(crate) fn apply_pull_page(&mut self, page: &PullResponse, expected_cursor: i64, report: &mut SyncReport) -> Result<()> {
        let vault_id = self.session()?.account.vault_id.clone();
        if page.cursor < expected_cursor {
            return Err(VaultError::Integrity);
        }
        for item in &page.items {
            self.apply_remote(item, report)?;
        }
        self.store.transaction(|s| {
            if s.cursor(&vault_id)? != expected_cursor {
                return Err(VaultError::ConflictStale);
            }
            s.set_cursor(&vault_id, page.cursor, now())
        })
    }

    pub(crate) fn apply_remote(&mut self, remote: &RemoteItem, report: &mut SyncReport) -> Result<()> {
        use crate::conflict::{ConflictField, StoredBase};
        let vault_id = self.session()?.account.vault_id.clone();
        // 损坏不能被视为成功，否则 pull 游标将永久越过未应用的数据。
        if remote.revision < 1 {
            return Err(VaultError::Integrity);
        }
        let remote_data = self.decrypt_blob(&remote.id, remote.revision, &remote.blob)?;
        crate::vault::validate_item(&remote_data)?;
        if remote.kind != remote_data.kind.as_str() {
            return Err(VaultError::Integrity);
        }
        let remote_row = ItemRow {
            id: remote.id.clone(),
            vault_id: vault_id.clone(),
            kind: remote.kind.clone(),
            blob: remote.blob.0.clone(),
            revision: remote.revision,
            server_rev: remote.revision,
            base_blob: Some(remote.blob.0.clone()),
            base_deleted: Some(remote.deleted),
            dirty: false,
            deleted_at: remote.deleted.then_some(remote.updated_at),
            created_at: remote_data.created_at,
            updated_at: remote_data.updated_at,
        };
        let local = self.store.get_item(&remote.id)?;
        let active = self.store.active_conflict(&vault_id, &remote.id)?;
        let payload = active.as_ref().map(|c| self.open_conflict(c)).transpose()?;
        if let Some(l) = &local {
            if l.vault_id != vault_id {
                return Err(VaultError::Integrity);
            }
            // 响应丢失后的重复拉取，只认可精确信封与墓碑，不重新密封或按时间覆盖。
            if remote.revision == l.revision
                && remote.blob.0 == l.blob
                && remote.deleted == l.deleted_at.is_some()
                && active.as_ref().is_none_or(|c| c.state == "resolution_pending")
                && self.acknowledge_snapshot(l)?
            {
                return Ok(());
            }
            if let Some(p) = &payload {
                if remote.revision < p.remote.revision {
                    return Ok(());
                }
                if remote.revision == p.remote.revision {
                    if remote.blob.0 != p.remote.blob || remote.deleted != p.remote.deleted_at.is_some() {
                        return Err(VaultError::Integrity);
                    }
                    return Ok(());
                }
            }
            if remote.revision <= l.server_rev {
                if remote.revision == l.server_rev
                    && (l.base_blob.as_ref() != Some(&remote.blob.0) || l.base_deleted.is_some_and(|d| d != remote.deleted))
                {
                    return Err(VaultError::Integrity);
                }
                return Ok(());
            }
            if l.dirty || active.is_some() {
                let local_data = self.decrypt_blob(&l.id, l.revision, &l.blob)?;
                let base_snapshot = if active.as_ref().is_some_and(|c| c.state == "pending") {
                    payload.as_ref().and_then(|p| p.base.clone())
                } else {
                    l.base_blob.as_ref().map(|blob| StoredBase { revision: l.server_rev, blob: blob.clone(), deleted: l.base_deleted })
                };
                let base = base_snapshot.as_ref().map(|b| self.decrypt_blob(&l.id, b.revision, &b.blob)).transpose()?;
                let outcome = merge(base.as_ref(), &local_data, &remote_data);
                let (deleted, deletion_conflict) = crate::merge::merge_deleted(
                    base.as_ref(),
                    base_snapshot.as_ref().and_then(|b| b.deleted),
                    &local_data,
                    l.deleted_at.is_some(),
                    &remote_data,
                    remote.deleted,
                );
                let mut fields: Vec<_> = outcome.conflicts.iter().map(|s| ConflictField::from_merge(s)).collect();
                if deletion_conflict {
                    fields.push(ConflictField::Deleted);
                }
                // 已存在裁决工作记录时，新远端必须重新确认；不把旧决定自动套到新数据上。
                if active.is_some() && fields.is_empty() {
                    fields.push(ConflictField::Resolution);
                }
                if !fields.is_empty() {
                    let count = fields.len() as u32;
                    let record = self.prepare_conflict(l, &remote_row, fields, base_snapshot)?;
                    self.store.transaction(|s| {
                        s.check_item(Some(l), &l.id)?;
                        s.check_conflict(active.as_ref(), &vault_id, &l.id)?;
                        if let Some(old) = &active {
                            s.retire_conflict(&old.id, "superseded")?;
                        }
                        s.put_conflict(&record)
                    })?;
                    report.conflicts += count;
                    return Ok(());
                }
                let revision = l.revision.max(remote.revision).checked_add(1).ok_or(VaultError::Integrity)?;
                let row = ItemRow {
                    id: l.id.clone(),
                    vault_id: vault_id.clone(),
                    kind: outcome.data.kind.as_str().into(),
                    blob: self.seal_blob(&l.id, revision, &outcome.data)?,
                    revision,
                    server_rev: remote.revision,
                    base_blob: Some(remote.blob.0.clone()),
                    base_deleted: Some(remote.deleted),
                    dirty: true,
                    deleted_at: deleted.then_some(outcome.data.updated_at),
                    created_at: l.created_at,
                    updated_at: outcome.data.updated_at,
                };
                self.store.transaction(|s| {
                    s.check_item(Some(l), &l.id)?;
                    s.check_conflict(None, &vault_id, &l.id)?;
                    s.put_item(&row)
                })?;
                report.merged += 1;
                return Ok(());
            }
        }
        self.store.transaction(|s| {
            s.check_item(local.as_ref(), &remote.id)?;
            s.check_conflict(None, &vault_id, &remote.id)?;
            s.put_item(&remote_row)
        })?;
        report.pulled += 1;
        Ok(())
    }

    /// 推送脏条目，返回是否有冲突（需要重新拉取合并）。
    fn push_dirty(&mut self, api: &ApiClient, report: &mut SyncReport) -> Result<bool> {
        let dirty = self.store.dirty_items()?;
        for row in &dirty {
            self.validate_outgoing_snapshot(row)?;
        }
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
                        let sent = chunk.iter().find(|r| r.id == res.id).ok_or(VaultError::Integrity)?;
                        if res.revision != sent.revision {
                            return Err(VaultError::Integrity);
                        }
                        if self.acknowledge_snapshot(sent)? {
                            report.pushed += 1;
                        }
                    }
                    PushStatus::Conflict => conflicted = true,
                }
            }
        }
        Ok(conflicted)
    }
}

pub(crate) fn account_keys(a: &AccountRecord) -> Result<AccountKeys> {
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
    fn lan_http_requires_debug_and_exact_explicit_origin() {
        let selected = "http://192.168.0.4:9777";
        assert!(validate_server_url_with_override(selected, None, true).is_err());
        assert!(validate_server_url_with_override(selected, Some(selected), false).is_err());
        assert_eq!(validate_server_url_with_override(selected, Some(selected), true).unwrap(), selected);
        for other in ["http://192.168.0.5:9777", "http://192.168.0.4:9778", "http://192.168.0.4:9777/path", "http://8.8.8.8:9777"] {
            assert!(validate_server_url_with_override(other, Some(selected), true).is_err());
        }
        for value in ["http://8.8.8.8", "http://198.18.0.1", "http://private.example.test", "http://192.168.0.4?token=x"] {
            assert!(configure_development_http_server(Some(value)).is_err());
        }
    }

    #[test]
    fn authentication_client_does_not_follow_redirects() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let worker = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut request = [0; 4096];
            let _ = stream.read(&mut request).unwrap();
            stream
                .write_all(
                    b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .unwrap();
        });
        let result = ApiClient::new(&base).unwrap().get::<serde_json::Value>("/healthz");
        assert!(matches!(result, Err(VaultError::Server { status: 302, .. })));
        worker.join().unwrap();
    }

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
