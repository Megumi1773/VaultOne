//! VaultOne 客户端内核（vault-core）
//!
//! | 模块 | 职责 | 复用的成熟库 |
//! |---|---|---|
//! | [`vault`] | 建号、解锁、快速解锁、条目 CRUD、改密、恢复 | `vault-crypto` |
//! | [`envelope`] | 条目密文信封（每条目独立 Item Key，AES-256-GCM） | `aes-gcm` / `hkdf` |
//! | [`store`] | 本地 SQLite 真相源、离线队列 | `rusqlite`（bundled SQLite） |
//! | [`sync`] | SRP 登录、设备批准、增量同步、云端恢复 | `reqwest` / `srp` |
//! | [`merge`] | **自研**：零知识字段级三方合并 | — |
//! | [`urlmatch`] | **自研策略**：防钓鱼自动填充匹配 | `psl` / `url` |
//! | [`generator`] | 随机密码 / 口令短语 | `passwords` / `eff-wordlist` |
//! | [`totp`] | TOTP | `totp-rs` |
//! | [`security`] | 弱密码 / 重复 / 泄露检测 | `zxcvbn` / HIBP k-匿名 |

pub mod envelope;
pub mod error;
pub mod generator;
pub mod item;
pub mod merge;
pub mod security;
pub mod store;
pub mod sync;
pub mod totp;
pub mod urlmatch;
pub mod vault;

pub use error::{Result, VaultError};
pub use vault::Vault;
pub use vault_crypto::kdf::KdfParams;
