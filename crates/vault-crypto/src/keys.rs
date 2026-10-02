//! Secret Key 与 Recovery Code 的生成、格式化、解析。
//!
//! - Secret Key：240-bit，设备本地生成并保存在系统钥匙串，打印在 Recovery Kit 上。
//!   格式 `V1-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX`（Crockford Base32）。
//! - Recovery Code：256-bit，只出现在 Recovery Kit 上，用于在忘记主密码时解封 Vault Key。
//!   格式 `R1-XXXX-XXXX-…`（13 组）。
//!
//! Crockford Base32 不含 I/L/O/U，解析时容忍大小写与 I→1、L→1、O→0 的手抄误差。

use std::sync::OnceLock;

use data_encoding::{Encoding, Specification};
use hkdf::Hkdf;
use sha2::Sha256;
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use crate::secret::{random_bytes, Key32};
use crate::{CryptoError, Result};

pub const SECRET_KEY_BYTES: usize = 30;
pub const RECOVERY_CODE_BYTES: usize = 32;
const SECRET_KEY_PREFIX: &str = "V1";
const RECOVERY_PREFIX: &str = "R1";

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
    let compact: Zeroizing<String> = Zeroizing::new(input.chars().filter(|c| !c.is_whitespace() && *c != '-').collect());
    let normalize = |c: char| match c.to_ascii_uppercase() {
        'I' | 'L' => '1',
        'O' => '0',
        u => u,
    };
    let head: String = compact.chars().take(prefix.len()).map(normalize).collect();
    if head != prefix {
        return None;
    }
    let body: Zeroizing<String> = Zeroizing::new(compact.chars().skip(prefix.len()).collect());
    let bytes = Zeroizing::new(crockford().decode(body.as_bytes()).ok()?);
    (bytes.len() == expected_len).then_some(bytes)
}

/// 设备 Secret Key（240-bit）。
pub struct SecretKey(Zeroizing<Vec<u8>>);

impl SecretKey {
    pub fn generate() -> Self {
        Self(Zeroizing::new(random_bytes::<SECRET_KEY_BYTES>().to_vec()))
    }

    pub fn parse(input: &str) -> Result<Self> {
        parse_grouped(SECRET_KEY_PREFIX, input, SECRET_KEY_BYTES)
            .map(Self)
            .ok_or_else(|| CryptoError::InvalidInput("Secret Key 格式不正确".into()))
    }

    pub fn format(&self) -> Zeroizing<String> {
        format_grouped(SECRET_KEY_PREFIX, &self.0, 6)
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

/// 备份二次确认：比对用户重输的 Secret Key 与本机保存的是否为同一把密钥。
///
/// 比对发生在 Crockford Base32 解码之后的 30 字节上，因此大小写、分组连字符、空白以及
/// I/L/O 的手抄差异都被容忍（沿用 [`SecretKey::parse`] 的规范），但字节内容必须完全一致——
/// 这正是「抄错一位」要拦住的情况。比对为常量时间，不按字节提前返回，避免泄露差异位置。
/// 解析失败与内容不符返回同一个 [`CryptoError::SecretKeyMismatch`]，不给出手抄位置信号。
/// 成功时返回本机密钥的规范形态，便于调用方展示或写进备份卡。
pub fn verify_secret_key(stored: &str, candidate: &str) -> Result<Zeroizing<String>> {
    let stored = SecretKey::parse(stored).map_err(|_| CryptoError::SecretKeyMismatch)?;
    let candidate = SecretKey::parse(candidate).map_err(|_| CryptoError::SecretKeyMismatch)?;
    if bool::from(stored.as_bytes().ct_eq(candidate.as_bytes())) {
        Ok(candidate.format())
    } else {
        Err(CryptoError::SecretKeyMismatch)
    }
}

/// 恢复码的格式校验与规范化。
///
/// 本机不保存恢复码的字节（恢复码只在生成时展示、由用户离线保管），因此这里只做
/// Crockford Base32 解析与规范化，不声称它一定属于当前账户——内容正确性由服务端在
/// 实际恢复时判定。返回规范形态，供备份卡与恢复套件重新导出使用。
pub fn canonical_recovery_code(candidate: &str) -> Result<Zeroizing<String>> {
    Ok(RecoveryCode::parse(candidate).map_err(|_| CryptoError::InvalidInput("恢复码格式不正确".into()))?.format())
}

/// Recovery Code（256-bit）。
pub struct RecoveryCode(Zeroizing<Vec<u8>>);

impl RecoveryCode {
    pub fn generate() -> Self {
        Self(Zeroizing::new(random_bytes::<RECOVERY_CODE_BYTES>().to_vec()))
    }

    pub fn parse(input: &str) -> Result<Self> {
        parse_grouped(RECOVERY_PREFIX, input, RECOVERY_CODE_BYTES)
            .map(Self)
            .ok_or_else(|| CryptoError::InvalidInput("恢复码格式不正确".into()))
    }

    pub fn format(&self) -> Zeroizing<String> {
        format_grouped(RECOVERY_PREFIX, &self.0, 4)
    }

    /// 恢复码本身有 256-bit 熵，无需内存硬 KDF。用作密封盒长期密钥时，
    /// 密封盒内部仍会以每次随机 32 字节盐做 HKDF。
    pub fn wrap_key(&self, account_id: &str) -> Result<Key32> {
        self.derive(account_id, "recovery-wrap")
    }

    /// 向服务端证明持有恢复码的凭据（服务端只存其 SHA-256）。
    pub fn auth_token(&self, account_id: &str) -> Result<Key32> {
        self.derive(account_id, "recovery-auth")
    }

    fn derive(&self, account_id: &str, label: &str) -> Result<Key32> {
        let hk = Hkdf::<Sha256>::new(None, &self.0);
        let info = format!("vaultone/v1/{label}|{account_id}");
        Key32::fill_with(|out| hk.expand(info.as_bytes(), out).map_err(|_| CryptoError::Kdf))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_key_roundtrip() {
        let sk = SecretKey::generate();
        let text = sk.format();
        assert!(text.starts_with("V1-"));
        assert_eq!(text.split('-').count(), 9);
        assert_eq!(SecretKey::parse(&text).unwrap().as_bytes(), sk.as_bytes());
    }

    #[test]
    fn tolerant_parsing() {
        let sk = SecretKey::generate();
        let text = sk.format().to_lowercase().replace('-', " ");
        assert_eq!(SecretKey::parse(&text).unwrap().as_bytes(), sk.as_bytes());

        let rc = RecoveryCode::generate();
        let confused = rc.format().replace('0', "O").replace('1', "l");
        assert!(RecoveryCode::parse(&confused).is_ok());
    }

    #[test]
    fn rejects_garbage() {
        assert!(SecretKey::parse("V1-ABC").is_err());
        assert!(SecretKey::parse("").is_err());
        assert!(RecoveryCode::parse("R1-XXXX").is_err());
        assert!(RecoveryCode::parse(&SecretKey::generate().format()).is_err());
    }

    #[test]
    fn recovery_subkeys_separated() {
        let rc = RecoveryCode::generate();
        assert_ne!(rc.wrap_key("a").unwrap(), rc.auth_token("a").unwrap());
        assert_ne!(rc.wrap_key("a").unwrap(), rc.wrap_key("b").unwrap());
    }

    #[test]
    fn verify_secret_key_compares_bytes_after_normalizing() {
        let sk = SecretKey::generate();
        let text = sk.format();

        // 原样与规范化写法都通过，返回值是本机密钥的规范形态
        assert_eq!(*verify_secret_key(&text, &text).unwrap(), *text);
        let sloppy = format!(" {} ", text.to_lowercase().replace('-', "  "));
        assert_eq!(*verify_secret_key(&text, &sloppy).unwrap(), *text);

        // 手抄易混字符 I/L/O 按 Crockford 规范等价
        let confused = text.replace('1', "l").replace('0', "O");
        assert_eq!(*verify_secret_key(&text, &confused).unwrap(), *text);
    }

    #[test]
    fn verify_secret_key_rejects_mismatch_without_leaking_position() {
        let a = SecretKey::generate();
        let b = SecretKey::generate();
        assert!(matches!(verify_secret_key(&a.format(), &b.format()), Err(CryptoError::SecretKeyMismatch)));

        // 只错一位：必须被拦住
        let text = a.format();
        let mut chars: Vec<char> = text.chars().collect();
        let last = chars.len() - 1;
        chars[last] = if chars[last] == '2' { '3' } else { '2' };
        let off_by_one: String = chars.into_iter().collect();
        assert_ne!(off_by_one, *text);
        assert!(matches!(verify_secret_key(&text, &off_by_one), Err(CryptoError::SecretKeyMismatch)));

        // 格式非法与内容不符返回同一个错误，不给出手抄位置信号
        assert!(matches!(verify_secret_key(&text, "V1-ABC"), Err(CryptoError::SecretKeyMismatch)));
        assert!(matches!(verify_secret_key(&text, ""), Err(CryptoError::SecretKeyMismatch)));
        assert!(matches!(verify_secret_key("garbage", &text), Err(CryptoError::SecretKeyMismatch)));

        // Recovery Code 不是 Secret Key
        assert!(matches!(verify_secret_key(&text, &RecoveryCode::generate().format()), Err(CryptoError::SecretKeyMismatch)));
    }

    #[test]
    fn canonical_recovery_code_normalizes_and_rejects() {
        let rc = RecoveryCode::generate();
        let text = rc.format();
        assert_eq!(*canonical_recovery_code(&text).unwrap(), *text);

        // 小写、空格分隔与 I/L/O 手抄差异都归一到同一规范形态
        let sloppy = format!(" {} ", text.to_lowercase().replace('-', " "));
        assert_eq!(*canonical_recovery_code(&sloppy).unwrap(), *text);
        let confused = text.replace('1', "l").replace('0', "O");
        assert_eq!(*canonical_recovery_code(&confused).unwrap(), *text);

        // 格式错误被拒绝；Secret Key 不能当作恢复码
        assert!(canonical_recovery_code("R1-XXXX").is_err());
        assert!(canonical_recovery_code("").is_err());
        assert!(canonical_recovery_code(&SecretKey::generate().format()).is_err());
    }
}
