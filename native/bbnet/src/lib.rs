//! bbnet: 游戏内置 agent 使用的原生网络库.
//!
//! 游戏里的 Lua 发不出 HTTPS 流式请求, 因此把网络放进这个库: 每个请求一个线程,
//! 手写 HTTP/1.1, 用 rustls 做 TLS, 在库内完成 chunked 解码与 SSE 分帧.
//! Lua 侧通过 LuaJIT ffi 每帧轮询取结果, 不使用回调 (ffi 回调不能从别的线程调用).
//!
//! 模块划分:
//! - `ffi`: C ABI 导出函数, 负责指针与内存管理, 所有入口都拦截 panic.
//! - `registry`: 全局句柄表, 请求的生命周期 (发起, 轮询, 取消, 释放).
//! - `worker`: 请求线程, 串起连接, 发送, 读取与分帧.
//! - `http`: URL 解析, 请求编码, 响应头解析, 响应体解码.
//! - `net`: TCP 连接, TLS 握手, 跨线程取消.
//! - `sse`: SSE 事件分帧.
//! - `yuv`: RGBA 到 NV12 的颜色转换, 供 Android 录像的硬件编码使用.

pub mod error;
pub mod ffi;
pub mod http;
pub mod net;
pub mod registry;
pub mod sse;
mod text;
mod worker;
pub mod yuv;

/// 库版本, 与 Cargo.toml 保持一致.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
