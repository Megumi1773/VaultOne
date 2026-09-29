//! 本机加密冲突记录；裁决仅排入同步队列，不表示服务端已经确认。

use vault_core::conflict::ConflictResolution;

use super::vault::with_vault;
use super::{BridgeError, BridgeResult};

pub fn list_conflicts(include_history: bool) -> BridgeResult<String> {
    let conflicts = with_vault(|v| v.list_conflicts(include_history))?;
    Ok(serde_json::to_string(&conflicts)?)
}

pub fn get_conflict(id: String) -> BridgeResult<String> {
    let conflict = with_vault(|v| v.get_conflict(&id))?;
    Ok(serde_json::to_string(&conflict)?)
}

pub fn refresh_conflict(id: String) -> BridgeResult<String> {
    let conflict = with_vault(|v| v.refresh_conflict(&id))?;
    Ok(serde_json::to_string(&conflict)?)
}

pub fn resolve_conflict(id: String, resolution_json: String) -> BridgeResult<()> {
    if resolution_json.len() > 2 * 1024 * 1024 {
        return Err(BridgeError { code: "invalid_input".into(), message: "冲突裁决内容过大".into() });
    }
    let resolution: ConflictResolution = serde_json::from_str(&resolution_json)?;
    with_vault(|v| v.resolve_conflict(&id, resolution))
}
