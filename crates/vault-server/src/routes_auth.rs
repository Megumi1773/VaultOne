//! 注册、SRP-6a 登录、设备验证、登出、恢复。

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rand::Rng;
use serde_json::{json, Value};
use sqlx::Row;
use subtle::ConstantTimeEq;
use vault_crypto::srp6a;
use vault_proto::*;

use crate::auth::{issue_session, Authed, ClientIp};
use crate::db::{self, UserRow};
use crate::error::{ApiError, ApiResult};
use crate::keys::sha256;
use crate::mail::Mail;
use crate::{now, validate, AppState};

const HANDSHAKE_TTL: i64 = 120;
const OTP_TTL: i64 = 600;
const OTP_MAX_ATTEMPTS: i64 = 5;
/// 滑动窗口内登录失败达到该次数即邮件告警（F-09）
const LOGIN_FAIL_ALERT: i64 = 5;
const LOGIN_FAIL_WINDOW: i64 = 3600;

pub async fn register(
    State(st): State<AppState>,
    ip: ClientIp,
    Json(req): Json<RegisterRequest>,
) -> ApiResult<(StatusCode, Json<LoginFinishResponse>)> {
    validate::email(&req.email)?;
    validate::uuid(&req.keys.account_id, "account_id")?;
    validate::uuid(&req.keys.vault_id, "vault_id")?;
    validate::kdf_lenient(&req.keys.kdf, st.allow_test_kdf)?;
    validate::srp(&req.srp_salt, &req.srp_verifier)?;
    validate::wrapped_key(&req.keys.vk_wrap, "vk_wrap")?;
    validate::wrapped_key(&req.keys.recovery_wrap, "recovery_wrap")?;
    validate::hash32(&req.recovery_auth_hash, "recovery_auth_hash")?;
    validate::device(&req.device)?;

    let email_hash = st.keys.email_hash(&req.email);
    if db::user_by_email_hash(&st.db, &email_hash).await?.is_some() {
        return Err(ApiError::new(StatusCode::CONFLICT, codes::EMAIL_TAKEN, "该邮箱已注册"));
    }
    let now = now();
    let mut tx = st.db.begin().await?;
    let inserted = sqlx::query(
        "INSERT INTO users(id, email_hash, email_enc, kdf, srp_salt, srp_verifier, vault_id, vk_wrap, vk_gen, recovery_wrap, recovery_auth_hash, created_at, updated_at)
         VALUES($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)",
    )
    .bind(req.keys.account_id.clone())
    .bind(email_hash)
    .bind(st.keys.encrypt_email(&req.email)?)
    .bind(serde_json::to_string(&req.keys.kdf)?)
    .bind(req.srp_salt.0.clone())
    .bind(req.srp_verifier.0.clone())
    .bind(req.keys.vault_id.clone())
    .bind(req.keys.vk_wrap.0.clone())
    .bind(req.keys.vk_gen.max(1))
    .bind(req.keys.recovery_wrap.0.clone())
    .bind(req.recovery_auth_hash.0.clone())
    .bind(db::ts(now))
    .bind(db::ts(now))
    .execute(&mut *tx)
    .await;
    if inserted.is_err() {
        // 唯一约束冲突（并发注册同一邮箱或 account_id 碰撞）
        return Err(ApiError::new(StatusCode::CONFLICT, codes::EMAIL_TAKEN, "该邮箱已注册"));
    }
    sqlx::query("INSERT INTO devices(user_id, id, name, platform, approved_at, approved_by, last_seen_at, created_at) VALUES($1, $2, $3, $4, $5, $6, $7, $8)")
        .bind(req.keys.account_id.clone())
        .bind(req.device.id.clone())
        .bind(req.device.name.trim().to_string())
        .bind(req.device.platform.as_str().to_string())
        .bind(db::ts(now))
        .bind("registration".to_string())
        .bind(db::ts(now))
        .bind(db::ts(now))
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    let session = issue_session(&st, &req.keys.account_id, &req.device.id, true).await?;
    db::audit(&st.db, &req.keys.account_id, Some(&req.device.id), "register", ip.0).await;
    st.mailer.send(Mail {
        to: req.email.trim().to_lowercase(),
        subject: "欢迎使用 VaultOne".into(),
        body: format!("您的 VaultOne 账户已创建，首台设备：{}。\n请妥善保管 Recovery Kit——我们无法为您找回主密码。", req.device.name),
    });
    tracing::info!(user = %req.keys.account_id, "account registered");
    let user = db::user_by_id(&st.db, &req.keys.account_id).await?.ok_or_else(ApiError::not_found)?;
    Ok((StatusCode::CREATED, Json(LoginFinishResponse { m2: Bytes::default(), session, keys: Some(user.keys()?) })))
}

fn decoy_account_id(st: &AppState, email: &str) -> String {
    let b = st.keys.decoy(email, "account-id", 16);
    let mut arr = [0u8; 16];
    arr.copy_from_slice(&b);
    uuid::Builder::from_random_bytes(arr).into_uuid().to_string()
}

pub async fn login_start(State(st): State<AppState>, Json(req): Json<LoginStartRequest>) -> ApiResult<Json<LoginStartResponse>> {
    validate::email(&req.email)?;
    let user = db::user_by_email_hash(&st.db, &st.keys.email_hash(&req.email)).await?;
    // 未注册邮箱返回确定性伪造参数，响应形态与真实账户一致（防账户枚举）
    let (user_id, account_id, kdf, srp_salt, verifier) = match &user {
        Some(u) => (Some(u.id.clone()), u.id.clone(), serde_json::from_str(&u.kdf)?, u.srp_salt.clone(), u.srp_verifier.clone()),
        None => {
            let mut kdf = KdfParams::recommended();
            kdf.salt = B64.encode(st.keys.decoy(&req.email, "kdf-salt", 32));
            (
                None,
                decoy_account_id(&st, &req.email),
                kdf,
                st.keys.decoy(&req.email, "srp-salt", 32),
                st.keys.decoy(&req.email, "verifier", 384),
            )
        }
    };
    let (b, b_pub) = srp6a::server_start(&verifier);
    let handshake_id = uuid::Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO handshakes(id, user_id, b_enc, expires_at) VALUES($1, $2, $3, $4)")
        .bind(handshake_id.clone())
        .bind(user_id)
        .bind(st.keys.seal_handshake(&handshake_id, &b)?)
        .bind(db::ts(now() + HANDSHAKE_TTL))
        .execute(&st.db)
        .await?;
    Ok(Json(LoginStartResponse { handshake_id, account_id, kdf, srp_salt: srp_salt.into(), b_pub: b_pub.into() }))
}

pub async fn login_finish(
    State(st): State<AppState>,
    ip: ClientIp,
    Json(req): Json<LoginFinishRequest>,
) -> ApiResult<Json<LoginFinishResponse>> {
    validate::device(&req.device)?;
    // 握手一次性：先删除再校验，防重放
    let row = sqlx::query("SELECT user_id, b_enc, expires_at FROM handshakes WHERE id = $1")
        .bind(req.handshake_id.clone())
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(ApiError::auth_failed)?;
    sqlx::query("DELETE FROM handshakes WHERE id = $1").bind(req.handshake_id.clone()).execute(&st.db).await?;
    let expires_at: i64 = db::parse_ts(&row.try_get::<String, _>("expires_at")?);
    let user_id: Option<String> = row.try_get("user_id")?;
    let (Some(user_id), true) = (user_id, expires_at >= now()) else {
        return Err(ApiError::auth_failed());
    };
    let user = db::user_by_id(&st.db, &user_id).await?.ok_or_else(ApiError::auth_failed)?;
    let b = st.keys.open_handshake(&req.handshake_id, &row.try_get::<Vec<u8>, _>("b_enc")?)?;
    let m2 = match srp6a::server_finish(&b, &user.srp_verifier, &req.a_pub, &req.m1) {
        Ok(m2) => m2,
        Err(_) => {
            db::audit(&st.db, &user.id, Some(&req.device.id), "login_fail", ip.0).await;
            tracing::info!(user = %user.id, "login failed");
            // 恰好达到阈值时告警一次，避免持续爆破时刷屏
            if db::count_events_since(&st.db, &user.id, "login_fail", now() - LOGIN_FAIL_WINDOW).await? == LOGIN_FAIL_ALERT {
                notify(
                    &st,
                    &user.id,
                    "VaultOne 异常登录尝试",
                    &format!("过去 1 小时内有 {LOGIN_FAIL_ALERT} 次使用错误主密码登录您账户的尝试。\n如非本人操作，您的数据仍受主密码与 Secret Key 双重保护，但建议尽快修改主密码。"),
                )
                .await;
            }
            return Err(ApiError::auth_failed());
        }
    };

    let email = st.keys.decrypt_email(&user.email_enc)?;
    let now = now();
    let approved = match db::device(&st.db, &user.id, &req.device.id).await? {
        Some(d) if d.revoked_at.is_some() => {
            return Err(ApiError::new(StatusCode::FORBIDDEN, codes::AUTH_FAILED, "该设备已被撤销，无法登录"));
        }
        Some(d) => {
            sqlx::query("UPDATE devices SET last_seen_at = $1, name = $2 WHERE user_id = $3 AND id = $4")
                .bind(db::ts(now))
                .bind(req.device.name.trim().to_string())
                .bind(user.id.clone())
                .bind(req.device.id.clone())
                .execute(&st.db)
                .await?;
            d.approved_at.is_some()
        }
        None => {
            sqlx::query("INSERT INTO devices(user_id, id, name, platform, last_seen_at, created_at) VALUES($1, $2, $3, $4, $5, $6)")
                .bind(user.id.clone())
                .bind(req.device.id.clone())
                .bind(req.device.name.trim().to_string())
                .bind(req.device.platform.as_str().to_string())
                .bind(db::ts(now))
                .bind(db::ts(now))
                .execute(&st.db)
                .await?;
            db::audit(&st.db, &user.id, Some(&req.device.id), "device_added", ip.0.clone()).await;
            false
        }
    };
    if !approved {
        send_device_otp(&st, &user.id, &req.device, &email).await?;
    } else {
        st.mailer.send(Mail {
            to: email.clone(),
            subject: "VaultOne 登录提醒".into(),
            body: format!("您的账户刚刚在设备「{}」上登录。如非本人操作，请立即修改主密码并撤销该设备。", req.device.name),
        });
    }
    let session = issue_session(&st, &user.id, &req.device.id, approved).await?;
    db::audit(&st.db, &user.id, Some(&req.device.id), "login_ok", ip.0).await;
    tracing::info!(user = %user.id, approved, "login ok");
    Ok(Json(LoginFinishResponse { m2: m2.into(), session, keys: approved.then(|| user.keys()).transpose()? }))
}

async fn send_device_otp(st: &AppState, user_id: &str, device: &DeviceInfo, email: &str) -> ApiResult<()> {
    let code = format!("{:06}", rand::rngs::OsRng.gen_range(0..1_000_000u32));
    let hash = st.keys.otp_hash(user_id, &device.id, &code);
    sqlx::query("DELETE FROM device_otps WHERE user_id = $1 AND device_id = $2")
        .bind(user_id.to_string())
        .bind(device.id.clone())
        .execute(&st.db)
        .await?;
    sqlx::query("INSERT INTO device_otps(user_id, device_id, code_hash, expires_at, attempts) VALUES($1, $2, $3, $4, 0)")
        .bind(user_id.to_string())
        .bind(device.id.clone())
        .bind(hash)
        .bind(db::ts(now() + OTP_TTL))
        .execute(&st.db)
        .await?;
    st.mailer.send(Mail {
        to: email.to_string(),
        subject: "VaultOne 新设备验证码".into(),
        body: format!(
            "有新设备「{}」正在登录您的 VaultOne 账户。\n验证码：{code}（10 分钟内有效）\n如非本人操作，请忽略本邮件并尽快修改主密码。",
            device.name
        ),
    });
    Ok(())
}

pub async fn verify_device(
    State(st): State<AppState>,
    auth: Authed,
    ip: ClientIp,
    Json(req): Json<VerifyDeviceRequest>,
) -> ApiResult<Json<Value>> {
    if auth.approved {
        return Ok(Json(json!({ "approved": true })));
    }
    let row = sqlx::query("SELECT code_hash, expires_at, attempts FROM device_otps WHERE user_id = $1 AND device_id = $2")
        .bind(auth.user_id.clone())
        .bind(auth.device_id.clone())
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| ApiError::bad_request("验证码已失效，请重新登录以获取新验证码"))?;
    let attempts: i64 = row.try_get("attempts")?;
    let expires_at: i64 = db::parse_ts(&row.try_get::<String, _>("expires_at")?);
    if attempts >= OTP_MAX_ATTEMPTS || expires_at < now() {
        sqlx::query("DELETE FROM device_otps WHERE user_id = $1 AND device_id = $2")
            .bind(auth.user_id.clone())
            .bind(auth.device_id.clone())
            .execute(&st.db)
            .await?;
        return Err(ApiError::bad_request("验证码已失效，请重新登录以获取新验证码"));
    }
    let expected: Vec<u8> = row.try_get("code_hash")?;
    let got = st.keys.otp_hash(&auth.user_id, &auth.device_id, req.code.trim());
    if !bool::from(expected.ct_eq(&got)) {
        sqlx::query("UPDATE device_otps SET attempts = attempts + 1 WHERE user_id = $1 AND device_id = $2")
            .bind(auth.user_id.clone())
            .bind(auth.device_id.clone())
            .execute(&st.db)
            .await?;
        return Err(ApiError::bad_request("验证码不正确"));
    }
    approve(&st, &auth.user_id, &auth.device_id, "email-otp").await?;
    db::audit(&st.db, &auth.user_id, Some(&auth.device_id), "device_approved", ip.0).await;
    Ok(Json(json!({ "approved": true })))
}

pub async fn approve(st: &AppState, user_id: &str, device_id: &str, by: &str) -> ApiResult<()> {
    sqlx::query("UPDATE devices SET approved_at = $1, approved_by = $2 WHERE user_id = $3 AND id = $4 AND revoked_at IS NULL")
        .bind(db::ts(now()))
        .bind(by.to_string())
        .bind(user_id.to_string())
        .bind(device_id.to_string())
        .execute(&st.db)
        .await?;
    sqlx::query("DELETE FROM device_otps WHERE user_id = $1 AND device_id = $2")
        .bind(user_id.to_string())
        .bind(device_id.to_string())
        .execute(&st.db)
        .await?;
    notify(st, user_id, "VaultOne 新设备已批准", "一台新设备已获准访问您的保险库。").await;
    Ok(())
}

/// 向账户邮箱发送安全通知（F-09）。邮箱解密或查询失败只记日志，不影响主流程。
pub async fn notify(st: &AppState, user_id: &str, subject: &str, body: &str) {
    match db::user_by_id(&st.db, user_id).await {
        Ok(Some(u)) => match st.keys.decrypt_email(&u.email_enc) {
            Ok(email) => st.mailer.send(Mail { to: email, subject: subject.into(), body: body.into() }),
            Err(e) => tracing::error!(target: "mail", error = %e, "decrypt email failed"),
        },
        Ok(None) => {}
        Err(e) => tracing::error!(target: "mail", error = %e, "load user for notify failed"),
    }
}

pub async fn logout(State(st): State<AppState>, auth: Authed) -> ApiResult<Json<Value>> {
    sqlx::query("UPDATE sessions SET revoked_at = $1 WHERE token_hash = $2").bind(db::ts(now())).bind(auth.token_hash).execute(&st.db).await?;
    Ok(Json(json!({ "ok": true })))
}

// ───────── 恢复（F-08） ─────────

pub async fn recovery_start(State(st): State<AppState>, Json(req): Json<RecoveryStartRequest>) -> ApiResult<Json<RecoveryStartResponse>> {
    validate::email(&req.email)?;
    let account_id = match db::user_by_email_hash(&st.db, &st.keys.email_hash(&req.email)).await? {
        Some(u) => u.id,
        None => decoy_account_id(&st, &req.email),
    };
    Ok(Json(RecoveryStartResponse { account_id }))
}

async fn check_recovery(st: &AppState, email: &str, auth: &[u8], ip: &ClientIp) -> ApiResult<UserRow> {
    validate::email(email)?;
    let user = db::user_by_email_hash(&st.db, &st.keys.email_hash(email)).await?.ok_or_else(ApiError::auth_failed)?;
    if !bool::from(sha256(auth).ct_eq(&user.recovery_auth_hash)) {
        db::audit(&st.db, &user.id, None, "recovery_fail", ip.0.clone()).await;
        return Err(ApiError::auth_failed());
    }
    Ok(user)
}

pub async fn recovery_fetch(
    State(st): State<AppState>,
    ip: ClientIp,
    Json(req): Json<RecoveryFetchRequest>,
) -> ApiResult<Json<AccountResponse>> {
    let user = check_recovery(&st, &req.email, &req.recovery_auth, &ip).await?;
    Ok(Json(AccountResponse { email: req.email.trim().to_lowercase(), keys: user.keys()? }))
}

pub async fn recovery_complete(
    State(st): State<AppState>,
    ip: ClientIp,
    Json(req): Json<RecoveryCompleteRequest>,
) -> ApiResult<Json<RecoveryCompleteResponse>> {
    validate::kdf_lenient(&req.kdf, st.allow_test_kdf)?;
    validate::srp(&req.srp_salt, &req.srp_verifier)?;
    validate::wrapped_key(&req.vk_wrap, "vk_wrap")?;
    validate::wrapped_key(&req.recovery_wrap, "recovery_wrap")?;
    validate::hash32(&req.recovery_auth_hash, "recovery_auth_hash")?;
    validate::device(&req.device)?;
    let user = check_recovery(&st, &req.email, &req.recovery_auth, &ip).await?;
    let now = now();
    let mut tx = st.db.begin().await?;
    sqlx::query(
        "UPDATE users SET kdf = $1, srp_salt = $2, srp_verifier = $3, vk_wrap = $4, vk_gen = vk_gen + 1,
         recovery_wrap = $5, recovery_auth_hash = $6, updated_at = $7 WHERE id = $8",
    )
    .bind(serde_json::to_string(&req.kdf)?)
    .bind(req.srp_salt.0.clone())
    .bind(req.srp_verifier.0.clone())
    .bind(req.vk_wrap.0.clone())
    .bind(req.recovery_wrap.0.clone())
    .bind(req.recovery_auth_hash.0.clone())
    .bind(db::ts(now))
    .bind(user.id.clone())
    .execute(&mut *tx)
    .await?;
    // 恢复意味着旧凭据可能已泄露：撤销所有既有会话
    sqlx::query("UPDATE sessions SET revoked_at = $1 WHERE user_id = $2 AND revoked_at IS NULL")
        .bind(db::ts(now))
        .bind(user.id.clone())
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM devices WHERE user_id = $1 AND id = $2")
        .bind(user.id.clone())
        .bind(req.device.id.clone())
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO devices(user_id, id, name, platform, approved_at, approved_by, last_seen_at, created_at) VALUES($1, $2, $3, $4, $5, $6, $7, $8)")
        .bind(user.id.clone())
        .bind(req.device.id.clone())
        .bind(req.device.name.trim().to_string())
        .bind(req.device.platform.as_str().to_string())
        .bind(db::ts(now))
        .bind("recovery-kit".to_string())
        .bind(db::ts(now))
        .bind(db::ts(now))
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    let session = issue_session(&st, &user.id, &req.device.id, true).await?;
    db::audit(&st.db, &user.id, Some(&req.device.id), "recovery_used", ip.0).await;
    st.mailer.send(Mail {
        to: req.email.trim().to_lowercase(),
        subject: "VaultOne 账户已通过 Recovery Kit 恢复".into(),
        body: "您的账户刚刚使用 Recovery Kit 重设了主密码，所有其他设备已被登出。如非本人操作，请立即联系我们。".into(),
    });
    tracing::warn!(user = %user.id, "account recovered");
    let user = db::user_by_id(&st.db, &user.id).await?.ok_or_else(ApiError::not_found)?;
    Ok(Json(RecoveryCompleteResponse { session, keys: user.keys()? }))
}
