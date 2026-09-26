//! E2EE 增量同步：推送（版本号乐观锁 + 幂等）与按 change_log 游标拉取。

use axum::extract::{Query, State};
use axum::Json;
use serde::Deserialize;
use sqlx::Row;
use vault_proto::*;

use crate::auth::Approved;
use crate::error::{ApiError, ApiResult};
use crate::keys::sha256;
use crate::{now, validate, AppState};

pub async fn push(State(st): State<AppState>, Approved(a): Approved, Json(req): Json<PushRequest>) -> ApiResult<Json<PushResponse>> {
    if req.items.len() > PUSH_MAX_ITEMS {
        return Err(ApiError::bad_request(format!("单次最多推送 {PUSH_MAX_ITEMS} 条")));
    }
    for it in &req.items {
        validate::uuid(&it.id, "item.id")?;
        validate::kind(&it.kind)?;
        validate::item_blob(&it.blob)?;
        if it.revision < 1 || it.revision <= it.base_revision || it.base_revision < 0 {
            return Err(ApiError::bad_request("版本号不合法"));
        }
    }
    let now = now();
    let mut results = Vec::with_capacity(req.items.len());
    let mut tx = st.db.begin().await?;
    for it in &req.items {
        let hash = sha256(&it.blob);
        let current = sqlx::query("SELECT revision, blob_hash FROM items WHERE user_id = $1 AND id = $2")
            .bind(a.user_id.clone())
            .bind(it.id.clone())
            .fetch_optional(&mut *tx)
            .await?;
        let (status, revision) = match current {
            Some(row) => {
                let cur_rev: i64 = row.try_get("revision")?;
                let cur_hash: Vec<u8> = row.try_get("blob_hash")?;
                if cur_rev == it.revision && cur_hash == hash {
                    // 重放（例如上次响应丢失）：幂等成功
                    (PushStatus::Applied, cur_rev)
                } else if cur_rev == it.base_revision {
                    sqlx::query(
                        "UPDATE items SET kind = $1, blob = $2, blob_hash = $3, revision = $4, deleted = $5, updated_at = $6, device_id = $7
                         WHERE user_id = $8 AND id = $9",
                    )
                    .bind(it.kind.clone())
                    .bind(it.blob.0.clone())
                    .bind(hash)
                    .bind(it.revision)
                    .bind(i64::from(it.deleted))
                    .bind(it.updated_at)
                    .bind(a.device_id.clone())
                    .bind(a.user_id.clone())
                    .bind(it.id.clone())
                    .execute(&mut *tx)
                    .await?;
                    (PushStatus::Applied, it.revision)
                } else {
                    (PushStatus::Conflict, cur_rev)
                }
            }
            None => {
                sqlx::query(
                    "INSERT INTO items(user_id, id, kind, blob, blob_hash, revision, deleted, updated_at, device_id, created_at)
                     VALUES($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
                )
                .bind(a.user_id.clone())
                .bind(it.id.clone())
                .bind(it.kind.clone())
                .bind(it.blob.0.clone())
                .bind(hash)
                .bind(it.revision)
                .bind(i64::from(it.deleted))
                .bind(it.updated_at)
                .bind(a.device_id.clone())
                .bind(now)
                .execute(&mut *tx)
                .await?;
                (PushStatus::Applied, it.revision)
            }
        };
        if status == PushStatus::Applied && revision == it.revision {
            // 版本历史（保留 30 天，冲突取证与回滚）+ 变更日志（每条目只保留最新一行）
            let exists = sqlx::query("SELECT 1 AS x FROM item_versions WHERE user_id = $1 AND item_id = $2 AND revision = $3")
                .bind(a.user_id.clone())
                .bind(it.id.clone())
                .bind(it.revision)
                .fetch_optional(&mut *tx)
                .await?
                .is_some();
            if !exists {
                sqlx::query(
                    "INSERT INTO item_versions(user_id, item_id, revision, blob, device_id, created_at) VALUES($1, $2, $3, $4, $5, $6)",
                )
                .bind(a.user_id.clone())
                .bind(it.id.clone())
                .bind(it.revision)
                .bind(it.blob.0.clone())
                .bind(a.device_id.clone())
                .bind(now)
                .execute(&mut *tx)
                .await?;
                sqlx::query("DELETE FROM change_log WHERE user_id = $1 AND item_id = $2")
                    .bind(a.user_id.clone())
                    .bind(it.id.clone())
                    .execute(&mut *tx)
                    .await?;
                sqlx::query("INSERT INTO change_log(user_id, item_id, revision, created_at) VALUES($1, $2, $3, $4)")
                    .bind(a.user_id.clone())
                    .bind(it.id.clone())
                    .bind(it.revision)
                    .bind(now)
                    .execute(&mut *tx)
                    .await?;
            }
        }
        results.push(PushResult { id: it.id.clone(), status, revision });
    }
    tx.commit().await?;
    let applied = results.iter().filter(|r| r.status == PushStatus::Applied).count();
    tracing::debug!(user = %a.user_id, applied, conflicts = results.len() - applied, "push");
    Ok(Json(PushResponse { results }))
}

#[derive(Deserialize)]
pub struct PullQuery {
    #[serde(default)]
    cursor: i64,
    #[serde(default)]
    limit: Option<i64>,
}

pub async fn pull(State(st): State<AppState>, Approved(a): Approved, Query(q): Query<PullQuery>) -> ApiResult<Json<PullResponse>> {
    let limit = q.limit.unwrap_or(PULL_PAGE_SIZE).clamp(1, 1000);
    let rows = sqlx::query(
        "SELECT c.seq, i.id, i.kind, i.blob, i.revision, i.deleted, i.updated_at
         FROM change_log c JOIN items i ON i.user_id = c.user_id AND i.id = c.item_id
         WHERE c.user_id = $1 AND c.seq > $2 ORDER BY c.seq LIMIT $3",
    )
    .bind(a.user_id.clone())
    .bind(q.cursor.max(0))
    .bind(limit + 1)
    .fetch_all(&st.db)
    .await?;
    let has_more = rows.len() as i64 > limit;
    let mut cursor = q.cursor.max(0);
    let mut items = Vec::with_capacity(rows.len().min(limit as usize));
    for r in rows.iter().take(limit as usize) {
        cursor = r.try_get("seq")?;
        items.push(RemoteItem {
            id: r.try_get("id")?,
            kind: r.try_get("kind")?,
            blob: r.try_get::<Vec<u8>, _>("blob")?.into(),
            revision: r.try_get("revision")?,
            deleted: r.try_get::<i64, _>("deleted")? != 0,
            updated_at: r.try_get("updated_at")?,
        });
    }
    let vk_gen: i64 =
        sqlx::query("SELECT vk_gen FROM users WHERE id = $1").bind(a.user_id.clone()).fetch_one(&st.db).await?.try_get("vk_gen")?;
    Ok(Json(PullResponse { items, cursor, has_more, vk_gen: Some(vk_gen) }))
}
