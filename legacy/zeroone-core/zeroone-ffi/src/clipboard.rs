//! 敏感内容剪贴板（F-10）。
//!
//! Windows 下写入剪贴板时同时设置：
//! - `ExcludeClipboardContentFromMonitorProcessing`：告知剪贴板监视程序忽略此内容
//! - `CanIncludeInClipboardHistory = 0`：不进入 Win+V 剪贴板历史
//! - `CanUploadToCloudClipboard = 0`：不跨设备云同步
//!
//! 清空时比对剪贴板序列号：若用户期间复制过其他内容，则不清空。

#[cfg(windows)]
mod imp {
    use std::ptr::null_mut;
    use std::thread::sleep;
    use std::time::Duration;

    use windows_sys::Win32::Foundation::{GlobalFree, HANDLE};
    use windows_sys::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, GetClipboardSequenceNumber, OpenClipboard, RegisterClipboardFormatW,
        SetClipboardData,
    };
    use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};

    const CF_UNICODETEXT: u32 = 13;

    struct ClipboardGuard;

    impl ClipboardGuard {
        fn open() -> Result<Self, String> {
            for _ in 0..10 {
                if unsafe { OpenClipboard(null_mut()) } != 0 {
                    return Ok(Self);
                }
                sleep(Duration::from_millis(15));
            }
            Err("剪贴板被其他程序占用".into())
        }
    }

    impl Drop for ClipboardGuard {
        fn drop(&mut self) {
            unsafe { CloseClipboard() };
        }
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    unsafe fn put_bytes(format: u32, bytes: &[u8]) -> Result<(), String> {
        let h = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1));
        if h.is_null() {
            return Err("GlobalAlloc 失败".into());
        }
        let p = GlobalLock(h) as *mut u8;
        if p.is_null() {
            GlobalFree(h);
            return Err("GlobalLock 失败".into());
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p, bytes.len());
        GlobalUnlock(h);
        // 成功后内存所有权归系统
        if SetClipboardData(format, h as HANDLE).is_null() {
            GlobalFree(h);
            return Err("SetClipboardData 失败".into());
        }
        Ok(())
    }

    pub fn copy_sensitive(text: &str) -> Result<u32, String> {
        let _guard = ClipboardGuard::open()?;
        unsafe {
            EmptyClipboard();
            let mut utf16: Vec<u16> = wide(text);
            let bytes = std::slice::from_raw_parts(utf16.as_ptr() as *const u8, utf16.len() * 2);
            let result = put_bytes(CF_UNICODETEXT, bytes);
            // 清零本进程内的 UTF-16 副本
            for c in utf16.iter_mut() {
                std::ptr::write_volatile(c, 0);
            }
            result?;
            let zero = 0u32.to_le_bytes();
            for name in ["CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"] {
                let fmt = RegisterClipboardFormatW(wide(name).as_ptr());
                if fmt != 0 {
                    let _ = put_bytes(fmt, &zero);
                }
            }
            let fmt = RegisterClipboardFormatW(wide("ExcludeClipboardContentFromMonitorProcessing").as_ptr());
            if fmt != 0 {
                let _ = put_bytes(fmt, &[0]);
            }
        }
        Ok(unsafe { GetClipboardSequenceNumber() })
    }

    pub fn clear_if_unchanged(sequence: u32) -> Result<bool, String> {
        if unsafe { GetClipboardSequenceNumber() } != sequence {
            return Ok(false);
        }
        let _guard = ClipboardGuard::open()?;
        unsafe { EmptyClipboard() };
        Ok(true)
    }
}

#[cfg(not(windows))]
mod imp {
    pub fn copy_sensitive(_text: &str) -> Result<u32, String> {
        Err("unsupported".into())
    }

    pub fn clear_if_unchanged(_sequence: u32) -> Result<bool, String> {
        Err("unsupported".into())
    }
}

pub use imp::{clear_if_unchanged, copy_sensitive};
