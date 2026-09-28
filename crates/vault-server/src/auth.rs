//! 会话认证：Bearer token（32 字节 CSPRNG）只以 SHA-256 形式存库；提取器在每个请求中校验
//! 会话未过期/未撤销、设备未撤销，并滑动续期。

use std::net::SocketAddr;

use axum::extract::{ConnectInfo, FromRequestParts};
use axum::http::request::Parts;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use sqlx::Row;
use vault_proto::SessionInfo;

use crate::error::{ApiError, ApiResult};
use crate::keys::sha256;
use crate::{db, now, AppState};

/// 已登录（设备可能尚未批准）。
pub struct Authed {
    pub user_id: String,
    pub device_id: String,
    pub approved: bool,
    pub token_hash: Vec<u8>,
}

/// 已登录且设备已批准。
pub struct Approved(pub Authed);

impl FromRequestParts<AppState> for Authed {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> ApiResult<Self> {
        let token = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .ok_or_else(ApiError::unauthorized)?;
        let token_hash = sha256(token.trim().as_bytes());
        let row = sqlx::query(
            "SELECT s.user_id, s.device_id, s.expires_at, d.approved_at, d.revoked_at
             FROM sessions s JOIN devices d ON d.user_id = s.user_id AND d.id = s.device_id
             WHERE s.token_hash = $1 AND s.revoked_at IS NULL",
        )
        .bind(token_hash.clone())
        .fetch_optional(&state.db)
        .await?
        .ok_or_else(ApiError::unauthorized)?;
        let expires_at: i64 = db::parse_ts(&row.try_get::<String, _>("expires_at")?);
        let revoked_at: Option<i64> = db::parse_ts_opt(row.try_get::<Option<String>, _>("revoked_at")?.as_deref());
        let now = now();
        if expires_at < now || revoked_at.is_some() {
            return Err(ApiError::unauthorized());
        }
        let authed = Authed {
            user_id: row.try_get("user_id")?,
            device_id: row.try_get("device_id")?,
            approved: row.try_get::<Option<String>, _>("approved_at")?.is_some(),
            token_hash,
        };
        // 滑动续期 + 设备最后活跃时间（每小时最多写一次）
        let ttl = state.cfg.session_ttl_days * 86400;
        if expires_at - now < ttl - 3600 {
            sqlx::query("UPDATE sessions SET expires_at = $1 WHERE token_hash = $2")
                .bind(db::ts(now + ttl))
                .bind(authed.token_hash.clone())
                .execute(&state.db)
                .await?;
            sqlx::query("UPDATE devices SET last_seen_at = $1 WHERE user_id = $2 AND id = $3")
                .bind(db::ts(now))
                .bind(authed.user_id.clone())
                .bind(authed.device_id.clone())
                .execute(&state.db)
                .await?;
        }
        Ok(authed)
    }
}

impl FromRequestParts<AppState> for Approved {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> ApiResult<Self> {
        let a = Authed::from_request_parts(parts, state).await?;
        if !a.approved {
            return Err(ApiError::not_approved());
        }
        Ok(Approved(a))
    }
}

/// 客户端 IP 的不可逆哈希（用于审计与异常登录告警，不可反查）。
pub struct ClientIp(pub Option<Vec<u8>>);

impl FromRequestParts<AppState> for ClientIp {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> ApiResult<Self> {
        let forwarded = state
            .cfg
            .trust_proxy
            .then(|| parts.headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()))
            .flatten()
            .and_then(|v| v.split(',').next())
            .map(|s| s.trim().to_string());
        let peer = parts.extensions.get::<ConnectInfo<SocketAddr>>().map(|c| c.0.ip().to_string());
        Ok(ClientIp(forwarded.or(peer).map(|ip| state.keys.decoy(&ip, "ip-hash", 16))))
    }
}

pub async fn issue_session(state: &AppState, user_id: &str, device_id: &str, approved: bool) -> ApiResult<SessionInfo> {
    let raw = vault_crypto::secret::random_bytes::<32>();
    let token = URL_SAFE_NO_PAD.encode(raw);
    let now = now();
    let expires_at = now + state.cfg.session_ttl_days * 86400;
    sqlx::query("INSERT INTO sessions(token_hash, user_id, device_id, expires_at, created_at) VALUES($1, $2, $3, $4, $5)")
        .bind(sha256(token.as_bytes()))
        .bind(user_id.to_string())
        .bind(device_id.to_string())
        .bind(db::ts(expires_at))
        .bind(db::ts(now))
        .execute(&state.db)
        .await?;
    Ok(SessionInfo { token, expires_at, device_id: device_id.to_string(), device_approved: approved })
}
