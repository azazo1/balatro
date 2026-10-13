use std::{net::{Ipv4Addr, SocketAddr}, path::PathBuf};
use balatro_web_server::api::{router, AppState};
use clap::Parser;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "balatro-web-server", version = engine::VERSION, about = "浏览器对局调试台的本地 HTTP 服务")]
struct Args {
    /// 本地监听端口, 只绑定 127.0.0.1.
    #[arg(long, default_value_t = 12347, value_parser = clap::value_parser!(u16).range(1..))]
    port: u16,
    /// 前端静态目录, 默认是安装包内与 bin 并列的 web.
    #[arg(long = "static", value_name = "DIRECTORY")]
    static_dir: Option<PathBuf>,
    /// 明确允许的 Vite 开发 Origin, 发行模式不需要.
    #[arg(long)]
    dev_origin: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    tracing_subscriber::fmt().with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "balatro_web_server=info,tower_http=info,balatro_web_lab=info".into())).init();
    let previous_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| { tracing::error!(panic=%info, "进程 panic"); previous_hook(info); }));
    let static_dir = args.static_dir.unwrap_or_else(|| std::env::current_exe().ok()
        .and_then(|path| path.parent().and_then(|p| p.parent()).map(|p| p.join("web")))
        .unwrap_or_else(|| PathBuf::from("web")));
    if !static_dir.join("index.html").is_file() && args.dev_origin.is_none() {
        return Err(format!("缺少前端产物 {}, 请先构建或通过 --static 指定", static_dir.display()).into());
    }
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, args.port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(url=%format!("http://{addr}"),version=engine::VERSION,static_dir=%static_dir.display(),"Engine Web 服务启动");
    axum::serve(listener, router(AppState::new(args.port, args.dev_origin), static_dir)).with_graceful_shutdown(async {
        match tokio::signal::ctrl_c().await {
            Ok(()) => tracing::info!("收到退出请求, 正在关闭服务"),
            Err(error) => tracing::error!(%error, "信号监听失败"),
        }
    }).await?;
    tracing::info!("服务已关闭");
    Ok(())
}
