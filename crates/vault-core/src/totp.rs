//! TOTP（F-07）：直接使用 `totp-rs`（RFC 6238 / RFC 4226，SHA1/256/512，6-8 位）。
//! 本模块只负责把条目中的 [`TotpConfig`] 与 otpauth URI 转换为 `totp_rs::TOTP`。

use totp_rs::{Algorithm, Secret, TOTP};
use zeroize::Zeroizing;

use crate::item::TotpConfig;
use crate::{Result, VaultError};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TotpCode {
    pub code: String,
    /// 当前验证码剩余有效秒数
    pub remaining: u32,
    pub period: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OtpAuth {
    pub config: TotpConfig,
    pub issuer: Option<String>,
    pub account: Option<String>,
}

fn algorithm(name: &str) -> Result<Algorithm> {
    Ok(match name.to_ascii_uppercase().as_str() {
        "SHA1" => Algorithm::SHA1,
        "SHA256" => Algorithm::SHA256,
        "SHA512" => Algorithm::SHA512,
        other => return Err(VaultError::InvalidInput(format!("不支持的 TOTP 算法: {other}"))),
    })
}

fn algorithm_name(a: Algorithm) -> &'static str {
    match a {
        Algorithm::SHA1 => "SHA1",
        Algorithm::SHA256 => "SHA256",
        Algorithm::SHA512 => "SHA512",
        #[allow(unreachable_patterns)]
        _ => "SHA1",
    }
}

fn normalize_secret(secret: &str) -> Zeroizing<String> {
    Zeroizing::new(secret.chars().filter(|c| !c.is_whitespace() && *c != '-' && *c != '=').map(|c| c.to_ascii_uppercase()).collect())
}

fn build(cfg: &TotpConfig) -> Result<TOTP> {
    if !(6..=8).contains(&cfg.digits) {
        return Err(VaultError::InvalidInput("TOTP 位数需为 6-8".into()));
    }
    if cfg.period == 0 || cfg.period > 300 {
        return Err(VaultError::InvalidInput("TOTP 周期不合法".into()));
    }
    let bytes = Secret::Encoded(normalize_secret(&cfg.secret).to_string())
        .to_bytes()
        .map_err(|_| VaultError::InvalidInput("TOTP 密钥不是合法的 Base32".into()))?;
    if bytes.is_empty() {
        return Err(VaultError::InvalidInput("TOTP 密钥为空".into()));
    }
    // new_unchecked：兼容 Google Authenticator 常见的 80-bit 密钥（totp-rs 的 new() 要求 ≥128 bit）
    Ok(TOTP::new_unchecked(algorithm(&cfg.alg)?, cfg.digits as usize, 1, cfg.period as u64, bytes, None, String::new()))
}

pub fn validate(cfg: &TotpConfig) -> Result<()> {
    build(cfg).map(|_| ())
}

pub fn generate(cfg: &TotpConfig, unix_time: u64) -> Result<TotpCode> {
    let totp = build(cfg)?;
    let period = cfg.period as u64;
    Ok(TotpCode { code: totp.generate(unix_time), remaining: (period - unix_time % period) as u32, period: cfg.period })
}

/// 校验验证码，允许 ±1 个时间窗口（计划书 F-07 验收要点）。
pub fn verify(cfg: &TotpConfig, code: &str, unix_time: u64) -> Result<bool> {
    Ok(build(cfg)?.check(code, unix_time))
}

/// 解析 `otpauth://totp/...` 或直接粘贴的 Base32 密钥。
pub fn parse(input: &str) -> Result<OtpAuth> {
    let input = input.trim();
    if !input.to_ascii_lowercase().starts_with("otpauth://") {
        let config = TotpConfig { secret: normalize_secret(input).to_string(), alg: "SHA1".into(), digits: 6, period: 30 };
        validate(&config)?;
        return Ok(OtpAuth { config, issuer: None, account: None });
    }
    let totp = TOTP::from_url_unchecked(input).map_err(|e| VaultError::InvalidInput(format!("otpauth 链接无效: {e:?}")))?;
    let config = TotpConfig {
        secret: totp.get_secret_base32(),
        alg: algorithm_name(totp.algorithm).into(),
        digits: totp.digits as u32,
        period: totp.step as u32,
    };
    validate(&config)?;
    let account = (!totp.account_name.is_empty()).then(|| totp.account_name.clone());
    Ok(OtpAuth { config, issuer: totp.issuer.clone(), account })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(secret: &str, alg: &str, digits: u32) -> TotpConfig {
        TotpConfig { secret: secret.into(), alg: alg.into(), digits, period: 30 }
    }

    // RFC 6238 附录 B 测试向量
    const S1: &str = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"; // "12345678901234567890"
    const S256: &str = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA"; // "12345678901234567890123456789012"
    const S512: &str = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA";

    #[test]
    fn rfc6238_vectors() {
        assert_eq!(generate(&cfg(S1, "SHA1", 8), 59).unwrap().code, "94287082");
        assert_eq!(generate(&cfg(S256, "SHA256", 8), 59).unwrap().code, "46119246");
        assert_eq!(generate(&cfg(S512, "SHA512", 8), 59).unwrap().code, "90693936");
        assert_eq!(generate(&cfg(S1, "SHA1", 8), 1111111109).unwrap().code, "07081804");
        assert_eq!(generate(&cfg(S1, "SHA1", 8), 20000000000).unwrap().code, "65353130");
    }

    #[test]
    fn remaining_seconds() {
        let c = generate(&cfg(S1, "SHA1", 6), 65).unwrap();
        assert_eq!(c.remaining, 25);
        assert_eq!(c.code.len(), 6);
    }

    #[test]
    fn verify_with_skew() {
        let c = cfg(S1, "SHA1", 6);
        let t = 1_700_000_000;
        let prev = generate(&c, t - 30).unwrap().code;
        assert!(verify(&c, &prev, t).unwrap());
        let far = generate(&c, t - 90).unwrap().code;
        assert!(!verify(&c, &far, t).unwrap() || far == generate(&c, t).unwrap().code);
    }

    #[test]
    fn parse_uri_and_raw() {
        let p =
            parse("otpauth://totp/ACME:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME&algorithm=SHA256&digits=8&period=60").unwrap();
        assert_eq!(p.config.alg, "SHA256");
        assert_eq!(p.config.digits, 8);
        assert_eq!(p.config.period, 60);
        assert_eq!(p.issuer.as_deref(), Some("ACME"));
        assert_eq!(p.account.as_deref(), Some("alice@example.com"));

        let raw = parse(" jbsw y3dp ehpk 3pxp ").unwrap();
        assert_eq!(raw.config.secret, "JBSWY3DPEHPK3PXP");
        assert!(parse("not base32 !!").is_err());
        assert!(parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1").is_err());
    }

    #[test]
    fn rejects_bad_config() {
        assert!(validate(&cfg(S1, "MD5", 6)).is_err());
        assert!(validate(&cfg(S1, "SHA1", 5)).is_err());
        let mut c = cfg(S1, "SHA1", 6);
        c.period = 0;
        assert!(validate(&c).is_err());
    }
}
