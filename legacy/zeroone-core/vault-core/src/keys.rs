//! Secret Key 与 Recovery Code 的生成、格式化、解析。
//!
//! - Secret Key：240-bit，设备本地生成并保存在系统钥匙串，打印在 Recovery Kit 上。
//!   格式 `Z1-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX`（Crockford Base32）。
//! - Recovery Code：256-bit，只出现在 Recovery Kit 上，用于在忘记主密码时解封 Vault Key。
//!   格式 `R1-XXXX-XXXX-…`（13 组）。
//!
//! Crockford Base32 不含 I/L/O/U，解析时容忍大小写与 I→1、L→1、O→0 的手抄误差。

use std::sync::OnceLock;

use data_encoding::{Encoding, Specification};
use zeroize::Zeroizing;

use crate::crypto::hkdf_sha512;
use crate::secret::{random_bytes, Key32};
use crate::{Result, VaultError};

pub const SECRET_KEY_BYTES: usize = 30;
pub const RECOVERY_CODE_BYTES: usize = 32;
const SECRET_KEY_PREFIX: &str = "Z1";
const RECOVERY_PREFIX: &str = "R1";
const INFO_RECOVERY: &[u8] = b"zeroone/v1/recovery";

fn crockford() -> &'static Encoding {
    static ENC: OnceLock<Encoding> = OnceLock::new();
    ENC.get_or_init(|| {
        let mut spec = Specification::new();
        spec.symbols.push_str("0123456789ABCDEFGHJKMNPQRSTVWXYZ");
        spec.translate.from.push_str("abcdefghjkmnpqrstvwxyzIiLlOo");
        spec.translate.to.push_str("ABCDEFGHJKMNPQRSTVWXYZ111100");
        spec.check_trailing_bits = false;
        spec.encoding().expect("crockford spec")
    })
}

fn format_grouped(prefix: &str, bytes: &[u8], group: usize) -> Zeroizing<String> {
    let encoded = Zeroizing::new(crockford().encode(bytes));
    let mut out = Zeroizing::new(String::with_capacity(encoded.len() * 2));
    out.push_str(prefix);
    for (i, ch) in encoded.chars().enumerate() {
        if i % group == 0 {
            out.push('-');
        }
        out.push(ch);
    }
    out
}

fn parse_grouped(prefix: &str, input: &str, expected_len: usize) -> Option<Zeroizing<Vec<u8>>> {
    let compact: Zeroizing<String> =
        Zeroizing::new(input.chars().filter(|c| !c.is_whitespace() && *c != '-').collect());
    let normalize = |c: char| match c.to_ascii_uppercase() {
        'I' | 'L' => '1',
        'O' => '0',
        u => u,
    };
    let head: String = compact.chars().take(prefix.chars().count()).map(normalize).collect();
    if head != prefix {
        return None;
    }
    let body: Zeroizing<String> = Zeroizing::new(compact.chars().skip(prefix.chars().count()).collect());
    let bytes = Zeroizing::new(crockford().decode(body.as_bytes()).ok()?);
    (bytes.len() == expected_len).then_some(bytes)
}

/// 设备 Secret Key。
pub struct SecretKey(Zeroizing<Vec<u8>>);

impl SecretKey {
    pub fn generate() -> Self {
        Self(Zeroizing::new(random_bytes::<SECRET_KEY_BYTES>().to_vec()))
    }

    pub fn parse(input: &str) -> Result<Self> {
        parse_grouped(SECRET_KEY_PREFIX, input, SECRET_KEY_BYTES)
            .map(Self)
            .ok_or_else(|| VaultError::InvalidInput("Secret Key 格式不正确".into()))
    }

    pub fn format(&self) -> Zeroizing<String> {
        format_grouped(SECRET_KEY_PREFIX, &self.0, 6)
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

/// Recovery Code。
pub struct RecoveryCode(Zeroizing<Vec<u8>>);

impl RecoveryCode {
    pub fn generate() -> Self {
        Self(Zeroizing::new(random_bytes::<RECOVERY_CODE_BYTES>().to_vec()))
    }

    pub fn parse(input: &str) -> Result<Self> {
        parse_grouped(RECOVERY_PREFIX, input, RECOVERY_CODE_BYTES)
            .map(Self)
            .ok_or(VaultError::InvalidRecoveryCode)
    }

    pub fn format(&self) -> Zeroizing<String> {
        format_grouped(RECOVERY_PREFIX, &self.0, 4)
    }

    /// 恢复码本身有 256-bit 熵，直接 HKDF 即可，无需内存硬 KDF。
    pub fn derive_wrap_key(&self, account_id: &str) -> Result<Key32> {
        hkdf_sha512(&self.0, account_id.as_bytes(), INFO_RECOVERY)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_key_roundtrip() {
        let sk = SecretKey::generate();
        let text = sk.format();
        assert!(text.starts_with("Z1-"));
        assert_eq!(text.split('-').count(), 9);
        let parsed = SecretKey::parse(&text).unwrap();
        assert_eq!(parsed.as_bytes(), sk.as_bytes());
    }

    #[test]
    fn tolerant_parsing() {
        let sk = SecretKey::generate();
        let text = sk.format().to_lowercase().replace('-', " ");
        assert_eq!(SecretKey::parse(&text).unwrap().as_bytes(), sk.as_bytes());

        let rc = RecoveryCode::generate();
        let text = rc.format();
        let confused = text.replace('0', "O").replace('1', "l");
        // 前缀 R1 中的 1 也会被替换为 l，解析应当依然成功
        assert!(RecoveryCode::parse(&confused).is_ok());
    }

    #[test]
    fn rejects_garbage() {
        assert!(SecretKey::parse("Z1-ABC").is_err());
        assert!(SecretKey::parse("").is_err());
        assert!(matches!(RecoveryCode::parse("R1-XXXX"), Err(VaultError::InvalidRecoveryCode)));
        // 前缀不匹配
        let sk = SecretKey::generate();
        assert!(RecoveryCode::parse(&sk.format()).is_err());
    }
}
