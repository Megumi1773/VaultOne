//! VaultOne 线协议（JSON over HTTPS）。
//!
//! 所有字段要么是非敏感元数据，要么是客户端用 AES-256-GCM 密封盒加密后的密文（[`Bytes`]，base64）。
//! 服务端与客户端共用本 crate，保证两端结构一致。

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

pub use vault_crypto::kdf::KdfParams;

pub const API_VERSION: &str = "v1";

/// 以 base64 序列化的字节串。
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Bytes(pub Vec<u8>);

impl std::fmt::Debug for Bytes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Bytes({} B)", self.0.len())
    }
}

impl Serialize for Bytes {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&B64.encode(&self.0))
    }
}

impl<'de> Deserialize<'de> for Bytes {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        B64.decode(s.as_bytes()).map(Bytes).map_err(serde::de::Error::custom)
    }
}

impl From<Vec<u8>> for Bytes {
    fn from(v: Vec<u8>) -> Self {
        Bytes(v)
    }
}

impl std::ops::Deref for Bytes {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        &self.0
    }
}

// ───────────────────────── 通用 ─────────────────────────

/// 错误响应体。`code` 为稳定的机器可读错误码，`message` 面向用户。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}

pub mod codes {
    pub const BAD_REQUEST: &str = "bad_request";
    pub const UNAUTHORIZED: &str = "unauthorized";
    pub const AUTH_FAILED: &str = "auth_failed";
    pub const DEVICE_NOT_APPROVED: &str = "device_not_approved";
    pub const CONFLICT: &str = "conflict";
    pub const EMAIL_TAKEN: &str = "email_taken";
    pub const NOT_FOUND: &str = "not_found";
    pub const RATE_LIMITED: &str = "rate_limited";
    pub const INTERNAL: &str = "internal";
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Windows,
    Macos,
    Linux,
    Ios,
    Android,
    Extension,
    Other,
}

impl Platform {
    pub fn as_str(self) -> &'static str {
        match self {
            Platform::Windows => "windows",
            Platform::Macos => "macos",
            Platform::Linux => "linux",
            Platform::Ios => "ios",
            Platform::Android => "android",
            Platform::Extension => "extension",
            Platform::Other => "other",
        }
    }

    pub fn parse(s: &str) -> Self {
        serde_json::from_value(serde_json::Value::String(s.to_string())).unwrap_or(Platform::Other)
    }

    pub fn current() -> Self {
        match std::env::consts::OS {
            "windows" => Platform::Windows,
            "macos" => Platform::Macos,
            "linux" => Platform::Linux,
            "ios" => Platform::Ios,
            "android" => Platform::Android,
            _ => Platform::Other,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceInfo {
    /// 客户端生成的设备 UUID（本地持久化）
    pub id: String,
    /// 用户可见设备名（用户自填，非指纹）
    pub name: String,
    pub platform: Platform,
}

/// 账户密钥材料（全部为密文或公开参数），服务端只做保管与下发。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountKeys {
    pub account_id: String,
    pub vault_id: String,
    pub kdf: KdfParams,
    /// Vault Key 被 WrapKey 封装后的密封盒
    pub vk_wrap: Bytes,
    pub vk_gen: i64,
    /// Vault Key 被 Recovery Code 派生密钥封装后的密封盒
    pub recovery_wrap: Bytes,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    /// Bearer token（服务端只存 SHA-256）
    pub token: String,
    pub expires_at: i64,
    pub device_id: String,
    pub device_approved: bool,
}

// ───────────────────────── 注册 / 登录 ─────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterRequest {
    pub email: String,
    pub keys: AccountKeys,
    pub srp_salt: Bytes,
    pub srp_verifier: Bytes,
    /// SHA-256(RecoveryCode 派生的 auth token)
    pub recovery_auth_hash: Bytes,
    pub device: DeviceInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginStartRequest {
    pub email: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginStartResponse {
    pub handshake_id: String,
    pub account_id: String,
    pub kdf: KdfParams,
    pub srp_salt: Bytes,
    pub b_pub: Bytes,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginFinishRequest {
    pub handshake_id: String,
    pub a_pub: Bytes,
    pub m1: Bytes,
    pub device: DeviceInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginFinishResponse {
    pub m2: Bytes,
    pub session: SessionInfo,
    /// 仅当设备已批准时下发
    pub keys: Option<AccountKeys>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifyDeviceRequest {
    pub code: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountResponse {
    pub email: String,
    pub keys: AccountKeys,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangeCredentialsRequest {
    pub kdf: KdfParams,
    pub srp_salt: Bytes,
    pub srp_verifier: Bytes,
    pub vk_wrap: Bytes,
    /// 客户端当前的 vk_gen，用于乐观锁
    pub expected_vk_gen: i64,
    /// 本地用恢复码重置后，恢复套件也随之轮换
    #[serde(default)]
    pub recovery_wrap: Option<Bytes>,
    #[serde(default)]
    pub recovery_auth_hash: Option<Bytes>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangeCredentialsResponse {
    pub vk_gen: i64,
}

// ───────────────────────── 恢复 ─────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryStartRequest {
    pub email: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryStartResponse {
    pub account_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryFetchRequest {
    pub email: String,
    pub recovery_auth: Bytes,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryCompleteRequest {
    pub email: String,
    pub recovery_auth: Bytes,
    pub kdf: KdfParams,
    pub srp_salt: Bytes,
    pub srp_verifier: Bytes,
    pub vk_wrap: Bytes,
    pub recovery_wrap: Bytes,
    pub recovery_auth_hash: Bytes,
    pub device: DeviceInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryCompleteResponse {
    pub session: SessionInfo,
    pub keys: AccountKeys,
}

// ───────────────────────── 设备与审计 ─────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceOut {
    pub id: String,
    pub name: String,
    pub platform: Platform,
    pub approved: bool,
    pub current: bool,
    pub created_at: i64,
    pub last_seen_at: Option<i64>,
    pub revoked_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEventOut {
    pub event: String,
    pub device_id: Option<String>,
    pub created_at: i64,
}

// ───────────────────────── 同步 ─────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushItem {
    pub id: String,
    /// login|card|note|identity（非敏感，用于客户端过滤）
    pub kind: String,
    /// 条目密封盒
    pub blob: Bytes,
    /// 客户端基于的服务端版本（新建为 0）
    pub base_revision: i64,
    /// 新版本号（> base_revision，与密文 AAD 绑定）
    pub revision: i64,
    pub deleted: bool,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PushRequest {
    pub items: Vec<PushItem>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PushStatus {
    Applied,
    Conflict,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PushResult {
    pub id: String,
    pub status: PushStatus,
    /// 服务端当前版本
    pub revision: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PushResponse {
    pub results: Vec<PushResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteItem {
    pub id: String,
    pub kind: String,
    pub blob: Bytes,
    pub revision: i64,
    pub deleted: bool,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PullResponse {
    pub items: Vec<RemoteItem>,
    /// 下一次拉取的游标（change_log.seq）
    pub cursor: i64,
    pub has_more: bool,
    /// 服务端当前的密钥封装代次；大于本地时说明其他设备改过主密码
    #[serde(default)]
    pub vk_gen: Option<i64>,
}

pub const PULL_PAGE_SIZE: i64 = 500;
pub const PUSH_MAX_ITEMS: usize = 500;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_roundtrip_as_base64() {
        let b = Bytes(vec![0, 1, 2, 255]);
        let s = serde_json::to_string(&b).unwrap();
        assert_eq!(s, "\"AAEC/w==\"");
        let back: Bytes = serde_json::from_str(&s).unwrap();
        assert_eq!(back, b);
        assert!(serde_json::from_str::<Bytes>("\"!!\"").is_err());
    }

    #[test]
    fn platform_roundtrip() {
        assert_eq!(serde_json::to_string(&Platform::Windows).unwrap(), "\"windows\"");
        assert_eq!(Platform::parse("android"), Platform::Android);
        assert_eq!(Platform::parse("toaster"), Platform::Other);
    }
}
