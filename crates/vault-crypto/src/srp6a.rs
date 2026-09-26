//! SRP-6a 口令认证（计划书 S-01）：主密码从不离开设备，服务端只存 verifier。
//!
//! 直接使用 RustCrypto `srp` crate（RFC 5054 3072-bit 群，H = SHA-256）。本模块只做两件事：
//! 1. 把 AuthKey（由主密码 + Secret Key 派生，256-bit）作为 SRP "口令"；
//! 2. 为客户端与服务端提供无状态、可序列化的调用封装。
//!
//! 身份 `I` 使用 account_id（UUID），不含邮箱。

use sha2::Sha256;
use srp::client::SrpClient;
use srp::groups::G_3072;
use srp::server::SrpServer;
use zeroize::Zeroizing;

use crate::secret::{random_bytes, random_vec, Key32};
use crate::{CryptoError, Result};

pub const SRP_SALT_LEN: usize = 32;
const EPHEMERAL_LEN: usize = 64;

/// 注册时由客户端计算，上传 (salt, verifier)。
pub struct Registration {
    pub salt: Vec<u8>,
    pub verifier: Vec<u8>,
}

pub fn register(identity: &str, auth_key: &Key32) -> Registration {
    let salt = random_vec(SRP_SALT_LEN);
    let verifier = verifier_with_salt(identity, auth_key, &salt);
    Registration { salt, verifier }
}

/// 用已知盐计算 verifier（新设备加入账户时在本地重建注册数据）。
pub fn verifier_with_salt(identity: &str, auth_key: &Key32, salt: &[u8]) -> Vec<u8> {
    SrpClient::<Sha256>::new(&G_3072).compute_verifier(identity.as_bytes(), auth_key.as_bytes(), salt)
}

/// 客户端第一步：生成临时私钥 a 与公钥 A。
pub struct ClientHandshake {
    a: Zeroizing<Vec<u8>>,
    pub a_pub: Vec<u8>,
}

/// 客户端第二步结果：发送 `m1`，并用 `expected_m2` 校验服务端。
pub struct ClientProof {
    pub m1: Vec<u8>,
    expected_m2: Vec<u8>,
    pub session_key: Zeroizing<Vec<u8>>,
}

impl ClientHandshake {
    pub fn start() -> Self {
        let a = Zeroizing::new(random_bytes::<EPHEMERAL_LEN>().to_vec());
        let a_pub = SrpClient::<Sha256>::new(&G_3072).compute_public_ephemeral(&a);
        Self { a, a_pub }
    }

    pub fn finish(&self, identity: &str, auth_key: &Key32, salt: &[u8], b_pub: &[u8]) -> Result<ClientProof> {
        let v = SrpClient::<Sha256>::new(&G_3072)
            .process_reply(&self.a, identity.as_bytes(), auth_key.as_bytes(), salt, b_pub)
            .map_err(|_| CryptoError::SrpAuth)?;
        // srp::SrpClientVerifier 未公开 M2，这里通过 verify_server 的同构计算取得：
        // M2 = H(A | M1 | K)，与 crate 内部一致。
        use sha2::Digest;
        let mut h = Sha256::new();
        h.update(&self.a_pub);
        h.update(v.proof());
        h.update(v.key());
        let expected_m2 = h.finalize().to_vec();
        debug_assert!(v.verify_server(&expected_m2).is_ok());
        Ok(ClientProof { m1: v.proof().to_vec(), expected_m2, session_key: Zeroizing::new(v.key().to_vec()) })
    }
}

impl ClientProof {
    pub fn verify_server(&self, m2: &[u8]) -> Result<()> {
        use subtle::ConstantTimeEq;
        if bool::from(self.expected_m2.ct_eq(m2)) {
            Ok(())
        } else {
            Err(CryptoError::SrpAuth)
        }
    }
}

/// 服务端第一步：生成 b（需在会话中暂存，建议 ≤ 2 分钟过期）与 B。
pub fn server_start(verifier: &[u8]) -> (Zeroizing<Vec<u8>>, Vec<u8>) {
    let b = Zeroizing::new(random_bytes::<EPHEMERAL_LEN>().to_vec());
    let b_pub = SrpServer::<Sha256>::new(&G_3072).compute_public_ephemeral(&b, verifier);
    (b, b_pub)
}

/// 服务端第二步：校验客户端证明 M1，成功返回 M2。
pub fn server_finish(b: &[u8], verifier: &[u8], a_pub: &[u8], m1: &[u8]) -> Result<Vec<u8>> {
    let v = SrpServer::<Sha256>::new(&G_3072).process_reply(b, verifier, a_pub).map_err(|_| CryptoError::SrpAuth)?;
    v.verify_client(m1).map_err(|_| CryptoError::SrpAuth)?;
    Ok(v.proof().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_handshake() {
        let auth = Key32::random().unwrap();
        let reg = register("acct-1", &auth);
        assert_eq!(reg.salt.len(), 32);

        let client = ClientHandshake::start();
        let (b, b_pub) = server_start(&reg.verifier);
        let proof = client.finish("acct-1", &auth, &reg.salt, &b_pub).unwrap();
        let m2 = server_finish(&b, &reg.verifier, &client.a_pub, &proof.m1).unwrap();
        proof.verify_server(&m2).unwrap();
    }

    #[test]
    fn wrong_password_rejected() {
        let reg = register("acct-1", &Key32::random().unwrap());
        let client = ClientHandshake::start();
        let (b, b_pub) = server_start(&reg.verifier);
        let proof = client.finish("acct-1", &Key32::random().unwrap(), &reg.salt, &b_pub).unwrap();
        assert!(server_finish(&b, &reg.verifier, &client.a_pub, &proof.m1).is_err());
    }

    #[test]
    fn fake_server_rejected() {
        let auth = Key32::random().unwrap();
        let reg = register("a", &auth);
        let client = ClientHandshake::start();
        let (_, b_pub) = server_start(&reg.verifier);
        let proof = client.finish("a", &auth, &reg.salt, &b_pub).unwrap();
        assert!(proof.verify_server(&[0u8; 32]).is_err());
    }

    #[test]
    fn malicious_zero_public_rejected() {
        let auth = Key32::random().unwrap();
        let reg = register("a", &auth);
        let (b, _) = server_start(&reg.verifier);
        assert!(server_finish(&b, &reg.verifier, &[0u8], &[0u8; 32]).is_err());
        let client = ClientHandshake::start();
        assert!(client.finish("a", &auth, &reg.salt, &[0u8]).is_err());
    }
}
