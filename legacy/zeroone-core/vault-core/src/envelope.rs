//! 条目密文信封（计划书 §4.3），写入 `items.blob`。
//!
//! ```json
//! {"v":1,"alg":"xchacha20-poly1305","kid":"…","wrappedKey":"…","nonce":"…","ct":"…","aad":"item|vault|rev"}
//! ```
//!
//! AAD 绑定条目 ID / 库 ID / 版本号，防止密文块被跨条目重放或回滚到旧版本。

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::crypto::{aead_decrypt, aead_encrypt, pad, unpad, unwrap_key, wrap_key};
use crate::secret::Key32;
use crate::{Result, VaultError};

pub const ENVELOPE_VERSION: u32 = 1;
pub const ALG_XCHACHA: &str = "xchacha20-poly1305";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Envelope {
    pub v: u32,
    pub alg: String,
    /// 封装 Item Key 所用 Vault Key 的标识（`<vault_id>#<代次>`）
    pub kid: String,
    pub wrapped_key: String,
    pub nonce: String,
    pub ct: String,
    pub aad: String,
}

pub fn item_aad(item_id: &str, vault_id: &str, revision: i64) -> String {
    format!("{item_id}|{vault_id}|{revision}")
}

impl Envelope {
    /// 生成新的随机 Item Key 并加密明文。
    pub fn seal(vault_key: &Key32, kid: &str, aad: &str, plaintext: &[u8]) -> Result<Self> {
        let item_key = Key32::random()?;
        let wrapped = wrap_key(vault_key, &item_key)?;
        let padded = pad(plaintext);
        let (nonce, ct) = aead_encrypt(&item_key, &padded, aad.as_bytes())?;
        Ok(Self {
            v: ENVELOPE_VERSION,
            alg: ALG_XCHACHA.into(),
            kid: kid.into(),
            wrapped_key: B64.encode(wrapped),
            nonce: B64.encode(nonce),
            ct: B64.encode(ct),
            aad: aad.into(),
        })
    }

    /// 解密。`expected_aad` 由调用方根据存储位置重新计算，而不是信任信封里自带的值。
    pub fn open(&self, vault_key: &Key32, expected_aad: &str) -> Result<Zeroizing<Vec<u8>>> {
        if self.v != ENVELOPE_VERSION || self.alg != ALG_XCHACHA {
            return Err(VaultError::Format(format!("不支持的信封版本 v{} / {}", self.v, self.alg)));
        }
        if self.aad != expected_aad {
            return Err(VaultError::Integrity);
        }
        let decode = |s: &str| B64.decode(s).map_err(|_| VaultError::Integrity);
        let item_key = unwrap_key(vault_key, &decode(&self.wrapped_key)?)?;
        let padded = aead_decrypt(&item_key, &decode(&self.nonce)?, &decode(&self.ct)?, expected_aad.as_bytes())?;
        unpad(padded)
    }

    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(self)?)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        serde_json::from_slice(bytes).map_err(|_| VaultError::Integrity)
    }

    /// 密文字节长度（已 padding 对齐），对应服务端 `items.blob_bytes`。
    pub fn ciphertext_len(&self) -> usize {
        B64.decode(&self.ct).map(|v| v.len()).unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open_roundtrip() {
        let vk = Key32::random().unwrap();
        let aad = item_aad("i1", "v1", 3);
        let env = Envelope::seal(&vk, "v1#1", &aad, b"{\"title\":\"x\"}").unwrap();
        assert_eq!(&*env.open(&vk, &aad).unwrap(), b"{\"title\":\"x\"}");
        // 每条目独立 Item Key 与 nonce
        let env2 = Envelope::seal(&vk, "v1#1", &aad, b"{\"title\":\"x\"}").unwrap();
        assert_ne!(env.wrapped_key, env2.wrapped_key);
        assert_ne!(env.nonce, env2.nonce);
    }

    #[test]
    fn rejects_replay_to_other_item_or_revision() {
        let vk = Key32::random().unwrap();
        let env = Envelope::seal(&vk, "k", &item_aad("i1", "v1", 1), b"secret").unwrap();
        assert!(env.open(&vk, &item_aad("i2", "v1", 1)).is_err());
        assert!(env.open(&vk, &item_aad("i1", "v1", 2)).is_err());

        // 篡改信封里的 aad 字段让它"看起来"匹配，也无法通过 AEAD 校验
        let mut forged = env.clone();
        forged.aad = item_aad("i2", "v1", 1);
        assert!(forged.open(&vk, &item_aad("i2", "v1", 1)).is_err());
    }

    #[test]
    fn ciphertext_is_padded() {
        let vk = Key32::random().unwrap();
        let short = Envelope::seal(&vk, "k", "a", b"x").unwrap();
        let longer = Envelope::seal(&vk, "k", "a", &[b'y'; 200]).unwrap();
        // 16 字节 Poly1305 tag
        assert_eq!(short.ciphertext_len(), 256 + 16);
        assert_eq!(short.ciphertext_len(), longer.ciphertext_len());
    }

    #[test]
    fn wrong_vault_key_fails() {
        let vk = Key32::random().unwrap();
        let env = Envelope::seal(&vk, "k", "a", b"x").unwrap();
        assert!(env.open(&Key32::random().unwrap(), "a").is_err());
    }
}
