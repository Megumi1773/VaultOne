//! Dart 可见 API（由 flutter_rust_bridge_codegen 生成绑定）。
//!
//! - 返回 `Result<T, BridgeError>` 的函数在 Dart 侧抛出 `BridgeError`（含稳定错误码 `code`）；
//! - 非 `#[frb(sync)]` 函数在 frb 线程池执行，Argon2id / 网络请求不会阻塞 UI 线程；
//! - 条目明文以 JSON 字符串跨越边界（schema 由 Rust `ItemData` 的 serde 定义唯一确定）。

pub mod browser;
pub mod clipboard;
pub mod cloud_account;
pub mod conflicts;
pub mod feedback;
pub mod logging;
pub mod sync;
pub mod tools;
pub mod vault;

use vault_core::VaultError;

/// Dart 侧异常。`code` 为稳定错误码，UI 据此本地化；`message` 为可直接展示的中文说明。
#[derive(Debug, Clone)]
pub struct BridgeError {
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<VaultError> for BridgeError {
    fn from(e: VaultError) -> Self {
        match &e {
            VaultError::Storage(_) | VaultError::Serde(_) | VaultError::Crypto(_) => {
                tracing::error!(target: "bridge", code = e.code(), error = %e, "operation failed");
            }
            _ => tracing::debug!(target: "bridge", code = e.code(), "operation rejected"),
        }
        let message = match &e {
            VaultError::Server { message, .. } => message.clone(),
            VaultError::Network(_) => "无法连接同步服务，请检查网络后重试".into(),
            VaultError::Storage(_) => "本地数据库读写失败".into(),
            _ => e.to_string(),
        };
        BridgeError { code: e.code().to_string(), message }
    }
}

impl From<serde_json::Error> for BridgeError {
    fn from(e: serde_json::Error) -> Self {
        BridgeError { code: "invalid_input".into(), message: format!("数据格式错误: {e}") }
    }
}

/// 密码学层的直接错误（不经过 `VaultError` 包装的调用，如备份二次确认）。
impl From<vault_crypto::CryptoError> for BridgeError {
    fn from(e: vault_crypto::CryptoError) -> Self {
        BridgeError::from(VaultError::from(e))
    }
}

pub type BridgeResult<T> = Result<T, BridgeError>;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
