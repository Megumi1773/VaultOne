//! 条目明文结构（计划书 §4.3）。只在客户端内存中存在，序列化后立即以 AES-256-GCM 密封。

use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ItemKind {
    Login,
    Card,
    Note,
    Identity,
}

impl ItemKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ItemKind::Login => "login",
            ItemKind::Card => "card",
            ItemKind::Note => "note",
            ItemKind::Identity => "identity",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "login" => ItemKind::Login,
            "card" => ItemKind::Card,
            "note" => ItemKind::Note,
            "identity" => ItemKind::Identity,
            _ => return None,
        })
    }
}

/// URL 匹配策略。自动填充（M3）按此做 eTLD+1 / host / 精确匹配。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UrlMatch {
    #[default]
    Domain,
    Host,
    Exact,
    Never,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct ItemUrl {
    pub url: String,
    #[serde(rename = "match", default)]
    #[zeroize(skip)]
    pub match_mode: UrlMatch,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct TotpConfig {
    pub secret: String,
    #[serde(default = "default_alg")]
    pub alg: String,
    #[serde(default = "default_digits")]
    pub digits: u32,
    #[serde(default = "default_period")]
    pub period: u32,
}

fn default_alg() -> String {
    "SHA1".into()
}
fn default_digits() -> u32 {
    6
}
fn default_period() -> u32 {
    30
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct CustomField {
    pub label: String,
    pub value: String,
    #[serde(default)]
    pub sensitive: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct PasswordHistoryEntry {
    pub p: String,
    pub t: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct CardData {
    #[serde(default)]
    pub cardholder: String,
    #[serde(default)]
    pub number: String,
    #[serde(default)]
    pub expiry: String,
    #[serde(default)]
    pub cvv: String,
    #[serde(default)]
    pub pin: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct IdentityData {
    #[serde(default)]
    pub full_name: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub phone: String,
    #[serde(default)]
    pub id_number: String,
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub company: String,
}

/// 条目明文。所有字符串字段在 drop 时清零。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct ItemData {
    #[serde(rename = "type")]
    #[zeroize(skip)]
    pub kind: ItemKind,
    pub title: String,
    #[serde(default)]
    pub urls: Vec<ItemUrl>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub totp: Option<TotpConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub card: Option<CardData>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<IdentityData>,
    #[serde(default)]
    pub custom_fields: Vec<CustomField>,
    #[serde(default)]
    pub password_history: Vec<PasswordHistoryEntry>,
    #[serde(default)]
    pub favorite: bool,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub updated_at: i64,
}

impl ItemData {
    pub fn new(kind: ItemKind, title: impl Into<String>) -> Self {
        Self {
            kind,
            title: title.into(),
            urls: vec![],
            username: None,
            password: None,
            totp: None,
            notes: None,
            card: None,
            identity: None,
            custom_fields: vec![],
            password_history: vec![],
            favorite: false,
            created_at: 0,
            updated_at: 0,
        }
    }
}

/// 解密后的完整条目（含存储元数据）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    pub id: String,
    pub vault_id: String,
    pub revision: i64,
    pub data: ItemData,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_matches_spec_shape() {
        let mut item = ItemData::new(ItemKind::Login, "某银行企业网银");
        item.urls.push(ItemUrl { url: "https://ebank.example.com".into(), match_mode: UrlMatch::Host });
        item.username = Some("user@example.com".into());
        item.totp = Some(TotpConfig { secret: "JBSWY3DPEHPK3PXP".into(), alg: "SHA1".into(), digits: 6, period: 30 });
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "login");
        assert_eq!(json["urls"][0]["match"], "host");
        assert!(json.get("customFields").is_some());
        assert!(json.get("password").is_none());

        let back: ItemData = serde_json::from_value(json).unwrap();
        assert_eq!(back, item);
    }
}
