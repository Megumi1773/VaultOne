//! 条目明文结构（计划书 §4.3）。只在客户端内存中存在，序列化后立即以 AES-256-GCM 密封。

use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UrlMatch {
    #[default]
    Domain,
    Host,
    Exact,
    Never,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct ItemUrl {
    pub url: String,
    #[serde(rename = "match", default)]
    #[zeroize(skip)]
    pub match_mode: UrlMatch,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
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

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct CustomField {
    pub label: String,
    pub value: String,
    #[serde(default)]
    pub sensitive: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct PasswordHistoryEntry {
    pub p: String,
    pub t: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
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

#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
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

/// 单个条目的标签数量上限；超出的标签被丢弃而不是报错，避免导入的脏数据让整次导入失败。
pub const TAG_LIMIT: usize = 20;

/// 分类名长度上限（字符数）。
pub const CATEGORY_LIMIT: usize = 64;

/// 条目明文。所有字符串字段在 drop 时清零。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
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
    /// 多标签（计划书 §3.6）。规范化后存储：去空白、小写、去重、保序。
    /// 旧库缺少该字段时按空数组读取（`serde(default)`），保持向前兼容。
    #[serde(default)]
    pub tags: Vec<String>,
    /// 单选分类（计划书 §3.6）；`None` 表示未分类。分类名是用户自由输入，不做大小写折叠。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub updated_at: i64,
}

impl ItemData {
    /// 导入去重键：仅排除新建条目时会重写的创建/更新时间。
    /// ID、保险库 ID、版本在 Item 上，不参与内容比较。密码历史（含历史时间）是可恢复数据，
    /// 与类型、收藏、全部 URL/匹配规则、自定义字段等一起保留；数组顺序及 None/空值严格区分。
    /// 使用完整结构的 Hash + Eq，而非仅比较摘要，避免摘要碰撞被当成重复；drop 时仍清零。
    pub(crate) fn into_import_content(mut self) -> Self {
        self.created_at = 0;
        self.updated_at = 0;
        self
    }

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
            tags: vec![],
            category: None,
            created_at: 0,
            updated_at: 0,
        }
    }

    /// 规范化标签：去首尾空白、丢弃空标签、按小写去重并保持原有顺序。
    ///
    /// 大小写不敏感去重意味着「Work」与「work」是同一个标签；保留首次出现的写法，
    /// 让用户的拼写不被静默改写。上限 `TAG_LIMIT` 防止单个条目膨胀同步负载。
    pub fn normalize_tags(tags: &[String]) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::new();
        for raw in tags {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                continue;
            }
            let key = trimmed.to_lowercase();
            if seen.insert(key) {
                out.push(trimmed.to_string());
            }
            if out.len() >= TAG_LIMIT {
                break;
            }
        }
        out
    }

    /// 规范化分类：去首尾空白，空串等价于「未分类」。
    pub fn normalize_category(category: Option<&str>) -> Option<String> {
        category.map(str::trim).filter(|c| !c.is_empty()).map(|c| c.chars().take(CATEGORY_LIMIT).collect())
    }

    /// 就地规范化标签与分类；新建与更新都走这里，保证落库与同步的内容形态一致。
    pub fn normalize_taxonomy(&mut self) {
        self.tags = Self::normalize_tags(&self.tags);
        self.category = Self::normalize_category(self.category.as_deref());
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

    #[test]
    fn tags_and_category_default_for_legacy_json() {
        // 旧库的条目没有 tags / category，必须能照常读取，而不是反序列化失败。
        let legacy = r#"{"type":"login","title":"旧条目","urls":[],"customFields":[],"favorite":false}"#;
        let data: ItemData = serde_json::from_str(legacy).unwrap();
        assert!(data.tags.is_empty());
        assert_eq!(data.category, None);
    }

    #[test]
    fn tag_normalization_trims_dedupes_case_insensitively_and_keeps_order() {
        let tags: Vec<String> = ["  工作 ", "work", "WORK", "", "  ", "个人"].iter().map(|s| s.to_string()).collect();
        assert_eq!(ItemData::normalize_tags(&tags), vec!["工作", "work", "个人"]);
    }

    #[test]
    fn tag_normalization_caps_count() {
        let many: Vec<String> = (0..TAG_LIMIT + 5).map(|i| format!("t{i}")).collect();
        assert_eq!(ItemData::normalize_tags(&many).len(), TAG_LIMIT);
    }

    #[test]
    fn category_normalization_treats_blank_as_uncategorized() {
        assert_eq!(ItemData::normalize_category(Some("  银行  ")), Some("银行".to_string()));
        assert_eq!(ItemData::normalize_category(Some("   ")), None);
        assert_eq!(ItemData::normalize_category(None), None);
        assert_eq!(ItemData::normalize_category(Some(&"长".repeat(CATEGORY_LIMIT + 10))).unwrap().chars().count(), CATEGORY_LIMIT);
    }

    #[test]
    fn normalize_taxonomy_is_idempotent() {
        let mut data = ItemData::new(ItemKind::Login, "银行");
        data.tags = vec![" 工作 ".into(), "WORK".into(), "work".into()];
        data.category = Some("  金融  ".into());
        data.normalize_taxonomy();
        let once = data.clone();
        data.normalize_taxonomy();
        assert_eq!(data, once, "重复规范化不应继续改变内容");
        assert_eq!(once.tags, vec!["工作", "WORK"]);
        assert_eq!(once.category.as_deref(), Some("金融"));
    }
}
