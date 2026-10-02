//! 截图保护（§8.3）：阻止本应用窗口被截屏 / 录屏捕获。
//!
//! Windows 上通过 `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` 实现：窗口内容对
//! 捕获 API 呈现为空白，但用户自己看得到。其他平台暂不支持，返回 `false`，界面据此把开关
//! 标成不可用——**不假装成功**。
//!
//! 窗口句柄由本进程自行枚举得到：只认属于当前进程 id 的可见顶层窗口，不去猜窗口标题。

/// 不参与捕获（Windows 10 2004+）。旧系统上会返回失败，调用方按不支持处理。
#[cfg(windows)]
const WDA_EXCLUDEFROMCAPTURE: u32 = 0x0000_0011;
#[cfg(windows)]
const WDA_NONE: u32 = 0x0000_0000;

#[cfg(windows)]
mod win {
    use std::ffi::c_void;

    pub type Hwnd = *mut c_void;

    #[link(name = "user32")]
    extern "system" {
        pub fn EnumWindows(callback: extern "system" fn(Hwnd, isize) -> i32, param: isize) -> i32;
        pub fn GetWindowThreadProcessId(hwnd: Hwnd, pid: *mut u32) -> u32;
        pub fn IsWindowVisible(hwnd: Hwnd) -> i32;
        pub fn SetWindowDisplayAffinity(hwnd: Hwnd, affinity: u32) -> i32;
    }
}

/// 枚举回调的累积状态：当前进程的可见顶层窗口，以及实际被设置成功的数量。
#[cfg(windows)]
struct AffinityTargets {
    pid: u32,
    affinity: u32,
    applied: usize,
}

#[cfg(windows)]
extern "system" fn apply_to_window(hwnd: win::Hwnd, param: isize) -> i32 {
    // SAFETY: 回调只在 EnumWindows 内部被同步调用，param 始终是有效的 &mut AffinityTargets。
    let targets = unsafe { &mut *(param as *mut AffinityTargets) };
    let mut pid = 0u32;
    unsafe { win::GetWindowThreadProcessId(hwnd, &mut pid) };
    if pid != targets.pid || unsafe { win::IsWindowVisible(hwnd) } == 0 {
        return 1; // 继续枚举
    }
    if unsafe { win::SetWindowDisplayAffinity(hwnd, targets.affinity) } != 0 {
        targets.applied += 1;
    }
    1
}

/// 开关截图保护。返回是否至少有一个窗口被成功设置；`false` 表示当前平台不支持。
#[flutter_rust_bridge::frb(sync)]
pub fn set_protection(enabled: bool) -> bool {
    #[cfg(windows)]
    {
        let mut targets =
            AffinityTargets { pid: std::process::id(), affinity: if enabled { WDA_EXCLUDEFROMCAPTURE } else { WDA_NONE }, applied: 0 };
        // SAFETY: 回调签名与 EnumWindows 要求一致，param 指向本帧内有效的结构体。
        unsafe {
            win::EnumWindows(apply_to_window, &mut targets as *mut AffinityTargets as isize);
        }
        return targets.applied > 0;
    }
    #[allow(unreachable_code)]
    {
        let _ = enabled;
        false
    }
}

/// 当前平台是否支持截图保护。界面据此决定开关是否可点，避免用户打开一个没有作用的选项。
#[flutter_rust_bridge::frb(sync)]
pub fn is_supported() -> bool {
    cfg!(windows)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supported_matches_platform() {
        // 只有 Windows 实现了真实调用；其他平台必须如实报告不支持。
        assert_eq!(is_supported(), cfg!(windows));
    }

    #[test]
    fn unsupported_platform_reports_failure() {
        if cfg!(windows) {
            return;
        }
        assert!(!set_protection(true), "不支持的平台不能假装成功");
        assert!(!set_protection(false));
    }
}
