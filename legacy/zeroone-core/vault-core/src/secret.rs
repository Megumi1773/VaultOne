//! 密钥材料容器。
//!
//! [`Key32`] 使用 `memsec::malloc` 分配独立内存页：页面 `mlock/VirtualLock` 防止写入 swap，
//! 前后有保护页防越界读，释放时先清零再归还。这相当于 libsodium 的 `sodium_malloc`。

use std::fmt;
use std::ptr::NonNull;

use rand::rngs::OsRng;
use rand::RngCore;
use subtle::ConstantTimeEq;
use zeroize::Zeroize;

use crate::{Result, VaultError};

pub const KEY_LEN: usize = 32;

pub struct Key32 {
    ptr: NonNull<[u8; KEY_LEN]>,
}

// 内存由本结构独占，没有内部共享可变状态。
unsafe impl Send for Key32 {}
unsafe impl Sync for Key32 {}

impl Key32 {
    fn alloc() -> Result<Self> {
        // SAFETY: memsec::malloc 返回一块至少 KEY_LEN 字节的独立受保护内存。
        let ptr = unsafe { memsec::malloc::<[u8; KEY_LEN]>() }.ok_or(VaultError::Crypto)?;
        let mut key = Key32 { ptr };
        key.bytes_mut().zeroize();
        Ok(key)
    }

    /// 由 CSPRNG（OsRng）生成随机密钥。
    pub fn random() -> Result<Self> {
        let mut key = Self::alloc()?;
        OsRng.fill_bytes(key.bytes_mut());
        Ok(key)
    }

    /// 从切片复制。调用方负责清零来源缓冲区。
    pub fn from_slice(src: &[u8]) -> Result<Self> {
        if src.len() != KEY_LEN {
            return Err(VaultError::Format("密钥长度必须为 32 字节".into()));
        }
        let mut key = Self::alloc()?;
        key.bytes_mut().copy_from_slice(src);
        Ok(key)
    }

    /// 通过闭包就地填充，避免中间缓冲区。
    pub fn fill_with(f: impl FnOnce(&mut [u8; KEY_LEN]) -> Result<()>) -> Result<Self> {
        let mut key = Self::alloc()?;
        f(key.bytes_mut())?;
        Ok(key)
    }

    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        // SAFETY: ptr 在 self 生命周期内有效且已初始化。
        unsafe { self.ptr.as_ref() }
    }

    fn bytes_mut(&mut self) -> &mut [u8; KEY_LEN] {
        // SAFETY: 同上，且 &mut self 保证独占。
        unsafe { self.ptr.as_mut() }
    }

    pub fn try_clone(&self) -> Result<Self> {
        Self::from_slice(self.as_bytes())
    }
}

impl Drop for Key32 {
    fn drop(&mut self) {
        self.bytes_mut().zeroize();
        // SAFETY: ptr 来自 memsec::malloc，且只释放一次。
        unsafe { memsec::free(self.ptr) }
    }
}

impl PartialEq for Key32 {
    fn eq(&self, other: &Self) -> bool {
        self.as_bytes().ct_eq(other.as_bytes()).into()
    }
}
impl Eq for Key32 {}

impl fmt::Debug for Key32 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Key32(<redacted>)")
    }
}

/// 生成指定长度的随机字节。
pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut buf = [0u8; N];
    OsRng.fill_bytes(&mut buf);
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn random_keys_differ() {
        let a = Key32::random().unwrap();
        let b = Key32::random().unwrap();
        assert_ne!(a, b);
        assert_eq!(a, a.try_clone().unwrap());
    }

    #[test]
    fn debug_is_redacted() {
        let k = Key32::from_slice(&[7u8; 32]).unwrap();
        assert_eq!(format!("{k:?}"), "Key32(<redacted>)");
    }

    #[test]
    fn rejects_wrong_length() {
        assert!(Key32::from_slice(&[0u8; 16]).is_err());
    }
}
