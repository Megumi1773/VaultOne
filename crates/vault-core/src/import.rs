//! 从其他密码管理器导入（计划书 P1：Chrome / LastPass / Bitwarden / 1Password，CSV + 1PIF）。
//!
//! CSV 解析用 `csv` crate；本模块只做**列名映射**：各家导出的列名不同，但语义集中在
//! 标题 / 网址 / 用户名 / 密码 / TOTP / 备注 / 收藏几项，按别名表识别即可覆盖：
//!
//! | 来源 | 典型表头 |
//! |---|---|
//! | Chrome / Edge | `name,url,username,password,note` |
//! | Firefox | `url,username,password,httpRealm,…`（无标题列，取主机名） |
//! | Bitwarden | `folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp` |
//! | LastPass | `url,username,password,totp,extra,name,grouping,fav`（`http://sn` 为安全笔记） |
//! | 1Password 8 | `Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes` |
//!
//! 1PIF（1Password 7 交换格式）是以固定分隔行隔开的 JSON 记录，按 `typeName` 映射到四种条目类型。
//!
//! 导入结果只存在于内存，由调用方逐条经 [`crate::Vault::import_items`] 加密入库。
//! 无法识别的 TOTP 值不丢弃，降级为敏感自定义字段。

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::item::{CardData, CustomField, IdentityData, ItemData, ItemKind, ItemUrl};
use crate::{Result, VaultError};

/// 1PIF 记录分隔行
const PIF_SEPARATOR: &str = "***5642bee8-a5ff-11dc-8314-0800200c9a66***";
const TITLE_MAX: usize = 200;

#[derive(Debug)]
pub struct ImportResult {
    /// 识别出的来源（`chrome` / `firefox` / `bitwarden` / `lastpass` / `1password` / `1pif` / `csv`）
    pub format: &'static str,
    pub items: Vec<ItemData>,
    /// 无法转换而跳过的记录数（空行、文件夹、回收站条目等）
    pub skipped: usize,
}

/// 导入结果计数。分开记「覆盖」是因为它改变了既有数据，用户需要看到这一点。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportOutcome {
    pub added: usize,
    pub updated: usize,
    pub duplicates: usize,
    pub invalid: usize,
}

/// 同名判定的键：标题去首尾空白后不区分大小写。
pub fn title_key(title: &str) -> String {
    title.trim().to_lowercase()
}

/// 在「标题 (2)」「标题 (3)」……里找第一个没被占用的。`taken` 为已占用的标题键。
pub fn unique_title(title: &str, taken: &std::collections::HashSet<String>) -> String {
    for n in 2..1000 {
        let candidate = format!("{title} ({n})");
        if !taken.contains(&title_key(&candidate)) {
            return candidate;
        }
    }
    // 999 个同名的极端情况：加个不会重复的后缀，不返回一个必然冲突的名字。
    format!("{title} ({})", uuid::Uuid::new_v4())
}

/// 界面一次预览最多展示的行数。解析仍然处理全部行，只是不把整份文件塞进预览。
pub const PREVIEW_ROWS: usize = 20;

/// 遇到同名条目时的处理策略（计划书 §3.7）。
///
/// `Skip` 与既有行为完全一致（只按内容去重），另外两种只在标题相同时才有区别——
/// 这样新增策略不会悄悄改变老路径的行为。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ImportStrategy {
    /// 保留现有的，导入的同名条目丢弃。
    #[default]
    Skip,
    /// 用导入的内容覆盖同名条目（保留其 ID 与创建时间）。
    Overwrite,
    /// 两条都留：同名条目按「标题 (2)」递增后缀另建一条。
    KeepBoth,
}

/// 源列 → 目标字段的映射。列下标是 CSV 表头里的位置。
///
/// 自动识别可能认错（尤其是自制的通用 CSV），所以这份映射要能由界面覆盖并回传：
/// 用户改完下拉框，后端就按新映射重新解析，而不是让用户自己改名表头再试一次。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ColumnMapping {
    pub title: Option<usize>,
    pub url: Option<usize>,
    pub username: Option<usize>,
    pub password: Option<usize>,
    pub totp: Option<usize>,
    pub notes: Option<usize>,
    pub favorite: Option<usize>,
    pub kind: Option<usize>,
    pub fields: Option<usize>,
    pub tags: Option<usize>,
    pub category: Option<usize>,
}

impl ColumnMapping {
    /// 全部已映射的列下标（用于算出「哪些列没被用到」）。
    fn mapped(&self) -> Vec<usize> {
        [
            self.title,
            self.url,
            self.username,
            self.password,
            self.totp,
            self.notes,
            self.favorite,
            self.kind,
            self.fields,
            self.tags,
            self.category,
        ]
        .into_iter()
        .flatten()
        .collect()
    }
}

/// 导入预览：解析结果 + 供界面核对与调整的原始信息。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportPreview {
    pub format: &'static str,
    /// CSV 表头（1PIF 为空，没有列可映射）。
    pub headers: Vec<String>,
    /// 原始数据的前 [`PREVIEW_ROWS`] 行，与 `headers` 一一对应。
    pub sample_rows: Vec<Vec<String>>,
    /// 数据行总数（不含表头）。
    pub total_rows: usize,
    /// 解析出的条目（尚未入库）。
    pub items: Vec<ItemData>,
    /// 被跳过的行数。
    pub skipped: usize,
    /// 解析警告，逐条可读；空表示没有任何异常。
    pub warnings: Vec<String>,
    /// 当前生效的列映射，供界面回显下拉框。
    pub mapping: ColumnMapping,
    /// 表头里没有任何字段用到的列名。
    pub unused_columns: Vec<String>,
}

/// 自动识别格式并解析。
pub fn parse(content: &str) -> Result<ImportResult> {
    let content = content.trim_start_matches('\u{feff}');
    if content.lines().any(|l| l.trim() == PIF_SEPARATOR) || content.trim_start().starts_with('{') {
        parse_1pif(content)
    } else {
        parse_csv(content)
    }
}

/// 解析并生成预览；`mapping` 非空时用调用方给的映射覆盖自动识别结果。
pub fn preview(content: &str, mapping: Option<ColumnMapping>) -> Result<ImportPreview> {
    let content = content.trim_start_matches('\u{feff}');
    if content.lines().any(|l| l.trim() == PIF_SEPARATOR) || content.trim_start().starts_with('{') {
        let result = parse_1pif(content)?;
        // 1PIF 是结构化 JSON，没有列可映射，也没有可调整的余地。
        let total = result.items.len() + result.skipped;
        return Ok(ImportPreview {
            format: result.format,
            headers: Vec::new(),
            sample_rows: Vec::new(),
            total_rows: total,
            items: result.items,
            skipped: result.skipped,
            warnings: Vec::new(),
            mapping: ColumnMapping::default(),
            unused_columns: Vec::new(),
        });
    }
    parse_csv_preview(content, mapping)
}

// ───────────────────────────── CSV ─────────────────────────────

fn detect(headers: &[String]) -> ColumnMapping {
    ColumnMapping {
        title: find(headers, &["name", "title"]),
        url: find(headers, &["login_uri", "url", "website", "urls", "login url"]),
        username: find(headers, &["login_username", "username", "user name", "login"]),
        password: find(headers, &["login_password", "password"]),
        totp: find(headers, &["login_totp", "totp", "otpauth", "one-time password"]),
        notes: find(headers, &["notes", "note", "extra", "comments"]),
        favorite: find(headers, &["favorite", "fav"]),
        kind: find(headers, &["type"]),
        fields: find(headers, &["fields"]),
        tags: find(headers, &["tags", "tag", "labels", "label"]),
        category: find(headers, &["category", "folder", "grouping", "group"]),
    }
}

fn find(headers: &[String], aliases: &[&str]) -> Option<usize> {
    aliases.iter().find_map(|a| headers.iter().position(|h| h == a))
}

fn detect_csv(headers: &[String]) -> &'static str {
    let has = |h: &str| headers.iter().any(|x| x == h);
    if has("login_uri") || has("login_password") {
        "bitwarden"
    } else if has("grouping") && has("extra") {
        "lastpass"
    } else if has("otpauth") || (has("title") && has("archived")) {
        "1password"
    } else if has("httprealm") || has("formactionorigin") {
        "firefox"
    } else if has("name") && has("url") && has("note") {
        "chrome"
    } else {
        "csv"
    }
}

pub fn parse_csv(content: &str) -> Result<ImportResult> {
    let p = parse_csv_preview(content, None)?;
    Ok(ImportResult { format: p.format, items: p.items, skipped: p.skipped })
}

/// CSV 解析 + 预览。`mapping` 非空时用它覆盖自动识别出来的列映射。
pub fn parse_csv_preview(content: &str, mapping: Option<ColumnMapping>) -> Result<ImportPreview> {
    let mut rdr = csv::ReaderBuilder::new().flexible(true).trim(csv::Trim::Headers).from_reader(content.as_bytes());
    let headers: Vec<String> = rdr
        .headers()
        .map_err(|e| VaultError::InvalidInput(format!("CSV 表头无法解析: {e}")))?
        .iter()
        .map(|h| h.trim().to_ascii_lowercase())
        .collect();
    let format = detect_csv(&headers);
    let cols = mapping.unwrap_or_else(|| detect(&headers));
    if cols.password.is_none() && cols.notes.is_none() {
        return Err(VaultError::InvalidInput("无法识别的 CSV：缺少 password / notes 列".into()));
    }

    let mut items = Vec::new();
    let mut skipped = 0usize;
    let mut total_rows = 0usize;
    let mut sample_rows: Vec<Vec<String>> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();
    let mut totp_downgraded = 0usize;

    for record in rdr.records() {
        total_rows += 1;
        let Ok(record) = record else {
            skipped += 1;
            warnings.push(format!("第 {total_rows} 行格式错误，已跳过"));
            continue;
        };
        if sample_rows.len() < PREVIEW_ROWS {
            sample_rows.push(record.iter().map(|s| s.trim().to_string()).collect());
        }
        let get = |c: Option<usize>| c.and_then(|i| record.get(i)).map(str::trim).filter(|s| !s.is_empty());

        let url = get(cols.url);
        let password = get(cols.password);
        let username = get(cols.username);
        let notes = get(cols.notes);
        // LastPass 用伪网址 http://sn 标记安全笔记；Bitwarden 用 type 列
        let is_note = url == Some("http://sn") || get(cols.kind).is_some_and(|k| k.eq_ignore_ascii_case("note"));
        if password.is_none() && username.is_none() && notes.is_none() && url.is_none() {
            skipped += 1;
            continue;
        }

        let mut data = ItemData::new(if is_note { ItemKind::Note } else { ItemKind::Login }, "");
        if !is_note {
            if let Some(u) = url {
                // Bitwarden 多个网址以逗号连接
                let list: Vec<&str> = if format == "bitwarden" { u.split(',').collect() } else { vec![u] };
                data.urls = list.into_iter().map(str::trim).filter(|s| !s.is_empty()).map(url_entry).collect();
            }
            data.username = username.map(Into::into);
            data.password = password.map(Into::into);
            if let Some(t) = get(cols.totp) {
                // TOTP 认不出来时不丢数据，但要让用户知道它变成了普通字段。
                if crate::totp::parse(t).is_err() {
                    totp_downgraded += 1;
                }
                set_totp(&mut data, t);
            }
        }
        data.notes = notes.map(Into::into);
        data.favorite = get(cols.favorite).is_some_and(|f| matches!(f, "1" | "true" | "TRUE" | "True" | "yes"));
        if let Some(f) = get(cols.fields) {
            data.custom_fields.extend(bitwarden_fields(f));
        }
        // 标签与分类：与导出保持同一格式（`|` 分隔多标签），格式不一致时按单值处理。
        if let Some(t) = get(cols.tags) {
            data.tags = ItemData::normalize_tags(&split_multi(t));
        }
        data.category = ItemData::normalize_category(get(cols.category));
        let title = get(cols.title).map(str::to_string).or_else(|| url.and_then(host_of)).or_else(|| username.map(str::to_string));
        finish(&mut data, title);
        items.push(data);
    }

    if skipped > 0 {
        warnings.push(format!("有 {skipped} 行没有可导入的内容，已跳过"));
    }
    if totp_downgraded > 0 {
        warnings.push(format!("有 {totp_downgraded} 行的两步验证密钥无法识别，已保存为敏感自定义字段"));
    }
    let mapped = cols.mapped();
    let unused_columns: Vec<String> = headers.iter().enumerate().filter(|(i, _)| !mapped.contains(i)).map(|(_, h)| h.clone()).collect();
    if !unused_columns.is_empty() {
        warnings.push(format!("有 {} 列没有被使用：{}", unused_columns.len(), unused_columns.join("、")));
    }

    Ok(ImportPreview { format, headers, sample_rows, total_rows, items, skipped, warnings, mapping: cols, unused_columns })
}

/// 拆分多值字段：兼容 `|`、`,` 与 `;` 三种常见分隔符（Bitwarden 用逗号，部分导出用分号）。
fn split_multi(s: &str) -> Vec<String> {
    s.split(['|', ',', ';']).map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect()
}

/// Bitwarden 的 `fields` 列：每行 `名称: 值`。
fn bitwarden_fields(s: &str) -> Vec<CustomField> {
    s.lines()
        .filter_map(|line| {
            let (label, value) = line.split_once(": ").or_else(|| line.split_once(':'))?;
            Some(CustomField { label: label.trim().into(), value: value.trim().into(), sensitive: false })
        })
        .filter(|f| !f.label.is_empty() || !f.value.is_empty())
        .collect()
}

// ───────────────────────────── 1PIF ─────────────────────────────

pub fn parse_1pif(content: &str) -> Result<ImportResult> {
    let mut items = Vec::new();
    let mut skipped = 0;
    let mut parsed_any = false;
    for chunk in content.split(PIF_SEPARATOR) {
        let chunk = chunk.trim();
        if chunk.is_empty() {
            continue;
        }
        let Ok(rec) = serde_json::from_str::<Value>(chunk) else {
            skipped += 1;
            continue;
        };
        parsed_any = true;
        match pif_record(&rec) {
            Some(item) => items.push(item),
            None => skipped += 1,
        }
    }
    if !parsed_any {
        return Err(VaultError::InvalidInput("无法识别的 1PIF 文件".into()));
    }
    Ok(ImportResult { format: "1pif", items, skipped })
}

fn s<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
}

/// 1PIF 字段值可能是字符串、数字（如有效期 202612）或对象（地址）。
fn value_text(v: &Value) -> Option<String> {
    match v {
        Value::String(s) if !s.trim().is_empty() => Some(s.trim().to_string()),
        Value::Number(n) => Some(n.to_string()),
        Value::Object(o) => {
            let parts: Vec<&str> = ["street", "city", "state", "zip", "country"]
                .iter()
                .filter_map(|k| o.get(*k).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()))
                .collect();
            (!parts.is_empty()).then(|| parts.join(", "))
        }
        _ => None,
    }
}

/// 展开 `secureContents.sections[].fields[]` 为 (名称 n, 标签 t, 类型 k, 值)。
fn section_fields(sc: &Value) -> Vec<(String, String, String, String)> {
    let mut out = Vec::new();
    for section in sc.get("sections").and_then(Value::as_array).into_iter().flatten() {
        for f in section.get("fields").and_then(Value::as_array).into_iter().flatten() {
            if let Some(v) = f.get("v").and_then(value_text) {
                let get = |k| f.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
                out.push((get("n"), get("t"), get("k"), v));
            }
        }
    }
    out
}

fn pif_record(rec: &Value) -> Option<ItemData> {
    let type_name = s(rec, "typeName").unwrap_or_default();
    if type_name.starts_with("system.") || rec.get("trashed").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let empty = Value::Null;
    let sc = rec.get("secureContents").unwrap_or(&empty);
    let mut fields = section_fields(sc);
    let take = |fields: &mut Vec<(String, String, String, String)>, names: &[&str]| -> Option<String> {
        let i = fields.iter().position(|(n, ..)| names.contains(&n.as_str()))?;
        Some(fields.remove(i).3)
    };

    let kind = match type_name {
        "webforms.WebForm" | "passwords.Password" => ItemKind::Login,
        "wallet.financial.CreditCard" => ItemKind::Card,
        "identities.Identity" => ItemKind::Identity,
        _ => ItemKind::Note,
    };
    let mut data = ItemData::new(kind, "");
    data.notes = s(sc, "notesPlain").map(Into::into);
    data.favorite = rec.get("faveIndex").is_some();

    match kind {
        ItemKind::Login => {
            let designated = |d: &str| {
                sc.get("fields")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .find_map(|f| (f.get("designation").and_then(Value::as_str) == Some(d)).then(|| s(f, "value")).flatten())
            };
            data.username = designated("username").map(Into::into);
            data.password = designated("password").or_else(|| s(sc, "password")).map(Into::into);
            let mut urls: Vec<String> =
                sc.get("URLs").and_then(Value::as_array).into_iter().flatten().filter_map(|u| s(u, "url").map(str::to_string)).collect();
            if urls.is_empty() {
                urls.extend(s(rec, "location").map(str::to_string));
            }
            data.urls = urls.iter().map(|u| url_entry(u)).collect();
            if let Some(i) = fields.iter().position(|(n, _, _, v)| n.starts_with("TOTP_") || v.starts_with("otpauth://")) {
                let totp = fields.remove(i).3;
                set_totp(&mut data, &totp);
            }
        }
        ItemKind::Card => {
            data.card = Some(CardData {
                cardholder: take(&mut fields, &["cardholder"]).unwrap_or_default(),
                number: take(&mut fields, &["ccnum"]).unwrap_or_default(),
                expiry: take(&mut fields, &["expiry"]).map(|e| format_expiry(&e)).unwrap_or_default(),
                cvv: take(&mut fields, &["cvv"]).unwrap_or_default(),
                pin: take(&mut fields, &["pin"]).unwrap_or_default(),
            });
        }
        ItemKind::Identity => {
            let first = take(&mut fields, &["firstname"]).unwrap_or_default();
            let last = take(&mut fields, &["lastname"]).unwrap_or_default();
            data.identity = Some(IdentityData {
                full_name: [first, last].into_iter().filter(|x| !x.is_empty()).collect::<Vec<_>>().join(" "),
                email: take(&mut fields, &["email"]).unwrap_or_default(),
                phone: take(&mut fields, &["defphone", "cellphone", "homephone", "busphone"]).unwrap_or_default(),
                id_number: String::new(),
                address: take(&mut fields, &["address"]).unwrap_or_default(),
                company: take(&mut fields, &["company"]).unwrap_or_default(),
            });
        }
        ItemKind::Note => {}
    }
    // 其余字段原样保留为自定义字段；concealed 类型标为敏感
    data.custom_fields.extend(fields.into_iter().map(|(n, t, k, v)| CustomField {
        label: if t.is_empty() { n } else { t },
        value: v,
        sensitive: k == "concealed",
    }));
    let title = s(rec, "title").map(str::to_string);
    finish(&mut data, title);
    Some(data)
}

/// 1PIF 有效期是 `YYYYMM` 数字，转为 `MM/YY`。
fn format_expiry(raw: &str) -> String {
    if raw.len() == 6 && raw.chars().all(|c| c.is_ascii_digit()) {
        format!("{}/{}", &raw[4..6], &raw[2..4])
    } else {
        raw.to_string()
    }
}

// ───────────────────────────── 公共 ─────────────────────────────

fn url_entry(u: &str) -> ItemUrl {
    ItemUrl { url: u.to_string(), ..Default::default() }
}

fn host_of(u: &str) -> Option<String> {
    let with_scheme = if u.contains("://") { u.to_string() } else { format!("https://{u}") };
    url::Url::parse(&with_scheme).ok()?.host_str().map(|h| h.trim_start_matches("www.").to_string())
}

/// otpauth 链接或 Base32 密钥 → TotpConfig；无法识别则保存为敏感自定义字段，不丢数据。
fn set_totp(data: &mut ItemData, raw: &str) {
    match crate::totp::parse(raw) {
        Ok(auth) => data.totp = Some(auth.config.clone()),
        Err(_) => data.custom_fields.push(CustomField { label: "TOTP".into(), value: raw.into(), sensitive: true }),
    }
}

fn finish(data: &mut ItemData, title: Option<String>) {
    let title = title.unwrap_or_else(|| "导入的条目".into());
    data.title = title.chars().take(TITLE_MAX).collect();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chrome_csv() {
        let csv = "\u{feff}name,url,username,password,note\n\
                   example.com,https://example.com/login,alice,pw1,\n\
                   ,https://www.github.com/,bob,pw2,\"多行\n备注\"\n";
        let r = parse(csv).unwrap();
        assert_eq!(r.format, "chrome");
        assert_eq!(r.items.len(), 2);
        assert_eq!(r.items[0].title, "example.com");
        assert_eq!(r.items[0].urls[0].url, "https://example.com/login");
        assert_eq!(r.items[0].password.as_deref(), Some("pw1"));
        assert_eq!(r.items[1].title, "github.com");
        assert_eq!(r.items[1].notes.as_deref(), Some("多行\n备注"));
    }

    #[test]
    fn firefox_csv_without_title() {
        let csv = "\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\"\n\
                   \"https://accounts.example.org\",\"carol\",\"pw\",,\"https://accounts.example.org\",\"{x}\"\n";
        let r = parse(csv).unwrap();
        assert_eq!(r.format, "firefox");
        assert_eq!(r.items[0].title, "accounts.example.org");
    }

    #[test]
    fn bitwarden_csv() {
        let csv = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n\
                   ,1,login,GitHub,,\"PIN: 1234\nrecovery: abc\",0,\"https://github.com,https://gist.github.com\",dave,pw,JBSWY3DPEHPK3PXP\n\
                   ,,note,Wi-Fi,SSID home,,0,,,,\n";
        let r = parse(csv).unwrap();
        assert_eq!(r.format, "bitwarden");
        let gh = &r.items[0];
        assert!(gh.favorite);
        assert_eq!(gh.urls.len(), 2);
        assert_eq!(gh.totp.as_ref().unwrap().secret, "JBSWY3DPEHPK3PXP");
        assert_eq!(gh.custom_fields.len(), 2);
        assert_eq!(gh.custom_fields[0].label, "PIN");
        assert_eq!(gh.custom_fields[0].value, "1234");
        assert_eq!(r.items[1].kind, ItemKind::Note);
        assert_eq!(r.items[1].notes.as_deref(), Some("SSID home"));
    }

    #[test]
    fn lastpass_csv() {
        let csv = "url,username,password,totp,extra,name,grouping,fav\n\
                   https://mail.example.com,erin,pw,otpauth://totp/x?secret=JBSWY3DPEHPK3PXP,,Mail,Work,0\n\
                   http://sn,,,,护照号 E123,护照,Personal,1\n\
                   https://bad.example,frank,pw,not-a-secret!,,Bad,,0\n";
        let r = parse(csv).unwrap();
        assert_eq!(r.format, "lastpass");
        assert!(r.items[0].totp.is_some());
        assert_eq!(r.items[1].kind, ItemKind::Note);
        assert!(r.items[1].urls.is_empty());
        assert!(r.items[1].favorite);
        // 无法识别的 TOTP 降级为敏感自定义字段
        assert!(r.items[2].totp.is_none());
        assert!(r.items[2].custom_fields[0].sensitive);
    }

    #[test]
    fn onepassword_csv() {
        let csv = "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\n\
                   Bank,https://bank.example,gina,pw,,true,false,,\n";
        let r = parse(csv).unwrap();
        assert_eq!(r.format, "1password");
        assert_eq!(r.items[0].title, "Bank");
        assert!(r.items[0].favorite);
    }

    #[test]
    fn rejects_unknown_csv_and_skips_empty_rows() {
        assert!(parse("a,b,c\n1,2,3\n").is_err());
        let r = parse("name,url,username,password,note\n,,,,\n").unwrap();
        assert_eq!(r.items.len(), 0);
        assert_eq!(r.skipped, 1);
    }

    #[test]
    fn onepif() {
        let pif = format!(
            "{}\n{sep}\n{}\n{sep}\n{}\n{sep}\n{}\n{sep}\n{}\n{sep}\n",
            r#"{"typeName":"webforms.WebForm","title":"Example","location":"https://example.com","faveIndex":1,"secureContents":{"fields":[{"designation":"username","value":"hank"},{"designation":"password","value":"pw"}],"URLs":[{"url":"https://example.com/login"}],"sections":[{"fields":[{"n":"TOTP_1","t":"一次性密码","k":"concealed","v":"otpauth://totp/x?secret=JBSWY3DPEHPK3PXP"},{"n":"q","t":"安全问题","k":"concealed","v":"蓝色"}]}]}}"#,
            r#"{"typeName":"wallet.financial.CreditCard","title":"Visa","secureContents":{"sections":[{"fields":[{"n":"cardholder","v":"Hank"},{"n":"ccnum","v":"4111111111111111"},{"n":"expiry","k":"monthYear","v":202612},{"n":"cvv","v":"123"}]}]}}"#,
            r#"{"typeName":"identities.Identity","title":"我","secureContents":{"sections":[{"fields":[{"n":"firstname","v":"Hank"},{"n":"lastname","v":"Hill"},{"n":"address","k":"address","v":{"street":"1 Main St","city":"Arlen","country":"us"}}]}]}}"#,
            r#"{"typeName":"securenotes.SecureNote","title":"笔记","secureContents":{"notesPlain":"内容"}}"#,
            r#"{"typeName":"system.folder.Regular","title":"文件夹"}"#,
            sep = PIF_SEPARATOR
        );
        let r = parse(&pif).unwrap();
        assert_eq!(r.format, "1pif");
        assert_eq!(r.items.len(), 4);
        assert_eq!(r.skipped, 1);

        let login = &r.items[0];
        assert_eq!(login.username.as_deref(), Some("hank"));
        assert_eq!(login.urls[0].url, "https://example.com/login");
        assert!(login.totp.is_some());
        assert!(login.favorite);
        assert_eq!(login.custom_fields.len(), 1);
        assert!(login.custom_fields[0].sensitive);

        let card = r.items[1].card.as_ref().unwrap();
        assert_eq!(card.number, "4111111111111111");
        assert_eq!(card.expiry, "12/26");

        let id = r.items[2].identity.as_ref().unwrap();
        assert_eq!(id.full_name, "Hank Hill");
        assert_eq!(id.address, "1 Main St, Arlen, us");

        assert_eq!(r.items[3].notes.as_deref(), Some("内容"));
    }

    // ───────────── 预览与列映射（§3.7）─────────────

    #[test]
    fn preview_exposes_headers_rows_and_mapping() {
        let csv = "name,url,username,password,note\n\
                   GitHub,https://github.com,alice,pw1,\n\
                   GitLab,https://gitlab.com,bob,pw2,\n";
        let p = preview(csv, None).unwrap();
        assert_eq!(p.format, "chrome");
        assert_eq!(p.headers, vec!["name", "url", "username", "password", "note"]);
        assert_eq!(p.total_rows, 2);
        assert_eq!(p.sample_rows.len(), 2);
        assert_eq!(p.sample_rows[0][0], "GitHub");
        assert_eq!(p.items.len(), 2);
        assert_eq!(p.skipped, 0);
        assert!(p.warnings.is_empty(), "干净的 CSV 不该有警告：{:?}", p.warnings);
        assert!(p.unused_columns.is_empty());
        // 映射要能回传给界面回显下拉框。
        assert_eq!(p.mapping.title, Some(0));
        assert_eq!(p.mapping.password, Some(3));
    }

    #[test]
    fn preview_caps_sample_rows_but_parses_everything() {
        let mut csv = String::from("name,url,username,password,note\n");
        for i in 0..50 {
            csv.push_str(&format!("item{i},https://e{i}.example,u{i},pw{i},\n"));
        }
        let p = preview(&csv, None).unwrap();
        assert_eq!(p.sample_rows.len(), PREVIEW_ROWS, "预览只取前 {PREVIEW_ROWS} 行");
        assert_eq!(p.total_rows, 50);
        assert_eq!(p.items.len(), 50, "解析仍处理全部行");
    }

    #[test]
    fn preview_warns_about_unused_columns_and_skipped_rows() {
        let csv = "name,url,username,password,note,mystery\n\
                   GitHub,https://github.com,alice,pw1,,x\n\
                   ,,,,\n";
        let p = preview(csv, None).unwrap();
        assert_eq!(p.unused_columns, vec!["mystery"]);
        assert!(p.warnings.iter().any(|w| w.contains("mystery")), "{:?}", p.warnings);
        assert!(p.warnings.iter().any(|w| w.contains("1 行")), "应报告跳过行数：{:?}", p.warnings);
    }

    #[test]
    fn preview_warns_when_totp_is_downgraded() {
        let csv = "name,url,username,password,totp\nGitHub,https://github.com,alice,pw,not-a-secret!\n";
        let p = preview(csv, None).unwrap();
        assert!(p.warnings.iter().any(|w| w.contains("两步验证")), "{:?}", p.warnings);
        assert!(p.items[0].totp.is_none());
        assert!(p.items[0].custom_fields[0].sensitive, "认不出来的密钥要保存成敏感字段，不能丢");
    }

    #[test]
    fn explicit_mapping_overrides_detection() {
        // 自制 CSV：列名认不出来，只有 password 靠别名命中，因此 title/url 都没映射上。
        let csv = "col1,col2,col3,password\nMyBank,https://bank.example,alice,pw\n";
        let auto = preview(csv, None).unwrap();
        assert_eq!(auto.mapping.title, None);
        assert_eq!(auto.mapping.username, None, "col3 不在用户名的别名表里");
        // 只有 password 命中时推不出标题，落到兜底标题——这正是需要手动映射的理由。
        assert_ne!(auto.items[0].title, "MyBank");
        assert!(auto.unused_columns.contains(&"col1".to_string()));

        let mapped =
            preview(csv, Some(ColumnMapping { title: Some(0), url: Some(1), username: Some(2), password: Some(3), ..Default::default() }))
                .unwrap();
        assert_eq!(mapped.items[0].title, "MyBank");
        assert_eq!(mapped.items[0].urls[0].url, "https://bank.example");
        assert!(mapped.unused_columns.is_empty(), "全部列都用上了：{:?}", mapped.unused_columns);
    }

    #[test]
    fn mapping_roundtrips_through_json() {
        let mapping = ColumnMapping { title: Some(0), password: Some(2), ..Default::default() };
        let json = serde_json::to_string(&mapping).unwrap();
        let back: ColumnMapping = serde_json::from_str(&json).unwrap();
        assert_eq!(back, mapping);
        // 缺字段的载荷按「未映射」处理，不报错。
        let partial: ColumnMapping = serde_json::from_str(r#"{"title":1}"#).unwrap();
        assert_eq!(partial.title, Some(1));
        assert_eq!(partial.password, None);
    }

    #[test]
    fn pif_preview_has_no_columns_to_map() {
        let pif = format!(
            "{}\n{sep}\n",
            r#"{"typeName":"securenotes.SecureNote","title":"笔记","secureContents":{"notesPlain":"内容"}}"#,
            sep = PIF_SEPARATOR
        );
        let p = preview(&pif, None).unwrap();
        assert_eq!(p.format, "1pif");
        assert!(p.headers.is_empty(), "1PIF 是结构化数据，没有列可映射");
        assert_eq!(p.items.len(), 1);
        assert!(p.warnings.is_empty());
    }

    #[test]
    fn unique_title_skips_taken_names() {
        let taken: std::collections::HashSet<String> = ["github", "github (2)"].iter().map(|s| title_key(s)).collect();
        assert_eq!(unique_title("GitHub", &taken), "GitHub (3)");
        assert_eq!(unique_title("Fresh", &std::collections::HashSet::new()), "Fresh (2)");
    }

    #[test]
    fn title_key_ignores_case_and_surrounding_space() {
        assert_eq!(title_key("  GitHub  "), title_key("github"));
        assert_ne!(title_key("GitHub"), title_key("GitLab"));
    }
}
