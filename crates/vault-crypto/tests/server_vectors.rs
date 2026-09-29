//! S0 固定测试材料，绝不能用于生产；a=1 特意覆盖无补齐公钥 A=05。
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use sha2::Sha256;
use srp::{client::SrpClient, groups::G_3072, server::SrpServer};
use vault_crypto::{srp6a, Key32};

/// 生产 seal 强制随机盐/IV；仅在测试中用现有原语固定随机输入，不修改生产 API。
#[test]
fn fixed_server_sealed_boxes() {
    use aes_gcm::{
        aead::{Aead, KeyInit, Payload},
        Aes256Gcm, Nonce,
    };
    use hkdf::Hkdf;
    let secret: Vec<u8> = (0..32).collect();
    let salt: Vec<u8> = (32..64).collect();
    let iv: Vec<u8> = (64..76).collect();
    for (label, aad, plaintext) in [
        ("email-enc", b"vaultone-server/email".as_slice(), b"alice@example.test".to_vec()),
        ("handshake", b"00000000-0000-4000-8000-000000000001".as_slice(), vec![0x22; 64]),
    ] {
        let mut root = [0; 32];
        Hkdf::<Sha256>::new(Some(b"vaultone-server/v1"), &secret).expand(label.as_bytes(), &mut root).unwrap();
        let mut mk = [0; 32];
        Hkdf::<Sha256>::new(Some(&salt), &root).expand(b"vaultone/v1/sealed", &mut mk).unwrap();
        let mut blob = vec![1, 1];
        blob.extend_from_slice(&salt);
        blob.extend_from_slice(&iv);
        let mut full_aad = blob.clone();
        full_aad.extend_from_slice(&(aad.len() as u64).to_be_bytes());
        full_aad.extend_from_slice(aad);
        blob.extend(Aes256Gcm::new((&mk).into()).encrypt(Nonce::from_slice(&iv), Payload { msg: &plaintext, aad: &full_aad }).unwrap());
        let expected = if label == "email-enc" {
            "AQEgISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0R/sbohjyMTIxfgIc/IBvyfiDZ9cR/DPf7eo8/+eJr0MDE="
        } else {
            "AQEgISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS1cFkHrSAXIWUJUGbCwZuAeYyUpBqeekUhza7tlUIYdLb9DdttyPtdPLiN44O2PFUs81SBuGpBwkwpImj2HTie3RZ+UnM4kCc67D0HpTGDc/"
        };
        assert_eq!(B64.encode(&blob), expected);
        let key = Key32::from_slice(&root).unwrap();
        assert_eq!(&*vault_crypto::sealed::open(&key, &blob, aad).unwrap(), &plaintext);
        assert!(vault_crypto::sealed::open(&key, &blob, b"wrong-context").is_err());
    }
}

#[test]
fn srp_fixed_transcript() {
    let identity = "00000000-0000-4000-8000-000000000001";
    let auth = Key32::from_slice(&(0u8..32).collect::<Vec<_>>()).unwrap();
    let salt: Vec<u8> = (32..64).collect();
    let b = [0x22; 64];
    let client = SrpClient::<Sha256>::new(&G_3072);
    let server = SrpServer::<Sha256>::new(&G_3072);
    let v = srp6a::verifier_with_salt(identity, &auth, &salt);
    let a_pub = client.compute_public_ephemeral(&[1]);
    assert_eq!(a_pub, [5]);
    let b_pub = server.compute_public_ephemeral(&b, &v);
    let proof = client.process_reply(&[1], identity.as_bytes(), auth.as_bytes(), &salt, &b_pub).unwrap();
    let m2 = srp6a::server_finish(&b, &v, &a_pub, proof.proof()).unwrap();
    assert_eq!(B64.encode(&v), "vbwhF0PrhG41PuxxrhCeykqvJFO8D2z1rf+jlRH+0Cq0/Z/cqkkivyuCEA859m5h/H8lNiYPEyuiwVcYrF8IaPhtKN8Lir2OWtZbQbUMUYlGZeY2yJB/uHBR0DPbcG7BbfCB/nLKT7eJMAlzhYYONYOg9Hu3lO7x44M1dzt+GJPrU454vNZdNIgONOr72dKd6YmpqTYC9CDctMNY1rCXCkF5TQZp3h0sA0ifmycpYlKPLK1t5IFpsfb+DeLepI6EQNLiVfj125YMY2cPo/qeJElCbtGA60nJQPmdQFBGE7y3zNccxYd3eeeY+8eUoJToLBt1wFo9WLCzMYvA2RyX47dVNhOEiTaOMG8TKuO8gTZH2ef2BZfMiUPEvIvnXIjIrEOGrF6KlIPfh/mdgeOSlF0gTF09jZ8pWgI0dnHHrtYX9UeSZWswmiqMrzknI4t6VRD8Q5rIcnF30J3l0noMnbSZTxB3PL1j762+GzHClTsNFO/mvT8IzKomZejAdc1K");
    assert_eq!(B64.encode(&b_pub), "LQ9O0xR9vsDxAToZ3O6kCbkWe5ln5bgi3V6gU8NojYfJ03ZMrth7khD/bQ1OWWUvLygbbBsCdZLC2pExiAdV9wxPAPUj2sIXJ0sX6OpU0GSlmNkhxYeHvdTk4/vhWi7pazMyxEJ0ouEwEBLYsdegbVnSuq94LDQCa/pjTIsqG8tSaNig9rT8FZU0O3gtzslxM5E9TSruQ/r97JbgRkC7NxP58/5pcXgNJw7DUcQOqRmmjre8bDJIZ02LpgP7GBv/jQkiaNFkZY1uN8+SQEJ2WjGm+IBWjPXsTjfczN4lHx+9s+C2+amZ5emqFYSTVmv0wttyxuKJbXKMIaDwBgiFhlWd/ks7YhXBNfSwX6QJpCTo1eP5rJFEt5ZguQhyiSfcNCVu1hwUDuXH/s6kVyu0J7rrnqtiS5ENJUN+lL8IoV7c3bTHRkrjnPXPxqc9j8l9VtqkYS5wXG35Ev48P2nJCWueWLe6vkYniQzu28FhzvePl1s3OO/a/7pnnk9TEAM7");
    assert_eq!(B64.encode(proof.key()), "uUFbJzZon6HRLDlmE/VnwUbyHAD/tSD+PG8tBQZKnRtcVifNBSXPBUo2qvUbfTHR2LKvthuV9qqDPONIx+HbNBZSNfuMKX/dwzNUMLPaJqTVkDkfsHkpeA6TLPUXlOIYKvm9V7Pf2PXGrc7vCLv5JkhZQIMSNNdl21HQs9sbngFqPsJB7FXeY7zm5jsA8jdHkuFOd2/MUkFxh7OfpAV+snRUER/Xq7L1H/ODIpm+bcIXEORa7wsc75hxW9Z3ZPiTIfdJ4TvUOhSZ0IAwONk33gfzsdnsErqpXREBbsP4u3URzhnrf+MgMrkJ+TFDEQHgQg1W85T/3x2RKKdN2Dj6cIyPF7fBe6yuXpqqBrEs7GLhqQpZsxHabA1f2UtTul7Fn7eDUI2ILqc/rTA4IOAjCGltdDQ0VRJ4cWXfRZGhtV83EUZw1hy6XrDZ0dyA3hLB6sH58lEFDgaKVbIs63iGXkEbgF7n/oxeQUyV39qR2Bj3sVBiKbFugMeh1D/wF2gc");
    assert_eq!(B64.encode(proof.proof()), "/c0Jmw7cI0bN+Bw7Sxch0bcOMPs4LLm09PDeg63yhoc=");
    assert_eq!(B64.encode(&m2), "cY8FzH+OodMB/PU1/sDkO/0jafHDYP6003nV5WF3D0o=");
    proof.verify_server(&m2).unwrap();
    assert!(srp6a::server_finish(&b, &v, &[0], proof.proof()).is_err());
    assert!(srp6a::server_finish(&b, &v, &a_pub, &[0; 32]).is_err());
}
