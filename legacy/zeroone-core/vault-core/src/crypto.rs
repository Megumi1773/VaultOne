//! 底层密码学原语封装。只使用成熟的 RustCrypto 实现，不自创算法（计划书 R-01）。

use aes_kw::KekAes256;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use hkdf::Hkdf;
use sha2::Sha512;
use zeroize::Zeroizing;

use crate::secret::{random_bytes, Key32, KEY_LEN};
use crate::{Result, VaultError};

pub const XNONCE_LEN: usize = 24;
pub const WRAPPED_KEY_LEN: usize = KEY_LEN + 8;
pub const PAD_BLOCK: usize = 256;

/// HKDF-SHA512（RFC 5869）派生 256-bit 子密钥，`info` 用于域分离。
pub fn hkdf_sha512(ikm: &[u8], salt: &[u8], info: &[u8]) -> Result<Key32> {
    let hk = Hkdf::<Sha512>::new(Some(salt), ikm);
    Key32::fill_with(|out| hk.expand(info, out).map_err(|_| VaultError::Crypto))
}

/// AES-256-KW（RFC 3394）封装一个 256-bit 密钥，输出 40 字节。
pub fn wrap_key(kek: &Key32, key: &Key32) -> Result<Vec<u8>> {
    let kek = KekAes256::new(kek.as_bytes().into());
    let mut out = vec![0u8; WRAPPED_KEY_LEN];
    kek.wrap(key.as_bytes(), &mut out).map_err(|_| VaultError::Crypto)?;
    Ok(out)
}

/// 解封。完整性校验失败返回 [`VaultError::Integrity`]，由调用方映射为具体语义。
pub fn unwrap_key(kek: &Key32, wrapped: &[u8]) -> Result<Key32> {
    if wrapped.len() != WRAPPED_KEY_LEN {
        return Err(VaultError::Integrity);
    }
    let kek = KekAes256::new(kek.as_bytes().into());
    Key32::fill_with(|out| kek.unwrap(wrapped, out).map_err(|_| VaultError::Integrity))
}

/// XChaCha20-Poly1305 加密，nonce 每次随机 24 字节（碰撞概率可忽略）。
pub fn aead_encrypt(key: &Key32, plaintext: &[u8], aad: &[u8]) -> Result<([u8; XNONCE_LEN], Vec<u8>)> {
    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    let nonce = random_bytes::<XNONCE_LEN>();
    let ct = cipher
        .encrypt(XNonce::from_slice(&nonce), Payload { msg: plaintext, aad })
        .map_err(|_| VaultError::Crypto)?;
    Ok((nonce, ct))
}

pub fn aead_decrypt(key: &Key32, nonce: &[u8], ciphertext: &[u8], aad: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if nonce.len() != XNONCE_LEN {
        return Err(VaultError::Integrity);
    }
    let cipher = XChaCha20Poly1305::new(key.as_bytes().into());
    cipher
        .decrypt(XNonce::from_slice(nonce), Payload { msg: ciphertext, aad })
        .map(Zeroizing::new)
        .map_err(|_| VaultError::Integrity)
}

/// ISO/IEC 7816-4 填充至 256 字节倍数，缓解密文长度泄露（计划书 §3.1）。
pub fn pad(data: &[u8]) -> Zeroizing<Vec<u8>> {
    let padded_len = (data.len() + 1).div_ceil(PAD_BLOCK) * PAD_BLOCK;
    let mut out = Zeroizing::new(Vec::with_capacity(padded_len));
    out.extend_from_slice(data);
    out.push(0x80);
    out.resize(padded_len, 0);
    out
}

pub fn unpad(mut data: Zeroizing<Vec<u8>>) -> Result<Zeroizing<Vec<u8>>> {
    let marker = data.iter().rposition(|&b| b != 0).ok_or(VaultError::Integrity)?;
    if data[marker] != 0x80 {
        return Err(VaultError::Integrity);
    }
    data.truncate(marker);
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrap_roundtrip_and_tamper() {
        let kek = Key32::random().unwrap();
        let key = Key32::random().unwrap();
        let mut wrapped = wrap_key(&kek, &key).unwrap();
        assert_eq!(unwrap_key(&kek, &wrapped).unwrap(), key);

        let other = Key32::random().unwrap();
        assert!(matches!(unwrap_key(&other, &wrapped), Err(VaultError::Integrity)));

        wrapped[5] ^= 1;
        assert!(unwrap_key(&kek, &wrapped).is_err());
    }

    #[test]
    fn aead_roundtrip_and_aad_binding() {
        let key = Key32::random().unwrap();
        let (nonce, ct) = aead_encrypt(&key, b"hello", b"a|b|1").unwrap();
        assert_eq!(&*aead_decrypt(&key, &nonce, &ct, b"a|b|1").unwrap(), b"hello");
        assert!(aead_decrypt(&key, &nonce, &ct, b"a|b|2").is_err());
    }

    #[test]
    fn padding_aligns_and_roundtrips() {
        for len in [0usize, 1, 254, 255, 256, 257, 1000] {
            let data = vec![0xABu8; len];
            let padded = pad(&data);
            assert_eq!(padded.len() % PAD_BLOCK, 0);
            assert!(padded.len() > len);
            assert_eq!(&*unpad(padded).unwrap(), &data[..]);
        }
        // 明文以 0x00 结尾也能正确还原
        let data = vec![1u8, 0, 0];
        assert_eq!(&*unpad(pad(&data)).unwrap(), &data[..]);
    }

    #[test]
    fn hkdf_domain_separation() {
        let a = hkdf_sha512(b"ikm", b"salt", b"auth").unwrap();
        let b = hkdf_sha512(b"ikm", b"salt", b"wrap").unwrap();
        assert_ne!(a, b);
    }
}
