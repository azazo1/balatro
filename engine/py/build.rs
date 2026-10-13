//! 链接参数: Python 扩展的符号由解释器在运行时提供, 链接阶段不该去找它们.
//!
//! pyo3 自己也会在启用 `extension-module` 时加这些参数, 但直接写在这里更稳 —— 换平台或换
//! pyo3 版本都不会漏掉, 而漏掉的表现是"链接时找不到 _Py_IsInitialized 之类的符号".

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    match target_os.as_str() {
        "macos" => {
            println!("cargo:rustc-cdylib-link-arg=-Wl,-undefined,dynamic_lookup");
            println!("cargo:rustc-cdylib-link-arg=-Wl,-flat_namespace");
        }
        "linux" | "android" => {
            println!("cargo:rustc-cdylib-link-arg=-Wl,--allow-shlib-undefined");
        }
        // Windows 上扩展是 dll, 未定义符号默认允许, 不需要额外参数.
        _ => {}
    }
}
