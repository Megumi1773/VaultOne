//! 导入 / 导出历史（计划书 §3.7「导入导出历史」）。
//!
//! 设计要点：
//!
//! 1. **本机记录、不参与同步。** 这是一台机器上的操作痕迹，同步出去等于把「什么时候导过
//!    哪些站点的数据」这类活动元数据交给服务端，与零知识的姿态不符。
//! 2. **以 Vault Key 密封后存放**（复用 `Vault::set_sealed_setting`），锁定时读不到。
//!    文件名本身就是线索（`某银行导出.csv`），明文躺在磁盘上不合适。
//! 3. **有硬上限**，超出丢弃最旧的。历史是给人看的，不是审计日志——审计在服务端。
//!
//! 纯函数部分（`push` / `encode` / `decode`）与存储分离，便于单独测。

use serde::{Deserialize, Serialize};

/// 历史条数上限。超出时丢弃最旧的。
pub const TRANSFER_HISTORY_LIMIT: usize = 50;

/// 来源标签（通常是文件名）的长度上限。
pub const TRANSFER_SOURCE_LIMIT: usize = 200;

/// 一次传输的方向。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransferDirection {
    Import,
    Export,
}

/// 一次导入或导出的记录。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferRecord {
    /// Unix 秒。
    pub at: i64,
    pub direction: TransferDirection,
    /// 识别出的格式：`chrome` / `bitwarden` / `1pif` / `wljbak` / `csv` …
    pub format: String,
    /// 来源或去向的说明（一般是文件名）。可能为空——导出时字节流由调用方写盘，内核不知道路径。
    #[serde(default)]
    pub source: String,
    pub added: u32,
    pub updated: u32,
    pub duplicates: u32,
    pub skipped: u32,
    /// 字节数。导入时为文件大小，导出时为产物大小。
    #[serde(default)]
    pub bytes: u64,
}

/// 把一条新记录放到最前并裁剪到上限。返回新列表（不改原列表）。
pub fn push(history: &[TransferRecord], record: TransferRecord) -> Vec<TransferRecord> {
    let mut out = Vec::with_capacity(history.len() + 1);
    out.push(record);
    out.extend(history.iter().take(TRANSFER_HISTORY_LIMIT - 1).cloned());
    out
}

/// 编码成待密封的字节。
pub fn encode(history: &[TransferRecord]) -> crate::Result<Vec<u8>> {
    Ok(serde_json::to_vec(history)?)
}

/// 解码。**损坏时返回空列表而不是报错**：历史读不出来不该让用户连数据都看不到。
pub fn decode(raw: &[u8]) -> Vec<TransferRecord> {
    serde_json::from_slice(raw).unwrap_or_default()
}

/// 规范化来源标签：去首尾空白与换行、限量。
pub fn normalize_source(source: &str) -> String {
    source.trim().replace(['\n', '\r'], " ").chars().take(TRANSFER_SOURCE_LIMIT).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(at: i64) -> TransferRecord {
        TransferRecord {
            at,
            direction: TransferDirection::Import,
            format: "chrome".into(),
            source: "export.csv".into(),
            added: 1,
            updated: 0,
            duplicates: 0,
            skipped: 0,
            bytes: 10,
        }
    }

    #[test]
    fn newest_first_and_capped() {
        let mut history: Vec<TransferRecord> = Vec::new();
        for i in 0..TRANSFER_HISTORY_LIMIT as i64 + 5 {
            history = push(&history, rec(i));
        }
        assert_eq!(history.len(), TRANSFER_HISTORY_LIMIT, "超出上限要裁剪");
        assert_eq!(history[0].at, TRANSFER_HISTORY_LIMIT as i64 + 4, "最新的在最前");
        assert_eq!(history.last().unwrap().at, 5, "丢掉的是最旧的几条");
    }

    #[test]
    fn push_does_not_mutate_the_input() {
        let original = vec![rec(1)];
        let next = push(&original, rec(2));
        assert_eq!(original.len(), 1);
        assert_eq!(next.len(), 2);
    }

    #[test]
    fn roundtrips_through_json() {
        let history = vec![rec(7)];
        let back = decode(&encode(&history).unwrap());
        assert_eq!(back, history);
        // wire 值要稳定：界面上按它取词。
        let json = serde_json::to_value(&history[0]).unwrap();
        assert_eq!(json["direction"], "import");
        assert_eq!(json["format"], "chrome");
    }

    #[test]
    fn decode_tolerates_garbage() {
        assert!(decode(b"not json").is_empty());
        assert!(decode(b"").is_empty());
        assert!(decode(b"{}").is_empty(), "形状不对也当空");
    }

    #[test]
    fn source_is_trimmed_and_capped() {
        assert_eq!(normalize_source("  a.csv  "), "a.csv");
        assert_eq!(normalize_source("a\nb"), "a b", "换行会破坏展示，替换掉");
        assert_eq!(normalize_source(&"x".repeat(TRANSFER_SOURCE_LIMIT + 10)).chars().count(), TRANSFER_SOURCE_LIMIT);
    }

    #[test]
    fn missing_optional_fields_default() {
        // 旧记录或外部写入缺 `source` / `bytes` 时不该整条丢掉。
        let r: TransferRecord =
            serde_json::from_str(r#"{"at":1,"direction":"export","format":"csv","added":0,"updated":0,"duplicates":0,"skipped":0}"#)
                .unwrap();
        assert_eq!(r.source, "");
        assert_eq!(r.bytes, 0);
    }
}
