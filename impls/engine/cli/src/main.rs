//! 引擎命令行 `balatro` 的入口: 一个二进制带两条子命令.
//!
//! 这里只负责分发, 具体逻辑在 play (逐步对局与查规则) 与 replay_check (离线回放核对) 里.

mod play;
mod replay_check;

const HELP: &str = "\
用法: balatro <子命令> [参数]

子命令:
  play          在引擎里逐步对局, 或查卡牌与手册    balatro play --help
  replay-check  离线逐步核对回放文件, 不启动游戏    balatro replay-check --strict <fixture.jsonl>

不带子命令或给 -h 时打印这份说明, 两个子命令各自的参数见它们的 --help.
";

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    match argv.first().map(String::as_str) {
        Some("play") => play::run(&argv[1..]),
        Some("replay-check") => replay_check::run(&argv[1..]),
        Some("-V") | Some("--version") => println!("balatro {}", engine::VERSION),
        None | Some("-h") | Some("--help") | Some("help") => print!("{HELP}"),
        Some(other) => {
            eprintln!("未知子命令: {other}");
            eprint!("{HELP}");
            std::process::exit(2);
        },
    }
}
