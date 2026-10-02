//! VaultOne 线协议（JSON over HTTPS）。
//!
//! 保险库同步字段是非敏感元数据或客户端 AES-256-GCM 密文；[`feedback`] 是另行同意的客服可读文本。
//! Rust 客户端共享本 crate 的线协议定义，Java 服务端通过交叉测试对齐。

pub mod feedback;

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
    /// 昵称（§8.2）。旧服务端不返回该字段，因此必须 `serde(default)`——否则接旧服务端会直接反序列化失败。
    #[serde(default)]
    pub nickname: String,
    /// 头像地址（§8.1）。同上，缺省为空。
    #[serde(default)]
    pub avatar: String,
    /// 注册时间（Unix 秒，§8.1）。恢复流程复用本类型时不返回该字段，缺省为 0。
    #[serde(default)]
    pub created_at: i64,
}

/// 更新账户资料（§8.2）。两个字段都是全量替换。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateProfileRequest {
    pub nickname: String,
    pub avatar: String,
}

/// 账户资料（§8.1）。从 [`AccountResponse`] 里抽出来的三个展示字段。
///
/// 单独一个类型是因为客户端要把它缓存到本机：缓存整份 `AccountResponse` 会把密钥材料也写进去，
/// 而密钥材料有它自己的存放方式，不该顺手多存一份。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountProfile {
    pub nickname: String,
    pub avatar: String,
    /// 注册时间（Unix 秒）。旧服务端不返回时为 0。
    pub created_at: i64,
}

impl AccountResponse {
    /// 取出资料部分。
    pub fn profile(&self) -> AccountProfile {
        AccountProfile { nickname: self.nickname.clone(), avatar: self.avatar.clone(), created_at: self.created_at }
    }
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

/// 浏览器扩展 ⇄ 桌面端的本地通道约定（Native Messaging 宿主与桌面端共用，二者必须一致）。
/// 消息格式与认证见 `vault_core::browser`。本地套接字上为"一行一条 JSON"。
pub mod browser_ipc {
    /// Native Messaging 宿主名（扩展 `chrome.runtime.connectNative` 使用）
    pub const NATIVE_HOST_NAME: &str = "app.vaultone.browser";
    /// macOS：沙盒应用与（非沙盒）宿主共享套接字的 App Group 容器
    pub const MACOS_APP_GROUP: &str = "group.app.vaultone";
    /// 单条消息上限（Chrome 发往宿主的上限为 4 GiB，这里按业务需要收紧）
    pub const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
    /// 允许连接宿主的扩展 ID（写入宿主清单的 `allowed_origins`）。第一项由 `extension/manifest.json`
    /// 中的 `key` 固定，用于开发期"加载已解压的扩展"；上架 Chrome 应用店 / Edge 加载项后把商店分配的 ID 追加到这里。
    pub const EXTENSION_IDS: &[&str] = &["pginfajjjgcjmijmddppkbhejjjcealc"];

    /// 本地通道地址。Windows 为命名管道名（不含 `\\.\pipe\` 前缀，按用户名区分）；其余平台为套接字文件路径。
    /// 环境变量 `VAULTONE_BROWSER_ENDPOINT` 可覆盖（仅用于测试与排障）。
    pub fn endpoint() -> String {
        if let Ok(ep) = std::env::var("VAULTONE_BROWSER_ENDPOINT") {
            if !ep.is_empty() {
                return ep;
            }
        }
        #[cfg(windows)]
        {
            let user: String =
                std::env::var("USERNAME").unwrap_or_default().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
            format!("vaultone-browser-{user}")
        }
        #[cfg(target_os = "macos")]
        {
            // 沙盒内 HOME 指向 ~/Library/Containers/<bundle>/Data，取其前缀得到真实主目录
            let home = std::env::var("HOME").unwrap_or_default();
            let home = home.split("/Library/Containers/").next().unwrap_or_default();
            format!("{home}/Library/Group Containers/{MACOS_APP_GROUP}/browser.sock")
        }
        #[cfg(all(unix, not(target_os = "macos")))]
        {
            match std::env::var("XDG_RUNTIME_DIR") {
                Ok(dir) if !dir.is_empty() => format!("{dir}/vaultone-browser.sock"),
                _ => format!("{}/.vaultone/browser.sock", std::env::var("HOME").unwrap_or_default()),
            }
        }
    }
}

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

    #[test]
    fn account_response_tolerates_old_servers_without_profile_fields() {
        // 旧服务端（以及恢复流程的 keysOnly）不返回资料字段：必须能解析，不能因为多了三个字段就
        // 把「连旧服务端」变成硬失败。
        let keys = AccountKeys {
            account_id: "a".into(),
            vault_id: "v".into(),
            kdf: KdfParams { alg: "argon2id".into(), m: 19456, t: 2, p: 1, salt: "AAAAAAAAAAAAAAAAAAAAAA==".into() },
            vk_wrap: Bytes(vec![1]),
            vk_gen: 1,
            recovery_wrap: Bytes(vec![2]),
        };
        let json = serde_json::json!({ "email": "a@b.c", "keys": keys });
        let acc: AccountResponse = serde_json::from_value(json).unwrap();
        assert_eq!(acc.nickname, "");
        assert_eq!(acc.avatar, "");
        assert_eq!(acc.created_at, 0);
        assert_eq!(acc.profile(), AccountProfile::default());

        // 新服务端返回资料时正常解析。
        let full = serde_json::json!({
            "email": "a@b.c", "keys": keys, "nickname": "阿澈", "avatar": "https://e.com/a.png", "created_at": 1700000000
        });
        let acc: AccountResponse = serde_json::from_value(full).unwrap();
        assert_eq!(acc.profile().nickname, "阿澈");
        assert_eq!(acc.profile().created_at, 1700000000);
    }
}
