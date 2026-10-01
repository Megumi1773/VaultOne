//! 用户主动提交、客服可读的反馈；不得自动附带保险库内容或恢复材料。

use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FeedbackCreate {
    pub id: String,
    pub category: FeedbackCategory,
    pub content: String,
    pub contact: Option<String>,
    pub consent: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedbackCategory {
    Bug,
    Suggestion,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedbackStatus {
    Open,
    InProgress,
    Resolved,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedbackSummary {
    pub id: String,
    pub category: FeedbackCategory,
    pub status: FeedbackStatus,
    pub created_at: i64,
    pub updated_at: i64,
    pub version: i64,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct FeedbackDetail {
    #[serde(flatten)]
    pub summary: FeedbackSummary,
    pub content: String,
    pub contact: Option<String>,
    pub reply: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedbackPage {
    pub items: Vec<FeedbackSummary>,
    pub next_before: Option<i64>,
}

impl std::fmt::Debug for FeedbackCreate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FeedbackCreate[redacted]")
    }
}
impl std::fmt::Debug for FeedbackDetail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FeedbackDetail[redacted]")
    }
}
