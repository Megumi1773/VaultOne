//! Secret Key / Recovery Code 解析：任意字符串不 panic；解析成功则格式化后可再次解析回同一值。
#![no_main]
use libfuzzer_sys::fuzz_target;
use vault_crypto::keys::{RecoveryCode, SecretKey};

fuzz_target!(|s: &str| {
    if let Ok(sk) = SecretKey::parse(s) {
        assert_eq!(SecretKey::parse(&sk.format()).unwrap().as_bytes(), sk.as_bytes());
    }
    if let Ok(rc) = RecoveryCode::parse(s) {
        let again = RecoveryCode::parse(&rc.format()).unwrap();
        assert_eq!(again.wrap_key("a").unwrap(), rc.wrap_key("a").unwrap());
    }
});
