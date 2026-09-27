//! 条目信封（来自服务端 / 本地库的不可信字节）：反序列化与解密均不得 panic。
#![no_main]
use libfuzzer_sys::fuzz_target;
use vault_core::envelope::Envelope;
use vault_crypto::Key32;

fuzz_target!(|data: &[u8]| {
    if let Ok(env) = Envelope::from_bytes(data) {
        let key = Key32::from_slice(&[7u8; 32]).unwrap();
        let _ = env.open(&key, "item", "vault", 1);
    }
});
