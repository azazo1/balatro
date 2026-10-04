//! 让 agent 在引擎里逐步对局与查规则. 用法见 `engine/README.md` 的 "让 agent 玩" 一节.
//!
//! 每一步是一次独立命令: 每次调用把动作文件从头重放一遍再打印局面 (引擎确定, 所以不需要常驻
//! 进程). 动作先执行, 成功了才写进动作文件, 因此被拒绝的动作不会留在历史里.
//!
//! 输出照着内置 agent (`mods/balatrobot`) 给模型的那一份做: 牌的中文名与效果, 盲注目标与跳过
//! 奖励, 牌型等级与已打次数, 上一手的明细, 以及会随局面变的值. 缺了这些, agent 会输在信息差上.

mod replay;
mod session;

use std::path::PathBuf;

use balatro_engine::agent::{action, dynamics, prompt, summary};
use balatro_engine::data::json::Json;
use balatro_engine::data::knowledge;
use balatro_engine::run::{Phase, RunState};
use balatro_engine::scoring::EvalEnv;

/// 打印一行, 忽略写出错误 —— 输出被 `head` 之类的命令截断时不算失败.
///
/// std 的 `println!` 在管道关闭时会 panic (`Broken pipe`), 而这个命令是要被自动化调用的:
/// "读了几行就走" 是正常用法, 不该让调用方看到 panic 与 101 退出码.
macro_rules! say {
    ($($arg:tt)*) => {{ use std::io::Write; let _ = writeln!(std::io::stdout(), $($arg)*); }};
}

/// 同上, 但末尾不换行.
macro_rules! emit {
    ($($arg:tt)*) => {{ use std::io::Write; let _ = write!(std::io::stdout(), $($arg)*); }};
}

const HELP: &str = "\
用法: play <子命令> [参数]

子命令:
  step      在引擎里走一步对局 (默认子命令)
  lookup    查卡牌的中文名与效果      play lookup j_odd_todd 奇数托德
  docs      手册目录, 或读某一节      play docs [路径] [--offset N] [--limit N]
  search    在手册里搜子串            play search 利息 [--doc rules/economy.md]
  prompt    输出系统提示词            play prompt [--endless] [--strategy 文本]

step 的参数:
  --seed 种子 --deck 牌组 --stake 赌注   开局参数 (必给)
  --actions 文件                        这一局的动作文件, 也是全部历史 (必给)
  --do JSON                             追加并执行一条动作
  --emit 文件                           把这局导出成游戏能回放的文件

牌组可写 RED 或 b_red; 赌注可写 GOLD 或 8.
";

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let (command, rest): (&str, &[String]) = match argv.first().map(String::as_str) {
        None | Some("-h") | Some("--help") | Some("help") => {
            emit!("{HELP}");
            return;
        }
        Some("lookup") => ("lookup", &argv[1..]),
        Some("docs") => ("docs", &argv[1..]),
        Some("search") => ("search", &argv[1..]),
        Some("prompt") => ("prompt", &argv[1..]),
        Some("step") => ("step", &argv[1..]),
        // 不写子命令时按对局走, 这样最常用的一条路径不必多打一个词.
        Some(_) => ("step", &argv[..]),
    };
    match command {
        "lookup" => run_lookup(rest),
        "docs" => run_docs(rest),
        "search" => run_search(rest),
        "prompt" => run_prompt(rest),
        _ => run_step(rest),
    }
}

/// 取一个 `--名字 值` 形式的参数.
fn value_of<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    let at = args.iter().position(|arg| arg == name)?;
    args.get(at + 1).map(String::as_str)
}

fn flag(args: &[String], name: &str) -> bool {
    args.iter().any(|arg| arg == name)
}

// ---------------------------------------------------------------- 对局

struct StepArgs {
    seed: String,
    deck: String,
    stake: String,
    actions: PathBuf,
    do_action: Option<String>,
    emit: Option<PathBuf>,
}

fn run_step(args: &[String]) {
    // 缺参数时报清楚再退出, 不用 panic: 调用方多是 agent, 而 panic 的样子像"程序坏了",
    // 它多半会当成引擎的 bug 来排查, 而不是去补上参数.
    let need = |name: &str| match value_of(args, name) {
        Some(value) => value.to_owned(),
        None => {
            eprintln!("缺参数 {name}.\n");
            eprint!("{HELP}");
            std::process::exit(2);
        }
    };
    let step = StepArgs {
        seed: need("--seed"),
        deck: need("--deck"),
        stake: need("--stake"),
        actions: PathBuf::from(need("--actions")),
        do_action: value_of(args, "--do").map(str::to_owned),
        emit: value_of(args, "--emit").map(PathBuf::from),
    };

    let mut run = RunState::new(&step.seed, session::stake_of(&step.stake))
        .with_deck(&session::deck_of(&step.deck))
        .with_uda(session::uda_from_template());

    // 动作文件是这份对局的全部历史. 不存在就当开局: 建堆并写第一行 `start`.
    let mut actions: Vec<Json> = Vec::new();
    if step.actions.is_file() {
        for line in std::fs::read_to_string(&step.actions)
            .unwrap_or_default()
            .lines()
        {
            if line.trim().is_empty() {
                continue;
            }
            actions.push(
                match Json::parse(line) {
                    Ok(parsed) => parsed,
                    Err(error) => {
                        eprintln!("{} 里这行不是合法 JSON: {line}\n  ({error})", step.actions.display());
                        std::process::exit(2);
                    }
                }
            );
        }
    } else {
        if let Some(parent) = step.actions.parent() {
            std::fs::create_dir_all(parent).expect("能建动作文件所在目录");
        }
        actions.push(Json::parse("{\"method\":\"start\"}").expect("内建的是合法 JSON"));
        std::fs::write(&step.actions, "{\"method\":\"start\"}\n").expect("能写动作文件");
    }

    let env = EvalEnv::default();
    let verbose = std::env::var("PLAY_VERBOSE").is_ok();
    let mut records: Vec<String> = Vec::new();
    let mut wall = 0.0f64;
    let mut last_hand: Option<String> = None;

    // 先把历史重放一遍. 任何一步失败都直接停 —— 那说明动作文件与引擎对不上, 继续走只会把
    // 偏差叠到后面每一步. 停下时把截断命令直接给出来, 调用方多半是个 agent, 它要的是"做什么".
    for (index, step_json) in actions.iter().enumerate() {
        let method = step_json.get("method").and_then(Json::as_str).unwrap_or("?");
        match action::apply(step_json, &mut run, &env) {
            Ok(what) => {
                if verbose {
                    eprintln!("  [{}] {method}: {what}", index + 1);
                }
                if method == "play" {
                    last_hand = Some(what.clone());
                }
                // `start` 不进回放文件: 游戏那边开局参数走 `run` 段, 不认这条动作.
                if method != "start" {
                    wall += 1.5;
                    records.push(replay::record_of(step_json, &run, wall));
                }
            }
            Err(error) => {
                eprintln!("重放第 {} 步 ({method}) 失败: {error:?}", index + 1);
                eprintln!("{}", action::explain(&error, &run));
                // 只报事实 (前几行是好的), 不给截断命令 —— 那是调用方的事, 而这里给出的任何
                // 命令行都只在一部分平台上能跑.
                eprintln!(
                    "{} 的前 {} 行是好的, 想从这里继续就把它截断到前 {} 行再调用.",
                    step.actions.display(),
                    index,
                    index
                );
                std::process::exit(2);
            }
        }
    }

    // 新动作: **先执行, 成功了才落盘**. 反过来的话, 一条被拒绝的动作会留在历史里, 之后每次
    // 重放都在同一位置失败, 对局就废了 —— agent 犯错是常态, 动作文件里只该装真的生效过的.
    if let Some(text) = &step.do_action {
        let step_json = match Json::parse(text) {
            Ok(parsed) => parsed,
            Err(error) => {
                // 这一条最常发生: 引号被 shell 吃掉, 或者少一个逗号. 说清是哪种, 并原样回报收到的
                // 文本 —— 调用方才能看出到底是自己写错了, 还是参数在传递途中被改过.
                eprintln!("--do 不是合法 JSON: {error}\n  收到的是: {text}");
                std::process::exit(2);
            }
        };
        match action::apply(&step_json, &mut run, &env) {
            Ok(what) => {
                use std::io::Write;
                let mut file = std::fs::OpenOptions::new()
                    .append(true)
                    .open(&step.actions)
                    .expect("能追加动作文件");
                writeln!(file, "{}", text.trim()).expect("能写动作文件");
                wall += 1.5;
                records.push(replay::record_of(&step_json, &run, wall));
                if step_json.get("method").and_then(Json::as_str) == Some("play") {
                    last_hand = Some(what.clone());
                }
                eprintln!("刚做: {what}");
            }
            Err(error) => {
                eprintln!("这一步没有生效: {error:?}");
                eprintln!("{}", action::explain(&error, &run));
                eprintln!("动作文件没有变化, 直接换一条动作重试即可.");
                std::process::exit(1);
            }
        }
    }

    if let Some(path) = &step.emit {
        let spec = replay::RunSpec {
            seed: step.seed.clone(),
            deck: step.deck.clone(),
            stake: step.stake.clone(),
        };
        let text = replay::render(&spec, &records);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("能建回放文件所在目录");
        }
        std::fs::write(path, &text).expect("能写回放文件");
        eprintln!("已导出回放: {} ({} 步, {} 字节)", path.display(), records.len(), text.len());
        return;
    }

    print_state(&run, &step, records.len(), last_hand.as_deref());
}

/// 打印当前局面. 分三段: agent 要看的信息, 引擎的状态摘要, 以及"下一步能做什么".
fn print_state(run: &RunState, step: &StepArgs, steps: usize, last_hand: Option<&str>) {
    say!(
        "=== 第 {steps} 步 | {} ===",
        summary::phase_zh(run.phase)
    );
    say!("种子 {} / 牌组 {} / 赌注 {}", step.seed, step.deck, step.stake);
    say!(
        "{}",
        summary::render(
            run,
            &summary::Extras {
                last_hand,
                note: None
            }
        )
    );

    let dynamics = dynamics::render(run);
    if !dynamics.is_empty() {
        say!("--- 会变的值 ---");
        say!("{dynamics}");
    }

    say!("----");
    say!("digest: {}", balatro_engine::run::digest(run));
    say!("可选动作: {}", allowed_actions(run));
    say!("动作文件: {}", step.actions.display());
}

fn allowed_actions(run: &RunState) -> &'static str {
    match run.phase {
        Phase::BlindSelect => "select | skip | reroll_boss",
        Phase::SelectingHand => {
            "play {\"cards\":[..]} | discard {\"cards\":[..]} | rearrange | sort_hand_suit | \
             sort_hand_value | use {\"consumable\":n,\"cards\":[..]}"
        }
        Phase::RoundEval => "cash_out",
        Phase::Shop => {
            "buy {\"card\":n} / buy {\"voucher\":n} / buy {\"pack\":n} | reroll | \
             sell {\"joker\":n} | use {\"consumable\":n} | next_round"
        }
        Phase::BoosterOpened => "pack {\"card\":n,\"targets\":[..]} | pack {\"skip\":true} | sell {\"joker\":n}",
        Phase::GameOver => "这一局结束了 (换 --seed 或换牌组重开)",
    }
}

// ---------------------------------------------------------------- 查询

fn run_lookup(args: &[String]) {
    let keys: Vec<&str> = args.iter().filter(|arg| !arg.starts_with("--")).map(String::as_str).collect();
    if keys.is_empty() {
        eprintln!("用法: play lookup <卡牌 id 或中文名或英文名> [更多...]");
        std::process::exit(2);
    }
    for key in keys {
        let found = knowledge::find_cards(key);
        if found.is_empty() {
            say!("{key}: 没查到");
            let hints = knowledge::candidates(key);
            if !hints.is_empty() {
                say!("  相近的: {}", hints.join("; "));
            }
            continue;
        }
        for card in found {
            say!("{} {} / {}", card.id, card.name_zh, card.name_en);
            emit!("  类别 {}", card.category);
            if let Some(rarity) = card.rarity.as_ref() {
                emit!(", 稀有度 {rarity}");
            }
            if let Some(cost) = card.base_cost {
                emit!(", 基础价 ${}", summary::number(cost));
            }
            if let Some(compat) = card.blueprint_compat {
                emit!(", 可被蓝图复制: {}", if compat { "是" } else { "否" });
            }
            say!();
            if !card.effect_zh.is_empty() {
                say!("  效果: {}", card.effect_zh);
            }
            if knowledge::effect_is_dynamic(&card.effect_zh) {
                say!("  (效果里有占位, 实际值随局面变 —— 用对局输出里的会变的值那一段看当前值)");
            }
        }
    }
}

fn run_docs(args: &[String]) {
    let limit: usize = value_of(args, "--limit").and_then(|text| text.parse().ok()).unwrap_or(200);
    let offset: usize = value_of(args, "--offset").and_then(|text| text.parse().ok()).unwrap_or(1);
    let path = args.iter().find(|arg| !arg.starts_with("--") && !arg.ends_with(|c: char| c.is_ascii_digit()));
    let Some(path) = path else {
        // 没给路径就列目录: 顺序与手册的阅读顺序一致.
        say!("手册 ({} 份, 路径相对 docs/game/):", knowledge::manual().len());
        for doc in knowledge::manual() {
            say!(
                "  {:28} {:4} 行  {}",
                doc.path,
                doc.body.lines().count(),
                knowledge::manual_title(doc.body)
            );
        }
        say!("\n读某一节: play docs <路径> [--offset N --limit M]");
        return;
    };
    let Some(doc) = knowledge::find_manual(path) else {
        eprintln!("手册里没有 {path}. 用 play docs 看有哪些.");
        std::process::exit(2);
    };
    let lines: Vec<&str> = doc.body.lines().collect();
    let start = offset.max(1) - 1;
    let end = (start + limit).min(lines.len());
    say!("# {} ({}, 第 {}~{} 行 / 共 {} 行)", doc.path, knowledge::manual_title(doc.body), start + 1, end, lines.len());
    for (index, line) in lines[start..end].iter().enumerate() {
        say!("{:5}  {line}", start + index + 1);
    }
    if end < lines.len() {
        say!("--- 还有 {} 行, 用 --offset {} 接着看 ---", lines.len() - end, end + 1);
    }
}

fn run_search(args: &[String]) {
    let query = args
        .iter()
        .find(|arg| !arg.starts_with("--") && value_of(args, "--doc") != Some(arg.as_str()));
    let Some(query) = query else {
        eprintln!("用法: play search <要找的子串> [--doc 手册路径]");
        std::process::exit(2);
    };
    let doc = value_of(args, "--doc");
    let limit: usize = value_of(args, "--limit").and_then(|text| text.parse().ok()).unwrap_or(40);
    let hits = knowledge::search_manual(query, doc, limit);
    if hits.is_empty() {
        say!("没找到 {query}{}", doc.map(|d| format!(" (限定在 {d})")).unwrap_or_default());
        return;
    }
    say!("找到 {} 处{}:", hits.len(), if hits.len() >= limit { " (只显示前几条, 用 --limit 加大)" } else { "" });
    for (path, line_no, line) in hits {
        say!("  {path}:{line_no}: {line}");
    }
}

fn run_prompt(args: &[String]) {
    let strategy = value_of(args, "--strategy");
    emit!("{}", prompt::system(flag(args, "--endless"), strategy));
}
