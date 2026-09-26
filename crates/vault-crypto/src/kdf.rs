//! 主密钥派生（2SKD：主密码 + Secret Key 双因子，计划书 S-02）。
//!
//! ```text
//! salt       = OsRng(32)                                   —— 注册/改密时生成，明文随 KDF 参数存储
//! MUK        = Argon2id(NFKD(主密码), salt, m=64MiB,t=3,p=4)
//!              XOR HKDF-SHA256(SecretKey, salt, "vaultone/v1/secret-key|<account>")
//! AuthKey    = HKDF-SHA256(MUK, salt, "vaultone/v1/auth|<account>")   → SRP-6a 口令
//! WrapKey    = HKDF-SHA256(MUK, salt, "vaultone/v1/wrap|<account>")   → 封装 Vault Key
//! ```
//!
//! 两路独立派生再异或：即使服务端的 salt/KDF 参数被拖库，
//! 攻击者没有设备上的 240-bit Secret Key 也无法离线爆破主密码。

use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use unicode_normalization::UnicodeNormalization;
use zeroize::Zeroizing;

use crate::secret::{random_bytes, Key32};
use crate::{CryptoError, Result};

pub const KDF_SALT_LEN: usize = 32;
pub const MIN_SALT_LEN: usize = 16;
pub const MIN_MASTER_PASSWORD_LEN: usize = 10;

/// 安全下限：防止服务端或本地库被篡改后把参数降级（OWASP 2024 Argon2id 最低建议 19MiB/t=2）。
const MIN_M_KIB: u32 = 19 * 1024;
const MIN_T: u32 = 2;

/// KDF 参数，明文保存在本地库与服务端。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KdfParams {
    pub alg: String,
    /// 内存开销（KiB）
    pub m: u32,
    pub t: u32,
    pub p: u32,
    /// base64 编码的随机盐（≥16 字节，默认 32 字节）
    pub salt: String,
}

impl KdfParams {
    /// 计划书默认参数：m=64MiB, t=3, p=4，32 字节随机盐。
    pub fn recommended() -> Self {
        Self::with_cost(64 * 1024, 3, 4)
    }

    pub fn with_cost(m: u32, t: u32, p: u32) -> Self {
        Self { alg: "argon2id".into(), m, t, p, salt: B64.encode(random_bytes::<KDF_SALT_LEN>()) }
    }

    /// 同成本、换新盐（改主密码 / 恢复时使用）。
    pub fn rotate_salt(&self) -> Self {
        Self::with_cost(self.m, self.t, self.p)
    }

    /// 仅供测试：低成本参数，跳过下限检查。
    #[doc(hidden)]
    pub fn insecure_for_tests() -> Self {
        Self::with_cost(8, 1, 1)
    }

    pub fn salt_bytes(&self) -> Result<Vec<u8>> {
        let salt = B64.decode(&self.salt).map_err(|_| CryptoError::InvalidInput("salt".into()))?;
        if salt.len() < MIN_SALT_LEN {
            return Err(CryptoError::InvalidInput("salt 长度不足 16 字节".into()));
        }
        Ok(salt)
    }

    fn validate(&self) -> Result<Vec<u8>> {
        if self.alg != "argon2id" {
            return Err(CryptoError::Unsupported(format!("KDF {}", self.alg)));
        }
        // 低成本参数仅在单元测试或显式启用 `insecure-test-kdf` 特性（仅 dev-dependencies 使用）时放行
        let allow_weak = cfg!(any(test, feature = "insecure-test-kdf")) && self.m == 8 && self.t == 1 && self.p == 1;
        if !allow_weak && (self.m < MIN_M_KIB || self.t < MIN_T) {
            return Err(CryptoError::InvalidInput("KDF 参数低于安全下限".into()));
        }
        if self.p < 1 || self.p > 16 || self.m > 4 * 1024 * 1024 || self.t > 64 {
            return Err(CryptoError::InvalidInput("KDF 参数超出范围".into()));
        }
        self.salt_bytes()
    }
}

fn hkdf(ikm: &[u8], salt: &[u8], info: &[u8]) -> Result<Key32> {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    Key32::fill_with(|out| hk.expand(info, out).map_err(|_| CryptoError::Kdf))
}

fn info(label: &str, account_id: &str) -> Vec<u8> {
    format!("vaultone/v1/{label}|{account_id}").into_bytes()
}

/// 由主密码 + Secret Key 派生 Master Unlock Key。
pub fn derive_muk(master_password: &str, secret_key: &[u8], account_id: &str, params: &KdfParams) -> Result<Key32> {
    let salt = params.validate()?;
    let normalized: Zeroizing<String> = Zeroizing::new(master_password.nfkd().collect());
    let argon = Argon2::new(
        Algorithm::Argon2id,
        Version::V0x13,
        Params::new(params.m, params.t, params.p, Some(32)).map_err(|_| CryptoError::Kdf)?,
    );
    let sk_part = hkdf(secret_key, &salt, &info("secret-key", account_id))?;
    Key32::fill_with(|out| {
        argon.hash_password_into(normalized.as_bytes(), &salt, out).map_err(|_| CryptoError::Kdf)?;
        for (o, s) in out.iter_mut().zip(sk_part.as_bytes()) {
            *o ^= s;
        }
        Ok(())
    })
}

/// 由 MUK 派生的两把子密钥。
pub struct DerivedKeys {
    pub auth_key: Key32,
    pub wrap_key: Key32,
}

pub fn derive_subkeys(muk: &Key32, account_id: &str, params: &KdfParams) -> Result<DerivedKeys> {
    let salt = params.salt_bytes()?;
    Ok(DerivedKeys {
        auth_key: hkdf(muk.as_bytes(), &salt, &info("auth", account_id))?,
        wrap_key: hkdf(muk.as_bytes(), &salt, &info("wrap", account_id))?,
    })
}

/// 一步完成：主密码 + Secret Key → (AuthKey, WrapKey)。
pub fn derive_all(master_password: &str, secret_key: &[u8], account_id: &str, params: &KdfParams) -> Result<DerivedKeys> {
    let muk = derive_muk(master_password, secret_key, account_id, params)?;
    derive_subkeys(&muk, account_id, params)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p() -> KdfParams {
        KdfParams::insecure_for_tests()
    }

    #[test]
    fn both_factors_and_account_matter() {
        let p = p();
        let sk = [1u8; 30];
        let base = derive_muk("correct horse", &sk, "acct", &p).unwrap();
        assert_eq!(base, derive_muk("correct horse", &sk, "acct", &p).unwrap());
        assert_ne!(base, derive_muk("correct horsE", &sk, "acct", &p).unwrap());
        assert_ne!(base, derive_muk("correct horse", &[2u8; 30], "acct", &p).unwrap());
        assert_ne!(base, derive_muk("correct horse", &sk, "acct2", &p).unwrap());
        // 换盐后结果不同
        assert_ne!(base, derive_muk("correct horse", &sk, "acct", &p.rotate_salt()).unwrap());
    }

    #[test]
    fn default_salt_is_32_bytes_and_random() {
        let a = KdfParams::recommended();
        let b = KdfParams::recommended();
        assert_eq!(a.salt_bytes().unwrap().len(), 32);
        assert_ne!(a.salt, b.salt);
        assert_eq!((a.m, a.t, a.p), (65536, 3, 4));
    }

    #[test]
    fn nfkd_normalizes_equivalent_input() {
        let p = p();
        let a = derive_muk("caf\u{00e9}", &[9; 30], "a", &p).unwrap();
        let b = derive_muk("cafe\u{0301}", &[9; 30], "a", &p).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn rejects_downgrade_and_short_salt() {
        let mut bad = p();
        bad.alg = "pbkdf2".into();
        assert!(derive_muk("x", &[0; 30], "a", &bad).is_err());
        let mut bad = p();
        bad.salt = B64.encode([0u8; 8]);
        assert!(derive_muk("x", &[0; 30], "a", &bad).is_err());
        let weak = KdfParams::with_cost(1024, 1, 1);
        assert!(derive_muk("x", &[0; 30], "a", &weak).is_err());
    }

    #[test]
    fn subkeys_are_separated() {
        let p = p();
        let k = derive_all("pw", &[3; 30], "a", &p).unwrap();
        assert_ne!(k.auth_key, k.wrap_key);
    }
}
