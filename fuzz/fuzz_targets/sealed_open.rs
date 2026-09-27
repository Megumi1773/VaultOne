//! 任意字节当作密封盒解密：不得 panic，只能返回 Integrity / Unsupported。
#![no_main]
use libfuzzer_sys::fuzz_target;
use vault_crypto::{sealed, CryptoError, Key32};

fuzz_target!(|data: &[u8]| {
    // 前 32 字节当密钥、1 字节当 AAD 长度，其余为密文
    if data.len() < 33 {
        return;
    }
    let key = Key32::from_slice(&data[..32]).unwrap();
    let aad_len = (data[32] as usize).min(data.len() - 33);
    let (aad, ct) = data[33..].split_at(aad_len);
    match sealed::open(&key, ct, aad) {
        Err(CryptoError::Integrity) | Err(CryptoError::Unsupported(_)) => {}
        Ok(_) => panic!("伪造密文通过了认证"),
        Err(e) => panic!("意外错误类型: {e:?}"),
    }
});
