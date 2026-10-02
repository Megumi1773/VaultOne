use thiserror::Error;

pub type Result<T> = std::result::Result<T, CryptoError>;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CryptoError {
    /// 认证标签校验失败、密文被篡改、密钥错误或格式损坏。刻意不细分，避免成为解密预言机。
    #[error("数据完整性校验失败")]
    Integrity,
    #[error("参数不合法: {0}")]
    InvalidInput(String),
    #[error("不支持的格式: {0}")]
    Unsupported(String),
    #[error("密钥派生失败")]
    Kdf,
    #[error("受保护内存分配失败")]
    Memory,
    #[error("SRP 认证失败")]
    SrpAuth,
    /// 两个 Secret Key 的字节内容不一致（备份二次确认用；不区分格式错误与内容不符）。
    #[error("Secret Key 不一致")]
    SecretKeyMismatch,
}
