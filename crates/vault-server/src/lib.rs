//! VaultOne 零知识同步服务。
//!
//! 服务端永远不接收主密码、Secret Key 或任何明文条目字段（计划书 §3.1 核心原则）：
//! - 认证：SRP-6a，库中只有 verifier（由 256-bit AuthKey 计算，不可离线爆破）；
//! - 数据：条目、Vault Key 封装、恢复封装均为客户端 AES-256-GCM 密封盒，服务端只校验结构；
//! - 邮箱：HMAC 索引 + AES-256-GCM 密文，日志中脱敏。

pub mod auth;
pub mod config;
pub mod db;
pub mod error;
pub mod keys;
pub mod mail;
pub mod routes_account;
pub mod routes_auth;
pub mod routes_sync;
pub mod validate;

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::DefaultBodyLimit;
use axum::http::{header, HeaderName, HeaderValue, Method, Request, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{delete, get, post, put};
use axum::{Json, Router};
use serde_json::json;
use sqlx::AnyPool;
use tower::ServiceBuilder;
use tower_governor::governor::GovernorConfigBuilder;
use tower_governor::key_extractor::{KeyExtractor, SmartIpKeyExtractor};
use tower_governor::{GovernorError, GovernorLayer};
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::set_header::SetResponseHeaderLayer;
use tower_http::trace::TraceLayer;
use vault_proto::{codes, ErrorBody};

use crate::config::Config;
use crate::keys::ServerKeys;
use crate::mail::Mailer;

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub struct Inner {
    pub db: AnyPool,
    pub keys: ServerKeys,
    pub cfg: Config,
    pub mailer: Mailer,
    /// 仅集成测试置 true：允许客户端使用低成本 KDF 参数
    pub allow_test_kdf: bool,
}

#[derive(Clone)]
pub struct AppState(pub Arc<Inner>);

impl std::ops::Deref for AppState {
    type Target = Inner;
    fn deref(&self) -> &Inner {
        &self.0
    }
}

impl AppState {
    pub async fn new(cfg: Config, mailer: Mailer, allow_test_kdf: bool) -> anyhow::Result<Self> {
        let keys = ServerKeys::new(&cfg.secret_bytes()?)?;
        let db = db::connect(&cfg).await?;
        Ok(Self(Arc::new(Inner { db, keys, cfg, mailer, allow_test_kdf })))
    }
}

/// 限流键：可信反向代理之后取 X-Forwarded-For，否则取对端 IP（不可伪造）。
#[derive(Clone, Copy)]
struct ClientIpKey {
    trust_proxy: bool,
}

impl KeyExtractor for ClientIpKey {
    type Key = std::net::IpAddr;

    fn extract<T>(&self, req: &Request<T>) -> Result<Self::Key, GovernorError> {
        if self.trust_proxy {
            return SmartIpKeyExtractor.extract(req);
        }
        req.extensions()
            .get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
            .map(|c| c.0.ip())
            .ok_or(GovernorError::UnableToExtractKey)
    }
}

fn governor(
    ms: u64,
    burst: u32,
    trust_proxy: bool,
) -> GovernorLayer<ClientIpKey, governor::middleware::NoOpMiddleware<governor::clock::QuantaInstant>> {
    let mut builder = GovernorConfigBuilder::default().key_extractor(ClientIpKey { trust_proxy });
    builder.per_millisecond(ms.max(1)).burst_size(burst.max(1));
    builder.error_handler(|e| {
        let (status, code, message) = match e {
            GovernorError::TooManyRequests { .. } => (StatusCode::TOO_MANY_REQUESTS, codes::RATE_LIMITED, "请求过于频繁，请稍后再试"),
            _ => (StatusCode::INTERNAL_SERVER_ERROR, codes::INTERNAL, "服务暂时不可用"),
        };
        (status, Json(ErrorBody { code: code.into(), message: message.into() })).into_response()
    });
    let config = Arc::new(builder.finish().expect("governor config"));
    let limiter = config.limiter().clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            limiter.retain_recent();
        }
    });
    GovernorLayer { config }
}

async fn healthz() -> impl IntoResponse {
    Json(json!({ "status": "ok", "version": env!("CARGO_PKG_VERSION") }))
}

async fn readyz(axum::extract::State(st): axum::extract::State<AppState>) -> impl IntoResponse {
    match sqlx::query("SELECT 1").execute(&st.db).await {
        Ok(_) => (StatusCode::OK, Json(json!({ "status": "ready" }))),
        Err(e) => {
            tracing::error!(error = %e, "readiness check failed");
            (StatusCode::SERVICE_UNAVAILABLE, Json(json!({ "status": "unavailable" })))
        }
    }
}

async fn fallback() -> impl IntoResponse {
    (StatusCode::NOT_FOUND, Json(ErrorBody { code: codes::NOT_FOUND.into(), message: "接口不存在".into() }))
}

fn panic_response(_: Box<dyn std::any::Any + Send + 'static>) -> axum::response::Response {
    tracing::error!("handler panicked");
    (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorBody { code: codes::INTERNAL.into(), message: "服务暂时不可用".into() })).into_response()
}

pub fn router(st: AppState) -> Router {
    use routes_account as acc;
    use routes_auth as au;
    use routes_sync as sy;
    let cfg = &st.cfg;

    let auth_routes = Router::new()
        .route("/v1/auth/register", post(au::register))
        .route("/v1/auth/login/start", post(au::login_start))
        .route("/v1/auth/login/finish", post(au::login_finish))
        .route("/v1/devices/self/verify", post(au::verify_device))
        .route("/v1/recovery/start", post(au::recovery_start))
        .route("/v1/recovery/fetch", post(au::recovery_fetch))
        .route("/v1/recovery/complete", post(au::recovery_complete))
        .layer(governor(cfg.auth_rate_ms, cfg.auth_burst, cfg.trust_proxy));

    let api_routes = Router::new()
        .route("/v1/auth/logout", post(au::logout))
        .route("/v1/account", get(acc::get_account).delete(acc::delete_account))
        .route("/v1/account/credentials", put(acc::change_credentials))
        .route("/v1/devices", get(acc::list_devices))
        .route("/v1/devices/self", get(acc::device_self))
        .route("/v1/devices/{id}/approve", post(acc::approve_device))
        .route("/v1/devices/{id}", delete(acc::revoke_device))
        .route("/v1/audit", get(acc::audit_events))
        .route("/v1/sync/pull", get(sy::pull))
        .route("/v1/sync/push", post(sy::push).layer(DefaultBodyLimit::max(64 * 1024 * 1024)))
        .layer(governor(cfg.api_rate_ms, cfg.api_burst, cfg.trust_proxy));

    let origins: Vec<HeaderValue> =
        cfg.cors_origins.split(',').filter(|s| !s.trim().is_empty()).filter_map(|s| s.trim().parse().ok()).collect();
    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([Method::GET, Method::POST, Method::PUT, Method::DELETE])
        .allow_headers([header::AUTHORIZATION, header::CONTENT_TYPE]);

    let x_request_id = HeaderName::from_static("x-request-id");
    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .merge(auth_routes)
        .merge(api_routes)
        .fallback(fallback)
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .layer(
            ServiceBuilder::new()
                .layer(SetRequestIdLayer::new(x_request_id.clone(), MakeRequestUuid))
                .layer(
                    // 访问日志：只记录方法、路径、状态码、耗时、请求 ID；不记录请求体、查询串与 Authorization
                    TraceLayer::new_for_http().make_span_with(|req: &Request<_>| {
                        let rid = req.headers().get("x-request-id").and_then(|v| v.to_str().ok()).unwrap_or("-").to_string();
                        tracing::info_span!("http", method = %req.method(), path = %req.uri().path(), request_id = %rid)
                    }),
                )
                .layer(PropagateRequestIdLayer::new(x_request_id))
                .layer(CatchPanicLayer::custom(panic_response))
                .layer(cors)
                .layer(SetResponseHeaderLayer::overriding(header::CACHE_CONTROL, HeaderValue::from_static("no-store")))
                .layer(SetResponseHeaderLayer::overriding(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff")))
                .layer(SetResponseHeaderLayer::overriding(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY")))
                .layer(SetResponseHeaderLayer::overriding(header::REFERRER_POLICY, HeaderValue::from_static("no-referrer")))
                .layer(SetResponseHeaderLayer::overriding(
                    header::STRICT_TRANSPORT_SECURITY,
                    HeaderValue::from_static("max-age=63072000; includeSubDomains"),
                )),
        )
        .with_state(st)
}

/// 后台清理任务。
pub fn spawn_gc(st: AppState) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            if let Err(e) = db::gc(&st.db, st.cfg.version_retention_days).await {
                tracing::error!(error = %e, "gc failed");
            }
        }
    });
}

/// 启动 HTTP 服务（供 main 与集成测试共用）。
pub async fn serve(st: AppState, listener: tokio::net::TcpListener) -> anyhow::Result<()> {
    spawn_gc(st.clone());
    let app = router(st);
    axum::serve(listener, app.into_make_service_with_connect_info::<std::net::SocketAddr>())
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
            tracing::info!("shutdown signal received");
        })
        .await?;
    Ok(())
}
