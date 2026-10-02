//! 云同步：连接/登录/新设备验证/同步/设备管理/云端恢复。

use vault_core::sync::{self as core_sync, LoginOutcome};

use super::vault::{with_vault, EnrollmentDto};
use super::BridgeResult;

#[derive(Debug, Clone)]
pub struct SyncReportDto {
    pub pulled: u32,
    pub pushed: u32,
    pub merged: u32,
    pub conflicts: u32,
    pub credentials_updated: bool,
}

impl From<core_sync::SyncReport> for SyncReportDto {
    fn from(r: core_sync::SyncReport) -> Self {
        Self { pulled: r.pulled, pushed: r.pushed, merged: r.merged, conflicts: r.conflicts, credentials_updated: r.credentials_updated }
    }
}

#[derive(Debug, Clone)]
pub struct RemoteStatusDto {
    pub server_url: String,
    pub device_id: String,
    pub device_name: String,
    pub last_sync_at: Option<i64>,
    pub pending: u64,
}

#[derive(Debug, Clone)]
pub struct DeviceDto {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub approved: bool,
    pub current: bool,
    pub created_at: i64,
    pub last_seen_at: Option<i64>,
    pub revoked: bool,
}

#[derive(Debug, Clone)]
pub struct AuditEventDto {
    pub event: String,
    pub device_id: Option<String>,
    pub created_at: i64,
}

pub fn remote_status() -> BridgeResult<Option<RemoteStatusDto>> {
    with_vault(|v| {
        Ok(v.remote_status()?.map(|r| RemoteStatusDto {
            server_url: r.server_url,
            device_id: r.device_id,
            device_name: r.device_name,
            last_sync_at: r.last_sync_at,
            pending: r.pending,
        }))
    })
}

/// 仅调试构建可登记一个私网 HTTP 服务器，None 撤销例外。
pub fn configure_development_http(server_url: Option<String>) -> BridgeResult<()> {
    Ok(core_sync::configure_development_http_server(server_url.as_deref())?)
}

/// 测试服务器连通性。
pub fn ping_server(server_url: String) -> BridgeResult<()> {
    Ok(core_sync::ping(&server_url)?)
}

/// 已有本地账户 → 注册到同步服务并完成首次同步。
pub fn connect_register(server_url: String, device_name: String) -> BridgeResult<SyncReportDto> {
    with_vault(|v| v.connect_register(&server_url, &device_name).map(Into::into))
}

/// 新设备登录已有账户。返回 true 表示已完成加入；false 表示需要验证设备。
pub fn login_existing(server_url: String, email: String, password: String, secret_key: String, device_name: String) -> BridgeResult<bool> {
    with_vault(|v| v.login_existing(&server_url, &email, &password, &secret_key, &device_name).map(|o| o == LoginOutcome::Joined))
}

pub fn verify_new_device(code: String) -> BridgeResult<()> {
    with_vault(|v| v.verify_new_device(&code))
}

/// 轮询：是否已被其他设备批准（批准后自动完成加入）。
pub fn check_new_device_approved() -> BridgeResult<bool> {
    with_vault(|v| v.check_new_device_approved())
}

pub fn sync_now() -> BridgeResult<SyncReportDto> {
    with_vault(|v| v.sync_now().map(Into::into))
}

pub fn reconnect(password: String, secret_key: String) -> BridgeResult<()> {
    with_vault(|v| v.reconnect(&password, &secret_key))
}

pub fn disconnect() -> BridgeResult<()> {
    with_vault(|v| v.disconnect())
}

pub fn delete_remote_account(password: String, secret_key: String) -> BridgeResult<()> {
    with_vault(|v| v.delete_remote_account(&password, &secret_key))
}

pub fn list_devices() -> BridgeResult<Vec<DeviceDto>> {
    with_vault(|v| {
        Ok(v.list_devices()?
            .into_iter()
            .map(|d| DeviceDto {
                id: d.id,
                name: d.name,
                platform: d.platform.as_str().into(),
                approved: d.approved,
                current: d.current,
                created_at: d.created_at,
                last_seen_at: d.last_seen_at,
                revoked: d.revoked_at.is_some(),
            })
            .collect())
    })
}

pub fn approve_device(device_id: String) -> BridgeResult<()> {
    with_vault(|v| v.approve_device(&device_id))
}

pub fn revoke_device(device_id: String) -> BridgeResult<()> {
    with_vault(|v| v.revoke_device(&device_id))
}

pub fn audit_events() -> BridgeResult<Vec<AuditEventDto>> {
    with_vault(|v| {
        Ok(v.audit_events()?
            .into_iter()
            .map(|e| AuditEventDto { event: e.event, device_id: e.device_id, created_at: e.created_at })
            .collect())
    })
}

/// 所有设备丢失后，用 Recovery Kit 从云端恢复。
pub fn recover_from_server(
    server_url: String,
    email: String,
    recovery_code: String,
    secret_key: String,
    new_password: String,
    device_name: String,
) -> BridgeResult<EnrollmentDto> {
    with_vault(|v| v.recover_from_server(&server_url, &email, &recovery_code, &secret_key, &new_password, &device_name).map(Into::into))
}

// ───────── 账户资料（§8.1 / §8.2）─────────

/// 账户资料。`online` 表示本次是否成功从服务端刷新；失败时返回的是本机缓存。
#[derive(Debug, Clone)]
pub struct AccountProfileDto {
    pub nickname: String,
    pub avatar: String,
    pub created_at: i64,
    /// 我的邀请码（§8.1 / §9）。旧服务端不返回时为空。
    pub invite_code: String,
    pub online: bool,
}

/// 从内核的资料结构构造 DTO，避免三处各写一遍字段映射。
fn profile_dto(p: vault_proto::AccountProfile, online: bool) -> AccountProfileDto {
    AccountProfileDto { nickname: p.nickname, avatar: p.avatar, created_at: p.created_at, invite_code: p.invite_code, online }
}

/// 读取账户资料（§8.1）。**联网失败不报错**，回退到本机缓存并置 `online=false` ——
/// 账户总览在离线时也该有东西可显示，这正是本地优先的意思。
pub fn account_profile() -> BridgeResult<AccountProfileDto> {
    with_vault(|v| {
        let cached = v.cached_profile()?;
        match v.fetch_profile() {
            Ok(p) => Ok(profile_dto(p, true)),
            Err(e) => {
                tracing::debug!(target: "bridge", error = %e, "account profile fetch failed; serving cache");
                Ok(profile_dto(cached.unwrap_or_default(), false))
            }
        }
    })
}

/// 更新账户资料（§8.2）。需要联网；成功后服务端返回的值即为新值。
pub fn update_account_profile(nickname: String, avatar: String) -> BridgeResult<AccountProfileDto> {
    with_vault(|v| Ok(profile_dto(v.update_profile(&nickname, &avatar)?, true)))
}

/// 补填邀请人邀请码（§9）。一次性绑定，绑定后不可更改；需要联网。
pub fn bind_invite(code: String) -> BridgeResult<AccountProfileDto> {
    with_vault(|v| Ok(profile_dto(v.bind_invite(&code)?, true)))
}
