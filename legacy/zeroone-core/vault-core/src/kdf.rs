//! 主密钥派生（2SKD：主密码 + Secret Key 双因子）。
//!
//! `MUK = Argon2id(NFKD(主密码), salt) XOR HKDF-SHA512(SecretKey, account_id, "zeroone/v1/secret-key")`
//!
//! 两路独立派生再异或：即使服务端的 salt/KDF 参数被拖库，
//! 攻击者没有设备上的 240-bit Secret Key 也无法离线爆破主密码（计划书 S-02）。

use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;
use zeroize::Zeroizing;

use crate::crypto::hkdf_sha512;
use crate::secret::{random_bytes, Key32};
use crate::{Result, VaultError};

const INFO_SECRET_KEY: &[u8] = b"zeroone/v1/secret-key";
const INFO_AUTH: &[u8] = b"zeroone/v1/auth";
const INFO_WRAP: &[u8] = b"zeroone/v1/wrap";

pub const MIN_MASTER_PASSWORD_LEN: usize = 10;

/// KDF 参数，明文保存在本地库与服务端（`users.kdf_params`）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KdfParams {
    pub alg: String,
    /// 内存开销，单位 KiB
    pub m: u32,
    pub t: u32,
    pub p: u32,
    /// base64 编码的 16 字节随机盐
    pub salt: String,
}

impl KdfParams {
    /// 计划书默认参数：m=64MiB, t=3, p=4。
    pub fn recommended() -> Self {
        Self::with_cost(64 * 1024, 3, 4)
    }

    pub fn with_cost(m: u32, t: u32, p: u32) -> Self {
        Self { alg: "argon2id".into(), m, t, p, salt: B64.encode(random_bytes::<16>()) }
    }

    fn validate(&self) -> Result<Vec<u8>> {
        if self.alg != "argon2id" {
            return Err(VaultError::Format(format!("不支持的 KDF: {}", self.alg)));
        }
        // 下限防止被降级攻击篡改为弱参数；测试构建允许低成本参数。
        let min_m = if cfg!(test) { 8 } else { 19 * 1024 };
        if self.m < min_m || self.t < 1 || self.p < 1 {
            return Err(VaultError::Format("KDF 参数低于安全下限".into()));
        }
        let salt = B64.decode(&self.salt).map_err(|_| VaultError::Format("salt".into()))?;
        if salt.len() < 16 {
            return Err(VaultError::Format("salt 长度不足".into()));
        }
        Ok(salt)
    }
}

/// 由主密码 + Secret Key 派生 Master Unlock Key。
pub fn derive_muk(master_password: &str, secret_key: &[u8], account_id: &str, params: &KdfParams) -> Result<Key32> {
    let salt = params.validate()?;
    let normalized: Zeroizing<String> = Zeroizing::new(master_password.nfkd().collect());
    let argon = Argon2::new(
        Algorithm::Argon2id,
        Version::V0x13,
        Params::new(params.m, params.t, params.p, Some(32)).map_err(|_| VaultError::Crypto)?,
    );
    let sk_part = hkdf_sha512(secret_key, account_id.as_bytes(), INFO_SECRET_KEY)?;
    Key32::fill_with(|out| {
        argon
            .hash_password_into(normalized.as_bytes(), &salt, out)
            .map_err(|_| VaultError::Crypto)?;
        for (o, s) in out.iter_mut().zip(sk_part.as_bytes()) {
            *o ^= s;
        }
        Ok(())
    })
}

/// AuthKey：M2 用于 SRP-6a 身份校验，服务端只存 verifier。
pub fn derive_auth_key(muk: &Key32, account_id: &str) -> Result<Key32> {
    hkdf_sha512(muk.as_bytes(), account_id.as_bytes(), INFO_AUTH)
}

/// KeyWrapKey：解封 Vault Key。
pub fn derive_wrap_key(muk: &Key32, account_id: &str) -> Result<Key32> {
    hkdf_sha512(muk.as_bytes(), account_id.as_bytes(), INFO_WRAP)
}

#[cfg(test)]
pub(crate) fn test_params() -> KdfParams {
    KdfParams::with_cost(8, 1, 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_factors_matter() {
        let p = test_params();
        let sk = [1u8; 30];
        let base = derive_muk("correct horse", &sk, "acct", &p).unwrap();
        assert_eq!(base, derive_muk("correct horse", &sk, "acct", &p).unwrap());
        assert_ne!(base, derive_muk("correct horsE", &sk, "acct", &p).unwrap());
        assert_ne!(base, derive_muk("correct horse", &[2u8; 30], "acct", &p).unwrap());
        assert_ne!(base, derive_muk("correct horse", &sk, "acct2", &p).unwrap());
    }

    #[test]
    fn nfkd_normalizes_equivalent_input() {
        let p = test_params();
        let sk = [9u8; 30];
        // "é" 预组合形式 与 "e + 组合重音" 应得到相同密钥
        let a = derive_muk("caf\u{00e9}", &sk, "a", &p).unwrap();
        let b = derive_muk("cafe\u{0301}", &sk, "a", &p).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn rejects_downgraded_params() {
        let mut p = test_params();
        p.alg = "pbkdf2".into();
        assert!(derive_muk("x", &[0; 30], "a", &p).is_err());
        let mut p = test_params();
        p.salt = B64.encode([0u8; 4]);
        assert!(derive_muk("x", &[0; 30], "a", &p).is_err());
    }

    #[test]
    fn subkeys_are_separated() {
        let muk = Key32::random().unwrap();
        assert_ne!(derive_auth_key(&muk, "a").unwrap(), derive_wrap_key(&muk, "a").unwrap());
    }
}
