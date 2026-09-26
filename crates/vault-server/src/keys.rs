//! 服务端密钥：全部由 `server_secret` 经 HKDF-SHA256 域分离派生，不落盘、不硬编码。
//!
//! | 子密钥 | 用途 |
//! |---|---|
//! | email-index | HMAC-SHA256(规范化邮箱) → 登录查找索引（不可反查） |
//! | email-enc | AES-256-GCM 密封盒加密邮箱（发送通知时解密） |
//! | handshake | AES-256-GCM 密封盒加密 SRP 临时私钥 b（存数据库，支持多实例） |
//! | decoy | 未注册邮箱的伪造 KDF/SRP 参数（防账户枚举） |
//! | otp | HMAC 保存设备验证码 |

use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use vault_crypto::{sealed, Key32};

type HmacSha256 = Hmac<Sha256>;

pub struct ServerKeys {
    email_index: Key32,
    email_enc: Key32,
    handshake: Key32,
    decoy: Key32,
    otp: Key32,
}

fn derive(secret: &[u8], label: &str) -> anyhow::Result<Key32> {
    let hk = Hkdf::<Sha256>::new(Some(b"vaultone-server/v1"), secret);
    Ok(Key32::fill_with(|out| hk.expand(label.as_bytes(), out).map_err(|_| vault_crypto::CryptoError::Kdf))?)
}

pub fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

pub fn normalize_email(e: &str) -> String {
    e.trim().to_lowercase()
}

impl ServerKeys {
    pub fn new(secret: &[u8]) -> anyhow::Result<Self> {
        Ok(Self {
            email_index: derive(secret, "email-index")?,
            email_enc: derive(secret, "email-enc")?,
            handshake: derive(secret, "handshake")?,
            decoy: derive(secret, "decoy")?,
            otp: derive(secret, "otp")?,
        })
    }

    fn mac(key: &Key32, parts: &[&[u8]]) -> Vec<u8> {
        let mut m = <HmacSha256 as Mac>::new_from_slice(key.as_bytes()).expect("hmac key");
        for p in parts {
            m.update(&(p.len() as u64).to_be_bytes());
            m.update(p);
        }
        m.finalize().into_bytes().to_vec()
    }

    pub fn email_hash(&self, email: &str) -> Vec<u8> {
        Self::mac(&self.email_index, &[normalize_email(email).as_bytes()])
    }

    pub fn encrypt_email(&self, email: &str) -> anyhow::Result<Vec<u8>> {
        Ok(sealed::seal(&self.email_enc, normalize_email(email).as_bytes(), b"vaultone-server/email")?)
    }

    pub fn decrypt_email(&self, blob: &[u8]) -> anyhow::Result<String> {
        let raw = sealed::open(&self.email_enc, blob, b"vaultone-server/email")?;
        Ok(String::from_utf8(raw.to_vec())?)
    }

    pub fn seal_handshake(&self, handshake_id: &str, b: &[u8]) -> anyhow::Result<Vec<u8>> {
        Ok(sealed::seal(&self.handshake, b, handshake_id.as_bytes())?)
    }

    pub fn open_handshake(&self, handshake_id: &str, blob: &[u8]) -> anyhow::Result<zeroize::Zeroizing<Vec<u8>>> {
        Ok(sealed::open(&self.handshake, blob, handshake_id.as_bytes())?)
    }

    /// 为未注册邮箱生成确定性的伪造值，使响应与真实账户不可区分。
    pub fn decoy(&self, email: &str, label: &str, len: usize) -> Vec<u8> {
        let mut out = Vec::with_capacity(len);
        let mut counter = 0u32;
        while out.len() < len {
            out.extend(Self::mac(&self.decoy, &[normalize_email(email).as_bytes(), label.as_bytes(), &counter.to_be_bytes()]));
            counter += 1;
        }
        out.truncate(len);
        out
    }

    pub fn otp_hash(&self, user_id: &str, device_id: &str, code: &str) -> Vec<u8> {
        Self::mac(&self.otp, &[user_id.as_bytes(), device_id.as_bytes(), code.as_bytes()])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn email_roundtrip_and_index() {
        let k = ServerKeys::new(&[7u8; 32]).unwrap();
        assert_eq!(k.email_hash("A@B.com "), k.email_hash("a@b.com"));
        let blob = k.encrypt_email("a@b.com").unwrap();
        assert!(!String::from_utf8_lossy(&blob).contains("a@b.com"));
        assert_eq!(k.decrypt_email(&blob).unwrap(), "a@b.com");
        let other = ServerKeys::new(&[8u8; 32]).unwrap();
        assert!(other.decrypt_email(&blob).is_err());
    }

    #[test]
    fn decoy_is_deterministic() {
        let k = ServerKeys::new(&[7u8; 32]).unwrap();
        assert_eq!(k.decoy("x@y.z", "salt", 32), k.decoy("X@y.z", "salt", 32));
        assert_ne!(k.decoy("x@y.z", "salt", 32), k.decoy("x@y.z", "kdf", 32));
        assert_eq!(k.decoy("x@y.z", "v", 384).len(), 384);
    }
}
