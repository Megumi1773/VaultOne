//! TOTP 输入（扫码得到的 otpauth:// 链接或手输密钥，完全不可信）：解析与生成不得 panic。
#![no_main]
use libfuzzer_sys::fuzz_target;
use vault_core::totp;

fuzz_target!(|s: &str| {
    if let Ok(auth) = totp::parse(s) {
        let code = totp::generate(&auth.config, 1_700_000_000).expect("已通过校验的配置必须能生成");
        assert!(totp::verify(&auth.config, &code.code, 1_700_000_000).unwrap());
    }
});
