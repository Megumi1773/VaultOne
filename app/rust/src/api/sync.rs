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
