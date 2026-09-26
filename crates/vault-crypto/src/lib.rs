//! VaultOne 密码学编排层（vault-crypto）
//!
//! 本 crate **不实现任何密码学算法**，只把经过审计的 RustCrypto 原语按固定规则组合：
//!
//! | 用途 | 原语（crate） |
//! |---|---|
//! | 对称加密（唯一允许的模式） | AES-256-GCM（`aes-gcm`） |
//! | 每次加密的一次性子密钥 | HKDF-SHA256（`hkdf`），32 字节随机盐 |
//! | 主密码派生 | Argon2id（`argon2`），32 字节随机盐 |
//! | 口令认证 | SRP-6a / RFC 5054 3072-bit 群（`srp`） |
//! | 随机数 | 操作系统 CSPRNG（`rand::rngs::OsRng`） |
//! | 密钥内存 | `memsec`（mlock/VirtualLock + 保护页）+ `zeroize` |
//!
//! 全部敏感数据都经 [`sealed`] 模块的"密封盒"格式加密：每次加密生成新的 32 字节盐与
//! 12 字节 IV，二者随密文一同存储并纳入 GCM 认证标签校验。详见 `docs/03-加密规范.md`。

pub mod error;
pub mod kdf;
pub mod keys;
pub mod pad;
pub mod sealed;
pub mod secret;
pub mod srp6a;

pub use error::{CryptoError, Result};
pub use secret::Key32;
