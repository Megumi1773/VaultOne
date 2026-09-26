//! ZeroOne 加密内核（vault-core）
//!
//! 密钥层级（见计划书 §3.2）：
//!
//! ```text
//! 主密码 ──Argon2id(salt)──┐
//!                          ├─ XOR ─> MUK ──HKDF-SHA512──┬─ info=auth ─> AuthKey（SRP-6a，M2）
//! Secret Key ──HKDF(acct)──┘                            └─ info=wrap ─> KeyWrapKey
//! KeyWrapKey ──AES-256-KW──> Vault Key（随机 256-bit）
//! Vault Key  ──AES-256-KW──> Item Key（每条目随机 256-bit）
//! Item Key   ──XChaCha20-Poly1305(aad=item|vault|rev)──> 条目密文（padding 至 256B）
//! ```
//!
//! 所有密钥材料只存在于本 crate 的 [`secret::Key32`] 中：堆上分配、`mlock` 防换页、drop 时清零。

pub mod crypto;
pub mod envelope;
pub mod error;
pub mod generator;
pub mod item;
pub mod kdf;
pub mod keys;
pub mod secret;
pub mod security;
pub mod store;
pub mod totp;
pub mod vault;

pub use error::{Result, VaultError};
