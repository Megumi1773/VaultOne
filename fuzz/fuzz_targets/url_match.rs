//! URL 匹配（页面 URL 来自任意网站）：不 panic，且满足防钓鱼不变量——https 条目绝不匹配非 https 页面。
#![no_main]
use libfuzzer_sys::fuzz_target;
use vault_core::item::{ItemUrl, UrlMatch};
use vault_core::urlmatch::match_url;

fuzz_target!(|input: (&str, &str, u8)| {
    let (saved, page, mode) = input;
    let match_mode = [UrlMatch::Domain, UrlMatch::Host, UrlMatch::Exact, UrlMatch::Never][(mode % 4) as usize];
    let item = ItemUrl { url: saved.to_string(), match_mode };
    let result = match_url(&item, page);
    if match_mode == UrlMatch::Never {
        assert!(result.is_none());
    }
    if result.is_some() && saved.trim().to_ascii_lowercase().starts_with("https://") {
        assert!(page.trim().to_ascii_lowercase().starts_with("https://") || !page.contains("://"));
    }
});
