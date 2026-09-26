//! 密码生成器（F-04）。全部使用 OsRng（CSPRNG），`gen_range` 采用拒绝采样，无模偏差。

use rand::rngs::OsRng;
use rand::seq::SliceRandom;
use rand::Rng;
use zeroize::Zeroizing;

use crate::{Result, VaultError};

const LOWER: &str = "abcdefghijklmnopqrstuvwxyz";
const UPPER: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const DIGITS: &str = "0123456789";
const SYMBOLS: &str = "!@#$%^&*()-_=+[]{};:,.<>/?~";
/// 易混字符：0/O/o、1/l/I/|、以及引号类
const AMBIGUOUS: &str = "0Oo1lI|`'\"";

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

fn charsets(opts: &PasswordOptions) -> Vec<Vec<char>> {
    [(opts.lowercase, LOWER), (opts.uppercase, UPPER), (opts.digits, DIGITS), (opts.symbols, SYMBOLS)]
        .into_iter()
        .filter(|(on, _)| *on)
        .map(|(_, set)| set.chars().filter(|c| !opts.exclude_ambiguous || !AMBIGUOUS.contains(*c)).collect())
        .collect()
}

/// 生成随机密码，保证每个启用的字符集至少出现一次。
pub fn generate_password(opts: &PasswordOptions) -> Result<Zeroizing<String>> {
    if !(MIN_LENGTH..=MAX_LENGTH).contains(&opts.length) {
        return Err(VaultError::InvalidInput(format!("长度需在 {MIN_LENGTH}-{MAX_LENGTH} 之间")));
    }
    let sets = charsets(opts);
    if sets.is_empty() {
        return Err(VaultError::InvalidInput("至少选择一种字符类型".into()));
    }
    let all: Vec<char> = sets.iter().flatten().copied().collect();
    let mut rng = OsRng;
    let mut chars: Zeroizing<Vec<char>> = Zeroizing::new(Vec::with_capacity(opts.length as usize));
    for set in &sets {
        chars.push(set[rng.gen_range(0..set.len())]);
    }
    while chars.len() < opts.length as usize {
        chars.push(all[rng.gen_range(0..all.len())]);
    }
    chars.shuffle(&mut rng);
    Ok(Zeroizing::new(chars.iter().collect()))
}

/// 生成口令短语，词表为 BIP-39 英文 2048 词（每词 11 bit 熵）。
pub fn generate_passphrase(opts: &PassphraseOptions) -> Result<Zeroizing<String>> {
    if !(MIN_WORDS..=MAX_WORDS).contains(&opts.words) {
        return Err(VaultError::InvalidInput(format!("词数需在 {MIN_WORDS}-{MAX_WORDS} 之间")));
    }
    let list = bip39::Language::English.word_list();
    let mut rng = OsRng;
    let mut words: Vec<Zeroizing<String>> = (0..opts.words)
        .map(|_| {
            let w = list[rng.gen_range(0..list.len())];
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

/// 生成器理论熵（bit），用于 UI 展示。
pub fn password_entropy_bits(opts: &PasswordOptions) -> f64 {
    let pool: usize = charsets(opts).iter().map(Vec::len).sum();
    if pool == 0 {
        return 0.0;
    }
    opts.length as f64 * (pool as f64).log2()
}

pub fn passphrase_entropy_bits(opts: &PassphraseOptions) -> f64 {
    let mut bits = opts.words as f64 * 11.0;
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
        for length in [MIN_LENGTH, 20, MAX_LENGTH] {
            let opts = PasswordOptions { length, ..Default::default() };
            let pw = generate_password(&opts).unwrap();
            assert_eq!(pw.chars().count(), length as usize);
            assert!(pw.chars().any(|c| c.is_ascii_lowercase()));
            assert!(pw.chars().any(|c| c.is_ascii_uppercase()));
            assert!(pw.chars().any(|c| c.is_ascii_digit()));
            assert!(pw.chars().any(|c| SYMBOLS.contains(c)));
            assert!(!pw.chars().any(|c| AMBIGUOUS.contains(c)));
        }
    }

    #[test]
    fn digits_only() {
        let opts = PasswordOptions {
            length: 12,
            lowercase: false,
            uppercase: false,
            symbols: false,
            exclude_ambiguous: false,
            ..Default::default()
        };
        let pw = generate_password(&opts).unwrap();
        assert!(pw.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn rejects_invalid_options() {
        assert!(generate_password(&PasswordOptions { length: 7, ..Default::default() }).is_err());
        assert!(generate_password(&PasswordOptions { length: 65, ..Default::default() }).is_err());
        let none = PasswordOptions { lowercase: false, uppercase: false, digits: false, symbols: false, ..Default::default() };
        assert!(generate_password(&none).is_err());
        assert!(generate_passphrase(&PassphraseOptions { words: 2, ..Default::default() }).is_err());
    }

    #[test]
    fn no_duplicates_in_large_sample() {
        // 计划书要求 100 万次无重复；单元测试取 10 万次控制耗时，完整量级放在 `--ignored` 用例。
        let opts = PasswordOptions { length: 16, ..Default::default() };
        let mut seen = HashSet::new();
        for _ in 0..100_000 {
            assert!(seen.insert(generate_password(&opts).unwrap().to_string()));
        }
    }

    #[test]
    #[ignore = "耗时较长，发布前手动执行：cargo test --release -- --ignored"]
    fn no_duplicates_in_one_million() {
        let opts = PasswordOptions { length: 16, ..Default::default() };
        let mut seen = HashSet::with_capacity(1_000_000);
        for _ in 0..1_000_000 {
            assert!(seen.insert(generate_password(&opts).unwrap().to_string()));
        }
    }

    #[test]
    fn passphrase_shape() {
        let opts = PassphraseOptions { words: 4, separator: ".".into(), capitalize: true, include_number: true };
        let p = generate_passphrase(&opts).unwrap();
        let parts: Vec<&str> = p.split('.').collect();
        assert_eq!(parts.len(), 4);
        assert!(parts.iter().all(|w| w.chars().next().unwrap().is_uppercase()));
        assert_eq!(p.chars().filter(|c| c.is_ascii_digit()).count(), 1);
    }

    #[test]
    fn entropy_estimates() {
        assert!(password_entropy_bits(&PasswordOptions::default()) > 100.0);
        assert!((passphrase_entropy_bits(&PassphraseOptions { include_number: false, ..Default::default() }) - 55.0).abs() < 1e-9);
    }
}
