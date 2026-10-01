//! C ABI 导出函数, 供 LuaJIT ffi 调用. 声明见各函数文档.
//!
//! 所有入口都用 `catch_unwind` 包住, panic 不会跨越 FFI: request 返回 -1, poll 返回 ERROR.
//! 返回给调用方的字符串由本库分配, 必须用 `bbnet_free` 释放.

use std::ffi::{CStr, c_char, c_int};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use crate::http::request::{Request, Timeouts};
use crate::registry::{self, Item};

pub const BBNET_NONE: c_int = 0;
pub const BBNET_STATUS: c_int = 1;
pub const BBNET_EVENT: c_int = 2;
pub const BBNET_BODY: c_int = 3;
pub const BBNET_DONE: c_int = 4;
pub const BBNET_ERROR: c_int = 5;

/// 分配的字符串前面藏一个 usize 记录长度, `bbnet_free` 据此还原分配.
const PREFIX: usize = size_of::<usize>();

/// 发起请求, 立即返回句柄 (>0); 参数错误返回 -1.
///
/// `int64_t bbnet_request(const char *method, const char *url, const char *headers,
///                        const char *body, size_t body_len, uint32_t timeout_ms);`
///
/// # Safety
/// `method`, `url` 须为 NUL 结尾的字符串; `headers` 为 NULL 或 NUL 结尾的字符串;
/// `body` 为 NULL 或指向至少 `body_len` 字节的可读内存.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bbnet_request(
    method: *const c_char,
    url: *const c_char,
    headers: *const c_char,
    body: *const c_char,
    body_len: usize,
    timeout_ms: u32,
) -> i64 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: 调用方保证指针合法, 见函数文档.
        let method = unsafe { c_str(method) }?;
        let url = unsafe { c_str(url) }?;
        let headers = if headers.is_null() {
            ""
        } else {
            unsafe { c_str(headers) }?
        };
        let body = match (body.is_null(), body_len) {
            (_, 0) => Vec::new(),
            (true, _) => return None,
            // SAFETY: 调用方保证 body 指向至少 body_len 字节.
            (false, n) => unsafe { std::slice::from_raw_parts(body.cast::<u8>(), n) }.to_vec(),
        };
        let request = Request::new(
            method,
            url,
            headers,
            body,
            Timeouts::from_millis(timeout_ms),
        )
        .ok()?;
        Some(registry::start(request))
    }));
    result.ok().flatten().unwrap_or(-1)
}

/// 取出一项结果, 返回种类 (`BBNET_*`).
///
/// `int bbnet_poll(int64_t id, int *status, char **out, size_t *out_len);`
///
/// STATUS 时写入 `*status`; 有字符串时 `*out` 指向库分配的内存 (末尾另有 NUL, 不计入长度),
/// 无数据时 `*out = NULL`, `*out_len = 0`. 各输出指针均可为 NULL.
///
/// # Safety
/// 非 NULL 的输出指针须可写.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bbnet_poll(
    id: i64,
    status: *mut c_int,
    out: *mut *mut c_char,
    out_len: *mut usize,
) -> c_int {
    // SAFETY: 调用方保证非 NULL 的输出指针可写.
    unsafe { write_out(out, out_len, None) };
    let polled = catch_unwind(|| registry::poll(id))
        .unwrap_or_else(|_| Some(Item::Error("internal: panic in poll".into())));
    let (kind, data) = match polled {
        None => (BBNET_NONE, None),
        Some(Item::Status(code, headers)) => {
            if !status.is_null() {
                // SAFETY: 同上.
                unsafe { *status = c_int::from(code) };
            }
            (BBNET_STATUS, Some(headers.into_bytes()))
        }
        Some(Item::Event(e)) => (BBNET_EVENT, Some(e)),
        Some(Item::Body(b)) => (BBNET_BODY, Some(b)),
        Some(Item::Done) => (BBNET_DONE, None),
        Some(Item::Error(msg)) => (BBNET_ERROR, Some(msg.into_bytes())),
    };
    // SAFETY: 同上.
    unsafe { write_out(out, out_len, data) };
    kind
}

/// 释放 `bbnet_poll` 返回的字符串. NULL 忽略.
///
/// `void bbnet_free(char *p);`
///
/// # Safety
/// `p` 须为 `bbnet_poll` 返回且尚未释放的指针, 或 NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bbnet_free(p: *mut c_char) {
    if p.is_null() {
        return;
    }
    let _ = catch_unwind(|| {
        // SAFETY: p 由 alloc_bytes 分配, 前面 PREFIX 字节存着数据长度.
        unsafe {
            let base = p.cast::<u8>().sub(PREFIX);
            let len = base.cast::<usize>().read_unaligned();
            let total = PREFIX + len + 1;
            drop(Box::from_raw(ptr::slice_from_raw_parts_mut(base, total)));
        }
    });
}

/// 取消请求, 可重复调用. 阻塞中的读取立即返回, 之后 poll 得到 ERROR "cancelled".
///
/// `void bbnet_cancel(int64_t id);`
#[unsafe(no_mangle)]
pub extern "C" fn bbnet_cancel(id: i64) {
    let _ = catch_unwind(|| registry::cancel(id));
}

/// 释放句柄 (未结束时先取消), 之后该 id 无效.
///
/// `void bbnet_close(int64_t id);`
#[unsafe(no_mangle)]
pub extern "C" fn bbnet_close(id: i64) {
    let _ = catch_unwind(|| registry::close(id));
}

/// 返回静态版本字符串, 例如 "bbnet 0.1.0", 不要 free.
///
/// `const char *bbnet_version(void);`
#[unsafe(no_mangle)]
pub extern "C" fn bbnet_version() -> *const c_char {
    static VERSION: &str = concat!("bbnet ", env!("CARGO_PKG_VERSION"), "\0");
    VERSION.as_ptr().cast()
}

/// # Safety
/// `p` 为 NULL 或 NUL 结尾的字符串.
unsafe fn c_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    // SAFETY: 由调用方保证.
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// 分配 `[长度][数据][NUL]`, 返回指向数据的指针.
fn alloc_bytes(data: &[u8]) -> *mut c_char {
    let mut buf = Vec::with_capacity(PREFIX + data.len() + 1);
    buf.extend_from_slice(&data.len().to_ne_bytes());
    buf.extend_from_slice(data);
    buf.push(0);
    let base = Box::into_raw(buf.into_boxed_slice()).cast::<u8>();
    // SAFETY: 分配长度至少为 PREFIX + 1.
    unsafe { base.add(PREFIX).cast() }
}

/// # Safety
/// 非 NULL 的指针须可写.
unsafe fn write_out(out: *mut *mut c_char, out_len: *mut usize, data: Option<Vec<u8>>) {
    let (p, len) = match data {
        Some(d) if !out.is_null() => (alloc_bytes(&d), d.len()),
        _ => (ptr::null_mut(), 0),
    };
    // SAFETY: 由调用方保证.
    unsafe {
        if !out.is_null() {
            *out = p;
        }
        if !out_len.is_null() {
            *out_len = len;
        }
    }
}
