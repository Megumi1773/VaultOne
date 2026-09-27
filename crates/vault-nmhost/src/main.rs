//! VaultOne Native Messaging 宿主（计划书 F-05："通过 Native Messaging 调用桌面端完成解密"）。
//!
//! Chrome / Edge 以子进程方式启动本程序，经 stdin/stdout 交换"4 字节小端长度 + UTF-8 JSON"消息
//! （<https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging>）。
//! 本程序只做**逐条转发**：把消息写入桌面端的本地套接字（一行一条 JSON），再把回复原样送回浏览器。
//! 它不解析业务字段、不持有任何密钥；认证与解密全部在桌面端完成（见 `vault_core::browser`）。

use std::io::{self, BufRead, BufReader, Read, Write};

use interprocess::local_socket::prelude::*;
use interprocess::local_socket::Stream;
use serde_json::{json, Value};
use vault_proto::browser_ipc::{endpoint, MAX_MESSAGE_BYTES};

/// 读一条浏览器消息；stdin 关闭（浏览器断开）时返回 `None`。
fn read_message(input: &mut impl Read) -> io::Result<Option<Value>> {
    let mut len = [0u8; 4];
    match input.read_exact(&mut len) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_le_bytes(len) as usize;
    if len > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "message too large"));
    }
    let mut buf = vec![0u8; len];
    input.read_exact(&mut buf)?;
    serde_json::from_slice(&buf).map(Some).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

fn write_message(output: &mut impl Write, msg: &Value) -> io::Result<()> {
    let bytes = serde_json::to_vec(msg)?;
    output.write_all(&(bytes.len() as u32).to_le_bytes())?;
    output.write_all(&bytes)?;
    output.flush()
}

fn connect() -> io::Result<BufReader<Stream>> {
    let ep = endpoint();
    #[cfg(windows)]
    let name = ep.to_ns_name::<interprocess::local_socket::GenericNamespaced>()?;
    #[cfg(not(windows))]
    let name = ep.to_fs_name::<interprocess::local_socket::GenericFilePath>()?;
    Ok(BufReader::new(Stream::connect(name)?))
}

/// 转发一条消息并取回回复（连接断开时重连一次）。
fn relay(conn: &mut Option<BufReader<Stream>>, msg: &Value) -> Value {
    // serde_json 的紧凑序列化不含换行，可安全作为"一行一条"
    let line = format!("{msg}\n");
    for _ in 0..2 {
        if conn.is_none() {
            match connect() {
                Ok(c) => *conn = Some(c),
                Err(_) => break,
            }
        }
        let c = conn.as_mut().expect("connected");
        let mut reply = String::new();
        let ok = c.get_mut().write_all(line.as_bytes()).is_ok() && c.read_line(&mut reply).map(|n| n > 0).unwrap_or(false);
        if ok {
            if let Ok(v) = serde_json::from_str(&reply) {
                return v;
            }
        }
        *conn = None;
    }
    json!({ "ok": false, "code": "app_not_running", "message": "未检测到正在运行的 VaultOne 桌面端，请先打开并解锁" })
}

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let (mut input, mut output) = (stdin.lock(), stdout.lock());
    let mut conn = None;
    loop {
        match read_message(&mut input) {
            Ok(Some(msg)) => {
                let reply = relay(&mut conn, &msg);
                if write_message(&mut output, &reply).is_err() {
                    break;
                }
            }
            Ok(None) => break,
            Err(e) => {
                let _ = write_message(&mut output, &json!({ "ok": false, "code": "invalid_input", "message": e.to_string() }));
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framing_roundtrip() {
        let mut buf = Vec::new();
        write_message(&mut buf, &json!({"type":"hello"})).unwrap();
        assert_eq!(u32::from_le_bytes(buf[..4].try_into().unwrap()) as usize, buf.len() - 4);
        let mut cursor = io::Cursor::new(buf);
        assert_eq!(read_message(&mut cursor).unwrap().unwrap()["type"], "hello");
        assert!(read_message(&mut cursor).unwrap().is_none());
    }

    #[test]
    fn rejects_oversized_and_garbage() {
        let mut big = (MAX_MESSAGE_BYTES as u32 + 1).to_le_bytes().to_vec();
        big.extend_from_slice(b"{}");
        assert!(read_message(&mut io::Cursor::new(big)).is_err());
        let mut bad = 3u32.to_le_bytes().to_vec();
        bad.extend_from_slice(b"xyz");
        assert!(read_message(&mut io::Cursor::new(bad)).is_err());
    }
}
