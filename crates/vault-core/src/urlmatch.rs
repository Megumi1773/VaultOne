//! 自动填充 URL 匹配引擎（计划书 S-06："严格 eTLD+1 同源校验，防跨域钓鱼站点诱导填充"）。
//!
//! 公共后缀判定直接使用 `psl` crate（Mozilla Public Suffix List 编译期内嵌）。本模块自研的部分是
//! **防钓鱼匹配策略**（见 docs/01 "自研部分"）：
//!
//! 1. 协议降级拒绝：条目保存为 https，页面为 http → 不匹配（防 SSL strip 诱导填充）；
//! 2. IP 字面量、`localhost`、单标签主机只允许 Host/Exact 精确匹配，不做"同域"放宽；
//! 3. 未收录于公共后缀表的顶级域不做 eTLD+1 放宽（防 `evil.attacker-tld` 被当成同一注册域）；
//! 4. 国际化域名一律比较 punycode（`url` crate 规范化），同形异义字母（如西里尔 а）自然不相等；
//! 5. 对候选条目按 Exact > Host > Domain 打分排序，UI 只对最高分自动填充。

use url::{Host, Url};

use crate::item::{Item, ItemUrl, UrlMatch};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum MatchQuality {
    Domain = 1,
    Host = 2,
    Exact = 3,
}

fn parse(input: &str) -> Option<Url> {
    let trimmed = input.trim();
    let with_scheme = if trimmed.contains("://") { trimmed.to_string() } else { format!("https://{trimmed}") };
    let url = Url::parse(&with_scheme).ok()?;
    matches!(url.scheme(), "http" | "https").then_some(url)
}

/// 可安全放宽到 eTLD+1 的主机：必须是域名、至少两个标签，且公共后缀已被收录。
fn registrable_domain(url: &Url) -> Option<String> {
    let Some(Host::Domain(host)) = url.host() else { return None };
    if !host.contains('.') {
        return None;
    }
    let suffix = psl::suffix(host.as_bytes())?;
    if !suffix.is_known() {
        return None;
    }
    psl::domain_str(host).map(str::to_ascii_lowercase)
}

/// 判断单个保存的 URL 是否匹配当前页面。
pub fn match_url(saved: &ItemUrl, page: &str) -> Option<MatchQuality> {
    if saved.match_mode == UrlMatch::Never {
        return None;
    }
    let saved_url = parse(&saved.url)?;
    let page_url = parse(page)?;
    // 规则 1：协议降级拒绝
    if saved_url.scheme() == "https" && page_url.scheme() != "https" {
        return None;
    }
    // 端口只比较显式端口：http→https 升级时默认端口 80/443 视为一致
    let same_host = saved_url.host_str()?.eq_ignore_ascii_case(page_url.host_str()?) && saved_url.port() == page_url.port();

    match saved.match_mode {
        UrlMatch::Exact => {
            let strip = |u: &Url| format!("{}{}", u.origin().ascii_serialization(), u.path().trim_end_matches('/'));
            (strip(&saved_url) == strip(&page_url)).then_some(MatchQuality::Exact)
        }
        UrlMatch::Host => same_host.then_some(MatchQuality::Host),
        UrlMatch::Domain => {
            if same_host {
                return Some(MatchQuality::Host);
            }
            // 规则 2/3：只有可注册域名才允许放宽
            let a = registrable_domain(&saved_url)?;
            let b = registrable_domain(&page_url)?;
            (a == b).then_some(MatchQuality::Domain)
        }
        UrlMatch::Never => None,
    }
}

/// 在全部条目中找出匹配当前页面的登录条目，按匹配质量从高到低排序。
pub fn find_matches<'a>(items: &'a [Item], page: &str) -> Vec<(&'a Item, MatchQuality)> {
    let mut out: Vec<(&Item, MatchQuality)> =
        items.iter().filter_map(|item| item.data.urls.iter().filter_map(|u| match_url(u, page)).max().map(|q| (item, q))).collect();
    out.sort_by(|a, b| b.1.cmp(&a.1).then(b.0.data.updated_at.cmp(&a.0.data.updated_at)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(url: &str, m: UrlMatch) -> ItemUrl {
        ItemUrl { url: url.into(), match_mode: m }
    }

    #[test]
    fn domain_mode_matches_subdomains_of_same_registrable_domain() {
        let s = u("https://accounts.example.co.uk/login", UrlMatch::Domain);
        assert_eq!(match_url(&s, "https://www.example.co.uk/"), Some(MatchQuality::Domain));
        assert_eq!(match_url(&s, "https://accounts.example.co.uk/x"), Some(MatchQuality::Host));
        assert_eq!(match_url(&s, "https://example.co.uk.evil.com/"), None);
        assert_eq!(match_url(&s, "https://other.co.uk/"), None);
    }

    #[test]
    fn public_suffix_hosts_are_not_merged() {
        // github.io 是公共后缀：a.github.io 与 b.github.io 属于不同主体
        let s = u("https://alice.github.io", UrlMatch::Domain);
        assert_eq!(match_url(&s, "https://mallory.github.io"), None);
    }

    #[test]
    fn rejects_scheme_downgrade() {
        let s = u("https://bank.example.com", UrlMatch::Domain);
        assert_eq!(match_url(&s, "http://bank.example.com"), None);
        let plain = u("http://intranet.example.com", UrlMatch::Host);
        assert_eq!(match_url(&plain, "https://intranet.example.com"), Some(MatchQuality::Host));
    }

    #[test]
    fn ip_and_single_label_need_exact_host() {
        let s = u("https://192.168.1.10:8443", UrlMatch::Domain);
        assert_eq!(match_url(&s, "https://192.168.1.10:8443/admin"), Some(MatchQuality::Host));
        assert_eq!(match_url(&s, "https://192.168.1.11:8443"), None);
        assert_eq!(match_url(&s, "https://192.168.1.10:9443"), None);
        let local = u("http://nas", UrlMatch::Domain);
        assert_eq!(match_url(&local, "http://nas2"), None);
    }

    #[test]
    fn homograph_domains_do_not_match() {
        let s = u("https://apple.com", UrlMatch::Domain);
        // 西里尔字母 а (U+0430)
        assert_eq!(match_url(&s, "https://\u{0430}pple.com"), None);
    }

    #[test]
    fn exact_and_never_modes() {
        let s = u("https://example.com/login/", UrlMatch::Exact);
        assert_eq!(match_url(&s, "https://example.com/login?next=1"), Some(MatchQuality::Exact));
        assert_eq!(match_url(&s, "https://example.com/other"), None);
        assert_eq!(match_url(&u("https://example.com", UrlMatch::Never), "https://example.com"), None);
    }

    #[test]
    fn bare_hostnames_default_to_https() {
        let s = u("example.com", UrlMatch::Domain);
        assert_eq!(match_url(&s, "https://login.example.com"), Some(MatchQuality::Domain));
        assert_eq!(match_url(&s, "javascript:alert(1)"), None);
    }
}
