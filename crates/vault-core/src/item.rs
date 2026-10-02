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

/// 分类名长度上限（字符数，含层级分隔符）。
pub const CATEGORY_LIMIT: usize = 64;

/// 分类层级深度上限（段数）。超过的部分被截断。
pub const CATEGORY_DEPTH_LIMIT: usize = 6;

/// 分类单段名称长度上限（字符数）。
pub const CATEGORY_SEGMENT_LIMIT: usize = 32;

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
    ///
    /// 分类是**层级路径**（`工作/生产/服务器`）：按 `/` 切段后逐段去空白、丢弃空段，
    /// 再重新拼装。因此 `工作//生产/`、`工作 / 生产` 与 `工作/生产` 是同一个分类，
    /// 树形分组可以直接从条目派生，不需要单独的分组表与新的同步实体。
    ///
    /// 超过 `CATEGORY_DEPTH_LIMIT` 的层级被截断（保留前缀）而不是报错——
    /// 导入的脏数据不应让整次导入失败。
    pub fn normalize_category(category: Option<&str>) -> Option<String> {
        let raw = category?;
        let mut segments: Vec<String> = Vec::new();
        for part in raw.split('/') {
            let trimmed = part.trim();
            if trimmed.is_empty() {
                continue;
            }
            // 单段过长时按字符截断，避免一个异常长的名字撑大条目体积。
            segments.push(trimmed.chars().take(CATEGORY_SEGMENT_LIMIT).collect());
            if segments.len() >= CATEGORY_DEPTH_LIMIT {
                break;
            }
        }
        if segments.is_empty() {
            return None;
        }
        let path: String = segments.join("/");
        // 整条路径也受长度约束，并在截断后去掉可能残留的结尾分隔符。
        let clipped: String = path.chars().take(CATEGORY_LIMIT).collect();
        let clipped = clipped.trim_end_matches('/').to_string();
        (!clipped.is_empty()).then_some(clipped)
    }

    /// 分类路径的全部祖先，由浅到深；`工作/生产/服务器` → `["工作", "工作/生产"]`。
    /// 用于树形展示与「选中某节点时连同后代一起筛选」。
    pub fn category_ancestors(path: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut acc = String::new();
        for part in path.split('/') {
            let trimmed = part.trim();
            if trimmed.is_empty() {
                continue;
            }
            if !acc.is_empty() {
                acc.push('/');
            }
            acc.push_str(trimmed);
            out.push(acc.clone());
        }
        // 最后一个元素是自身；祖先不含自身。
        out.pop();
        out
    }

    /// 该条目的分类是否落在 `prefix` 子树内（含自身）。`prefix` 为 None 表示不过滤。
    pub fn category_matches(&self, prefix: Option<&str>) -> bool {
        let Some(prefix) = prefix else { return true };
        let Some(path) = self.category.as_deref() else { return false };
        path == prefix || path.starts_with(&format!("{prefix}/"))
    }

    /// 就地规范化标签与分类；新建与更新都走这里，保证落库与同步的内容形态一致。
    pub fn normalize_taxonomy(&mut self) {
        self.tags = Self::normalize_tags(&self.tags);
        self.category = Self::normalize_category(self.category.as_deref());
    }
}

/// 分类树节点。树从条目本身派生（不存独立的分组表），因此**空分类不会出现在树里**。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CategoryNode {
    /// 段名（不含父路径）。
    pub name: String,
    /// 完整路径，作为筛选与重命名的标识。
    pub path: String,
    /// 直属该分类的条目数（不含后代）。
    pub direct: usize,
    /// 含后代汇总的条目数（计划书 §3.11「分组条目数含后代汇总」）。
    pub total: usize,
    pub children: Vec<CategoryNode>,
}

/// 从条目集合派生分类树。`None` 分类的条目被忽略（它们不属于任何分类）。
///
/// 排序：同层按段名不区分大小写升序。计划书 §3.11 的自定义 `sortOrder` 需要分组级
/// 元数据，当前设计没有该载体，因此这里固定按名称排序（已在 docs/11 记为未覆盖）。
pub fn build_category_tree<'a>(categories: impl IntoIterator<Item = Option<&'a str>>) -> Vec<CategoryNode> {
    // 先按路径累计直属数量，再据此搭树，避免在树上做插入时反复查找。
    let mut direct: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for path in categories.into_iter().flatten() {
        if let Some(normalized) = ItemData::normalize_category(Some(path)) {
            *direct.entry(normalized).or_insert(0) += 1;
        }
    }

    // 收集所有出现过的路径（含中间层，即使中间层本身没有直属条目）。
    let mut all_paths: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for path in direct.keys() {
        all_paths.insert(path.clone());
        for ancestor in ItemData::category_ancestors(path) {
            all_paths.insert(ancestor);
        }
    }

    fn children_of(path: Option<&str>, all: &std::collections::BTreeSet<String>) -> Vec<String> {
        let prefix = path.map(|p| format!("{p}/"));
        let depth = path.map_or(1, |p| p.split('/').count() + 1);
        all.iter()
            .filter(|candidate| {
                candidate.split('/').count() == depth
                    && match &prefix {
                        Some(prefix) => candidate.starts_with(prefix.as_str()),
                        None => true,
                    }
            })
            .cloned()
            .collect()
    }

    fn build(path: &str, all: &std::collections::BTreeSet<String>, direct: &std::collections::HashMap<String, usize>) -> CategoryNode {
        let name = path.rsplit('/').next().unwrap_or(path).to_string();
        let mut children: Vec<CategoryNode> = children_of(Some(path), all).iter().map(|child| build(child, all, direct)).collect();
        children.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()).then_with(|| a.name.cmp(&b.name)));
        let own = direct.get(path).copied().unwrap_or(0);
        let total = own + children.iter().map(|c| c.total).sum::<usize>();
        CategoryNode { name, path: path.to_string(), direct: own, total, children }
    }

    let mut roots: Vec<CategoryNode> = children_of(None, &all_paths).iter().map(|root| build(root, &all_paths, &direct)).collect();
    roots.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()).then_with(|| a.name.cmp(&b.name)));
    roots
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
        // 单段过长按 `CATEGORY_SEGMENT_LIMIT` 截断（整条路径另有 `CATEGORY_LIMIT` 上限，
        // 由 `category_path_is_capped_in_depth_and_segment_length` 覆盖）。
        assert_eq!(
            ItemData::normalize_category(Some(&"长".repeat(CATEGORY_SEGMENT_LIMIT + 10))).unwrap().chars().count(),
            CATEGORY_SEGMENT_LIMIT
        );
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

    #[test]
    fn category_path_normalization_folds_whitespace_and_empty_segments() {
        for raw in ["工作/生产/服务器", "工作 / 生产 / 服务器", "工作//生产/服务器", "/工作/生产/服务器/"] {
            assert_eq!(ItemData::normalize_category(Some(raw)).as_deref(), Some("工作/生产/服务器"), "「{raw}」应规范化成同一个层级路径");
        }
        // 只有分隔符或空白 → 未分类。
        assert_eq!(ItemData::normalize_category(Some("/")), None);
        assert_eq!(ItemData::normalize_category(Some(" / / ")), None);
    }

    #[test]
    fn category_path_is_capped_in_depth_and_segment_length() {
        let deep = (1..=CATEGORY_DEPTH_LIMIT + 3).map(|i| format!("L{i}")).collect::<Vec<_>>().join("/");
        let normalized = ItemData::normalize_category(Some(&deep)).unwrap();
        assert_eq!(normalized.split('/').count(), CATEGORY_DEPTH_LIMIT, "超出深度的层级应被截断");

        let long = "长".repeat(CATEGORY_SEGMENT_LIMIT + 10);
        assert_eq!(ItemData::normalize_category(Some(&long)).unwrap().chars().count(), CATEGORY_SEGMENT_LIMIT);

        // 截断后的路径仍可再次规范化而不改变（幂等），且不会残留结尾分隔符。
        let again = ItemData::normalize_category(Some(&normalized)).unwrap();
        assert_eq!(again, normalized);
        assert!(!again.ends_with('/'));
    }

    #[test]
    fn category_ancestors_excludes_self_and_is_shallow_to_deep() {
        assert_eq!(ItemData::category_ancestors("工作/生产/服务器"), vec!["工作", "工作/生产"]);
        assert_eq!(ItemData::category_ancestors("工作"), Vec::<String>::new());
        assert_eq!(ItemData::category_ancestors(""), Vec::<String>::new());
    }

    #[test]
    fn category_matches_includes_descendants_only() {
        let mut item = ItemData::new(ItemKind::Login, "服务器");
        item.category = Some("工作/生产/服务器".into());

        assert!(item.category_matches(None), "不过滤时全部匹配");
        assert!(item.category_matches(Some("工作")), "祖先应匹配");
        assert!(item.category_matches(Some("工作/生产")), "祖先应匹配");
        assert!(item.category_matches(Some("工作/生产/服务器")), "自身应匹配");
        assert!(!item.category_matches(Some("工作/生")), "前缀但不是完整段名，不应匹配");
        assert!(!item.category_matches(Some("个人")), "无关分类不应匹配");

        // 未分类条目只在不过滤时匹配。
        let uncategorized = ItemData::new(ItemKind::Login, "未分类");
        assert!(uncategorized.category_matches(None));
        assert!(!uncategorized.category_matches(Some("工作")));
    }

    #[test]
    fn category_tree_aggregates_descendant_counts() {
        let categories = [
            Some("工作/生产/服务器"),
            Some("工作/生产/数据库"),
            Some("工作/生产"),
            Some("工作/个人"),
            Some("个人"),
            None, // 未分类条目不出现在树里
        ];
        let tree = build_category_tree(categories);
        assert_eq!(tree.len(), 2, "根节点应只有「工作」与「个人」");

        let work = tree.iter().find(|n| n.path == "工作").unwrap();
        assert_eq!(work.name, "工作");
        assert_eq!(work.direct, 0, "「工作」本身没有直属条目");
        assert_eq!(work.total, 4, "含后代汇总：生产(3) + 个人(1)");

        let production = work.children.iter().find(|n| n.path == "工作/生产").unwrap();
        assert_eq!(production.direct, 1);
        assert_eq!(production.total, 3, "直属 1 + 两个子分类各 1");
        assert_eq!(production.children.len(), 2);

        let personal = tree.iter().find(|n| n.path == "个人").unwrap();
        assert_eq!(personal.direct, 1);
        assert_eq!(personal.total, 1);
        assert!(personal.children.is_empty());
    }

    #[test]
    fn category_tree_sorts_siblings_by_name_ignoring_case() {
        let tree = build_category_tree([Some("beta"), Some("Alpha"), Some("gamma")]);
        let names: Vec<&str> = tree.iter().map(|n| n.name.as_str()).collect();
        assert_eq!(names, vec!["Alpha", "beta", "gamma"]);
    }

    #[test]
    fn category_tree_ignores_raw_paths_that_normalize_away() {
        // 只有分隔符的脏数据不应产生一个空名节点。
        let tree = build_category_tree([Some("/"), Some(" / / "), Some("工作")]);
        assert_eq!(tree.len(), 1);
        assert_eq!(tree[0].path, "工作");
    }

    #[test]
    fn category_tree_is_empty_without_categories() {
        assert!(build_category_tree([None, None]).is_empty());
        assert!(build_category_tree(std::iter::empty::<Option<&str>>()).is_empty());
    }
}
