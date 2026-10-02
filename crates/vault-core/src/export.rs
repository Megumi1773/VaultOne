//! 导出：加密备份包（`.wljbak`）与明文 CSV。
//!
//! `.wljbak` 布局：
//!
//! ```text
//! magic(7) ‖ sealed( seal(vault_key, JSON{format, exportedAt, items}, aad = account_id) )
//! ```
//!
//! 载荷用账户的 Vault Key 密封——只有同一账户（主密码 + Secret Key 解锁后得到同一
//! Vault Key）才能还原，服务端全程不参与。`account_id` 作为 AAD，备份被挪到别的账户
//! 下无法打开。CSV 为明文迁移格式，导出前必须提示用户妥善保管。

use serde::{Deserialize, Serialize};
use vault_crypto::{sealed, Key32};

use crate::item::{Item, ItemData};
use crate::{Result, VaultError};

/// 文件魔数：`WLJBAK` + 格式版本字节。
pub const MAGIC: &[u8; 7] = b"WLJBAK\x01";
/// 载荷内部格式版本。
pub const FORMAT: u32 = 1;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Payload {
    format: u32,
    exported_at: i64,
    items: Vec<ItemData>,
}

/// 打包加密备份。条目只在此处序列化后立即密封，明文不落盘。
pub fn backup(vault_key: &Key32, account_id: &str, items: &[ItemData]) -> Result<Vec<u8>> {
    let payload = Payload { format: FORMAT, exported_at: crate::vault::now(), items: items.to_vec() };
    let json = serde_json::to_vec(&payload)?;
    let body = sealed::seal(vault_key, &json, account_id.as_bytes())?;
    let mut out = Vec::with_capacity(MAGIC.len() + body.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&body);
    Ok(out)
}

/// 解开加密备份，返回其中的条目。魔数 / 版本 / 账户不符或密文被篡改都返回错误。
pub fn restore(vault_key: &Key32, account_id: &str, data: &[u8]) -> Result<Vec<ItemData>> {
    let body = data.strip_prefix(MAGIC.as_slice()).ok_or_else(|| VaultError::InvalidInput("不是 VaultOne 备份包".into()))?;
    let json = sealed::open(vault_key, body, account_id.as_bytes())?;
    let payload: Payload = serde_json::from_slice(&json).map_err(|_| VaultError::Integrity)?;
    if payload.format != FORMAT {
        return Err(VaultError::InvalidInput(format!("备份格式版本 {} 不受支持", payload.format)));
    }
    Ok(payload.items)
}

/// 导出为通用 CSV（明文）。列：name,url,username,password,notes,totp,favorite,type,tags,category。
///
/// `tags` 以 `|` 分隔（CSV 字段转义会处理其中的逗号场景，但用分隔符更易被电子表格识别为多值）。
pub fn to_csv(items: &[Item]) -> String {
    let mut out = String::from("name,url,username,password,notes,totp,favorite,type,tags,category\n");
    for it in items {
        let d = &it.data;
        let url = d.urls.first().map(|u| u.url.as_str()).unwrap_or("");
        let totp = d.totp.as_ref().map(|t| t.secret.as_str()).unwrap_or("");
        let tags = d.tags.join("|");
        let row = [
            d.title.as_str(),
            url,
            d.username.as_deref().unwrap_or(""),
            d.password.as_deref().unwrap_or(""),
            d.notes.as_deref().unwrap_or(""),
            totp,
            if d.favorite { "true" } else { "false" },
            d.kind.as_str(),
            tags.as_str(),
            d.category.as_deref().unwrap_or(""),
        ];
        for (i, f) in row.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&csv_field(f));
        }
        out.push('\n');
    }
    out
}

/// RFC 4180 字段转义：含逗号 / 引号 / 换行时用双引号包裹，内部引号翻倍。
fn csv_field(s: &str) -> String {
    if s.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::ItemKind;

    fn sample() -> ItemData {
        let mut d = ItemData::new(ItemKind::Login, "示例");
        d.username = Some("u@example.com".into());
        d.password = Some("p@ss".into());
        d
    }

    #[test]
    fn backup_roundtrip() {
        let key = Key32::random().unwrap();
        let items = vec![sample()];
        let blob = backup(&key, "acct-1", &items).unwrap();
        assert_eq!(&blob[..MAGIC.len()], MAGIC);
        let back = restore(&key, "acct-1", &blob).unwrap();
        assert_eq!(back, items);
    }

    #[test]
    fn wrong_account_or_key_fails() {
        let key = Key32::random().unwrap();
        let blob = backup(&key, "acct-1", &[sample()]).unwrap();
        assert!(restore(&key, "acct-2", &blob).is_err());
        assert!(restore(&Key32::random().unwrap(), "acct-1", &blob).is_err());
    }

    #[test]
    fn tamper_and_missing_magic_rejected() {
        let key = Key32::random().unwrap();
        let blob = backup(&key, "a", &[sample()]).unwrap();
        let mut t = blob.clone();
        let last = t.len() - 1;
        t[last] ^= 0x01;
        assert!(restore(&key, "a", &t).is_err());
        assert!(restore(&key, "a", b"not a backup").is_err());
    }

    #[test]
    fn csv_escapes_and_headers() {
        let mut d = ItemData::new(ItemKind::Login, "a,b");
        d.username = Some("quote\"x".into());
        d.notes = Some("line1\nline2".into());
        d.tags = vec!["工作".into(), "生产".into()];
        d.category = Some("基础设施".into());
        let item = Item { id: "1".into(), vault_id: "v".into(), revision: 1, data: d };
        let csv = to_csv(&[item]);
        let mut lines = csv.lines();
        assert_eq!(lines.next().unwrap(), "name,url,username,password,notes,totp,favorite,type,tags,category");
        assert!(csv.contains("\"a,b\""));
        assert!(csv.contains("\"quote\"\"x\""));
        assert!(csv.contains("\"line1\nline2\""));
        // 多标签以 `|` 连接，分类单独成列。
        assert!(csv.contains("工作|生产"), "标签应作为一列导出：{csv}");
        assert!(csv.contains("基础设施"), "分类应作为一列导出：{csv}");
    }

    /// CSV 往返：导出的标签与分类必须能被导入解析回同样的值。
    #[test]
    fn csv_roundtrip_keeps_tags_and_category() {
        let mut d = ItemData::new(ItemKind::Login, "GitHub");
        d.username = Some("alice".into());
        d.password = Some("pw".into());
        d.tags = vec!["工作".into(), "生产".into()];
        d.category = Some("基础设施".into());
        let item = Item { id: "1".into(), vault_id: "v".into(), revision: 1, data: d };
        let csv = to_csv(&[item]);

        let parsed = crate::import::parse_csv(&csv).unwrap();
        assert_eq!(parsed.items.len(), 1);
        assert_eq!(parsed.items[0].tags, vec!["工作", "生产"]);
        assert_eq!(parsed.items[0].category.as_deref(), Some("基础设施"));
    }
}
