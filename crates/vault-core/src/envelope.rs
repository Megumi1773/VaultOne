//! 条目密文信封（计划书 §4.3），写入 `items.blob` 并原样同步到服务端。
//!
//! ```json
//! {"v":2,"alg":"aes-256-gcm","wrappedKey":"<密封盒 b64>","ct":"<密封盒 b64>"}
//! ```
//!
//! - `wrappedKey`：本次随机生成的 Item Key，被 Vault Key 以密封盒封装，AAD = `vaultone/item-key|<item>|<vault>`
//! - `ct`：条目 JSON 经 256 字节对齐填充后，被 Item Key 以密封盒加密，AAD = `vaultone/item|<item>|<vault>|<rev>`
//!
//! 两个密封盒各自带独立的 32 字节随机盐与 12 字节随机 IV。AAD 不存储在信封里，
//! 而是由读取方根据存储位置重新计算——密文块被跨条目搬运或回滚到旧版本都会校验失败。

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use vault_crypto::pad::{pad, unpad};
use vault_crypto::{sealed, Key32};
use zeroize::Zeroizing;

use crate::{Result, VaultError};

pub const ENVELOPE_VERSION: u32 = 2;
pub const ALG: &str = "aes-256-gcm";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Envelope {
    pub v: u32,
    pub alg: String,
    pub wrapped_key: String,
    pub ct: String,
}

fn key_aad(item_id: &str, vault_id: &str) -> Vec<u8> {
    format!("vaultone/item-key|{item_id}|{vault_id}").into_bytes()
}

fn content_aad(item_id: &str, vault_id: &str, revision: i64) -> Vec<u8> {
    format!("vaultone/item|{item_id}|{vault_id}|{revision}").into_bytes()
}

impl Envelope {
    /// 生成新的随机 Item Key 并加密明文。
    pub fn seal(vault_key: &Key32, item_id: &str, vault_id: &str, revision: i64, plaintext: &[u8]) -> Result<Self> {
        let item_key = Key32::random()?;
        let wrapped = sealed::wrap_key(vault_key, &item_key, &key_aad(item_id, vault_id))?;
        let ct = sealed::seal(&item_key, &pad(plaintext), &content_aad(item_id, vault_id, revision))?;
        Ok(Self { v: ENVELOPE_VERSION, alg: ALG.into(), wrapped_key: B64.encode(wrapped), ct: B64.encode(ct) })
    }

    pub fn open(&self, vault_key: &Key32, item_id: &str, vault_id: &str, revision: i64) -> Result<Zeroizing<Vec<u8>>> {
        if self.v != ENVELOPE_VERSION || self.alg != ALG {
            return Err(VaultError::InvalidInput(format!("不支持的信封版本 v{} / {}", self.v, self.alg)));
        }
        let decode = |s: &str| B64.decode(s).map_err(|_| VaultError::Integrity);
        let item_key = sealed::unwrap_key(vault_key, &decode(&self.wrapped_key)?, &key_aad(item_id, vault_id))?;
        let padded = sealed::open(&item_key, &decode(&self.ct)?, &content_aad(item_id, vault_id, revision))?;
        Ok(unpad(padded)?)
    }

    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(self)?)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        serde_json::from_slice(bytes).map_err(|_| VaultError::Integrity)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_fresh_keys() {
        let vk = Key32::random().unwrap();
        let a = Envelope::seal(&vk, "i1", "v1", 3, b"{\"title\":\"x\"}").unwrap();
        assert_eq!(&*a.open(&vk, "i1", "v1", 3).unwrap(), b"{\"title\":\"x\"}");
        let b = Envelope::seal(&vk, "i1", "v1", 3, b"{\"title\":\"x\"}").unwrap();
        assert_ne!(a.wrapped_key, b.wrapped_key);
        assert_ne!(a.ct, b.ct);
    }

    #[test]
    fn rejects_replay_to_other_item_vault_or_revision() {
        let vk = Key32::random().unwrap();
        let env = Envelope::seal(&vk, "i1", "v1", 1, b"secret").unwrap();
        assert!(env.open(&vk, "i2", "v1", 1).is_err());
        assert!(env.open(&vk, "i1", "v2", 1).is_err());
        assert!(env.open(&vk, "i1", "v1", 2).is_err());
        assert!(env.open(&Key32::random().unwrap(), "i1", "v1", 1).is_err());
    }

    #[test]
    fn ciphertext_is_length_padded() {
        let vk = Key32::random().unwrap();
        let short = Envelope::seal(&vk, "i", "v", 1, b"x").unwrap();
        let longer = Envelope::seal(&vk, "i", "v", 1, &[b'y'; 200]).unwrap();
        assert_eq!(short.ct.len(), longer.ct.len());
        let raw = B64.decode(&short.ct).unwrap();
        assert_eq!(raw.len(), 256 + sealed::OVERHEAD);
    }
}
