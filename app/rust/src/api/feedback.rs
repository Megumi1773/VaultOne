//! 主动文本反馈；只复用客户端会话，不暴露 token 给 Dart。
use super::vault::with_vault;
use super::{BridgeError, BridgeResult};
use vault_proto::feedback::FeedbackCreate;

pub fn new_feedback_id() -> String {
    vault_core::feedback::new_feedback_id()
}

pub fn submit_feedback(request_json: String) -> BridgeResult<String> {
    let request: FeedbackCreate = serde_json::from_str(&request_json)
        .map_err(|_| BridgeError { code: "invalid_input".into(), message: "反馈数据格式不正确".into() })?;
    let detail = with_vault(|v| v.submit_feedback(&request))?;
    Ok(serde_json::to_string(&detail)?)
}

pub fn list_feedback(before: Option<i64>, limit: u32) -> BridgeResult<String> {
    let page = with_vault(|v| v.list_feedback(before, limit))?;
    Ok(serde_json::to_string(&page)?)
}

pub fn get_feedback(id: String) -> BridgeResult<String> {
    let detail = with_vault(|v| v.get_feedback(&id))?;
    Ok(serde_json::to_string(&detail)?)
}
