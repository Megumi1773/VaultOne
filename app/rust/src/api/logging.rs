//! 客户端日志：`tracing` + `tracing-appender` 按天滚动写入应用数据目录，保留 7 天。
//!
//! 日志只包含事件类型、错误码、耗时、HTTP 路径与状态码；**绝不记录**主密码、Secret Key、
//! 条目内容、邮箱、会话 token。用户可在"设置 → 诊断"中导出日志文件反馈问题（计划书 R-07）。

use std::sync::OnceLock;

use tracing_appender::non_blocking::WorkerGuard;
use tracing_appender::rolling::{Builder, Rotation};
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{fmt, EnvFilter};

static GUARD: OnceLock<WorkerGuard> = OnceLock::new();

/// 初始化日志（重复调用无副作用）。`verbose` 为诊断模式，输出 debug 级别。
pub fn init_logging(log_dir: String, verbose: bool) -> Result<(), super::BridgeError> {
    if GUARD.get().is_some() {
        return Ok(());
    }
    let appender = Builder::new()
        .rotation(Rotation::DAILY)
        .filename_prefix("vaultone")
        .filename_suffix("log")
        .max_log_files(7)
        .build(&log_dir)
        .map_err(|e| super::BridgeError { code: "logging".into(), message: e.to_string() })?;
    let (writer, guard) = tracing_appender::non_blocking(appender);
    let level = if verbose { "debug" } else { "info" };
    let filter = EnvFilter::new(format!("warn,vault_core={level},vaultone_bridge={level},vault={level},sync={level},bridge={level}"));
    let result =
        tracing_subscriber::registry().with(filter).with(fmt::layer().with_writer(writer).with_ansi(false).with_target(true)).try_init();
    if result.is_ok() {
        let _ = GUARD.set(guard);
        std::panic::set_hook(Box::new(|info| {
            // panic 信息只记录位置，不记录 payload（可能含数据）
            let loc = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_default();
            tracing::error!(target: "bridge", location = %loc, "panic");
        }));
        tracing::info!(target: "bridge", version = env!("CARGO_PKG_VERSION"), os = std::env::consts::OS, "logging initialized");
    }
    Ok(())
}

/// 供 Dart 侧把 UI 层事件写入同一日志（调用方负责不传入敏感信息）。
pub fn log_event(level: String, message: String) {
    match level.as_str() {
        "error" => tracing::error!(target: "ui", "{message}"),
        "warn" => tracing::warn!(target: "ui", "{message}"),
        _ => tracing::info!(target: "ui", "{message}"),
    }
}
