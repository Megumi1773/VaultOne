//! ZeroOne FFI 桥接层。
//!
//! C ABI 只有两个函数：
//! - `zo_call(req, req_len, out_len) -> *mut u8`：输入输出均为 UTF-8 JSON
//! - `zo_free(ptr, len)`：清零并释放 `zo_call` 返回的缓冲区
//!
//! 请求：`{"method": "...", "params": {...}}`
//! 响应：`{"ok": true, "result": ...}` 或 `{"ok": false, "error": {"code": "...", "message": "..."}}`
//!
//! 同一套命令协议将来由浏览器扩展的 Native Messaging 宿主复用（计划书 S-05）。

mod clipboard;
mod dispatch;

use std::panic::{catch_unwind, AssertUnwindSafe};

use zeroize::Zeroize;

pub use dispatch::handle;

/// # Safety
/// `req` 必须指向 `req_len` 字节的有效内存；`out_len` 必须是可写的有效指针。
/// 返回的缓冲区必须用 [`zo_free`] 释放。
#[no_mangle]
pub unsafe extern "C" fn zo_call(req: *const u8, req_len: usize, out_len: *mut usize) -> *mut u8 {
    let input = if req.is_null() { &[][..] } else { std::slice::from_raw_parts(req, req_len) };
    let response = catch_unwind(AssertUnwindSafe(|| handle(input)))
        .unwrap_or_else(|_| br#"{"ok":false,"error":{"code":"internal","message":"内核发生内部错误"}}"#.to_vec());
    let mut boxed = response.into_boxed_slice();
    *out_len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    ptr
}

/// # Safety
/// `ptr`/`len` 必须来自 [`zo_call`] 的返回值，且只能释放一次。
#[no_mangle]
pub unsafe extern "C" fn zo_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    let mut boxed = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len));
    boxed.zeroize();
    drop(boxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c_abi_roundtrip() {
        let req = br#"{"method":"ping"}"#;
        let mut len = 0usize;
        let ptr = unsafe { zo_call(req.as_ptr(), req.len(), &mut len) };
        let body = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        unsafe { zo_free(ptr, len) };
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["result"]["core"], "zeroone");
    }
}
