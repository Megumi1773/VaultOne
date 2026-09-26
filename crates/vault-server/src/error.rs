//! 统一错误处理：所有错误都转换为 `{"code": "...", "message": "..."}` JSON 与对应 HTTP 状态码。
//! 内部错误只把细节写入日志，响应中只返回通用提示，避免泄露实现信息。

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use vault_proto::{codes, ErrorBody};

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
}

pub type ApiResult<T> = Result<T, ApiError>;

impl ApiError {
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self { status, code, message: message.into() }
    }

    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, codes::BAD_REQUEST, msg)
    }

    pub fn unauthorized() -> Self {
        Self::new(StatusCode::UNAUTHORIZED, codes::UNAUTHORIZED, "会话无效或已过期，请重新登录")
    }

    pub fn auth_failed() -> Self {
        Self::new(StatusCode::UNAUTHORIZED, codes::AUTH_FAILED, "认证失败")
    }

    pub fn not_approved() -> Self {
        Self::new(StatusCode::FORBIDDEN, codes::DEVICE_NOT_APPROVED, "设备尚未批准")
    }

    pub fn not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, codes::NOT_FOUND, "资源不存在")
    }

    pub fn conflict(msg: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, codes::CONFLICT, msg)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(ErrorBody { code: self.code.into(), message: self.message })).into_response()
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(e: sqlx::Error) -> Self {
        tracing::error!(error = %e, "database error");
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, codes::INTERNAL, "服务暂时不可用")
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        tracing::error!(error = %e, "internal error");
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, codes::INTERNAL, "服务暂时不可用")
    }
}

impl From<serde_json::Error> for ApiError {
    fn from(e: serde_json::Error) -> Self {
        tracing::error!(error = %e, "serialization error");
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, codes::INTERNAL, "服务暂时不可用")
    }
}
