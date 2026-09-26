use thiserror::Error;

pub type Result<T> = std::result::Result<T, VaultError>;

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
    #[error("条目不存在: {0}")]
    ItemNotFound(String),
    #[error("数据完整性校验失败")]
    Integrity,
    #[error("格式错误: {0}")]
    Format(String),
    #[error("参数不合法: {0}")]
    InvalidInput(String),
    #[error("密码学运算失败")]
    Crypto,
    #[error("存储错误: {0}")]
    Storage(#[from] rusqlite::Error),
    #[error("序列化错误: {0}")]
    Serde(#[from] serde_json::Error),
}
