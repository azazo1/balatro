#[derive(Debug)]
pub struct Error {
    pub status: u16,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn bad(message: impl Into<String>) -> Self { Self { status: 400, message: message.into() } }
    pub fn refused(message: impl Into<String>) -> Self { Self { status: 422, message: message.into() } }
    pub fn conflict() -> Self { Self { status: 409, message: "局面已变化, 请刷新后重试".into() } }
    pub fn missing() -> Self { Self { status: 404, message: "会话不存在或服务已经重启, 请载入保存的会话".into() } }
    pub fn internal() -> Self { Self { status: 500, message: "内部错误, 请查看诊断信息".into() } }
}
