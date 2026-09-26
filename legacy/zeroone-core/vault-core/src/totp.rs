//! TOTP（RFC 6238 / RFC 4226），支持 SHA1/256/512、6/8 位、30/60 秒（F-07）。

use data_encoding::BASE32_NOPAD;
use hmac::{Hmac, Mac};
use sha1::Sha1;
use sha2::{Sha256, Sha512};
use subtle::ConstantTimeEq;
use url::Url;
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

/// 从 otpauth URI 解析出的信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OtpAuth {
    pub config: TotpConfig,
    pub issuer: Option<String>,
    pub account: Option<String>,
}

fn decode_secret(secret: &str) -> Result<Zeroizing<Vec<u8>>> {
    let cleaned: Zeroizing<String> = Zeroizing::new(
        secret
            .chars()
            .filter(|c| !c.is_whitespace() && *c != '-' && *c != '=')
            .map(|c| c.to_ascii_uppercase())
            .collect(),
    );
    let bytes = BASE32_NOPAD
        .decode(cleaned.as_bytes())
        .map_err(|_| VaultError::InvalidInput("TOTP 密钥不是合法的 Base32".into()))?;
    if bytes.is_empty() {
        return Err(VaultError::InvalidInput("TOTP 密钥为空".into()));
    }
    Ok(Zeroizing::new(bytes))
}

fn validate(cfg: &TotpConfig) -> Result<()> {
    if !matches!(cfg.digits, 6 | 7 | 8) {
        return Err(VaultError::InvalidInput("TOTP 位数需为 6-8".into()));
    }
    if cfg.period == 0 || cfg.period > 300 {
        return Err(VaultError::InvalidInput("TOTP 周期不合法".into()));
    }
    Ok(())
}

fn hmac_digest(alg: &str, key: &[u8], msg: &[u8]) -> Result<Vec<u8>> {
    macro_rules! mac {
        ($h:ty) => {{
            let mut m = <Hmac<$h> as Mac>::new_from_slice(key).map_err(|_| VaultError::Crypto)?;
            m.update(msg);
            m.finalize().into_bytes().to_vec()
        }};
    }
    Ok(match alg.to_ascii_uppercase().as_str() {
        "SHA1" => mac!(Sha1),
        "SHA256" => mac!(Sha256),
        "SHA512" => mac!(Sha512),
        other => return Err(VaultError::InvalidInput(format!("不支持的 TOTP 算法: {other}"))),
    })
}

fn hotp(alg: &str, key: &[u8], counter: u64, digits: u32) -> Result<String> {
    let digest = hmac_digest(alg, key, &counter.to_be_bytes())?;
    let offset = (digest[digest.len() - 1] & 0x0f) as usize;
    let bin = u32::from_be_bytes([digest[offset] & 0x7f, digest[offset + 1], digest[offset + 2], digest[offset + 3]]);
    let code = bin % 10u32.pow(digits);
    Ok(format!("{code:0width$}", width = digits as usize))
}

pub fn generate(cfg: &TotpConfig, unix_time: u64) -> Result<TotpCode> {
    validate(cfg)?;
    let key = decode_secret(&cfg.secret)?;
    let period = cfg.period as u64;
    Ok(TotpCode {
        code: hotp(&cfg.alg, &key, unix_time / period, cfg.digits)?,
        remaining: (period - unix_time % period) as u32,
        period: cfg.period,
    })
}

/// 校验验证码，允许 ±`window` 个时间窗口。
pub fn verify(cfg: &TotpConfig, code: &str, unix_time: u64, window: u64) -> Result<bool> {
    validate(cfg)?;
    let key = decode_secret(&cfg.secret)?;
    let counter = unix_time / cfg.period as u64;
    let mut ok = false;
    for c in counter.saturating_sub(window)..=counter + window {
        let expected = hotp(&cfg.alg, &key, c, cfg.digits)?;
        ok |= bool::from(expected.as_bytes().ct_eq(code.as_bytes()));
    }
    Ok(ok)
}

/// 解析 `otpauth://totp/Issuer:account?secret=…&issuer=…&algorithm=…&digits=…&period=…`，
/// 也接受直接粘贴的 Base32 密钥。
pub fn parse(input: &str) -> Result<OtpAuth> {
    let input = input.trim();
    if !input.to_ascii_lowercase().starts_with("otpauth://") {
        let cfg = TotpConfig { secret: input.into(), alg: "SHA1".into(), digits: 6, period: 30 };
        decode_secret(&cfg.secret)?;
        return Ok(OtpAuth { config: cfg, issuer: None, account: None });
    }
    let url = Url::parse(input).map_err(|_| VaultError::InvalidInput("otpauth 链接格式错误".into()))?;
    if !url.host_str().is_some_and(|h| h.eq_ignore_ascii_case("totp")) {
        return Err(VaultError::InvalidInput("只支持 TOTP 类型".into()));
    }
    let mut cfg = TotpConfig { secret: String::new(), alg: "SHA1".into(), digits: 6, period: 30 };
    let mut issuer = None;
    for (k, v) in url.query_pairs() {
        match k.to_ascii_lowercase().as_str() {
            "secret" => cfg.secret = v.into_owned(),
            "algorithm" => cfg.alg = v.to_ascii_uppercase(),
            "digits" => cfg.digits = v.parse().map_err(|_| VaultError::InvalidInput("digits".into()))?,
            "period" => cfg.period = v.parse().map_err(|_| VaultError::InvalidInput("period".into()))?,
            "issuer" => issuer = Some(v.into_owned()),
            _ => {}
        }
    }
    decode_secret(&cfg.secret)?;
    validate(&cfg)?;
    hmac_digest(&cfg.alg, b"k", b"m")?;

    let label = url.path().trim_start_matches('/');
    let label = percent_decode(label);
    let (label_issuer, account) = match label.split_once(':') {
        Some((i, a)) => (Some(i.trim().to_string()), Some(a.trim().to_string())),
        None if label.is_empty() => (None, None),
        None => (None, Some(label.trim().to_string())),
    };
    Ok(OtpAuth { config: cfg, issuer: issuer.or(label_issuer), account })
}

fn percent_decode(s: &str) -> String {
    url::form_urlencoded::parse(format!("x={}", s.replace('+', "%2B")).as_bytes())
        .next()
        .map(|(_, v)| v.into_owned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(secret_ascii: &[u8], alg: &str) -> TotpConfig {
        TotpConfig { secret: BASE32_NOPAD.encode(secret_ascii), alg: alg.into(), digits: 8, period: 30 }
    }

    /// RFC 6238 附录 B 测试向量
    #[test]
    fn rfc6238_vectors() {
        let sha1 = cfg(b"12345678901234567890", "SHA1");
        let sha256 = cfg(b"12345678901234567890123456789012", "SHA256");
        let sha512 = cfg(b"1234567890123456789012345678901234567890123456789012345678901234", "SHA512");
        let cases: [(u64, &str, &str, &str); 6] = [
            (59, "94287082", "46119246", "90693936"),
            (1111111109, "07081804", "68084774", "25091201"),
            (1111111111, "14050471", "67062674", "99943326"),
            (1234567890, "89005924", "91819424", "93441116"),
            (2000000000, "69279037", "90698825", "38618901"),
            (20000000000, "65353130", "77737706", "47863826"),
        ];
        for (t, a, b, c) in cases {
            assert_eq!(generate(&sha1, t).unwrap().code, a, "sha1 t={t}");
            assert_eq!(generate(&sha256, t).unwrap().code, b, "sha256 t={t}");
            assert_eq!(generate(&sha512, t).unwrap().code, c, "sha512 t={t}");
        }
    }

    #[test]
    fn remaining_seconds() {
        let c = TotpConfig { secret: "JBSWY3DPEHPK3PXP".into(), alg: "SHA1".into(), digits: 6, period: 30 };
        assert_eq!(generate(&c, 60).unwrap().remaining, 30);
        assert_eq!(generate(&c, 89).unwrap().remaining, 1);
        assert_eq!(generate(&c, 89).unwrap().code.len(), 6);
    }

    #[test]
    fn verify_window() {
        let c = TotpConfig { secret: "JBSWY3DPEHPK3PXP".into(), alg: "SHA1".into(), digits: 6, period: 30 };
        let now = 1_700_000_000;
        let prev = generate(&c, now - 30).unwrap().code;
        let far = generate(&c, now - 90).unwrap().code;
        assert!(verify(&c, &prev, now, 1).unwrap());
        assert!(!verify(&c, &far, now, 1).unwrap() || far == prev);
    }

    #[test]
    fn parse_uri() {
        let o = parse("otpauth://totp/ACME%20Co:john@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co&algorithm=SHA256&digits=8&period=60").unwrap();
        assert_eq!(o.issuer.as_deref(), Some("ACME Co"));
        assert_eq!(o.account.as_deref(), Some("john@example.com"));
        assert_eq!(o.config.alg, "SHA256");
        assert_eq!(o.config.digits, 8);
        assert_eq!(o.config.period, 60);
    }

    #[test]
    fn parse_plain_secret_and_errors() {
        let o = parse("jbsw y3dp ehpk 3pxp").unwrap();
        assert_eq!(o.config.digits, 6);
        assert!(generate(&o.config, 0).is_ok());
        assert!(parse("not base32 !!").is_err());
        assert!(parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP").is_err());
        assert!(parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5").is_err());
    }
}
