use thiserror::Error;
use vault_crypto::CryptoError;

pub type Result<T> = std::result::Result<T, VaultError>;

/// 内核统一错误类型。`code()` 为稳定的机器可读错误码，UI 据此做本地化提示。
#[derive(Debug, Error)]
pub enum VaultError {
    /// 主密码或 Secret Key 错误。刻意不区分两者，避免给攻击者提供信号。
    #[error("主密码或 Secret Key 不正确")]
    InvalidCredentials,
    #[error("恢复码不正确")]
    InvalidRecoveryCode,
    #[error("保险库已锁定")]
    Locked,
    #[error("保险库尚未初始化")]
    NotInitialized,
    #[error("保险库已初始化")]
    AlreadyInitialized,
    #[error("条目不存在")]
    ItemNotFound,
    #[error("数据完整性校验失败")]
    Integrity,
    #[error("参数不合法: {0}")]
    InvalidInput(String),
    #[error("密码学运算失败")]
    Crypto(#[source] CryptoError),
    #[error("存储错误: {0}")]
    Storage(#[from] rusqlite::Error),
    #[error("序列化错误: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("网络错误: {0}")]
    Network(String),
    #[error("服务端错误 [{code}]: {message}")]
    Server { status: u16, code: String, message: String },
    #[error("尚未连接同步服务")]
    NotConnected,
    #[error("当前设备尚未获得批准，请输入邮件验证码或在已登录设备上批准")]
    DeviceNotApproved,
}

impl VaultError {
    pub fn code(&self) -> &str {
        match self {
            VaultError::InvalidCredentials => "invalid_credentials",
            VaultError::InvalidRecoveryCode => "invalid_recovery_code",
            VaultError::Locked => "locked",
            VaultError::NotInitialized => "not_initialized",
            VaultError::AlreadyInitialized => "already_initialized",
            VaultError::ItemNotFound => "not_found",
            VaultError::Integrity => "integrity",
            VaultError::InvalidInput(_) => "invalid_input",
            VaultError::Crypto(_) => "crypto",
            VaultError::Storage(_) => "storage",
            VaultError::Serde(_) => "serde",
            VaultError::Network(_) => "network",
            VaultError::Server { code, .. } => code,
            VaultError::NotConnected => "not_connected",
            VaultError::DeviceNotApproved => "device_not_approved",
        }
    }
}

impl From<CryptoError> for VaultError {
    fn from(e: CryptoError) -> Self {
        match e {
            CryptoError::Integrity => VaultError::Integrity,
            CryptoError::InvalidInput(m) => VaultError::InvalidInput(m),
            other => VaultError::Crypto(other),
        }
    }
}
