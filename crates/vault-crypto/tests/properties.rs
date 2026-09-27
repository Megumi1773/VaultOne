//! 属性测试（计划书 B-09）：对任意输入验证密码学编排层的不变量。
//!
//! 与各模块内的样例测试互补——样例测试钉住已知边界，这里用随机输入覆盖其余空间。
//! 任意字节输入不得 panic 的"健壮性"性质同时由 `fuzz/` 下的 cargo-fuzz 目标长时间覆盖。

use proptest::prelude::*;
use vault_crypto::keys::{RecoveryCode, SecretKey};
use vault_crypto::pad::{pad, unpad, PAD_BLOCK};
use vault_crypto::sealed::{self, OVERHEAD};
use vault_crypto::{srp6a, CryptoError, Key32};
use zeroize::Zeroizing;

fn key(bytes: [u8; 32]) -> Key32 {
    Key32::from_slice(&bytes).unwrap()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// 密封盒：任意明文 / AAD 往返一致，长度开销固定。
    #[test]
    fn sealed_roundtrip(k in any::<[u8; 32]>(), pt in prop::collection::vec(any::<u8>(), 0..2048), aad in prop::collection::vec(any::<u8>(), 0..128)) {
        let k = key(k);
        let ct = sealed::seal(&k, &pt, &aad).unwrap();
        prop_assert_eq!(ct.len(), pt.len() + OVERHEAD);
        prop_assert_eq!(&*sealed::open(&k, &ct, &aad).unwrap(), &pt[..]);
    }

    /// 密封盒：翻转任意一位都会被认证标签拒绝（版本/套件位返回 Unsupported，其余返回 Integrity）。
    #[test]
    fn sealed_any_bitflip_rejected(k in any::<[u8; 32]>(), pt in prop::collection::vec(any::<u8>(), 0..256), pos in any::<prop::sample::Index>(), bit in 0u8..8) {
        let k = key(k);
        let mut ct = sealed::seal(&k, &pt, b"aad").unwrap();
        let i = pos.index(ct.len());
        ct[i] ^= 1 << bit;
        prop_assert!(sealed::open(&k, &ct, b"aad").is_err());
    }

    /// 密封盒：AAD 不同（含前缀/扩展）必然失败——防跨条目重放。
    #[test]
    fn sealed_aad_binding(k in any::<[u8; 32]>(), aad in prop::collection::vec(any::<u8>(), 0..64), other in prop::collection::vec(any::<u8>(), 0..64)) {
        prop_assume!(aad != other);
        let k = key(k);
        let ct = sealed::seal(&k, b"payload", &aad).unwrap();
        prop_assert_eq!(sealed::open(&k, &ct, &other), Err(CryptoError::Integrity));
    }

    /// 密封盒：换密钥必然失败。
    #[test]
    fn sealed_key_binding(k1 in any::<[u8; 32]>(), k2 in any::<[u8; 32]>()) {
        prop_assume!(k1 != k2);
        let ct = sealed::seal(&key(k1), b"payload", b"").unwrap();
        prop_assert_eq!(sealed::open(&key(k2), &ct, b""), Err(CryptoError::Integrity));
    }

    /// 密封盒：任意字节串都不会让 open panic，且只返回 Integrity / Unsupported。
    #[test]
    fn sealed_open_arbitrary_bytes(k in any::<[u8; 32]>(), junk in prop::collection::vec(any::<u8>(), 0..512)) {
        match sealed::open(&key(k), &junk, b"") {
            Err(CryptoError::Integrity) | Err(CryptoError::Unsupported(_)) => {}
            other => prop_assert!(false, "unexpected {:?}", other.map(|v| v.len())),
        }
    }

    /// 密钥封装往返。
    #[test]
    fn wrap_unwrap_roundtrip(kek in any::<[u8; 32]>(), k in any::<[u8; 32]>(), aad in prop::collection::vec(any::<u8>(), 0..64)) {
        let w = sealed::wrap_key(&key(kek), &key(k), &aad).unwrap();
        prop_assert_eq!(sealed::unwrap_key(&key(kek), &w, &aad).unwrap(), key(k));
    }

    /// 填充：输出总是 256 的倍数、严格长于输入，且往返一致。
    #[test]
    fn pad_roundtrip(data in prop::collection::vec(any::<u8>(), 0..1500)) {
        let p = pad(&data);
        prop_assert_eq!(p.len() % PAD_BLOCK, 0);
        prop_assert!(p.len() > data.len());
        prop_assert!(p.len() - data.len() <= PAD_BLOCK);
        prop_assert_eq!(&*unpad(p).unwrap(), &data[..]);
    }

    /// 填充：任意输入 unpad 不 panic；成功时结果是输入的前缀。
    #[test]
    fn unpad_arbitrary(data in prop::collection::vec(any::<u8>(), 0..600)) {
        if let Ok(out) = unpad(Zeroizing::new(data.clone())) {
            prop_assert!(data.starts_with(&out));
            prop_assert_eq!(data[out.len()], 0x80);
            prop_assert!(data[out.len() + 1..].iter().all(|&b| b == 0));
        }
    }

    /// Secret Key / Recovery Code：任意字符串解析不 panic；合法输出经大小写、分隔符变形后仍能解析回同一值。
    #[test]
    fn key_parsing_is_total(s in ".{0,80}") {
        let _ = SecretKey::parse(&s);
        let _ = RecoveryCode::parse(&s);
    }

    #[test]
    fn secret_key_format_parse(lower in any::<bool>(), sep in prop::sample::select(vec!["-", " ", "", "\n"])) {
        let sk = SecretKey::generate();
        let mut text = sk.format().replace('-', sep);
        if lower { text = text.to_lowercase(); }
        let parsed = SecretKey::parse(&text).unwrap();
        prop_assert_eq!(parsed.as_bytes(), sk.as_bytes());
        // Secret Key 永远不会被当成恢复码接受
        prop_assert!(RecoveryCode::parse(&text).is_err());
    }

    #[test]
    fn recovery_code_format_parse(lower in any::<bool>()) {
        let rc = RecoveryCode::generate();
        let mut text = rc.format().to_string();
        if lower { text = text.to_lowercase(); }
        let parsed = RecoveryCode::parse(&text).unwrap();
        prop_assert_eq!(parsed.wrap_key("acct").unwrap(), rc.wrap_key("acct").unwrap());
        prop_assert!(SecretKey::parse(&text).is_err());
    }
}

proptest! {
    // SRP 使用 3072-bit 模幂，单次较慢，少跑几轮
    #![proptest_config(ProptestConfig::with_cases(12))]

    /// SRP-6a：同口令必然握手成功且双方会话密钥一致；口令不同必然被服务端拒绝。
    #[test]
    fn srp_handshake(auth in any::<[u8; 32]>(), wrong in any::<[u8; 32]>(), id in "[a-f0-9-]{8,36}") {
        let auth_key = key(auth);
        let reg = srp6a::register(&id, &auth_key);

        let client = srp6a::ClientHandshake::start();
        let (b, b_pub) = srp6a::server_start(&reg.verifier);
        let proof = client.finish(&id, &auth_key, &reg.salt, &b_pub).unwrap();
        let m2 = srp6a::server_finish(&b, &reg.verifier, &client.a_pub, &proof.m1).unwrap();
        prop_assert!(proof.verify_server(&m2).is_ok());

        prop_assume!(auth != wrong);
        let client = srp6a::ClientHandshake::start();
        let (b, b_pub) = srp6a::server_start(&reg.verifier);
        let bad = client.finish(&id, &key(wrong), &reg.salt, &b_pub).unwrap();
        prop_assert_eq!(srp6a::server_finish(&b, &reg.verifier, &client.a_pub, &bad.m1), Err(CryptoError::SrpAuth));
    }
}
