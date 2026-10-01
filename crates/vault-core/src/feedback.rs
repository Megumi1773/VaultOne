//! Java 反馈 API 的客户端；复用云会话，仅显式调用，不缓存/同步正文。

use crate::{Result, Vault, VaultError};
use uuid::Uuid;
use vault_proto::feedback::{FeedbackCreate, FeedbackDetail, FeedbackPage};

pub fn new_feedback_id() -> String {
    Uuid::new_v4().to_string()
}

fn valid_id(id: &str) -> Result<()> {
    if Uuid::parse_str(id).is_ok_and(|value| value.to_string() == id) {
        return Ok(());
    }
    Err(VaultError::InvalidInput("反馈标识不正确".into()))
}

fn valid_text(text: &str, max: usize, required: bool) -> bool {
    (!required || !text.trim().is_empty())
        && text.encode_utf16().count() <= max
        && !text.chars().any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
}

fn supported<T>(result: Result<T>) -> Result<T> {
    result.map_err(|e| match e {
        VaultError::Server { status: 404, .. } => {
            VaultError::Server { status: 404, code: "feedback_unavailable".into(), message: "此服务器暂不支持反馈功能".into() }
        }
        other => other,
    })
}

impl Vault {
    pub fn submit_feedback(&self, request: &FeedbackCreate) -> Result<FeedbackDetail> {
        let (api, _) = self.remote_api()?;
        valid_id(&request.id)?;
        if !request.consent
            || !valid_text(&request.content, 4000, true)
            || request.contact.as_ref().is_some_and(|s| !valid_text(s, 200, false))
        {
            return Err(VaultError::InvalidInput("请确认客服可读取反馈，正文最多4000、联系方式最多200个字符".into()));
        }
        supported(api.post("/v1/feedback", request))
    }

    pub fn list_feedback(&self, before: Option<i64>, limit: u32) -> Result<FeedbackPage> {
        let (api, _) = self.remote_api()?;
        if !(1..=50).contains(&limit) || before.is_some_and(|b| b < 1) {
            return Err(VaultError::InvalidInput("反馈分页参数不正确".into()));
        }
        let mut path = format!("/v1/feedback?limit={limit}");
        if let Some(before) = before {
            path.push_str(&format!("&before={before}"));
        }
        supported(api.get(&path))
    }

    pub fn get_feedback(&self, id: &str) -> Result<FeedbackDetail> {
        let (api, _) = self.remote_api()?;
        valid_id(id)?;
        api.get(&format!("/v1/feedback/{id}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vault_proto::feedback::{FeedbackCategory, FeedbackStatus};

    #[test]
    fn ids_and_text_are_bounded_before_network() {
        assert!(valid_id(&new_feedback_id()).is_ok());
        for id in ["../account", "?secret=value", "1-1-1-1-1", ""] {
            assert!(valid_id(id).is_err());
        }
        assert!(valid_text(&"😀".repeat(2000), 4000, true));
        assert!(!valid_text(&"😀".repeat(2001), 4000, true));
        assert!(!valid_text(" \n ", 4000, true));
        assert!(!valid_text("正文\0", 4000, true));
    }

    #[test]
    fn wire_and_debug_do_not_confuse_feedback_with_vault_data() {
        let request = FeedbackCreate {
            id: new_feedback_id(),
            category: FeedbackCategory::Bug,
            content: "private-content".into(),
            contact: Some("private-contact".into()),
            consent: true,
        };
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["category"], "bug");
        assert_eq!(value["consent"], true);
        assert!(!format!("{request:?}").contains("private"));
        let detail: FeedbackDetail = serde_json::from_str(r#"{"id":"a","category":"bug","status":"in_progress","created_at":1,"updated_at":2,"version":2,"content":"private-content","contact":null,"reply":"private-reply"}"#).unwrap();
        assert_eq!(detail.summary.status, FeedbackStatus::InProgress);
        assert!(!format!("{detail:?}").contains("private"));
    }
}
