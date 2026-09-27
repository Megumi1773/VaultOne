//! 浏览器扩展协议（计划书 F-05 / S-06）。
//!
//! 链路：扩展（MV3）⇄ Native Messaging 宿主（`vaultone-nmhost`，只做转发）⇄ 本地套接字 ⇄ 桌面端。
//! 解密只发生在桌面端进程内；扩展不持有任何保险库密钥，只按需拿到**与当前页面匹配**的单条凭据。
//!
//! 安全设计：
//! 1. **配对**：扩展首次连接时生成 256-bit 随机密钥发给桌面端，桌面端弹窗显示由密钥派生的 8 位配对码，
//!    用户核对与扩展弹窗中的一致后批准。配对密钥以 Vault Key 密封存储（[`crate::Vault::set_sealed_setting`]），
//!    锁定时无法校验，任何请求都只会得到 `locked`。
//! 2. **请求认证**：每个调用携带 `HMAC-SHA256(配对密钥, 域分隔 ‖ clientId ‖ nonce ‖ ts ‖ body)`，
//!    时间戳 ±120 s、nonce 去重，防止同机其他进程伪造或重放。
//! 3. **防钓鱼**：`fill` / `totp` 必须携带页面 URL，且该 URL 必须通过 [`crate::urlmatch`] 的严格匹配，
//!    否则拒绝——即使扩展被攻破，也无法按 ID 批量拉取不相关站点的密码。URL 由扩展后台从
//!    `sender.url`（发起请求的框架地址）取得，而非页面脚本自报。
//!
//! 传输层（本地套接字、UI 批准配对）由 FFI 桥实现；本模块是纯逻辑，便于单元测试。

use std::collections::{HashMap, VecDeque};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::item::{ItemData, ItemKind, ItemUrl, UrlMatch};
use crate::urlmatch::{find_matches, match_url};
use crate::vault::now;
use crate::{Result, Vault, VaultError};

pub const PROTOCOL_VERSION: u32 = 1;
const CLIENTS_KEY: &str = "browser_clients";
const MAC_DOMAIN: &[u8] = b"vaultone-browser/v1\n";
const MAX_SKEW_SECS: i64 = 120;
const REPLAY_WINDOW: usize = 4096;

/// 扩展发来的顶层消息。
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Request {
    /// 探测桌面端状态（无需认证，只返回版本与是否锁定）
    Hello {
        #[serde(default, rename = "clientId")]
        client_id: Option<String>,
    },
    /// 请求配对（需桌面端用户批准）
    Pair {
        #[serde(rename = "clientId")]
        client_id: String,
        name: String,
        key: String,
    },
    /// 已认证调用。`body` 是 JSON 字符串（按原文参与 MAC）
    Call {
        #[serde(rename = "clientId")]
        client_id: String,
        nonce: String,
        ts: i64,
        body: String,
        mac: String,
    },
}

/// 已认证调用的操作。
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum Op {
    /// 列出与页面匹配的条目（不含密码）
    Match { url: String },
    /// 取单条凭据用于填充
    Fill { url: String, id: String },
    /// 取当前 TOTP
    Totp { url: String, id: String },
    /// 表单提交后：判断是新凭据、密码变更还是已保存（不写入）
    Check { url: String, username: String, password: String },
    /// 用户在保存提示中确认后写入
    Save {
        url: String,
        #[serde(default)]
        title: Option<String>,
        username: String,
        password: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct PairedClient {
    pub id: String,
    pub name: String,
    /// base64 配对密钥
    pub key: String,
    pub created_at: i64,
    #[serde(default)]
    pub last_used_at: i64,
}

/// 配对码：配对密钥 SHA-256 的前 40 bit，Crockford Base32 显示为 `XXXX-XXXX`。扩展侧用同样算法计算。
pub fn pairing_code(key_b64: &str) -> Result<String> {
    let key = Zeroizing::new(B64.decode(key_b64).map_err(|_| VaultError::InvalidInput("配对密钥格式错误".into()))?);
    if key.len() != 32 {
        return Err(VaultError::InvalidInput("配对密钥长度错误".into()));
    }
    let digest = Sha256::digest(&*key);
    const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    let bits = u64::from_be_bytes([0, 0, 0, digest[0], digest[1], digest[2], digest[3], digest[4]]);
    let code: String = (0..8).rev().map(|i| ALPHABET[((bits >> (i * 5)) & 31) as usize] as char).collect();
    Ok(format!("{}-{}", &code[..4], &code[4..]))
}

pub fn list_clients(vault: &Vault) -> Result<Vec<PairedClient>> {
    match vault.get_sealed_setting(CLIENTS_KEY)? {
        Some(raw) => serde_json::from_slice(&raw).map_err(|_| VaultError::Integrity),
        None => Ok(vec![]),
    }
}

fn save_clients(vault: &Vault, clients: &[PairedClient]) -> Result<()> {
    let raw = Zeroizing::new(serde_json::to_vec(clients)?);
    vault.set_sealed_setting(CLIENTS_KEY, &raw)
}

/// 用户批准配对后调用。同一 clientId 重新配对会替换旧密钥。
pub fn add_client(vault: &Vault, client_id: &str, name: &str, key_b64: &str) -> Result<()> {
    pairing_code(key_b64)?; // 校验格式
    if client_id.is_empty() || client_id.len() > 64 {
        return Err(VaultError::InvalidInput("clientId 不合法".into()));
    }
    let mut clients = list_clients(vault)?;
    clients.retain(|c| c.id != client_id);
    clients.push(PairedClient {
        id: client_id.into(),
        name: name.chars().take(60).collect(),
        key: key_b64.into(),
        created_at: now(),
        last_used_at: 0,
    });
    save_clients(vault, &clients)?;
    tracing::info!(target: "browser", "browser client paired");
    Ok(())
}

pub fn remove_client(vault: &Vault, client_id: &str) -> Result<()> {
    let mut clients = list_clients(vault)?;
    clients.retain(|c| c.id != client_id);
    save_clients(vault, &clients)
}

/// 已见 nonce（防重放）。由传输层长期持有。
#[derive(Default)]
pub struct ReplayGuard {
    seen: HashMap<String, i64>,
    order: VecDeque<String>,
}

impl ReplayGuard {
    fn check_and_insert(&mut self, nonce: &str, ts: i64) -> bool {
        if self.seen.contains_key(nonce) {
            return false;
        }
        if self.order.len() >= REPLAY_WINDOW {
            if let Some(old) = self.order.pop_front() {
                self.seen.remove(&old);
            }
        }
        self.seen.insert(nonce.to_string(), ts);
        self.order.push_back(nonce.to_string());
        true
    }
}

fn error(code: &str, message: &str) -> Value {
    json!({ "ok": false, "code": code, "message": message })
}

fn mac_input(client_id: &str, nonce: &str, ts: i64, body: &str) -> Vec<u8> {
    let mut v = MAC_DOMAIN.to_vec();
    v.extend_from_slice(format!("{client_id}\n{nonce}\n{ts}\n").as_bytes());
    v.extend_from_slice(body.as_bytes());
    v
}

/// 计算请求 MAC（base64）。扩展侧实现相同算法；此函数供测试与文档对照。
pub fn compute_mac(key_b64: &str, client_id: &str, nonce: &str, ts: i64, body: &str) -> Result<String> {
    let key = Zeroizing::new(B64.decode(key_b64).map_err(|_| VaultError::Integrity)?);
    let mut mac = Hmac::<Sha256>::new_from_slice(&key).map_err(|_| VaultError::Integrity)?;
    mac.update(&mac_input(client_id, nonce, ts, body));
    Ok(B64.encode(mac.finalize().into_bytes()))
}

/// `hello`：无需认证。只暴露版本、锁定状态与该 clientId 是否已配对（锁定时无法得知，返回 null）。
pub fn hello(vault: &Vault, client_id: Option<&str>) -> Value {
    let unlocked = vault.is_unlocked();
    let paired = match (unlocked, client_id) {
        (true, Some(id)) => json!(list_clients(vault).map(|c| c.iter().any(|x| x.id == id)).unwrap_or(false)),
        _ => Value::Null,
    };
    json!({ "ok": true, "app": "vaultone", "version": PROTOCOL_VERSION, "locked": !unlocked, "paired": paired })
}

/// 处理已认证调用。返回值总是可直接发回扩展的 JSON（错误也编码在其中）。
pub fn handle_call(vault: &mut Vault, replay: &mut ReplayGuard, client_id: &str, nonce: &str, ts: i64, body: &str, mac: &str) -> Value {
    if !vault.is_unlocked() {
        return error("locked", "VaultOne 已锁定，请先在桌面端解锁");
    }
    let clients = match list_clients(vault) {
        Ok(c) => c,
        Err(_) => return error("internal", "读取配对信息失败"),
    };
    let Some(client) = clients.iter().find(|c| c.id == client_id) else {
        return error("unpaired", "此浏览器尚未与 VaultOne 配对");
    };
    // MAC 校验（常数时间）
    let valid = B64
        .decode(mac)
        .ok()
        .zip(B64.decode(&client.key).ok().map(Zeroizing::new))
        .and_then(|(tag, key)| {
            let mut m = Hmac::<Sha256>::new_from_slice(&key).ok()?;
            m.update(&mac_input(client_id, nonce, ts, body));
            m.verify_slice(&tag).ok()
        })
        .is_some();
    if !valid {
        tracing::warn!(target: "browser", "request with invalid mac rejected");
        return error("unauthorized", "请求认证失败，请在扩展中重新配对");
    }
    if (now() - ts).abs() > MAX_SKEW_SECS || nonce.len() < 16 || !replay.check_and_insert(nonce, ts) {
        return error("replay", "请求已过期或重复");
    }
    let op: Op = match serde_json::from_str(body) {
        Ok(op) => op,
        Err(_) => return error("invalid_input", "无法识别的请求"),
    };
    if let Some(c) = clients.iter().position(|c| c.id == client_id) {
        let mut updated = clients.clone();
        updated[c].last_used_at = now();
        let _ = save_clients(vault, &updated);
    }
    match dispatch(vault, op) {
        Ok(v) => v,
        Err(e) => error(e.code(), &e.to_string()),
    }
}

/// 页面 URL 必须能被条目某个网址严格匹配，否则一律视为不存在（不区分"无此条目"与"不匹配"）。
fn matched_item(vault: &Vault, url: &str, id: &str) -> Result<ItemData> {
    let item = vault.get_item(id)?;
    if item.data.kind != ItemKind::Login || !item.data.urls.iter().any(|u| match_url(u, url).is_some()) {
        tracing::warn!(target: "browser", "fill request for non-matching page rejected");
        return Err(VaultError::ItemNotFound);
    }
    Ok(item.data)
}

fn totp_json(data: &ItemData) -> Result<Value> {
    Ok(match &data.totp {
        Some(cfg) => {
            let c = crate::totp::generate(cfg, now() as u64)?;
            json!({ "code": c.code, "remaining": c.remaining, "period": c.period })
        }
        None => Value::Null,
    })
}

/// 页面 URL → 保存条目时使用的网址（只保留协议 + 主机 + 端口，去掉路径与查询参数中的会话信息）。
fn origin_of(url: &str) -> Option<(String, String)> {
    let u = url::Url::parse(url).ok()?;
    if !matches!(u.scheme(), "http" | "https") {
        return None;
    }
    let host = u.host_str()?.to_string();
    Some((u.origin().ascii_serialization(), host.trim_start_matches("www.").to_string()))
}

fn dispatch(vault: &mut Vault, op: Op) -> Result<Value> {
    match op {
        Op::Match { url } => {
            let items = vault.list_items()?;
            let matches: Vec<Value> = find_matches(&items, &url)
                .into_iter()
                .filter(|(i, _)| i.data.kind == ItemKind::Login)
                .map(|(i, q)| {
                    json!({
                        "id": i.id,
                        "title": i.data.title,
                        "username": i.data.username.clone().unwrap_or_default(),
                        "hasTotp": i.data.totp.is_some(),
                        "quality": q as u8,
                    })
                })
                .collect();
            Ok(json!({ "ok": true, "items": matches }))
        }
        Op::Fill { url, id } => {
            let data = matched_item(vault, &url, &id)?;
            tracing::info!(target: "browser", "credential released for fill");
            Ok(json!({
                "ok": true,
                "username": data.username.clone().unwrap_or_default(),
                "password": data.password.clone().unwrap_or_default(),
                "totp": totp_json(&data)?,
            }))
        }
        Op::Totp { url, id } => {
            let data = matched_item(vault, &url, &id)?;
            Ok(json!({ "ok": true, "totp": totp_json(&data)? }))
        }
        Op::Check { url, username, password } => {
            let items = vault.list_items()?;
            let same_user: Vec<_> = find_matches(&items, &url)
                .into_iter()
                .filter(|(i, _)| i.data.kind == ItemKind::Login && i.data.username.as_deref().unwrap_or_default() == username)
                .collect();
            let result = match same_user.first() {
                None => json!({ "ok": true, "result": "new" }),
                Some((i, _)) if i.data.password.as_deref() == Some(password.as_str()) => json!({ "ok": true, "result": "unchanged" }),
                Some((i, _)) => json!({ "ok": true, "result": "update", "id": i.id, "title": i.data.title }),
            };
            Ok(result)
        }
        Op::Save { url, title, username, password } => {
            if password.is_empty() {
                return Err(VaultError::InvalidInput("密码为空".into()));
            }
            let (origin, host) = origin_of(&url).ok_or_else(|| VaultError::InvalidInput("网址不合法".into()))?;
            let items = vault.list_items()?;
            let existing = find_matches(&items, &url)
                .into_iter()
                .find(|(i, _)| i.data.kind == ItemKind::Login && i.data.username.as_deref().unwrap_or_default() == username)
                .map(|(i, _)| i.clone());
            match existing {
                Some(item) => {
                    let mut data = item.data.clone();
                    data.password = Some(password);
                    let updated = vault.update_item(&item.id, data)?;
                    tracing::info!(target: "browser", "login updated from browser");
                    Ok(json!({ "ok": true, "result": "updated", "id": updated.id }))
                }
                None => {
                    let title = title.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()).unwrap_or(host);
                    let mut data = ItemData::new(ItemKind::Login, title.chars().take(200).collect::<String>());
                    data.urls = vec![ItemUrl { url: origin, match_mode: UrlMatch::Domain }];
                    data.username = (!username.is_empty()).then_some(username);
                    data.password = Some(password);
                    let created = vault.create_item(data)?;
                    tracing::info!(target: "browser", "login saved from browser");
                    Ok(json!({ "ok": true, "result": "created", "id": created.id }))
                }
            }
        }
    }
}

/// 解析一行请求并处理（`pair` 需要 UI 批准，由调用方另行处理，这里返回 `None`）。
pub fn handle_line(vault: &mut Vault, replay: &mut ReplayGuard, line: &str) -> Option<Value> {
    match serde_json::from_str::<Request>(line) {
        Ok(Request::Hello { client_id }) => Some(hello(vault, client_id.as_deref())),
        Ok(Request::Call { client_id, nonce, ts, body, mac }) => Some(handle_call(vault, replay, &client_id, &nonce, ts, &body, &mac)),
        Ok(Request::Pair { .. }) => None,
        Err(_) => Some(error("invalid_input", "无法识别的请求")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::KdfParams;

    const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="; // 0x00..0x1f

    fn vault() -> Vault {
        let mut v = Vault::open_in_memory().unwrap();
        v.create_account("me@example.com", "correct horse battery", KdfParams::insecure_for_tests()).unwrap();
        v
    }

    fn call(v: &mut Vault, g: &mut ReplayGuard, key: &str, nonce: &str, body: Value) -> Value {
        let body = body.to_string();
        let ts = now();
        let mac = compute_mac(key, "c1", nonce, ts, &body).unwrap();
        handle_call(v, g, "c1", nonce, ts, &body, &mac)
    }

    fn login(v: &mut Vault, url: &str, user: &str, pw: &str) -> String {
        let mut d = ItemData::new(ItemKind::Login, "Example");
        d.urls = vec![ItemUrl { url: url.into(), match_mode: UrlMatch::Domain }];
        d.username = Some(user.into());
        d.password = Some(pw.into());
        d.totp = Some(crate::item::TotpConfig { secret: "JBSWY3DPEHPK3PXP".into(), alg: "SHA1".into(), digits: 6, period: 30 });
        v.create_item(d).unwrap().id
    }

    #[test]
    fn pairing_code_is_stable() {
        assert_eq!(pairing_code(KEY).unwrap(), pairing_code(KEY).unwrap());
        assert_eq!(pairing_code(KEY).unwrap().len(), 9);
        assert!(pairing_code("short").is_err());
    }

    /// 与扩展 `extension/lib/protocol.js` 的固定向量一致（`extension/test/protocol.test.mjs` 断言同一组值）。
    #[test]
    fn cross_implementation_vectors() {
        assert_eq!(pairing_code(KEY).unwrap(), "CC6W-TAB6");
        let mac = compute_mac(KEY, "c1", "nonce-000000000001", 1_700_000_000, r#"{"op":"match","url":"https://example.com"}"#).unwrap();
        assert_eq!(mac, "/OZlkRpUPBhuPSw89NWc0zuRodBMKuhm1KImMX2aAxA=");
    }

    #[test]
    fn pairing_is_sealed_and_needs_unlock() {
        let mut v = vault();
        add_client(&v, "c1", "Chrome", KEY).unwrap();
        assert_eq!(list_clients(&v).unwrap().len(), 1);
        // 配对密钥不以明文落盘
        assert!(v.get_setting("sealed:browser_clients").unwrap().is_some_and(|s| !s.contains(KEY)));
        assert_eq!(hello(&v, Some("c1"))["paired"], true);
        v.lock();
        assert_eq!(hello(&v, Some("c1"))["paired"], Value::Null);
        let mut g = ReplayGuard::default();
        assert_eq!(call(&mut v, &mut g, KEY, "nonce-000000000001", json!({"op":"match","url":"https://example.com"}))["code"], "locked");
    }

    #[test]
    fn authentication_and_replay() {
        let mut v = vault();
        add_client(&v, "c1", "Chrome", KEY).unwrap();
        let mut g = ReplayGuard::default();
        let body = json!({"op":"match","url":"https://example.com"});
        assert_eq!(call(&mut v, &mut g, KEY, "nonce-000000000001", body.clone())["ok"], true);
        // 重放同一 nonce
        assert_eq!(call(&mut v, &mut g, KEY, "nonce-000000000001", body.clone())["code"], "replay");
        // 错误密钥
        let other = B64.encode([9u8; 32]);
        assert_eq!(call(&mut v, &mut g, &other, "nonce-000000000002", body.clone())["code"], "unauthorized");
        // 过期时间戳
        let b = body.to_string();
        let old = now() - 600;
        let mac = compute_mac(KEY, "c1", "nonce-000000000003", old, &b).unwrap();
        assert_eq!(handle_call(&mut v, &mut g, "c1", "nonce-000000000003", old, &b, &mac)["code"], "replay");
        // 未配对
        remove_client(&v, "c1").unwrap();
        assert_eq!(call(&mut v, &mut g, KEY, "nonce-000000000004", body)["code"], "unpaired");
    }

    #[test]
    fn fill_only_for_matching_page() {
        let mut v = vault();
        add_client(&v, "c1", "Chrome", KEY).unwrap();
        let id = login(&mut v, "https://example.com", "alice", "s3cret");
        let mut g = ReplayGuard::default();

        let m = call(&mut v, &mut g, KEY, "nonce-000000000010", json!({"op":"match","url":"https://login.example.com/x"}));
        assert_eq!(m["items"][0]["id"], id.as_str());
        assert!(m["items"][0].get("password").is_none());

        let f = call(&mut v, &mut g, KEY, "nonce-000000000011", json!({"op":"fill","url":"https://example.com/login","id":id}));
        assert_eq!(f["password"], "s3cret");
        assert_eq!(f["totp"]["code"].as_str().unwrap().len(), 6);

        // 钓鱼站 / 协议降级：拒绝
        for url in ["https://example.com.evil.io/", "http://example.com/", "https://examp1e.com/"] {
            let r = call(&mut v, &mut g, KEY, &format!("nonce-phish-{url}"), json!({"op":"fill","url":url,"id":id}));
            assert_eq!(r["code"], "not_found", "{url}");
        }
    }

    #[test]
    fn check_and_save() {
        let mut v = vault();
        add_client(&v, "c1", "Chrome", KEY).unwrap();
        let mut g = ReplayGuard::default();
        let url = "https://shop.example.org/account/login?session=abc";

        let r = call(&mut v, &mut g, KEY, "nonce-000000000020", json!({"op":"check","url":url,"username":"bob","password":"p1"}));
        assert_eq!(r["result"], "new");
        let r = call(&mut v, &mut g, KEY, "nonce-000000000021", json!({"op":"save","url":url,"username":"bob","password":"p1"}));
        assert_eq!(r["result"], "created");
        let item = v.list_items().unwrap().pop().unwrap();
        assert_eq!(item.data.title, "shop.example.org");
        assert_eq!(item.data.urls[0].url, "https://shop.example.org"); // 不保存路径与会话参数

        let r = call(&mut v, &mut g, KEY, "nonce-000000000022", json!({"op":"check","url":url,"username":"bob","password":"p1"}));
        assert_eq!(r["result"], "unchanged");
        let r = call(&mut v, &mut g, KEY, "nonce-000000000023", json!({"op":"check","url":url,"username":"bob","password":"p2"}));
        assert_eq!(r["result"], "update");
        let r = call(&mut v, &mut g, KEY, "nonce-000000000024", json!({"op":"save","url":url,"username":"bob","password":"p2"}));
        assert_eq!(r["result"], "updated");
        let item = v.list_items().unwrap().pop().unwrap();
        assert_eq!(item.data.password.as_deref(), Some("p2"));
        assert_eq!(item.data.password_history[0].p, "p1");
    }

    #[test]
    fn handle_line_parses_requests() {
        let mut v = vault();
        let mut g = ReplayGuard::default();
        assert_eq!(handle_line(&mut v, &mut g, r#"{"type":"hello"}"#).unwrap()["app"], "vaultone");
        assert!(handle_line(&mut v, &mut g, r#"{"type":"pair","clientId":"c","name":"n","key":"k"}"#).is_none());
        assert_eq!(handle_line(&mut v, &mut g, "garbage").unwrap()["code"], "invalid_input");
    }
}
