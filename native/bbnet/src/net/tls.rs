//! TLS 客户端: rustls + ring, 信任 webpki-roots 打包的 Mozilla 根证书, 不读系统证书.

use std::net::TcpStream;
use std::sync::{Arc, OnceLock};

use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};

use crate::error::{Error, Result};

/// 全进程共用一份配置, 首次使用时构建.
fn config() -> Result<Arc<ClientConfig>> {
    static CONFIG: OnceLock<std::result::Result<Arc<ClientConfig>, String>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let roots = RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
            };
            let provider = Arc::new(rustls::crypto::ring::default_provider());
            let mut config = ClientConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .map_err(|e| e.to_string())?
                .with_root_certificates(roots)
                .with_no_client_auth();
            config.alpn_protocols = vec![b"http/1.1".to_vec()];
            Ok(Arc::new(config))
        })
        .clone()
        .map_err(Error::Tls)
}

/// 完成握手后返回加密流. SNI 与证书校验都用 `host`, IP 字面量按 IP 校验.
pub fn handshake(
    host: &str,
    mut sock: TcpStream,
) -> Result<StreamOwned<ClientConnection, TcpStream>> {
    let name = ServerName::try_from(host.to_string())
        .map_err(|e| Error::Tls(format!("invalid server name {host}: {e}")))?;
    let mut conn = ClientConnection::new(config()?, name).map_err(|e| Error::Tls(e.to_string()))?;
    while conn.is_handshaking() {
        conn.complete_io(&mut sock)
            .map_err(|e| match Error::from_io("tls", e) {
                Error::Io { message, .. } => Error::Tls(message),
                other => other,
            })?;
    }
    Ok(StreamOwned::new(conn, sock))
}
