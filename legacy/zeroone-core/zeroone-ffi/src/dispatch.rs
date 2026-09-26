//! JSON 命令分发。每个命令的参数都是强类型结构，含秘密的结构在 drop 时清零。

use std::sync::{Mutex, MutexGuard, OnceLock};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use serde_json::{json, Value};
use vault_core::generator::{self, PassphraseOptions, PasswordOptions};
use vault_core::item::{Item, ItemData, TotpConfig};
use vault_core::kdf::KdfParams;
use vault_core::vault::{now, Enrollment, Vault};
use vault_core::{security, totp, VaultError};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::clipboard;

static VAULT: OnceLock<Mutex<Option<Vault>>> = OnceLock::new();

fn vault_slot() -> MutexGuard<'static, Option<Vault>> {
    let m = VAULT.get_or_init(|| Mutex::new(None));
    // 某次调用 panic 导致锁中毒时，保险库状态本身仍然一致（所有写入都在事务内），继续使用
    m.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Deserialize)]
struct Request<'a> {
    method: String,
    #[serde(borrow)]
    params: Option<&'a RawValue>,
}

struct ApiError {
    code: &'static str,
    message: String,
}

impl From<VaultError> for ApiError {
    fn from(e: VaultError) -> Self {
        let code = match &e {
            VaultError::InvalidCredentials => "invalid_credentials",
            VaultError::InvalidRecoveryCode => "invalid_recovery_code",
            VaultError::Locked => "locked",
            VaultError::NotInitialized => "not_initialized",
            VaultError::AlreadyInitialized => "already_initialized",
            VaultError::ItemNotFound(_) => "not_found",
            VaultError::Integrity => "integrity",
            VaultError::Format(_) | VaultError::InvalidInput(_) => "invalid_input",
            VaultError::Storage(_) => "storage",
            VaultError::Crypto | VaultError::Serde(_) => "internal",
        };
        ApiError { code, message: e.to_string() }
    }
}

fn bad_request(msg: impl Into<String>) -> ApiError {
    ApiError { code: "bad_request", message: msg.into() }
}

type ApiResult = Result<Value, ApiError>;

/// 处理一条 JSON 请求，返回 JSON 响应字节。
pub fn handle(input: &[u8]) -> Vec<u8> {
    let response = match serde_json::from_slice::<Request>(input) {
        Ok(req) => match dispatch(&req.method, req.params) {
            Ok(result) => json!({ "ok": true, "result": result }),
            Err(e) => json!({ "ok": false, "error": { "code": e.code, "message": e.message } }),
        },
        Err(e) => json!({ "ok": false, "error": { "code": "bad_request", "message": e.to_string() } }),
    };
    serde_json::to_vec(&response).unwrap_or_default()
}

fn parse<T: DeserializeOwned>(params: Option<&RawValue>) -> Result<T, ApiError> {
    let raw = params.map(RawValue::get).unwrap_or("{}");
    serde_json::from_str(raw).map_err(|e| bad_request(format!("参数错误: {e}")))
}

fn with_vault<T>(f: impl FnOnce(&mut Vault) -> Result<T, VaultError>) -> Result<T, ApiError> {
    let mut slot = vault_slot();
    let vault = slot.as_mut().ok_or_else(|| ApiError { code: "not_open", message: "保险库未打开".into() })?;
    Ok(f(vault)?)
}

// ---------- 参数结构 ----------

#[derive(Deserialize)]
struct OpenParams {
    path: String,
}

#[derive(Deserialize)]
struct KdfCost {
    m: u32,
    t: u32,
    p: u32,
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
struct CreateAccountParams {
    email: String,
    password: String,
    #[serde(default)]
    #[zeroize(skip)]
    kdf: Option<KdfCost>,
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
struct UnlockParams {
    password: String,
    secret_key: String,
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
struct ChangePasswordParams {
    current: String,
    secret_key: String,
    new_password: String,
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
struct RecoverParams {
    recovery_code: String,
    secret_key: String,
    new_password: String,
}

#[derive(Deserialize)]
struct IdParams {
    id: String,
}

#[derive(Deserialize)]
struct CreateItemParams {
    data: ItemData,
}

#[derive(Deserialize)]
struct UpdateItemParams {
    id: String,
    data: ItemData,
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
struct TotpParams {
    config: TotpConfig,
    #[serde(default)]
    #[zeroize(skip)]
    time: Option<u64>,
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
struct TextParams {
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct PasswordOptionsIn {
    length: u32,
    lowercase: bool,
    uppercase: bool,
    digits: bool,
    symbols: bool,
    exclude_ambiguous: bool,
}

impl Default for PasswordOptionsIn {
    fn default() -> Self {
        let d = PasswordOptions::default();
        Self {
            length: d.length,
            lowercase: d.lowercase,
            uppercase: d.uppercase,
            digits: d.digits,
            symbols: d.symbols,
            exclude_ambiguous: d.exclude_ambiguous,
        }
    }
}

impl From<PasswordOptionsIn> for PasswordOptions {
    fn from(o: PasswordOptionsIn) -> Self {
        PasswordOptions {
            length: o.length,
            lowercase: o.lowercase,
            uppercase: o.uppercase,
            digits: o.digits,
            symbols: o.symbols,
            exclude_ambiguous: o.exclude_ambiguous,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct PassphraseOptionsIn {
    words: u32,
    separator: String,
    capitalize: bool,
    include_number: bool,
}

impl Default for PassphraseOptionsIn {
    fn default() -> Self {
        let d = PassphraseOptions::default();
        Self { words: d.words, separator: d.separator, capitalize: d.capitalize, include_number: d.include_number }
    }
}

impl From<PassphraseOptionsIn> for PassphraseOptions {
    fn from(o: PassphraseOptionsIn) -> Self {
        PassphraseOptions { words: o.words, separator: o.separator, capitalize: o.capitalize, include_number: o.include_number }
    }
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
struct StrengthParams {
    password: String,
    #[serde(default)]
    inputs: Vec<String>,
}

#[derive(Deserialize)]
struct BreachCountParams {
    body: String,
    suffix: String,
}

#[derive(Deserialize)]
struct SettingParams {
    key: String,
    #[serde(default)]
    value: Option<String>,
}

#[derive(Deserialize)]
struct ClipboardClearParams {
    sequence: u32,
}

// ---------- 输出结构 ----------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ItemOut<'a> {
    id: &'a str,
    vault_id: &'a str,
    revision: i64,
    data: &'a ItemData,
}

fn item_json(item: &Item) -> Value {
    serde_json::to_value(ItemOut { id: &item.id, vault_id: &item.vault_id, revision: item.revision, data: &item.data })
        .unwrap_or(Value::Null)
}

fn items_json(items: &[Item]) -> Value {
    Value::Array(items.iter().map(item_json).collect())
}

fn enrollment_json(e: &Enrollment) -> Value {
    json!({
        "accountId": e.account_id,
        "email": e.email,
        "secretKey": e.secret_key.as_str(),
        "recoveryCode": e.recovery_code.as_str(),
    })
}

// ---------- 分发 ----------

fn dispatch(method: &str, params: Option<&RawValue>) -> ApiResult {
    match method {
        "ping" => Ok(json!({ "core": "zeroone", "version": env!("CARGO_PKG_VERSION") })),

        "open" => {
            let p: OpenParams = parse(params)?;
            let vault = Vault::open(&p.path)?;
            *vault_slot() = Some(vault);
            Ok(Value::Null)
        }
        "status" => {
            let slot = vault_slot();
            match slot.as_ref() {
                None => Ok(json!({ "open": false, "initialized": false, "unlocked": false })),
                Some(v) => Ok(json!({ "open": true, "initialized": v.is_initialized()?, "unlocked": v.is_unlocked() })),
            }
        }
        "create_account" => {
            let p: CreateAccountParams = parse(params)?;
            let kdf = match &p.kdf {
                Some(c) => KdfParams::with_cost(c.m, c.t, c.p),
                None => KdfParams::recommended(),
            };
            let e = with_vault(|v| v.create_account(&p.email, &p.password, kdf))?;
            Ok(enrollment_json(&e))
        }
        "unlock" => {
            let p: UnlockParams = parse(params)?;
            with_vault(|v| v.unlock(&p.password, &p.secret_key))?;
            Ok(Value::Null)
        }
        "lock" => {
            if let Some(v) = vault_slot().as_mut() {
                v.lock();
            }
            Ok(Value::Null)
        }
        "account_id" => with_vault(|v| Ok(json!(v.account_id()?))),
        "account" => with_vault(|v| {
            let kdf = v.kdf_params()?;
            Ok(json!({
                "accountId": v.account_id()?,
                "email": v.email()?.as_str(),
                "kdf": { "alg": kdf.alg, "m": kdf.m, "t": kdf.t, "p": kdf.p },
                "pendingChanges": v.pending_changes()?,
            }))
        }),
        "change_password" => {
            let p: ChangePasswordParams = parse(params)?;
            with_vault(|v| v.change_master_password(&p.current, &p.secret_key, &p.new_password))?;
            Ok(Value::Null)
        }
        "recover" => {
            let p: RecoverParams = parse(params)?;
            let e = with_vault(|v| v.recover(&p.recovery_code, &p.secret_key, &p.new_password))?;
            Ok(enrollment_json(&e))
        }

        "list_items" => with_vault(|v| Ok(items_json(&v.list_items()?))),
        "list_trash" => with_vault(|v| Ok(items_json(&v.list_trash()?))),
        "get_item" => {
            let p: IdParams = parse(params)?;
            with_vault(|v| Ok(item_json(&v.get_item(&p.id)?)))
        }
        "create_item" => {
            let p: CreateItemParams = parse(params)?;
            with_vault(|v| Ok(item_json(&v.create_item(p.data.clone())?)))
        }
        "update_item" => {
            let p: UpdateItemParams = parse(params)?;
            with_vault(|v| Ok(item_json(&v.update_item(&p.id, p.data.clone())?)))
        }
        "delete_item" => {
            let p: IdParams = parse(params)?;
            with_vault(|v| v.delete_item(&p.id))?;
            Ok(Value::Null)
        }
        "restore_item" => {
            let p: IdParams = parse(params)?;
            with_vault(|v| v.restore_item(&p.id))?;
            Ok(Value::Null)
        }

        "totp" => {
            let p: TotpParams = parse(params)?;
            let t = totp::generate(&p.config, p.time.unwrap_or(now() as u64))?;
            Ok(json!({ "code": t.code, "remaining": t.remaining, "period": t.period }))
        }
        "parse_totp" => {
            let p: TextParams = parse(params)?;
            let o = totp::parse(&p.text)?;
            Ok(json!({
                "config": { "secret": o.config.secret, "alg": o.config.alg, "digits": o.config.digits, "period": o.config.period },
                "issuer": o.issuer,
                "account": o.account,
            }))
        }

        "generate_password" => {
            let o: PasswordOptionsIn = parse(params)?;
            let opts: PasswordOptions = o.into();
            let pw = generator::generate_password(&opts)?;
            Ok(json!({ "value": pw.as_str(), "entropy": generator::password_entropy_bits(&opts) }))
        }
        "generate_passphrase" => {
            let o: PassphraseOptionsIn = parse(params)?;
            let opts: PassphraseOptions = o.into();
            let pw = generator::generate_passphrase(&opts)?;
            Ok(json!({ "value": pw.as_str(), "entropy": generator::passphrase_entropy_bits(&opts) }))
        }
        "strength" => {
            let p: StrengthParams = parse(params)?;
            let inputs: Vec<&str> = p.inputs.iter().map(String::as_str).collect();
            let s = security::estimate_strength(&p.password, &inputs);
            Ok(json!({ "score": s.score, "guessesLog10": s.guesses_log10, "warning": s.warning }))
        }
        "audit" => with_vault(|v| {
            let findings = security::audit(&v.list_items()?);
            Ok(Value::Array(
                findings
                    .into_iter()
                    .map(|f| json!({ "itemId": f.item_id, "weak": f.weak, "score": f.score, "reusedWith": f.reused_with }))
                    .collect(),
            ))
        }),
        "breach_query" => {
            let p: TextParams = parse(params)?;
            let q = security::breach_query(&p.text);
            Ok(json!({ "prefix": q.prefix, "suffix": q.suffix }))
        }
        "breach_count" => {
            let p: BreachCountParams = parse(params)?;
            Ok(json!(security::breach_count(&p.body, &p.suffix)))
        }

        "get_setting" => {
            let p: SettingParams = parse(params)?;
            with_vault(|v| Ok(json!(v.get_setting(&p.key)?)))
        }
        "set_setting" => {
            let p: SettingParams = parse(params)?;
            let value = p.value.clone().ok_or_else(|| bad_request("缺少 value"))?;
            with_vault(|v| v.set_setting(&p.key, &value))?;
            Ok(Value::Null)
        }

        "clipboard_copy" => {
            let p: TextParams = parse(params)?;
            match clipboard::copy_sensitive(&p.text) {
                Ok(seq) => Ok(json!({ "sequence": seq })),
                Err(e) if e == "unsupported" => Err(ApiError { code: "unsupported", message: e }),
                Err(e) => Err(ApiError { code: "clipboard", message: e }),
            }
        }
        "clipboard_clear" => {
            let p: ClipboardClearParams = parse(params)?;
            match clipboard::clear_if_unchanged(p.sequence) {
                Ok(cleared) => Ok(json!({ "cleared": cleared })),
                Err(e) if e == "unsupported" => Err(ApiError { code: "unsupported", message: e }),
                Err(e) => Err(ApiError { code: "clipboard", message: e }),
            }
        }

        other => Err(bad_request(format!("未知命令: {other}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(method: &str, params: Value) -> Value {
        let req = json!({ "method": method, "params": params });
        serde_json::from_slice(&handle(req.to_string().as_bytes())).unwrap()
    }

    fn ok(method: &str, params: Value) -> Value {
        let v = call(method, params);
        assert_eq!(v["ok"], true, "{method} 失败: {v}");
        v["result"].clone()
    }

    /// 全局单例保险库，所有流程放在同一个测试中串行执行
    #[test]
    fn end_to_end_flow() {
        let dir = std::env::temp_dir().join(format!("zeroone-ffi-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("vault.db");
        let _ = std::fs::remove_file(&path);

        assert_eq!(call("list_items", json!({}))["error"]["code"], "not_open");
        ok("open", json!({ "path": path.to_string_lossy() }));
        assert_eq!(ok("status", json!({}))["initialized"], false);

        let kit = ok(
            "create_account",
            json!({ "email": "me@example.com", "password": "correct horse battery", "kdf": { "m": 19456, "t": 1, "p": 1 } }),
        );
        let sk = kit["secretKey"].as_str().unwrap().to_string();
        assert!(sk.starts_with("Z1-"));

        let item = ok(
            "create_item",
            json!({ "data": { "type": "login", "title": "GitHub", "username": "octo", "password": "hunter2hunter2",
                              "urls": [{ "url": "https://github.com" }] } }),
        );
        assert_eq!(item["revision"], 1);
        assert_eq!(item["data"]["urls"][0]["match"], "domain");
        let id = item["id"].as_str().unwrap().to_string();

        ok("lock", json!({}));
        assert_eq!(call("list_items", json!({}))["error"]["code"], "locked");
        assert_eq!(
            call("unlock", json!({ "password": "wrong password", "secretKey": sk }))["error"]["code"],
            "invalid_credentials"
        );
        ok("unlock", json!({ "password": "correct horse battery", "secretKey": sk }));
        assert_eq!(ok("list_items", json!({})).as_array().unwrap().len(), 1);
        assert_eq!(ok("account", json!({}))["email"], "me@example.com");

        let upd = ok("update_item", json!({ "id": id, "data": { "type": "login", "title": "GitHub 2", "password": "x" } }));
        assert_eq!(upd["data"]["passwordHistory"][0]["p"], "hunter2hunter2");

        let audit = ok("audit", json!({}));
        assert_eq!(audit[0]["weak"], true);

        ok("set_setting", json!({ "key": "theme", "value": "dark" }));
        assert_eq!(ok("get_setting", json!({ "key": "theme" })), "dark");

        ok("delete_item", json!({ "id": id }));
        assert_eq!(ok("list_trash", json!({})).as_array().unwrap().len(), 1);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn stateless_commands() {
        let pw = ok("generate_password", json!({ "length": 32 }));
        assert_eq!(pw["value"].as_str().unwrap().len(), 32);
        let pp = ok("generate_passphrase", json!({ "words": 4, "separator": " " }));
        assert_eq!(pp["value"].as_str().unwrap().split(' ').count(), 4);

        let code = ok("totp", json!({ "config": { "secret": "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "digits": 8 }, "time": 59 }));
        assert_eq!(code["code"], "94287082");

        let parsed = ok("parse_totp", json!({ "text": "otpauth://totp/GitHub:octo?secret=JBSWY3DPEHPK3PXP&issuer=GitHub" }));
        assert_eq!(parsed["issuer"], "GitHub");

        assert!(ok("strength", json!({ "password": "password" }))["score"].as_u64().unwrap() <= 1);
        assert_eq!(ok("breach_query", json!({ "text": "password" }))["prefix"], "5BAA6");

        assert_eq!(call("nope", json!({}))["error"]["code"], "bad_request");
        let garbage: Value = serde_json::from_slice(&handle(b"not json")).unwrap();
        assert_eq!(garbage["ok"], false);
    }
}
