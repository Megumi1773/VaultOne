//! 剪贴板（F-10）：桌面端用 `arboard` 写入并打上"不进入剪贴板历史 / 不云同步 / 不被监控"标记，
//! 到期后仅当剪贴板内容仍是我们写入的那一份时才清空（比较 SHA-256，不在内存中保留明文）。
//! 移动端返回 false，由 Dart 侧使用系统剪贴板 + 定时清除。

use std::sync::Mutex;

use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};

static LAST: Mutex<Option<Vec<u8>>> = Mutex::new(None);

#[cfg(any(windows, target_os = "macos", target_os = "linux"))]
fn set_sensitive(text: &str) -> bool {
    let Ok(mut cb) = arboard::Clipboard::new() else { return false };
    let set = cb.set();
    #[cfg(windows)]
    let set = {
        use arboard::SetExtWindows;
        set.exclude_from_history().exclude_from_cloud().exclude_from_monitoring()
    };
    #[cfg(target_os = "macos")]
    let set = {
        use arboard::SetExtApple;
        set.exclude_from_history()
    };
    #[cfg(target_os = "linux")]
    let set = {
        use arboard::SetExtLinux;
        set.exclude_from_history()
    };
    set.text(text.to_string()).is_ok()
}

#[cfg(not(any(windows, target_os = "macos", target_os = "linux")))]
fn set_sensitive(_text: &str) -> bool {
    false
}

#[cfg(any(windows, target_os = "macos", target_os = "linux"))]
fn current_hash() -> Option<Vec<u8>> {
    let text = arboard::Clipboard::new().ok()?.get_text().ok()?;
    Some(Sha256::digest(zeroize::Zeroizing::new(text).as_bytes()).to_vec())
}

#[cfg(any(windows, target_os = "macos", target_os = "linux"))]
fn clear() -> bool {
    arboard::Clipboard::new().and_then(|mut c| c.clear()).is_ok()
}

#[cfg(not(any(windows, target_os = "macos", target_os = "linux")))]
fn current_hash() -> Option<Vec<u8>> {
    None
}

#[cfg(not(any(windows, target_os = "macos", target_os = "linux")))]
fn clear() -> bool {
    false
}

/// 复制敏感文本。返回 false 表示当前平台不支持，调用方应降级。
#[frb(sync)]
pub fn clipboard_copy_sensitive(text: String) -> bool {
    let ok = set_sensitive(&text);
    if ok {
        *LAST.lock().unwrap_or_else(|e| e.into_inner()) = Some(Sha256::digest(text.as_bytes()).to_vec());
    }
    ok
}

/// 若剪贴板仍是我们写入的内容则清空，返回是否执行了清空。
#[frb(sync)]
pub fn clipboard_clear_if_unchanged() -> bool {
    let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
    let Some(expected) = last.take() else { return false };
    if current_hash().as_deref() == Some(expected.as_slice()) {
        return clear();
    }
    false
}
