//! 无状态工具：密码生成、强度评估、TOTP。均为同步调用（微秒级）。

use flutter_rust_bridge::frb;
use vault_core::generator::{self, PassphraseOptions, PasswordOptions};
use vault_core::item::TotpConfig;
use vault_core::{security, totp};

use super::BridgeResult;

#[derive(Debug, Clone)]
pub struct Generated {
    pub value: String,
    pub entropy_bits: f64,
}

#[derive(Debug, Clone)]
pub struct StrengthDto {
    pub score: u8,
    pub guesses_log10: f64,
    pub warning: Option<String>,
}

#[derive(Debug, Clone)]
pub struct TotpCodeDto {
    pub code: String,
    pub remaining: u32,
    pub period: u32,
}

#[derive(Debug, Clone)]
pub struct TotpSpec {
    pub secret: String,
    pub alg: String,
    pub digits: u32,
    pub period: u32,
}

#[derive(Debug, Clone)]
pub struct ParsedTotp {
    pub spec: TotpSpec,
    pub issuer: Option<String>,
    pub account: Option<String>,
}

#[frb(sync)]
pub fn generate_password(
    length: u32,
    lowercase: bool,
    uppercase: bool,
    digits: bool,
    symbols: bool,
    exclude_ambiguous: bool,
) -> BridgeResult<Generated> {
    let opts = PasswordOptions { length, lowercase, uppercase, digits, symbols, exclude_ambiguous };
    let value = generator::generate_password(&opts)?;
    Ok(Generated { value: value.to_string(), entropy_bits: generator::password_entropy_bits(&opts) })
}

#[frb(sync)]
pub fn generate_passphrase(words: u32, separator: String, capitalize: bool, include_number: bool) -> BridgeResult<Generated> {
    let opts = PassphraseOptions { words, separator, capitalize, include_number };
    let value = generator::generate_passphrase(&opts)?;
    Ok(Generated { value: value.to_string(), entropy_bits: generator::passphrase_entropy_bits(&opts) })
}

#[frb(sync)]
pub fn password_strength(password: String, user_inputs: Vec<String>) -> StrengthDto {
    let inputs: Vec<&str> = user_inputs.iter().map(String::as_str).collect();
    let s = security::estimate_strength(&password, &inputs);
    StrengthDto { score: s.score, guesses_log10: s.guesses_log10, warning: s.warning }
}

#[frb(sync)]
pub fn totp_code(spec: TotpSpec, unix_time: u64) -> BridgeResult<TotpCodeDto> {
    let cfg = TotpConfig { secret: spec.secret, alg: spec.alg, digits: spec.digits, period: spec.period };
    let c = totp::generate(&cfg, unix_time)?;
    Ok(TotpCodeDto { code: c.code, remaining: c.remaining, period: c.period })
}

/// 解析 otpauth:// 链接（扫码结果）或手输 Base32 密钥。
#[frb(sync)]
pub fn parse_totp(text: String) -> BridgeResult<ParsedTotp> {
    let p = totp::parse(&text)?;
    Ok(ParsedTotp {
        spec: TotpSpec { secret: p.config.secret.clone(), alg: p.config.alg.clone(), digits: p.config.digits, period: p.config.period },
        issuer: p.issuer,
        account: p.account,
    })
}
