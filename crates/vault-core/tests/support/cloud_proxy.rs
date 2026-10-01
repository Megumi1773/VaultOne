//! 仅测试用的回环 HTTP 转发器：在上游提交后丢弃指定响应，验证客户端恢复能力。
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::thread::{self, JoinHandle};
use std::time::Duration;

pub struct CloudProxy {
    pub url: String,
    drop_next: Arc<Mutex<Option<String>>>,
    offline: Arc<AtomicBool>,
    reject_account: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl CloudProxy {
    pub fn start(upstream: &str) -> Self {
        assert!(upstream.starts_with("http://127.0.0.1:") || upstream.starts_with("http://localhost:"));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let drop_next = Arc::new(Mutex::new(None));
        let offline = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let reject_account = Arc::new(AtomicBool::new(false));
        let reject = reject_account.clone();
        let (d, o, s) = (drop_next.clone(), offline.clone(), stop.clone());
        let upstream = upstream.to_string();
        let worker = thread::spawn(move || {
            let client = reqwest::blocking::Client::builder().timeout(Duration::from_secs(15)).build().unwrap();
            while !s.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        forward(stream, &upstream, &client, &d, &o, &reject);
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => thread::sleep(Duration::from_millis(5)),
                    Err(_) => break,
                }
            }
        });
        Self { url, drop_next, offline, reject_account, stop, worker: Some(worker) }
    }
    pub fn reject_account_once(&self) {
        self.reject_account.store(true, Ordering::SeqCst);
    }

    pub fn drop_response(&self, path: &str) {
        *self.drop_next.lock().unwrap() = Some(path.into());
    }
    pub fn set_offline(&self, value: bool) {
        self.offline.store(value, Ordering::SeqCst);
    }
}

impl Drop for CloudProxy {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            worker.join().unwrap();
        }
    }
}

fn forward(
    mut stream: TcpStream,
    upstream: &str,
    client: &reqwest::blocking::Client,
    drop_next: &Mutex<Option<String>>,
    offline: &AtomicBool,
    reject_account: &AtomicBool,
) {
    // Windows accept 可能继承监听器的非阻塞模式；逐字节读取须显式切回阻塞。
    stream.set_nonblocking(false).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    stream.set_write_timeout(Some(Duration::from_secs(10))).unwrap();
    if offline.load(Ordering::SeqCst) {
        return;
    }
    let mut header = Vec::new();
    let mut byte = [0];
    while !header.ends_with(b"\r\n\r\n") {
        if stream.read_exact(&mut byte).is_err() {
            return;
        }
        header.push(byte[0]);
        assert!(header.len() < 16384);
    }
    let header = String::from_utf8(header).unwrap();
    let mut lines = header.lines();
    let mut request_line = lines.next().unwrap().split_whitespace();
    let method = reqwest::Method::from_bytes(request_line.next().unwrap().as_bytes()).unwrap();
    let path = request_line.next().unwrap();
    if path == "/v1/account" && reject_account.swap(false, Ordering::SeqCst) {
        let body = r#"{"code":"unauthorized","message":"expired"}"#;
        let response = format!(
            "HTTP/1.1 401 Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(response.as_bytes());
        return;
    }
    let mut request = client.request(method, format!("{upstream}{path}"));
    let mut length = 0;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            match name.to_ascii_lowercase().as_str() {
                "content-length" => length = value.trim().parse::<usize>().unwrap(),
                "content-type" | "authorization" => request = request.header(name, value.trim()),
                _ => {}
            }
        }
    }
    assert!(length < 4 * 1024 * 1024);
    let mut body = vec![0; length];
    if stream.read_exact(&mut body).is_err() {
        return;
    }
    let response = request.body(body).send().unwrap();
    let status = response.status().as_u16();
    let body = response.bytes().unwrap();
    let mut drop = drop_next.lock().unwrap();
    if drop.as_deref() == Some(path) {
        *drop = None;
        return;
    }
    std::mem::drop(drop);
    let head =
        format!("HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(&body);
}
