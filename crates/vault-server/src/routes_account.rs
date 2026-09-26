//! 账户、设备管理、审计日志。

use axum::extract::{Path, State};
use axum::Json;
use serde_json::{json, Value};
use sqlx::Row;
use vault_proto::*;

use crate::auth::{Approved, Authed, ClientIp};
use crate::db::{self, DeviceRow};
use crate::error::{ApiError, ApiResult};
use crate::mail::Mail;
use crate::routes_auth::approve;
use crate::{now, validate, AppState};

pub async fn get_account(State(st): State<AppState>, Approved(a): Approved) -> ApiResult<Json<AccountResponse>> {
    let user = db::user_by_id(&st.db, &a.user_id).await?.ok_or_else(ApiError::unauthorized)?;
    Ok(Json(AccountResponse { email: st.keys.decrypt_email(&user.email_enc)?, keys: user.keys()? }))
}

/// 变更主密码：客户端重新封装 Vault Key 并上传新 verifier。以 vk_gen 做乐观锁，防止两台设备同时改密互相覆盖。
pub async fn change_credentials(
    State(st): State<AppState>,
    Approved(a): Approved,
    ip: ClientIp,
    Json(req): Json<ChangeCredentialsRequest>,
) -> ApiResult<Json<ChangeCredentialsResponse>> {
    validate::kdf_lenient(&req.kdf, st.allow_test_kdf)?;
    validate::srp(&req.srp_salt, &req.srp_verifier)?;
    validate::wrapped_key(&req.vk_wrap, "vk_wrap")?;
    if let Some(r) = &req.recovery_wrap {
        validate::wrapped_key(r, "recovery_wrap")?;
    }
    if let Some(h) = &req.recovery_auth_hash {
        validate::hash32(h, "recovery_auth_hash")?;
    }
    let user = db::user_by_id(&st.db, &a.user_id).await?.ok_or_else(ApiError::unauthorized)?;
    // 客户端本地 vk_gen 每次改密 +1；服务端若已被其他设备推进到 ≥ 客户端值，则拒绝覆盖
    if user.vk_gen >= req.expected_vk_gen {
        return Err(ApiError::conflict("主密码已在其他设备上更改，请先同步"));
    }
    let new_gen = req.expected_vk_gen;
    sqlx::query(
        "UPDATE users SET kdf = $1, srp_salt = $2, srp_verifier = $3, vk_wrap = $4, vk_gen = $5,
         recovery_wrap = COALESCE($6, recovery_wrap), recovery_auth_hash = COALESCE($7, recovery_auth_hash), updated_at = $8
         WHERE id = $9 AND vk_gen = $10",
    )
    .bind(serde_json::to_string(&req.kdf)?)
    .bind(req.srp_salt.0.clone())
    .bind(req.srp_verifier.0.clone())
    .bind(req.vk_wrap.0.clone())
    .bind(new_gen)
    .bind(req.recovery_wrap.as_ref().map(|b| b.0.clone()))
    .bind(req.recovery_auth_hash.as_ref().map(|b| b.0.clone()))
    .bind(now())
    .bind(a.user_id.clone())
    .bind(user.vk_gen)
    .execute(&st.db)
    .await?;
    db::audit(&st.db, &a.user_id, Some(&a.device_id), "pwd_changed", ip.0).await;
    st.mailer.send(Mail {
        to: st.keys.decrypt_email(&user.email_enc)?,
        subject: "VaultOne 主密码已变更".into(),
        body: "您的主密码刚刚被修改。如非本人操作，请立即使用 Recovery Kit 恢复账户。".into(),
    });
    Ok(Json(ChangeCredentialsResponse { vk_gen: new_gen }))
}

/// 注销账户（个人信息保护法 / GDPR 删除权）：删除全部数据，不可恢复。
pub async fn delete_account(State(st): State<AppState>, Approved(a): Approved) -> ApiResult<Json<Value>> {
    let user = db::user_by_id(&st.db, &a.user_id).await?.ok_or_else(ApiError::unauthorized)?;
    let email = st.keys.decrypt_email(&user.email_enc).ok();
    let mut tx = st.db.begin().await?;
    for table in ["item_versions", "change_log", "items", "sessions", "device_otps", "devices", "audit_events"] {
        sqlx::query(&format!("DELETE FROM {table} WHERE user_id = $1")).bind(a.user_id.clone()).execute(&mut *tx).await?;
    }
    sqlx::query("DELETE FROM handshakes WHERE user_id = $1").bind(a.user_id.clone()).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM users WHERE id = $1").bind(a.user_id.clone()).execute(&mut *tx).await?;
    tx.commit().await?;
    if let Some(to) = email {
        st.mailer.send(Mail {
            to, subject: "VaultOne 账户已注销".into(), body: "您的账户及全部云端数据已被永久删除。".into()
        });
    }
    tracing::warn!(user = %a.user_id, "account deleted");
    Ok(Json(json!({ "ok": true })))
}

fn device_out(d: DeviceRow, current: &str) -> DeviceOut {
    DeviceOut {
        current: d.id == current,
        id: d.id,
        name: d.name,
        platform: Platform::parse(&d.platform),
        approved: d.approved_at.is_some(),
        created_at: d.created_at,
        last_seen_at: d.last_seen_at,
        revoked_at: d.revoked_at,
    }
}

pub async fn device_self(State(st): State<AppState>, a: Authed) -> ApiResult<Json<DeviceOut>> {
    let d = db::device(&st.db, &a.user_id, &a.device_id).await?.ok_or_else(ApiError::unauthorized)?;
    Ok(Json(device_out(d, &a.device_id)))
}

pub async fn list_devices(State(st): State<AppState>, Approved(a): Approved) -> ApiResult<Json<Vec<DeviceOut>>> {
    let rows = sqlx::query(
        "SELECT id, name, platform, approved_at, last_seen_at, revoked_at, created_at FROM devices WHERE user_id = $1 ORDER BY created_at",
    )
    .bind(a.user_id.clone())
    .fetch_all(&st.db)
    .await?;
    let out = rows.iter().map(DeviceRow::from_row).collect::<sqlx::Result<Vec<_>>>()?;
    Ok(Json(out.into_iter().map(|d| device_out(d, &a.device_id)).collect()))
}

pub async fn approve_device(
    State(st): State<AppState>,
    Approved(a): Approved,
    ip: ClientIp,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let d = db::device(&st.db, &a.user_id, &id).await?.ok_or_else(ApiError::not_found)?;
    if d.revoked_at.is_some() {
        return Err(ApiError::bad_request("该设备已被撤销"));
    }
    approve(&st, &a.user_id, &id, &a.device_id).await?;
    db::audit(&st.db, &a.user_id, Some(&id), "device_approved", ip.0).await;
    Ok(Json(json!({ "ok": true })))
}

pub async fn revoke_device(
    State(st): State<AppState>,
    Approved(a): Approved,
    ip: ClientIp,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    db::device(&st.db, &a.user_id, &id).await?.ok_or_else(ApiError::not_found)?;
    let now = now();
    sqlx::query("UPDATE devices SET revoked_at = $1 WHERE user_id = $2 AND id = $3")
        .bind(now)
        .bind(a.user_id.clone())
        .bind(id.clone())
        .execute(&st.db)
        .await?;
    sqlx::query("UPDATE sessions SET revoked_at = $1 WHERE user_id = $2 AND device_id = $3 AND revoked_at IS NULL")
        .bind(now)
        .bind(a.user_id.clone())
        .bind(id.clone())
        .execute(&st.db)
        .await?;
    db::audit(&st.db, &a.user_id, Some(&id), "device_revoked", ip.0).await;
    Ok(Json(json!({ "ok": true })))
}

pub async fn audit_events(State(st): State<AppState>, Approved(a): Approved) -> ApiResult<Json<Vec<AuditEventOut>>> {
    let rows = sqlx::query("SELECT event, device_id, created_at FROM audit_events WHERE user_id = $1 ORDER BY id DESC LIMIT 100")
        .bind(a.user_id.clone())
        .fetch_all(&st.db)
        .await?;
    let out = rows
        .iter()
        .map(|r| Ok(AuditEventOut { event: r.try_get("event")?, device_id: r.try_get("device_id")?, created_at: r.try_get("created_at")? }))
        .collect::<sqlx::Result<Vec<_>>>()?;
    Ok(Json(out))
}
