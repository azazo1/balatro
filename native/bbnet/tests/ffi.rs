//! 通过导出函数端到端测试: 本地 TcpListener 充当服务端.

use std::ffi::{CStr, CString, c_char, c_int};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, Instant};

use bbnet::ffi::*;

fn start(method: &str, url: &str, headers: &str, body: &[u8]) -> i64 {
    let method = CString::new(method).unwrap();
    let url = CString::new(url).unwrap();
    let headers = CString::new(headers).unwrap();
    // SAFETY: 参数均为合法的 C 字符串与缓冲区.
    let id = unsafe {
        bbnet_request(
            method.as_ptr(),
            url.as_ptr(),
            headers.as_ptr(),
            body.as_ptr().cast(),
            body.len(),
            5000,
        )
    };
    assert!(id > 0);
    id
}

/// 轮询一项, 没数据时稍等重试, 返回 (种类, 状态码, 数据).
fn next(id: i64) -> (c_int, c_int, Vec<u8>) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let mut status: c_int = 0;
        let mut out: *mut c_char = std::ptr::null_mut();
        let mut len = 0usize;
        // SAFETY: 输出指针均指向本地变量.
        let kind = unsafe { bbnet_poll(id, &mut status, &mut out, &mut len) };
        if kind != BBNET_NONE {
            let data = if out.is_null() {
                Vec::new()
            } else {
                // SAFETY: out 指向 len 字节, 末尾另有 NUL.
                let data = unsafe { std::slice::from_raw_parts(out.cast::<u8>(), len) }.to_vec();
                assert_eq!(unsafe { *out.add(len) }, 0);
                unsafe { bbnet_free(out) };
                data
            };
            return (kind, status, data);
        }
        assert!(Instant::now() < deadline, "等待结果超时");
        thread::sleep(Duration::from_millis(5));
    }
}

/// 读完请求头与 Content-Length 指定的请求体.
fn read_request(sock: &mut TcpStream) -> String {
    let mut req = Vec::new();
    let mut buf = [0u8; 1024];
    loop {
        let n = sock.read(&mut buf).unwrap();
        assert!(n > 0);
        req.extend_from_slice(&buf[..n]);
        let text = String::from_utf8_lossy(&req).into_owned();
        if let Some(pos) = text.find("\r\n\r\n") {
            let len = text
                .lines()
                .find_map(|l| l.strip_prefix("Content-Length: "))
                .map_or(0, |v| v.parse::<usize>().unwrap());
            if req.len() >= pos + 4 + len {
                return text;
            }
        }
    }
}

/// SSE 经 chunked 传输, 分隔符与 chunk 头都被切在不同的 TCP 写入里.
#[test]
fn chunked_sse_across_boundaries() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (mut sock, _) = listener.accept().unwrap();
        let request = read_request(&mut sock);
        let body = "data: {\"a\":1}\n\ndata: two\r\n\r\n: comment\n\ndata: tail";
        let mut wire = Vec::new();
        wire.extend_from_slice(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n",
        );
        for piece in body.as_bytes().chunks(7) {
            wire.extend_from_slice(format!("{:x}\r\n", piece.len()).as_bytes());
            wire.extend_from_slice(piece);
            wire.extend_from_slice(b"\r\n");
        }
        wire.extend_from_slice(b"0\r\n\r\n");
        for part in wire.chunks(5) {
            sock.write_all(part).unwrap();
            sock.flush().unwrap();
            thread::sleep(Duration::from_millis(1));
        }
        request
    });

    let id = start(
        "POST",
        &format!("http://127.0.0.1:{port}/v1/chat?x=1"),
        "User-Agent: custom/1\nX-Key: v\n",
        b"{\"q\":1}",
    );
    let (kind, status, headers) = next(id);
    assert_eq!((kind, status), (BBNET_STATUS, 200));
    assert!(
        String::from_utf8(headers)
            .unwrap()
            .contains("Content-Type: text/event-stream\n")
    );
    let mut events = Vec::new();
    let kind = loop {
        match next(id) {
            (BBNET_EVENT, _, e) => events.push(String::from_utf8(e).unwrap()),
            (kind, _, _) => break kind,
        }
    };
    assert_eq!(kind, BBNET_DONE);
    assert_eq!(
        events,
        ["data: {\"a\":1}", "data: two", ": comment", "data: tail"]
    );
    // 结束后再 poll 仍返回 DONE.
    assert_eq!(next(id).0, BBNET_DONE);
    bbnet_close(id);

    let request = server.join().unwrap();
    assert!(request.starts_with("POST /v1/chat?x=1 HTTP/1.1\r\n"));
    assert!(request.contains(&format!("Host: 127.0.0.1:{port}\r\n")));
    assert!(request.contains("User-Agent: custom/1\r\n"));
    assert!(!request.contains("bbnet/"));
    assert!(request.contains("Connection: close\r\n"));
    assert!(request.contains("Content-Length: 7\r\n"));
    assert!(request.ends_with("\r\n\r\n{\"q\":1}"));
}

/// 取消能让阻塞中的读取立即返回, 且服务端看到连接被关闭.
#[test]
fn cancel_interrupts_blocking_read() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (mut sock, _) = listener.accept().unwrap();
        read_request(&mut sock);
        sock.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial")
            .unwrap();
        // 不再发送, 等客户端取消. 超时说明取消没有关掉连接.
        sock.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut buf = [0u8; 16];
        let started = Instant::now();
        matches!(sock.read(&mut buf), Ok(0) | Err(_)) && started.elapsed() < Duration::from_secs(4)
    });

    let id = start("GET", &format!("http://127.0.0.1:{port}/"), "", b"");
    assert_eq!(next(id).0, BBNET_STATUS);
    assert_eq!(next(id), (BBNET_BODY, 0, b"partial".to_vec()));
    // 请求线程此时阻塞在读取上.
    thread::sleep(Duration::from_millis(100));
    let started = Instant::now();
    bbnet_cancel(id);
    bbnet_cancel(id);
    let (kind, _, msg) = next(id);
    assert_eq!(
        (kind, msg.as_slice()),
        (BBNET_ERROR, b"cancelled".as_slice())
    );
    assert_eq!(next(id).0, BBNET_ERROR);
    assert!(server.join().unwrap(), "服务端未观察到连接关闭");
    assert!(started.elapsed() < Duration::from_secs(2));
    bbnet_close(id);

    // 参数错误返回 -1, 版本字符串可读.
    let bad = CString::new("ftp://x").unwrap();
    let get = CString::new("GET").unwrap();
    // SAFETY: 参数均为合法的 C 字符串.
    let id = unsafe {
        bbnet_request(
            get.as_ptr(),
            bad.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            0,
        )
    };
    assert_eq!(id, -1);
    let version = unsafe { CStr::from_ptr(bbnet_version()) };
    assert_eq!(
        version.to_str().unwrap(),
        concat!("bbnet ", env!("CARGO_PKG_VERSION"))
    );
}
