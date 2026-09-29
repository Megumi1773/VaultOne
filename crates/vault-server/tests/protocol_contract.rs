//! S0 服务端契约；所有固定值都是公开测试材料。
use base64::{
    engine::general_purpose::{STANDARD as B64, URL_SAFE_NO_PAD},
    Engine,
};
use vault_server::keys::{normalize_email, sha256, ServerKeys};

#[test]
fn server_key_vectors() {
    let secret: Vec<u8> = (0..32).collect();
    let keys = ServerKeys::new(&secret).unwrap();
    assert_eq!(normalize_email("  ALICE@Example.TEST\n"), "alice@example.test");
    let expected = [
        "Uz8Jmkx7MwP3HWmIZWVEMbGI8+RZXZAVRWPRJWmIRl8=",
        "DrM1BF0mRIroNUsZn4Pf43HB+eCYwb7EbnZsPGiuaKA=",
        "berGTVV/EG19AMkQHioZQDd9/39OWVqlfo4aq8gOJaifqQFtjuhD5i/5oK9+urlv",
        "6oZqdX5MOLq/qBJ8vppAnT4fk6AP8UiP9zX8+Rev/9A=",
    ];
    for ((name, bytes), expected) in [
        ("email", keys.email_hash("  ALICE@Example.TEST\n")),
        ("otp", keys.otp_hash("00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", "000123")),
        ("decoy", keys.decoy("alice@example.test", "srp-salt", 48)),
        ("token", sha256(URL_SAFE_NO_PAD.encode(&secret).as_bytes())),
    ]
    .into_iter()
    .zip(expected)
    {
        assert_eq!(B64.encode(bytes), expected, "{name}");
    }
    let email =
        B64.decode("AQEgISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0R/sbohjyMTIxfgIc/IBvyfiDZ9cR/DPf7eo8/+eJr0MDE=").unwrap();
    assert_eq!(keys.decrypt_email(&email).unwrap(), "alice@example.test");
    let handshake = B64.decode("AQEgISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS1cFkHrSAXIWUJUGbCwZuAeYyUpBqeekUhza7tlUIYdLb9DdttyPtdPLiN44O2PFUs81SBuGpBwkwpImj2HTie3RZ+UnM4kCc67D0HpTGDc/").unwrap();
    assert_eq!(&*keys.open_handshake("00000000-0000-4000-8000-000000000001", &handshake).unwrap(), &[0x22; 64]);
    assert!(keys.open_handshake("other", &handshake).is_err());
    for i in 0..email.len() {
        let mut changed = email.clone();
        changed[i] ^= 1;
        assert!(keys.decrypt_email(&changed).is_err());
    }
}

#[test]
fn json_bytes_null_and_enums() {
    use serde_json::{from_value, json, to_value};
    use vault_proto::*;
    assert_eq!(to_value(Bytes(vec![0, 1, 2, 255])).unwrap(), json!("AAEC/w=="));
    assert_eq!(to_value(Bytes::default()).unwrap(), json!(""));
    for value in [json!(null), json!([0, 1]), json!("AAEC_w=="), json!("AAEC/w"), json!(" AAE=")] {
        assert!(from_value::<Bytes>(value).is_err());
    }
    let response = LoginFinishResponse {
        m2: Bytes::default(),
        session: SessionInfo { token: "test".into(), expires_at: 1, device_id: "d".into(), device_approved: false },
        keys: None,
    };
    assert_eq!(
        to_value(response).unwrap(),
        json!({"m2":"","session":{"token":"test","expires_at":1,"device_id":"d","device_approved":false},"keys":null})
    );
    assert_eq!(
        to_value(PullResponse { items: vec![], cursor: 0, has_more: false, vk_gen: None }).unwrap(),
        json!({"items":[],"cursor":0,"has_more":false,"vk_gen":null})
    );
    assert!(from_value::<PullResponse>(json!({"items":[],"cursor":0,"has_more":false})).unwrap().vk_gen.is_none());
    assert!(from_value::<Platform>(json!("Windows")).is_err());
    assert!(from_value::<Platform>(json!("unknown")).is_err());
    assert_eq!(to_value(PushStatus::Conflict).unwrap(), json!("conflict"));
    assert!(from_value::<LoginStartRequest>(json!({"email":"a@b.c", "future":true})).is_ok());
}

#[test]
fn validation_boundaries() {
    use vault_proto::KdfParams;
    use vault_server::validate as v;
    let k = KdfParams { alg: "argon2id".into(), m: 19456, t: 2, p: 1, salt: B64.encode([0; 16]) };
    assert!(v::kdf(&k).is_ok());
    assert!(v::kdf(&KdfParams { m: 19455, ..k.clone() }).is_err());
    assert!(v::kdf(&KdfParams { t: 65, ..k.clone() }).is_err());
    assert!(v::kdf(&KdfParams { p: 17, ..k }).is_err());
    assert!(v::srp(&[0; 16], &[0; 384]).is_ok());
    assert!(v::srp(&[0; 15], &[0; 384]).is_err());
    assert!(v::srp(&[0; 65], &[0; 384]).is_err());
    assert!(v::srp(&[0; 32], &[0; 385]).is_err());
    let mut wrapped = vec![0; 94];
    wrapped[0] = 1;
    wrapped[1] = 1;
    assert!(v::wrapped_key(&wrapped, "test").is_ok());
    assert!(v::wrapped_key(&wrapped[..93], "test").is_err());
    assert!(v::hash32(&[0; 31], "test").is_err());
    assert!(v::item_blob(b"plaintext").is_err());
    assert_eq!(vault_proto::PUSH_MAX_ITEMS, 500);
    assert_eq!(vault_proto::PULL_PAGE_SIZE, 500);
}

/// 走真实 Router/提取器/中间件，锁定业务 JSON 错误与框架拒绝的区别。
#[tokio::test]
async fn http_status_and_rejection_contract() {
    use axum::{
        body::{to_bytes, Body},
        extract::ConnectInfo,
        http::Request,
    };
    use tower::ServiceExt;
    use vault_server::{config::Config, mail::Mailer, AppState};
    let dir = tempfile::tempdir().unwrap();
    let cfg = Config {
        database_url: format!("sqlite:{}?mode=rwc", dir.path().join("contract.db").display().to_string().replace('\\', "/")),
        server_secret: Some("0123456789abcdef".repeat(4)),
        auth_burst: 1000,
        api_burst: 1000,
        ..Config::default()
    };
    let state = AppState::new(cfg, Mailer::Memory(Default::default()), true).await.unwrap();
    let app = vault_server::router(state);
    for (method, path, body, content_type, status, code) in [
        ("GET", "/healthz", "", None, 200, None),
        ("GET", "/readyz", "", None, 200, None),
        ("GET", "/missing", "", None, 404, Some("not_found")),
        ("GET", "/v1/account", "", None, 401, Some("unauthorized")),
        ("POST", "/v1/auth/login/start", r#"{"email":"bad"}"#, Some("application/json"), 400, Some("bad_request")),
        ("POST", "/v1/auth/login/start", "{", Some("application/json"), 400, None),
        ("POST", "/v1/auth/login/start", "{}", Some("application/json"), 422, None),
        ("POST", "/v1/auth/login/start", "{}", None, 415, None),
        ("GET", "/v1/auth/login/start", "", None, 405, None),
    ] {
        let mut req = Request::builder().method(method).uri(path);
        if let Some(ct) = content_type {
            req = req.header("content-type", ct);
        }
        let mut req = req.body(Body::from(body)).unwrap();
        req.extensions_mut().insert(ConnectInfo("127.0.0.1:12345".parse::<std::net::SocketAddr>().unwrap()));
        let res = app.clone().oneshot(req).await.unwrap();
        assert_eq!(res.status().as_u16(), status, "{method} {path} {body}");
        assert_eq!(res.headers()["cache-control"], "no-store");
        let content_type = res.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_owned();
        let bytes = to_bytes(res.into_body(), 1024 * 1024).await.unwrap();
        if let Some(code) = code {
            assert!(content_type.starts_with("application/json"));
            let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["code"], code);
            assert!(value["message"].is_string());
        } else if matches!(status, 400 | 422 | 415) {
            assert!(content_type.starts_with("text/plain"));
            assert!(serde_json::from_slice::<serde_json::Value>(&bytes).is_err());
        }
    }
}
