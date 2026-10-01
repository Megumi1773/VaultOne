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
    let filter = EnvFilter::new(format!(
        "warn,vault_core={level},vaultone_bridge={level},vault={level},sync={level},bridge={level},ui={level},browser={level}"
    ));
    // 进程内可能已存在全局订阅者（如 flutter_rust_bridge 的默认工具）。
    // 此处必须失败即报：否则日志静默失效，文件恒为 0 字节，真机故障无法事后诊断。
    tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().with_writer(writer).with_ansi(false).with_target(true))
        .try_init()
        .map_err(|e| super::BridgeError { code: "logging".into(), message: e.to_string() })?;
    let _ = GUARD.set(guard);
    std::panic::set_hook(Box::new(|info| {
        // panic 信息只记录位置，不记录 payload（可能含数据）
        let loc = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_default();
        tracing::error!(target: "bridge", location = %loc, "panic");
    }));
    tracing::info!(target: "bridge", version = env!("CARGO_PKG_VERSION"), os = std::env::consts::OS, "logging initialized");
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// 日志必须真的落盘：真机曾出现日志文件恒为 0 字节、故障无法事后诊断的情况。
    #[test]
    fn init_logging_writes_events_to_disk() {
        let dir = std::env::temp_dir().join(format!("vaultone-logprobe-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create temp log dir");

        init_logging(dir.to_string_lossy().to_string(), false).expect("init_logging");
        log_event("error".into(), "probe-marker-12345".into());

        // non_blocking writer 在后台线程落盘，轮询等待而不是假设立即可见。
        let mut hit = false;
        for _ in 0..100 {
            std::thread::sleep(std::time::Duration::from_millis(20));
            if let Ok(rd) = fs::read_dir(&dir) {
                hit = rd
                    .filter_map(|e| e.ok())
                    .any(|e| fs::read_to_string(e.path()).map(|s| s.contains("probe-marker-12345")).unwrap_or(false));
            }
            if hit {
                break;
            }
        }
        let listing: Vec<String> = fs::read_dir(&dir)
            .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).collect())
            .unwrap_or_default();
        let _ = fs::remove_dir_all(&dir);
        assert!(hit, "日志未写入磁盘；目录内容 = {listing:?}");

        // 重复调用必须幂等且仍返回 Ok：init() 会在每次启动时调用一次，
        // 而同一进程内 GUARD 已存在时不能再装第二遍订阅者。
        init_logging("被忽略的目录".into(), false).expect("重复初始化应当成功且无副作用");
    }
}
