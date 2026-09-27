//! 密封盒（Sealed Box）——VaultOne 唯一的对称加密格式。
//!
//! ```text
//! 偏移   长度  字段
//! 0      1     version = 0x01
//! 1      1     suite   = 0x01  (AES-256-GCM + HKDF-SHA256)
//! 2      32    salt    每次加密随机生成（OsRng）
//! 34     12    iv      每次加密随机生成（OsRng）
//! 46     n     ciphertext
//! 46+n   16    GCM 认证标签
//! ```
//!
//! 加密流程：
//! 1. `salt ← OsRng(32)`，`iv ← OsRng(12)`
//! 2. `k_msg = HKDF-SHA256(ikm = 长期密钥, salt, info = "vaultone/v1/sealed")`
//! 3. `aad' = header(version‖suite‖salt‖iv) ‖ len(aad) ‖ aad`
//! 4. `ct‖tag = AES-256-GCM(k_msg, iv, plaintext, aad')`
//!
//! 头部（含盐与 IV）作为 AAD 进入认证标签，任何一位被篡改都会导致解密失败。
//! 每条消息使用由随机盐派生的一次性子密钥，因此即使同一长期密钥加密海量数据，
//! 也不存在 96-bit 随机 IV 的生日界（2^32 条消息）问题。

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::secret::{random_bytes, Key32};
use crate::{CryptoError, Result};

pub const VERSION: u8 = 0x01;
pub const SUITE_AES256GCM_HKDF_SHA256: u8 = 0x01;
pub const SALT_LEN: usize = 32;
pub const IV_LEN: usize = 12;
pub const TAG_LEN: usize = 16;
pub const HEADER_LEN: usize = 2 + SALT_LEN + IV_LEN;
/// 密封盒相对明文的固定开销
pub const OVERHEAD: usize = HEADER_LEN + TAG_LEN;

const INFO: &[u8] = b"vaultone/v1/sealed";

fn message_key(key: &Key32, salt: &[u8]) -> Result<Key32> {
    let hk = Hkdf::<Sha256>::new(Some(salt), key.as_bytes());
    Key32::fill_with(|out| hk.expand(INFO, out).map_err(|_| CryptoError::Kdf))
}

fn full_aad(header: &[u8], aad: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(header.len() + 8 + aad.len());
    v.extend_from_slice(header);
    v.extend_from_slice(&(aad.len() as u64).to_be_bytes());
    v.extend_from_slice(aad);
    v
}

/// 加密。`aad` 为调用方的上下文绑定数据（不加密但受认证），用于防跨条目重放。
pub fn seal(key: &Key32, plaintext: &[u8], aad: &[u8]) -> Result<Vec<u8>> {
    let salt = random_bytes::<SALT_LEN>();
    let iv = random_bytes::<IV_LEN>();
    let mut out = Vec::with_capacity(OVERHEAD + plaintext.len());
    out.push(VERSION);
    out.push(SUITE_AES256GCM_HKDF_SHA256);
    out.extend_from_slice(&salt);
    out.extend_from_slice(&iv);

    let k = message_key(key, &salt)?;
    let cipher = Aes256Gcm::new(k.as_bytes().into());
    let ct = cipher
        .encrypt(Nonce::from_slice(&iv), Payload { msg: plaintext, aad: &full_aad(&out, aad) })
        .map_err(|_| CryptoError::Integrity)?;
    out.extend_from_slice(&ct);
    Ok(out)
}

/// 解密并校验认证标签。任何失败（密钥错、AAD 不符、篡改、截断）都返回 [`CryptoError::Integrity`]。
pub fn open(key: &Key32, sealed: &[u8], aad: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if sealed.len() < OVERHEAD {
        return Err(CryptoError::Integrity);
    }
    if sealed[0] != VERSION {
        return Err(CryptoError::Unsupported(format!("sealed box v{}", sealed[0])));
    }
    if sealed[1] != SUITE_AES256GCM_HKDF_SHA256 {
        return Err(CryptoError::Unsupported(format!("suite {}", sealed[1])));
    }
    let (header, body) = sealed.split_at(HEADER_LEN);
    let salt = &header[2..2 + SALT_LEN];
    let iv = &header[2 + SALT_LEN..];
    let k = message_key(key, salt)?;
    let cipher = Aes256Gcm::new(k.as_bytes().into());
    cipher
        .decrypt(Nonce::from_slice(iv), Payload { msg: body, aad: &full_aad(header, aad) })
        .map(Zeroizing::new)
        .map_err(|_| CryptoError::Integrity)
}

/// 用 `kek` 封装一个 256-bit 密钥（密钥层级中的每一级都用它）。
pub fn wrap_key(kek: &Key32, key: &Key32, aad: &[u8]) -> Result<Vec<u8>> {
    seal(kek, key.as_bytes(), aad)
}

pub fn unwrap_key(kek: &Key32, wrapped: &[u8], aad: &[u8]) -> Result<Key32> {
    let raw = open(kek, wrapped, aad)?;
    Key32::from_slice(&raw).map_err(|_| CryptoError::Integrity)
}

/// 从密封盒中读出盐与 IV（用于审计/测试，不涉及秘密）。
pub fn inspect(sealed: &[u8]) -> Option<(&[u8], &[u8])> {
    (sealed.len() >= OVERHEAD).then(|| (&sealed[2..2 + SALT_LEN], &sealed[2 + SALT_LEN..HEADER_LEN]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let k = Key32::random().unwrap();
        let ct = seal(&k, b"hello", b"ctx").unwrap();
        assert_eq!(ct.len(), OVERHEAD + 5);
        assert_eq!(&*open(&k, &ct, b"ctx").unwrap(), b"hello");
        let empty = seal(&k, b"", b"").unwrap();
        assert_eq!(&*open(&k, &empty, b"").unwrap(), b"");
    }

    #[test]
    fn fresh_salt_and_iv_every_time() {
        let k = Key32::random().unwrap();
        let a = seal(&k, b"same", b"").unwrap();
        let b = seal(&k, b"same", b"").unwrap();
        let (sa, ia) = inspect(&a).unwrap();
        let (sb, ib) = inspect(&b).unwrap();
        assert_ne!(sa, sb);
        assert_ne!(ia, ib);
        assert_ne!(a, b);
        assert_eq!(sa.len(), 32);
        assert_eq!(ia.len(), 12);
    }

    #[test]
    fn every_byte_is_authenticated() {
        let k = Key32::random().unwrap();
        let ct = seal(&k, b"secret payload", b"aad").unwrap();
        for i in 0..ct.len() {
            let mut t = ct.clone();
            t[i] ^= 0x01;
            assert!(open(&k, &t, b"aad").is_err(), "byte {i} not authenticated");
        }
        assert!(open(&k, &ct[..ct.len() - 1], b"aad").is_err());
    }

    #[test]
    fn aad_and_key_binding() {
        let k = Key32::random().unwrap();
        let ct = seal(&k, b"x", b"item-1").unwrap();
        assert_eq!(open(&k, &ct, b"item-2"), Err(CryptoError::Integrity));
        assert_eq!(open(&Key32::random().unwrap(), &ct, b"item-1"), Err(CryptoError::Integrity));
    }

    #[test]
    fn aad_length_prefix_prevents_ambiguity() {
        // header‖aad 的拼接不能被"挪动边界"伪造
        let k = Key32::random().unwrap();
        let ct = seal(&k, b"x", b"ab").unwrap();
        assert!(open(&k, &ct, b"a").is_err());
        assert!(open(&k, &ct, b"abc").is_err());
    }

    #[test]
    fn wrap_unwrap() {
        let kek = Key32::random().unwrap();
        let key = Key32::random().unwrap();
        let w = wrap_key(&kek, &key, b"vault").unwrap();
        assert_eq!(unwrap_key(&kek, &w, b"vault").unwrap(), key);
        assert!(unwrap_key(&kek, &w, b"other").is_err());
    }

    #[test]
    fn rejects_unknown_version_and_short_input() {
        let k = Key32::random().unwrap();
        let mut ct = seal(&k, b"x", b"").unwrap();
        ct[0] = 9;
        assert!(matches!(open(&k, &ct, b""), Err(CryptoError::Unsupported(_))));
        assert_eq!(open(&k, &[1u8; 10], b""), Err(CryptoError::Integrity));
    }

    #[test]
    fn known_answer_decrypts_with_reference_primitives() {
        // 用原语手工复算，保证格式说明与实现一致（第三方可据 docs/03 独立实现解密）
        let k = Key32::from_slice(&[0x42; 32]).unwrap();
        let ct = seal(&k, b"interop", b"A").unwrap();
        let (salt, iv) = inspect(&ct).unwrap();
        let hk = Hkdf::<Sha256>::new(Some(salt), &[0x42; 32]);
        let mut mk = [0u8; 32];
        hk.expand(b"vaultone/v1/sealed", &mut mk).unwrap();
        let mut aad = ct[..HEADER_LEN].to_vec();
        aad.extend_from_slice(&1u64.to_be_bytes());
        aad.extend_from_slice(b"A");
        let pt = Aes256Gcm::new((&mk).into()).decrypt(Nonce::from_slice(iv), Payload { msg: &ct[HEADER_LEN..], aad: &aad }).unwrap();
        assert_eq!(pt, b"interop");
    }

    /// 固定向量（docs/03 §2.4 公布，并已用 Python `cryptography` 独立实现验证）：格式一旦变化即失败。
    #[test]
    fn fixed_vector_from_spec() {
        const VECTOR: &str = "01014f404cc75de75ce8328cc1e76376b11224ec0b013f6b03d8781eada21fe81287c5eb701b05a15a6769a987b536ea\
                              09a9ee316ee9adfd705c406758465b86b31079e6c1425a0ad7ad7bb37c38c67ec7b492b0f7";
        let bytes: Vec<u8> = (0..VECTOR.len()).step_by(2).map(|i| u8::from_str_radix(&VECTOR[i..i + 2], 16).unwrap()).collect();
        let k = Key32::from_slice(&[0x42; 32]).unwrap();
        assert_eq!(&*open(&k, &bytes, b"vaultone/doc-vector").unwrap(), b"VaultOne interop vector");
        assert_eq!(open(&k, &bytes, b"vaultone/other"), Err(CryptoError::Integrity));
    }
}
