//! 密码生成器（F-04）。
//!
//! - 随机密码：直接使用 `passwords` crate（`strict` 模式保证每类字符至少出现一次，
//!   `exclude_similar_characters` 排除 0/O/1/l/I 等易混字符）。其随机源为 `rand::rng()`
//!   （ChaCha12 CSPRNG，由操作系统熵源定期重播种）。
//! - 口令短语：EFF 大词表（7776 词，每词 12.9 bit），用 `OsRng` 均匀抽取。

use rand::rngs::OsRng;
use rand::seq::SliceRandom;
use rand::Rng;
use zeroize::Zeroizing;

use crate::{Result, VaultError};

pub const MIN_LENGTH: u32 = 8;
pub const MAX_LENGTH: u32 = 64;
pub const MIN_WORDS: u32 = 3;
pub const MAX_WORDS: u32 = 8;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PasswordOptions {
    pub length: u32,
    pub lowercase: bool,
    pub uppercase: bool,
    pub digits: bool,
    pub symbols: bool,
    pub exclude_ambiguous: bool,
}

impl Default for PasswordOptions {
    fn default() -> Self {
        Self { length: 20, lowercase: true, uppercase: true, digits: true, symbols: true, exclude_ambiguous: true }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PassphraseOptions {
    pub words: u32,
    pub separator: String,
    pub capitalize: bool,
    pub include_number: bool,
}

impl Default for PassphraseOptions {
    fn default() -> Self {
        Self { words: 5, separator: "-".into(), capitalize: true, include_number: true }
    }
}

pub fn generate_password(opts: &PasswordOptions) -> Result<Zeroizing<String>> {
    if !(MIN_LENGTH..=MAX_LENGTH).contains(&opts.length) {
        return Err(VaultError::InvalidInput(format!("长度需在 {MIN_LENGTH}-{MAX_LENGTH} 之间")));
    }
    if !(opts.lowercase || opts.uppercase || opts.digits || opts.symbols) {
        return Err(VaultError::InvalidInput("至少选择一种字符类型".into()));
    }
    let generator = passwords::PasswordGenerator::new()
        .length(opts.length as usize)
        .lowercase_letters(opts.lowercase)
        .uppercase_letters(opts.uppercase)
        .numbers(opts.digits)
        .symbols(opts.symbols)
        .spaces(false)
        .exclude_similar_characters(opts.exclude_ambiguous)
        .strict(true);
    generator.generate_one().map(Zeroizing::new).map_err(|e| VaultError::InvalidInput(e.to_string()))
}

pub fn generate_passphrase(opts: &PassphraseOptions) -> Result<Zeroizing<String>> {
    if !(MIN_WORDS..=MAX_WORDS).contains(&opts.words) {
        return Err(VaultError::InvalidInput(format!("词数需在 {MIN_WORDS}-{MAX_WORDS} 之间")));
    }
    if opts.separator.chars().count() > 3 {
        return Err(VaultError::InvalidInput("分隔符最多 3 个字符".into()));
    }
    let list = eff_wordlist::large::LIST;
    let mut rng = OsRng;
    let mut words: Vec<Zeroizing<String>> = (0..opts.words)
        .map(|_| {
            let (_, w) = *list.choose(&mut rng).expect("非空词表");
            let mut s = Zeroizing::new(String::with_capacity(w.len() + 1));
            if opts.capitalize {
                let mut it = w.chars();
                if let Some(first) = it.next() {
                    s.extend(first.to_uppercase());
                    s.push_str(it.as_str());
                }
            } else {
                s.push_str(w);
            }
            s
        })
        .collect();
    if opts.include_number {
        let idx = rng.gen_range(0..words.len());
        words[idx].push(char::from(b'0' + rng.gen_range(0..10u8)));
    }
    let mut out = Zeroizing::new(String::new());
    for (i, w) in words.iter().enumerate() {
        if i > 0 {
            out.push_str(&opts.separator);
        }
        out.push_str(w);
    }
    Ok(out)
}

/// 生成器理论熵（bit），用于 UI 展示。字符池大小与 `passwords` crate 的字符表一致。
pub fn password_entropy_bits(opts: &PasswordOptions) -> f64 {
    let ex = opts.exclude_ambiguous;
    let pool = [
        (opts.lowercase, if ex { 23 } else { 26 }),
        (opts.uppercase, if ex { 24 } else { 26 }),
        (opts.digits, if ex { 8 } else { 10 }),
        (opts.symbols, if ex { 28 } else { 32 }),
    ]
    .iter()
    .filter(|(on, _)| *on)
    .map(|(_, n)| *n as f64)
    .sum::<f64>();
    if pool == 0.0 {
        return 0.0;
    }
    opts.length as f64 * pool.log2()
}

pub fn passphrase_entropy_bits(opts: &PassphraseOptions) -> f64 {
    let mut bits = opts.words as f64 * (eff_wordlist::large::LIST.len() as f64).log2();
    if opts.include_number {
        bits += (10.0f64).log2() + (opts.words as f64).log2();
    }
    bits
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn respects_length_and_charsets() {
        for len in [8, 20, 64] {
            let opts = PasswordOptions { length: len, ..Default::default() };
            let pw = generate_password(&opts).unwrap();
            assert_eq!(pw.chars().count(), len as usize);
            assert!(pw.chars().any(|c| c.is_ascii_lowercase()));
            assert!(pw.chars().any(|c| c.is_ascii_uppercase()));
            assert!(pw.chars().any(|c| c.is_ascii_digit()));
            assert!(pw.chars().any(|c| !c.is_ascii_alphanumeric()));
        }
        let digits_only = PasswordOptions {
            length: 12,
            lowercase: false,
            uppercase: false,
            symbols: false,
            exclude_ambiguous: false,
            ..Default::default()
        };
        assert!(generate_password(&digits_only).unwrap().chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn excludes_ambiguous() {
        let opts = PasswordOptions { length: 64, ..Default::default() };
        for _ in 0..200 {
            let pw = generate_password(&opts).unwrap();
            assert!(!pw.chars().any(|c| "0O1lI".contains(c)), "{}", *pw);
        }
    }

    #[test]
    fn rejects_bad_options() {
        assert!(generate_password(&PasswordOptions { length: 7, ..Default::default() }).is_err());
        assert!(generate_password(&PasswordOptions { length: 65, ..Default::default() }).is_err());
        let none = PasswordOptions { lowercase: false, uppercase: false, digits: false, symbols: false, ..Default::default() };
        assert!(generate_password(&none).is_err());
        assert!(generate_passphrase(&PassphraseOptions { words: 2, ..Default::default() }).is_err());
        assert!(generate_passphrase(&PassphraseOptions { words: 9, ..Default::default() }).is_err());
    }

    #[test]
    fn no_duplicates_in_many_samples() {
        // 计划书验收要求 100 万次无重复；单元测试取 5 万次，完整规模见 tests/generator_uniqueness.rs（#[ignore]）
        let opts = PasswordOptions::default();
        let mut seen = HashSet::new();
        for _ in 0..50_000 {
            assert!(seen.insert(generate_password(&opts).unwrap().to_string()));
        }
    }

    #[test]
    fn passphrase_shape() {
        let opts = PassphraseOptions { words: 6, separator: ".".into(), capitalize: true, include_number: true };
        let p = generate_passphrase(&opts).unwrap();
        let parts: Vec<&str> = p.split('.').collect();
        assert_eq!(parts.len(), 6);
        assert!(parts.iter().all(|w| w.chars().next().unwrap().is_uppercase()));
        assert_eq!(p.chars().filter(|c| c.is_ascii_digit()).count(), 1);
    }

    #[test]
    fn entropy_estimates() {
        let e = password_entropy_bits(&PasswordOptions::default());
        assert!(e > 110.0 && e < 140.0, "{e}");
        let p = passphrase_entropy_bits(&PassphraseOptions { words: 5, include_number: false, ..Default::default() });
        assert!((p - 64.6).abs() < 0.1, "{p}");
    }
}
