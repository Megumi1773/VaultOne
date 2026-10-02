//! 本机加密冲突工作记录：不可变候选快照、完整行 CAS、裁决出站队列。
//! 冲突记录不上传；跨设备最终写入仍依赖服务端真正的版本 CAS。

#[cfg(test)]
#[path = "conflict_tests.rs"]
mod tests;

use crate::item::ItemData;
use crate::store::ItemRow;
use crate::vault::{now, validate_item};
use crate::{Result, Vault, VaultError};
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use vault_crypto::sealed;
use zeroize::Zeroizing;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ConflictRow {
    pub id: String,
    pub vault_id: String,
    pub item_id: String,
    pub state: String,
    pub blob: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConflictField {
    Type,
    Title,
    Urls,
    Username,
    Password,
    Totp,
    Notes,
    Card,
    Identity,
    CustomFields,
    Favorite,
    Tags,
    Category,
    Deleted,
    Resolution,
}

impl ConflictField {
    pub(crate) fn from_merge(s: &str) -> Self {
        match s {
            "type" => Self::Type,
            "title" => Self::Title,
            "urls" => Self::Urls,
            "username" => Self::Username,
            "password" => Self::Password,
            "totp" => Self::Totp,
            "notes" => Self::Notes,
            "card" => Self::Card,
            "identity" => Self::Identity,
            "customFields" => Self::CustomFields,
            "favorite" => Self::Favorite,
            "tags" => Self::Tags,
            "category" => Self::Category,
            _ => unreachable!("合并器只返回固定字段"),
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConflictSide {
    Local,
    Remote,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FieldDecision {
    pub field: ConflictField,
    pub side: ConflictSide,
}

/// Fields 必须恰好覆盖所有冲突字段；Type/Resolution 要求整条或手工裁决。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "camelCase", deny_unknown_fields)]
pub enum ConflictResolution {
    Whole { side: ConflictSide },
    Fields { choices: Vec<FieldDecision> },
    Manual { data: Box<ItemData>, deleted: bool },
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConflictState {
    Pending,
    ResolutionPending,
    Resolved,
    Superseded,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConflictVersion {
    pub revision: i64,
    /// 旧库基线允许未知；当前两端总是 Some。
    pub deleted: Option<bool>,
    pub data: ItemData,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConflictDetail {
    /// 不可变候选令牌：刷新产生新 ID，旧 ID 永不重新激活。
    pub id: String,
    pub item_id: String,
    pub state: ConflictState,
    pub stale: bool,
    pub fields: Vec<ConflictField>,
    pub base: Option<ConflictVersion>,
    pub local: ConflictVersion,
    pub remote: ConflictVersion,
    pub suggested: ItemData,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct StoredBase {
    pub revision: i64,
    pub blob: Vec<u8>,
    pub deleted: Option<bool>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct ConflictPayload {
    pub base: Option<StoredBase>,
    pub local: ItemRow,
    pub remote: ItemRow,
    pub fields: Vec<ConflictField>,
    /// 裁决后的精确出站快照；原始双方不覆盖。
    pub result: Option<ItemRow>,
}

fn conflict_aad(row: &ConflictRow, account: &str) -> Vec<u8> {
    format!("vaultone/conflict/v1|{account}|{}|{}|{}", row.vault_id, row.item_id, row.id).into_bytes()
}

impl Vault {
    /// ACK 只能确认当初裁决的完整结果，不能用后续编辑冒充旧裁决成功。
    pub(crate) fn acknowledge_snapshot(&self, sent: &ItemRow) -> Result<bool> {
        self.session()?;
        let record = self.store.active_conflict(&sent.vault_id, &sent.id)?;
        if let Some(record) = &record {
            let payload = self.open_conflict(record)?;
            if record.state != "resolution_pending" || payload.result.as_ref() != Some(sent) {
                return Ok(false);
            }
        }
        self.store.acknowledge_snapshot(sent, record.as_ref())
    }

    /// 出站前必须匹配耐久裁决结果；兼容旧版遗留脏头时也不能绕过此屏障。
    pub(crate) fn validate_outgoing_snapshot(&self, row: &ItemRow) -> Result<()> {
        self.session()?;
        if let Some(record) = self.store.active_conflict(&row.vault_id, &row.id)? {
            let payload = self.open_conflict(&record)?;
            if record.state != "resolution_pending" || payload.result.as_ref() != Some(row) {
                return Err(VaultError::ConflictStale);
            }
        }
        Ok(())
    }

    pub(crate) fn open_conflict(&self, row: &ConflictRow) -> Result<ConflictPayload> {
        let s = self.session()?;
        if row.vault_id != s.account.vault_id {
            return Err(VaultError::Integrity);
        }
        let plain = sealed::open(&s.vault_key, &row.blob, &conflict_aad(row, &s.account.account_id))?;
        let payload: ConflictPayload = serde_json::from_slice(&plain).map_err(|_| VaultError::Integrity)?;
        if payload.local.id != row.item_id
            || payload.remote.id != row.item_id
            || payload.local.vault_id != row.vault_id
            || payload.remote.vault_id != row.vault_id
        {
            return Err(VaultError::Integrity);
        }
        Ok(payload)
    }
    fn seal_conflict(&self, row: &mut ConflictRow, payload: &ConflictPayload) -> Result<()> {
        let s = self.session()?;
        let json = Zeroizing::new(serde_json::to_vec(payload)?);
        row.blob = sealed::seal(&s.vault_key, &json, &conflict_aad(row, &s.account.account_id))?;
        Ok(())
    }
    pub(crate) fn prepare_conflict(
        &self,
        local: &ItemRow,
        remote: &ItemRow,
        fields: Vec<ConflictField>,
        base: Option<StoredBase>,
    ) -> Result<ConflictRow> {
        let mut row = ConflictRow {
            id: Uuid::new_v4().to_string(),
            vault_id: local.vault_id.clone(),
            item_id: local.id.clone(),
            state: "pending".into(),
            blob: vec![],
        };
        self.seal_conflict(&mut row, &ConflictPayload { base, local: local.clone(), remote: remote.clone(), fields, result: None })?;
        Ok(row)
    }
    fn conflict_version(&self, row: &ItemRow) -> Result<ConflictVersion> {
        Ok(ConflictVersion {
            revision: row.revision,
            deleted: Some(row.deleted_at.is_some()),
            data: self.decrypt_blob(&row.id, row.revision, &row.blob)?,
        })
    }
    fn detail(&self, row: &ConflictRow) -> Result<ConflictDetail> {
        let p = self.open_conflict(row)?;
        let base = p
            .base
            .as_ref()
            .map(|b| {
                Ok::<_, VaultError>(ConflictVersion {
                    revision: b.revision,
                    deleted: b.deleted,
                    data: self.decrypt_blob(&row.item_id, b.revision, &b.blob)?,
                })
            })
            .transpose()?;
        let local = self.conflict_version(&p.local)?;
        let remote = self.conflict_version(&p.remote)?;
        let suggested = crate::merge::merge(base.as_ref().map(|b| &b.data), &local.data, &remote.data).data;
        let expected = p.result.as_ref().unwrap_or(&p.local);
        let stale = self.store.get_item(&row.item_id)?.as_ref() != Some(expected);
        let state = match row.state.as_str() {
            "pending" => ConflictState::Pending,
            "resolution_pending" => ConflictState::ResolutionPending,
            "resolved" => ConflictState::Resolved,
            "superseded" => ConflictState::Superseded,
            _ => return Err(VaultError::Integrity),
        };
        Ok(ConflictDetail {
            id: row.id.clone(),
            item_id: row.item_id.clone(),
            state,
            stale,
            fields: p.fields,
            base,
            local,
            remote,
            suggested,
        })
    }
    /// 默认只列待裁决/待确认；include_history 可读取保留的旧双方版本。
    pub fn list_conflicts(&self, include_history: bool) -> Result<Vec<ConflictDetail>> {
        let vault = &self.session()?.account.vault_id;
        self.store
            .conflicts(vault)?
            .iter()
            .filter(|r| include_history || matches!(r.state.as_str(), "pending" | "resolution_pending"))
            .map(|r| self.detail(r))
            .collect()
    }
    pub fn get_conflict(&self, id: &str) -> Result<ConflictDetail> {
        self.session()?;
        let row = self.store.conflict(id)?.ok_or(VaultError::ConflictStale)?;
        self.detail(&row)
    }
    /// 本地编辑后显式刷新候选。保留原基线和远端，旧令牌失效且快照留档。
    pub fn refresh_conflict(&mut self, id: &str) -> Result<ConflictDetail> {
        self.session()?;
        let old = self.store.conflict(id)?.ok_or(VaultError::ConflictStale)?;
        if !matches!(old.state.as_str(), "pending" | "resolution_pending") {
            return Err(VaultError::ConflictStale);
        }
        let p = self.open_conflict(&old)?;
        let local = self.store.get_item(&old.item_id)?.ok_or(VaultError::ConflictStale)?;
        if old.state == "pending" && local == p.local {
            return self.detail(&old);
        }
        if old.state == "resolution_pending" && p.result.as_ref() == Some(&local) {
            return Err(VaultError::ConflictStale);
        }
        // 也允许修复旧版本遗留的“待 ACK 后再次改动”记录，但不重写精确待确认结果。
        let base = if old.state == "resolution_pending" {
            local.base_blob.as_ref().map(|blob| StoredBase { revision: local.server_rev, blob: blob.clone(), deleted: local.base_deleted })
        } else {
            p.base
        };
        let row = self.prepare_conflict(&local, &p.remote, vec![ConflictField::Resolution], base)?;
        self.store.transaction(|s| {
            s.check_item(Some(&local), &local.id)?;
            s.check_conflict(Some(&old), &local.vault_id, &local.id)?;
            s.retire_conflict(&old.id, "superseded")?;
            s.put_conflict(&row)
        })?;
        self.detail(&row)
    }
    /// 仅提交本机裁决，不代表服务端已接受。重复提交同一令牌返回 conflict_stale。
    pub fn resolve_conflict(&mut self, id: &str, resolution: ConflictResolution) -> Result<()> {
        self.session()?;
        let old = self.store.conflict(id)?.ok_or(VaultError::ConflictStale)?;
        if old.state != "pending" {
            return Err(VaultError::ConflictStale);
        }
        let mut p = self.open_conflict(&old)?;
        let detail = self.detail(&old)?;
        if detail.stale {
            return Err(VaultError::ConflictStale);
        }
        let (mut data, deleted) = match resolution {
            ConflictResolution::Whole { side } => match side {
                ConflictSide::Local => (detail.local.data.clone(), p.local.deleted_at.is_some()),
                ConflictSide::Remote => (detail.remote.data.clone(), p.remote.deleted_at.is_some()),
            },
            ConflictResolution::Manual { data, deleted } => (*data, deleted),
            ConflictResolution::Fields { choices } => {
                if p.fields.contains(&ConflictField::Type)
                    || p.fields.contains(&ConflictField::Resolution)
                    || choices.len() != p.fields.len()
                {
                    return Err(VaultError::InvalidInput("必须完整裁决全部冲突字段".into()));
                }
                let mut data = detail.suggested.clone();
                let mut deleted = p.local.deleted_at.is_some();
                let mut selected = Vec::new();
                for choice in choices {
                    if !p.fields.contains(&choice.field) || selected.contains(&choice.field) {
                        return Err(VaultError::InvalidInput("重复或无效的裁决字段".into()));
                    }
                    selected.push(choice.field);
                    let (source, tombstone) = match choice.side {
                        ConflictSide::Local => (&detail.local.data, p.local.deleted_at.is_some()),
                        ConflictSide::Remote => (&detail.remote.data, p.remote.deleted_at.is_some()),
                    };
                    match choice.field {
                        ConflictField::Title => data.title = source.title.clone(),
                        ConflictField::Urls => data.urls = source.urls.clone(),
                        ConflictField::Username => data.username = source.username.clone(),
                        ConflictField::Password => data.password = source.password.clone(),
                        ConflictField::Totp => data.totp = source.totp.clone(),
                        ConflictField::Notes => data.notes = source.notes.clone(),
                        ConflictField::Card => data.card = source.card.clone(),
                        ConflictField::Identity => data.identity = source.identity.clone(),
                        ConflictField::CustomFields => data.custom_fields = source.custom_fields.clone(),
                        ConflictField::Favorite => data.favorite = source.favorite,
                        ConflictField::Tags => data.tags = source.tags.clone(),
                        ConflictField::Category => data.category = source.category.clone(),
                        ConflictField::Deleted => deleted = tombstone,
                        _ => return Err(VaultError::InvalidInput("该冲突要求整条裁决".into())),
                    }
                }
                (data, deleted)
            }
        };
        data.created_at = p.local.created_at.min(p.remote.created_at);
        data.updated_at = now().max(p.local.updated_at.max(p.remote.updated_at).checked_add(1).ok_or(VaultError::Integrity)?);
        validate_item(&data)?;
        let revision = p.local.revision.max(p.remote.revision).checked_add(1).ok_or(VaultError::Integrity)?;
        let result = ItemRow {
            id: p.local.id.clone(),
            vault_id: p.local.vault_id.clone(),
            kind: data.kind.as_str().into(),
            blob: self.seal_blob(&p.local.id, revision, &data)?,
            revision,
            server_rev: p.remote.revision,
            base_blob: Some(p.remote.blob.clone()),
            base_deleted: Some(p.remote.deleted_at.is_some()),
            dirty: true,
            deleted_at: deleted.then_some(data.updated_at),
            created_at: p.local.created_at,
            updated_at: data.updated_at,
        };
        p.result = Some(result.clone());
        let mut row = old.clone();
        row.state = "resolution_pending".into();
        self.seal_conflict(&mut row, &p)?;
        self.store.transaction(|s| {
            s.check_item(Some(&p.local), &p.local.id)?;
            s.check_conflict(Some(&old), &p.local.vault_id, &p.local.id)?;
            s.put_item(&result)?;
            s.put_conflict(&row)
        })
    }
}
