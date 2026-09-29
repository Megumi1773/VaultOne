//! E2EE 增量同步：推送（版本号乐观锁 + 幂等）与按 change_log 游标拉取。

use axum::extract::{Query, State};
use axum::Json;
use serde::Deserialize;
use sqlx::Row;
use vault_proto::*;

use crate::auth::Approved;
use crate::db;
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
    // 必须是事务的首条查询：PG 锁住账户行，SQLite 在读快照前取得写锁。
    // 同账户所有 push 串行至提交，包含新条目插入及 change_log 序号分配；
    // 因而不会出现较大 cursor 先提交、较小 cursor 后提交而被客户端永久跳过。
    let locked = sqlx::query("UPDATE users SET vk_gen = vk_gen WHERE id = $1").bind(a.user_id.clone()).execute(&mut *tx).await?;
    if locked.rows_affected() != 1 {
        return Err(ApiError::unauthorized());
    }
    for it in &req.items {
        let hash = sha256(&it.blob);
        let current = sqlx::query("SELECT revision, blob_hash, kind, deleted, updated_at FROM items WHERE user_id = $1 AND id = $2")
            .bind(a.user_id.clone())
            .bind(it.id.clone())
            .fetch_optional(&mut *tx)
            .await?;
        let (status, revision, changed) = match current {
            Some(row) => {
                let cur_rev: i64 = row.try_get("revision")?;
                let cur_hash: Vec<u8> = row.try_get("blob_hash")?;
                if cur_rev == it.revision
                    && cur_hash == hash
                    && row.try_get::<String, _>("kind")? == it.kind
                    && row.try_get::<i64, _>("deleted")? == i64::from(it.deleted)
                    && row.try_get::<String, _>("updated_at")? == db::ts(it.updated_at)
                {
                    // 旧客户端响应丢失后的重试仍携带旧 base_revision；不比较 base 或设备。
                    // 但所有实际写入字段必须相同，不能把删除/类型/时间变更误当重放吞掉。
                    (PushStatus::Applied, cur_rev, false)
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
                    .bind(db::ts(it.updated_at))
                    .bind(a.device_id.clone())
                    .bind(a.user_id.clone())
                    .bind(it.id.clone())
                    .execute(&mut *tx)
                    .await?;
                    (PushStatus::Applied, it.revision, true)
                } else {
                    (PushStatus::Conflict, cur_rev, false)
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
                .bind(db::ts(it.updated_at))
                .bind(a.device_id.clone())
                .bind(db::ts(now))
                .execute(&mut *tx)
                .await?;
                (PushStatus::Applied, it.revision, true)
            }
        };
        if changed {
            // 只为真正的新写入追加历史和移动游标；历史被 GC 后的合法重试也保持无副作用。
            sqlx::query(
                "INSERT INTO item_versions(user_id, item_id, revision, blob, device_id, created_at) VALUES($1, $2, $3, $4, $5, $6)",
            )
            .bind(a.user_id.clone())
            .bind(it.id.clone())
            .bind(it.revision)
            .bind(it.blob.0.clone())
            .bind(a.device_id.clone())
            .bind(db::ts(now))
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
                .bind(db::ts(now))
                .execute(&mut *tx)
                .await?;
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
            updated_at: db::parse_ts(&r.try_get::<String, _>("updated_at")?),
        });
    }
    let vk_gen: i64 =
        sqlx::query("SELECT vk_gen FROM users WHERE id = $1").bind(a.user_id.clone()).fetch_one(&st.db).await?.try_get("vk_gen")?;
    Ok(Json(PullResponse { items, cursor, has_more, vk_gen: Some(vk_gen) }))
}
