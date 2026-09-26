//! 本地安全审计（F-09）：弱密码（zxcvbn）、重复密码、泄露密码（HIBP k-匿名前缀查询）。
//!
//! 泄露检测只向外发送 SHA-1 的前 5 位十六进制（Have I Been Pwned Range API，
//! 并开启 `Add-Padding` 让响应长度也不泄露信息），后缀比对在本地完成。

use std::collections::HashMap;
use std::time::Duration;

use sha1::{Digest, Sha1};

use crate::item::Item;
use crate::{Result, VaultError};

/// zxcvbn 评分 0-4，≤2 视为弱密码。
pub const WEAK_SCORE_THRESHOLD: u8 = 2;
pub const HIBP_RANGE_URL: &str = "https://api.pwnedpasswords.com/range/";

#[derive(Debug, Clone, PartialEq)]
pub struct Strength {
    /// 0（极弱）- 4（很强）
    pub score: u8,
    /// 估算破解所需猜测次数的 log10
    pub guesses_log10: f64,
    pub warning: Option<String>,
}

pub fn estimate_strength(password: &str, user_inputs: &[&str]) -> Strength {
    if password.is_empty() {
        return Strength { score: 0, guesses_log10: 0.0, warning: None };
    }
    let entropy = zxcvbn::zxcvbn(password, user_inputs);
    Strength {
        score: u8::from(entropy.score()),
        guesses_log10: entropy.guesses_log10(),
        warning: entropy.feedback().and_then(|f| f.warning()).map(|w| w.to_string()),
    }
}

/// k-匿名查询所需的前缀与后缀（均为大写十六进制）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BreachQuery {
    pub prefix: String,
    pub suffix: String,
}

pub fn breach_query(password: &str) -> BreachQuery {
    let digest = Sha1::digest(password.as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02X}")).collect();
    BreachQuery { prefix: hex[..5].to_string(), suffix: hex[5..].to_string() }
}

/// 解析 Range API 响应（每行 `SUFFIX:COUNT`；padding 行的 COUNT 为 0）。
pub fn breach_count(response_body: &str, suffix: &str) -> u64 {
    response_body
        .lines()
        .filter_map(|line| line.trim().split_once(':'))
        .find(|(s, _)| s.eq_ignore_ascii_case(suffix))
        .and_then(|(_, n)| n.trim().parse().ok())
        .unwrap_or(0)
}

/// 在线查询 HIBP（阻塞调用，应在后台线程执行）。
pub fn check_breach(password: &str) -> Result<u64> {
    check_breach_at(HIBP_RANGE_URL, password)
}

pub fn check_breach_at(base_url: &str, password: &str) -> Result<u64> {
    let q = breach_query(password);
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .user_agent(concat!("VaultOne/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| VaultError::Network(e.to_string()))?;
    let body = client
        .get(format!("{base_url}{}", q.prefix))
        .header("Add-Padding", "true")
        .send()
        .and_then(|r| r.error_for_status())
        .and_then(|r| r.text())
        .map_err(|e| VaultError::Network(e.to_string()))?;
    Ok(breach_count(&body, &q.suffix))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditFinding {
    pub item_id: String,
    pub weak: bool,
    pub score: u8,
    /// 与本条目使用相同密码的其他条目数
    pub reused_with: u32,
}

/// 对全部含密码的条目做弱密码与重复检测（纯本地）。
pub fn audit(items: &[Item]) -> Vec<AuditFinding> {
    let mut by_password: HashMap<&str, u32> = HashMap::new();
    for item in items {
        if let Some(pw) = item.data.password.as_deref().filter(|p| !p.is_empty()) {
            *by_password.entry(pw).or_default() += 1;
        }
    }
    items
        .iter()
        .filter_map(|item| {
            let pw = item.data.password.as_deref().filter(|p| !p.is_empty())?;
            let mut inputs: Vec<&str> = vec![item.data.title.as_str()];
            if let Some(u) = item.data.username.as_deref() {
                inputs.push(u);
            }
            let strength = estimate_strength(pw, &inputs);
            let reused_with = by_password.get(pw).copied().unwrap_or(1) - 1;
            let weak = strength.score <= WEAK_SCORE_THRESHOLD;
            (weak || reused_with > 0).then(|| AuditFinding { item_id: item.id.clone(), weak, score: strength.score, reused_with })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{ItemData, ItemKind};

    fn login(id: &str, pw: &str) -> Item {
        let mut data = ItemData::new(ItemKind::Login, id);
        data.password = Some(pw.into());
        Item { id: id.into(), vault_id: "v".into(), revision: 1, data }
    }

    #[test]
    fn strength_scores() {
        assert!(estimate_strength("password", &[]).score <= 1);
        assert!(estimate_strength("Tr0ub4dour-Correct-Horse-Battery-9!", &[]).score >= 3);
        assert_eq!(estimate_strength("", &[]).score, 0);
    }

    #[test]
    fn k_anonymity_prefix() {
        // SHA1("password") = 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8
        let q = breach_query("password");
        assert_eq!(q.prefix, "5BAA6");
        assert_eq!(q.suffix, "1E4C9B93F3F0682250B6CF8331B7EE68FD8");
        let body = "003D68EB55068C33ACE09247EE4C639306B:3\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:9545824\r\nFFFF:0\r\n";
        assert_eq!(breach_count(body, &q.suffix), 9_545_824);
        assert_eq!(breach_count(body, "FFFF"), 0);
        assert_eq!(breach_count(body, "ABC"), 0);
    }

    #[test]
    fn audit_flags_weak_and_reused() {
        let strong = "vK9#qLm2$Zp8!wRt5@Yx";
        let items = vec![login("a", "123456"), login("b", strong), login("c", strong), login("d", "Unique-Str0ng-Passphrase-42!")];
        let findings = audit(&items);
        assert!(findings.iter().find(|f| f.item_id == "a").unwrap().weak);
        let b = findings.iter().find(|f| f.item_id == "b").unwrap();
        assert_eq!(b.reused_with, 1);
        assert!(!b.weak);
        assert!(findings.iter().all(|f| f.item_id != "d"));
    }
}
