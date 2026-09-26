//! 输入校验。服务端虽然看不懂密文，但可以校验其**结构**：
//! 所有密文必须是合法的 AES-256-GCM 密封盒 / 条目信封，条目密文长度必须按 256 字节对齐。
//! 这同时构成计划书 §4.1 的"服务端零知识门禁"——客户端无法把明文当作 blob 上传。

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use vault_crypto::sealed;
use vault_proto::{DeviceInfo, KdfParams};

use crate::error::{ApiError, ApiResult};

pub const WRAPPED_KEY_LEN: usize = sealed::OVERHEAD + 32;
pub const MAX_BLOB_LEN: usize = 1024 * 1024;

pub fn uuid(s: &str, what: &str) -> ApiResult<()> {
    uuid::Uuid::parse_str(s).map(|_| ()).map_err(|_| ApiError::bad_request(format!("{what} 不是合法 UUID")))
}

pub fn email(e: &str) -> ApiResult<()> {
    let e = e.trim();
    let ok = e.len() <= 254 && e.split_once('@').is_some_and(|(l, d)| !l.is_empty() && d.contains('.'));
    if ok {
        Ok(())
    } else {
        Err(ApiError::bad_request("邮箱格式不正确"))
    }
}

pub fn kdf(k: &KdfParams) -> ApiResult<()> {
    let salt_ok = B64.decode(&k.salt).is_ok_and(|s| s.len() >= 16);
    let ok =
        k.alg == "argon2id" && k.m >= 19 * 1024 && k.m <= 4 * 1024 * 1024 && (2..=64).contains(&k.t) && (1..=16).contains(&k.p) && salt_ok;
    if ok {
        Ok(())
    } else {
        Err(ApiError::bad_request("KDF 参数不合法或低于安全下限"))
    }
}

/// 测试构建允许低成本 KDF 参数（与客户端 `insecure-test-kdf` 对应）。
pub fn kdf_lenient(k: &KdfParams, allow_test: bool) -> ApiResult<()> {
    if allow_test && k.alg == "argon2id" && k.m == 8 && k.t == 1 && k.p == 1 {
        return Ok(());
    }
    kdf(k)
}

pub fn srp(salt: &[u8], verifier: &[u8]) -> ApiResult<()> {
    if salt.len() < 16 || salt.len() > 64 || verifier.is_empty() || verifier.len() > 384 {
        return Err(ApiError::bad_request("SRP 参数不合法"));
    }
    Ok(())
}

/// 256-bit 密钥的密封盒（版本字节 + 32B 盐 + 12B IV + 32B 密文 + 16B 标签）。
pub fn wrapped_key(b: &[u8], what: &str) -> ApiResult<()> {
    if b.len() != WRAPPED_KEY_LEN || b[0] != sealed::VERSION || b[1] != sealed::SUITE_AES256GCM_HKDF_SHA256 {
        return Err(ApiError::bad_request(format!("{what} 不是合法的 AES-256-GCM 密封盒")));
    }
    Ok(())
}

pub fn hash32(b: &[u8], what: &str) -> ApiResult<()> {
    if b.len() != 32 {
        return Err(ApiError::bad_request(format!("{what} 长度不正确")));
    }
    Ok(())
}

pub fn device(d: &DeviceInfo) -> ApiResult<()> {
    uuid(&d.id, "device.id")?;
    let n = d.name.trim().chars().count();
    if n == 0 || n > 64 {
        return Err(ApiError::bad_request("设备名需为 1-64 个字符"));
    }
    Ok(())
}

pub fn kind(k: &str) -> ApiResult<()> {
    if matches!(k, "login" | "card" | "note" | "identity") {
        Ok(())
    } else {
        Err(ApiError::bad_request("未知条目类型"))
    }
}

/// 条目信封结构校验：`{"v":2,"alg":"aes-256-gcm","wrappedKey":<密封盒>,"ct":<密封盒, 256B 对齐>}`
pub fn item_blob(blob: &[u8]) -> ApiResult<()> {
    let bad = || ApiError::bad_request("条目密文格式不合法");
    if blob.len() > MAX_BLOB_LEN {
        return Err(ApiError::bad_request("条目过大"));
    }
    let v: serde_json::Value = serde_json::from_slice(blob).map_err(|_| bad())?;
    let obj = v.as_object().ok_or_else(bad)?;
    if obj.len() != 4 || obj.get("v").and_then(|x| x.as_u64()) != Some(2) || obj.get("alg").and_then(|x| x.as_str()) != Some("aes-256-gcm")
    {
        return Err(bad());
    }
    let decode = |k: &str| obj.get(k).and_then(|x| x.as_str()).and_then(|s| B64.decode(s).ok()).ok_or_else(bad);
    wrapped_key(&decode("wrappedKey")?, "wrappedKey")?;
    let ct = decode("ct")?;
    let body = ct.len().checked_sub(sealed::OVERHEAD).ok_or_else(bad)?;
    if ct[0] != sealed::VERSION || ct[1] != sealed::SUITE_AES256GCM_HKDF_SHA256 || body == 0 || body % 256 != 0 {
        return Err(bad());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use vault_crypto::Key32;

    fn envelope(ct_len: usize) -> Vec<u8> {
        let k = Key32::random().unwrap();
        let wk = sealed::wrap_key(&k, &k, b"").unwrap();
        let ct = sealed::seal(&k, &vec![0u8; ct_len], b"").unwrap();
        serde_json::to_vec(&serde_json::json!({"v":2,"alg":"aes-256-gcm","wrappedKey":B64.encode(wk),"ct":B64.encode(ct)})).unwrap()
    }

    #[test]
    fn accepts_real_envelopes_only() {
        assert!(item_blob(&envelope(256)).is_ok());
        assert!(item_blob(&envelope(512)).is_ok());
        assert!(item_blob(&envelope(100)).is_err(), "未对齐的明文长度泄露应被拒绝");
        assert!(item_blob(br#"{"title":"GitHub","password":"hunter2"}"#).is_err());
        assert!(item_blob(b"plaintext").is_err());
    }

    #[test]
    fn validates_kdf() {
        assert!(kdf(&KdfParams::recommended()).is_ok());
        assert!(kdf(&KdfParams::with_cost(1024, 1, 1)).is_err());
        let mut k = KdfParams::recommended();
        k.salt = B64.encode([0u8; 8]);
        assert!(kdf(&k).is_err());
    }
}
