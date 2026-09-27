//! 浏览器扩展通道（F-05）：在本地套接字上监听 Native Messaging 宿主的连接，
//! 把每行请求交给 `vault_core::browser` 处理；配对请求推送给 Dart 弹窗，由用户批准。
//!
//! 仅桌面端启用。套接字：Windows 为拒绝远程客户端的命名管道；macOS / Linux 为 0600 的 Unix 套接字。

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use interprocess::local_socket::traits::ListenerExt;
use serde_json::{json, Value};
use vault_core::browser::{self, ReplayGuard, Request};
use vault_proto::browser_ipc::{endpoint, EXTENSION_IDS, MAX_MESSAGE_BYTES, NATIVE_HOST_NAME};

use super::vault::with_vault;
use super::{BridgeError, BridgeResult};
use crate::frb_generated::StreamSink;

const PAIRING_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, Clone)]
pub struct PairingRequest {
    pub client_id: String,
    /// 扩展自报的浏览器名（仅用于展示）
    pub name: String,
    /// 由配对密钥派生，用户须核对与扩展弹窗中显示的一致
    pub code: String,
}

#[derive(Debug, Clone)]
pub struct BrowserClientDto {
    pub id: String,
    pub name: String,
    pub created_at: i64,
    pub last_used_at: i64,
}

static STARTED: AtomicBool = AtomicBool::new(false);
static ENABLED: AtomicBool = AtomicBool::new(false);
static SINK: Mutex<Option<StreamSink<PairingRequest>>> = Mutex::new(None);
static PENDING: OnceLock<Mutex<HashMap<String, Sender<bool>>>> = OnceLock::new();
static REPLAY: OnceLock<Mutex<ReplayGuard>> = OnceLock::new();

fn pending() -> std::sync::MutexGuard<'static, HashMap<String, Sender<bool>>> {
    PENDING.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

fn err(code: &str, message: &str) -> Value {
    json!({ "ok": false, "code": code, "message": message })
}

/// 启动（或重新启用）本地通道。配对请求通过 `sink` 推送给 Dart。重复调用只替换 sink。
pub fn start_browser_bridge(sink: StreamSink<PairingRequest>) -> BridgeResult<()> {
    *SINK.lock().unwrap_or_else(|e| e.into_inner()) = Some(sink);
    ENABLED.store(true, Ordering::SeqCst);
    if STARTED.swap(true, Ordering::SeqCst) {
        return Ok(());
    }
    let listener = match listen(&endpoint()) {
        Ok(l) => l,
        Err(e) => {
            STARTED.store(false, Ordering::SeqCst);
            tracing::warn!(target: "browser", error = %e, "browser channel unavailable");
            return Err(BridgeError {
                code: "browser_unavailable".into(),
                message: "浏览器扩展通道启动失败（可能已有另一个 VaultOne 在运行）".into(),
            });
        }
    };
    std::thread::Builder::new()
        .name("vaultone-browser".into())
        .spawn(move || {
            for conn in listener.incoming().filter_map(|c| c.ok()) {
                let _ = std::thread::Builder::new().name("vaultone-browser-conn".into()).spawn(move || serve(conn));
            }
        })
        .map_err(|_| BridgeError { code: "internal".into(), message: "无法启动浏览器扩展通道".into() })?;
    tracing::info!(target: "browser", "browser channel listening");
    Ok(())
}

/// 关闭集成：通道保持监听但拒绝一切请求（监听线程无法安全中断，且重新启用时无需重建）。
pub fn stop_browser_bridge() {
    ENABLED.store(false, Ordering::SeqCst);
    pending().clear();
}

/// Dart 弹窗的用户选择。
pub fn respond_pairing(client_id: String, approved: bool) {
    if let Some(tx) = pending().remove(&client_id) {
        let _ = tx.send(approved);
    }
}

pub fn list_browser_clients() -> BridgeResult<Vec<BrowserClientDto>> {
    let clients = with_vault(|v| browser::list_clients(v))?;
    Ok(clients
        .iter()
        .map(|c| BrowserClientDto { id: c.id.clone(), name: c.name.clone(), created_at: c.created_at, last_used_at: c.last_used_at })
        .collect())
}

pub fn remove_browser_client(id: String) -> BridgeResult<()> {
    with_vault(|v| browser::remove_client(v, &id))
}

fn listen(ep: &str) -> std::io::Result<interprocess::local_socket::Listener> {
    use interprocess::local_socket::{prelude::*, ListenerOptions};
    #[cfg(windows)]
    let opts = ListenerOptions::new().name(ep.to_ns_name::<interprocess::local_socket::GenericNamespaced>()?);
    #[cfg(not(windows))]
    let opts = {
        use interprocess::os::unix::local_socket::ListenerOptionsExt;
        if let Some(dir) = std::path::Path::new(ep).parent() {
            std::fs::create_dir_all(dir)?;
        }
        // 上次异常退出留下的套接字文件
        let _ = std::fs::remove_file(ep);
        ListenerOptions::new().name(ep.to_fs_name::<interprocess::local_socket::GenericFilePath>()?).mode(0o600)
    };
    opts.create_sync()
}

fn serve(conn: interprocess::local_socket::Stream) {
    let mut reader = BufReader::new(conn);
    loop {
        let mut line = String::new();
        match (&mut reader).take(MAX_MESSAGE_BYTES as u64 + 1).read_line(&mut line) {
            Ok(0) | Err(_) => return,
            Ok(n) if n > MAX_MESSAGE_BYTES => return,
            Ok(_) => {}
        }
        let reply = if ENABLED.load(Ordering::SeqCst) {
            handle(line.trim_end())
        } else {
            err("disabled", "已在 VaultOne 设置中关闭浏览器扩展集成")
        };
        let out = format!("{reply}\n");
        if reader.get_mut().write_all(out.as_bytes()).is_err() {
            return;
        }
    }
}

fn handle(line: &str) -> Value {
    if let Ok(Request::Pair { client_id, name, key }) = serde_json::from_str::<Request>(line) {
        return pair(client_id, name, key);
    }
    let replay = REPLAY.get_or_init(Default::default);
    match with_vault(|v| {
        let mut g = replay.lock().unwrap_or_else(|e| e.into_inner());
        Ok(browser::handle_line(v, &mut g, line))
    }) {
        Ok(Some(v)) => v,
        Ok(None) => err("invalid_input", "无法识别的请求"),
        Err(e) => err(&e.code, &e.message),
    }
}

/// 配对：推送给 Dart 弹窗，阻塞等待用户选择（本连接独占线程，不影响其他请求）。
fn pair(client_id: String, name: String, key: String) -> Value {
    let unlocked = with_vault(|v| Ok(v.is_unlocked())).unwrap_or(false);
    if !unlocked {
        return err("locked", "请先在桌面端解锁 VaultOne，再进行配对");
    }
    let code = match browser::pairing_code(&key) {
        Ok(c) => c,
        Err(e) => return err(e.code(), &e.to_string()),
    };
    let (tx, rx) = mpsc::channel();
    pending().insert(client_id.clone(), tx);
    let pushed = SINK
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .is_some_and(|s| s.add(PairingRequest { client_id: client_id.clone(), name: name.clone(), code }).is_ok());
    if !pushed {
        pending().remove(&client_id);
        return err("internal", "桌面端未就绪");
    }
    match rx.recv_timeout(PAIRING_TIMEOUT) {
        Ok(true) => match with_vault(|v| browser::add_client(v, &client_id, &name, &key)) {
            Ok(()) => json!({ "ok": true }),
            Err(e) => err(&e.code, &e.message),
        },
        Ok(false) => err("denied", "已在桌面端拒绝配对"),
        Err(_) => {
            pending().remove(&client_id);
            err("timeout", "配对超时，请重试")
        }
    }
}

/// 在各 Chromium 系浏览器中登记 Native Messaging 宿主（宿主程序与主程序位于同一目录）。
/// 返回写入的清单路径。Windows 写 HKCU 注册表；macOS / Linux 写用户级清单目录。
pub fn register_native_host() -> BridgeResult<String> {
    let fail = |m: String| BridgeError { code: "register_failed".into(), message: m };
    let exe = std::env::current_exe().map_err(|e| fail(e.to_string()))?;
    let host = exe.with_file_name(if cfg!(windows) { "vaultone-nmhost.exe" } else { "vaultone-nmhost" });
    if !host.exists() {
        return Err(fail(format!("未找到宿主程序 {}", host.display())));
    }
    let manifest = json!({
        "name": NATIVE_HOST_NAME,
        "description": "VaultOne 桌面端连接器",
        "path": host.to_string_lossy(),
        "type": "stdio",
        "allowed_origins": EXTENSION_IDS.iter().map(|id| format!("chrome-extension://{id}/")).collect::<Vec<_>>(),
    });
    let body = serde_json::to_vec_pretty(&manifest).map_err(|e| fail(e.to_string()))?;
    let file_name = format!("{NATIVE_HOST_NAME}.json");

    #[cfg(windows)]
    {
        use winreg::enums::HKEY_CURRENT_USER;
        use winreg::RegKey;
        // 清单放在宿主旁边，注册表各浏览器键指向它
        let path = host.with_file_name(&file_name);
        std::fs::write(&path, &body).map_err(|e| fail(e.to_string()))?;
        let hkcu = RegKey::predef(HKEY_CURRENT_USER);
        for browser in ["Google\\Chrome", "Microsoft\\Edge", "Chromium", "BraveSoftware\\Brave-Browser"] {
            let (key, _) = hkcu
                .create_subkey(format!("Software\\{browser}\\NativeMessagingHosts\\{NATIVE_HOST_NAME}"))
                .map_err(|e| fail(e.to_string()))?;
            key.set_value("", &path.to_string_lossy().to_string()).map_err(|e| fail(e.to_string()))?;
        }
        tracing::info!(target: "browser", "native host registered");
        Ok(path.to_string_lossy().into_owned())
    }
    #[cfg(not(windows))]
    {
        let home = std::env::var("HOME").unwrap_or_default();
        let home = home.split("/Library/Containers/").next().unwrap_or_default().to_string();
        let dirs: &[&str] = if cfg!(target_os = "macos") {
            &[
                "Library/Application Support/Google/Chrome",
                "Library/Application Support/Microsoft Edge",
                "Library/Application Support/Chromium",
                "Library/Application Support/BraveSoftware/Brave-Browser",
            ]
        } else {
            &[".config/google-chrome", ".config/microsoft-edge", ".config/chromium", ".config/BraveSoftware/Brave-Browser"]
        };
        let mut written = None;
        for d in dirs {
            let dir = std::path::Path::new(&home).join(d).join("NativeMessagingHosts");
            if std::fs::create_dir_all(&dir).and_then(|_| std::fs::write(dir.join(&file_name), &body)).is_ok() {
                written.get_or_insert(dir.join(&file_name));
            }
        }
        tracing::info!(target: "browser", ok = written.is_some(), "native host registered");
        written.map(|p| p.to_string_lossy().into_owned()).ok_or_else(|| fail("无法写入浏览器的宿主清单目录".into()))
    }
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Write};

    use interprocess::local_socket::prelude::*;
    use vault_core::{KdfParams, Vault};

    use super::*;

    const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";

    /// 真实本地套接字上的完整往返：hello → 已认证 match → 伪造 MAC 被拒。
    #[test]
    fn socket_roundtrip() {
        let mut v = Vault::open_in_memory().unwrap();
        v.create_account("me@example.com", "correct horse battery", KdfParams::insecure_for_tests()).unwrap();
        browser::add_client(&v, "c1", "Chrome", KEY).unwrap();
        *super::super::vault::slot_for_tests() = Some(v);
        ENABLED.store(true, Ordering::SeqCst);

        let ep = if cfg!(windows) {
            format!("vaultone-test-{}", std::process::id())
        } else {
            std::env::temp_dir().join(format!("vaultone-test-{}.sock", std::process::id())).to_string_lossy().into_owned()
        };
        let listener = listen(&ep).unwrap();
        std::thread::spawn(move || {
            for conn in listener.incoming().filter_map(|c| c.ok()) {
                std::thread::spawn(move || serve(conn));
            }
        });

        #[cfg(windows)]
        let name = ep.as_str().to_ns_name::<interprocess::local_socket::GenericNamespaced>().unwrap();
        #[cfg(not(windows))]
        let name = ep.as_str().to_fs_name::<interprocess::local_socket::GenericFilePath>().unwrap();
        let mut conn = BufReader::new(interprocess::local_socket::Stream::connect(name).unwrap());
        let mut ask = |req: &Value| -> Value {
            conn.get_mut()
                .write_all(
                    format!(
                        "{req}
"
                    )
                    .as_bytes(),
                )
                .unwrap();
            let mut line = String::new();
            conn.read_line(&mut line).unwrap();
            serde_json::from_str(&line).unwrap()
        };

        let hello = ask(&json!({"type":"hello","clientId":"c1"}));
        assert_eq!(hello["locked"], false);
        assert_eq!(hello["paired"], true);

        let body = json!({"op":"match","url":"https://example.com"}).to_string();
        let ts = vault_core::vault::now();
        let mac = browser::compute_mac(KEY, "c1", "nonce-socket-00001", ts, &body).unwrap();
        let r = ask(&json!({"type":"call","clientId":"c1","nonce":"nonce-socket-00001","ts":ts,"body":body,"mac":mac}));
        assert_eq!(r["ok"], true, "{r}");

        let r = ask(&json!({"type":"call","clientId":"c1","nonce":"nonce-socket-00002","ts":ts,"body":body,"mac":"AAAA"}));
        assert_eq!(r["code"], "unauthorized");

        // 经真实 Native Messaging 宿主转发（需先 `cargo build -p vault-nmhost`；未构建时跳过这一段）
        let host = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/debug").join(if cfg!(windows) {
            "vaultone-nmhost.exe"
        } else {
            "vaultone-nmhost"
        });
        if !host.exists() {
            eprintln!("skip native host relay: {} not built", host.display());
            return;
        }
        let mut child = std::process::Command::new(host)
            .env("VAULTONE_BROWSER_ENDPOINT", &ep)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let msg = json!({"type":"hello","clientId":"c1"}).to_string();
        let stdin = child.stdin.as_mut().unwrap();
        stdin.write_all(&(msg.len() as u32).to_le_bytes()).unwrap();
        stdin.write_all(msg.as_bytes()).unwrap();
        stdin.flush().unwrap();
        let mut out = child.stdout.take().unwrap();
        let mut len = [0u8; 4];
        std::io::Read::read_exact(&mut out, &mut len).unwrap();
        let mut buf = vec![0u8; u32::from_le_bytes(len) as usize];
        std::io::Read::read_exact(&mut out, &mut buf).unwrap();
        let reply: Value = serde_json::from_slice(&buf).unwrap();
        assert_eq!(reply["app"], "vaultone");
        assert_eq!(reply["paired"], true);
        drop(child.stdin.take());
        child.wait().unwrap();
    }
}
