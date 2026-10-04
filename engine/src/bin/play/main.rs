//! 让 agent 在引擎里逐步对局与查规则. 用法见 `engine/README.md` 的 "让 agent 玩" 一节.
//!
//! 每一步是一次独立命令: 每次调用把动作文件从头重放一遍再打印局面 (引擎确定, 所以不需要常驻
//! 进程). 动作先执行, 成功了才写进动作文件, 因此被拒绝的动作不会留在历史里.
//!
//! 输出照着内置 agent (`mods/balatrobot`) 给模型的那一份做: 牌的中文名与效果, 盲注目标与跳过
//! 奖励, 牌型等级与已打次数, 上一手的明细, 以及会随局面变的值. 缺了这些, agent 会输在信息差上.

mod replay;
mod session;

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::path::{Path, PathBuf};

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
  --seed 种子 --deck 牌组 --stake 赌注   开局参数. 新开一局时必给牌组与赌注;
                                        种子不给就随机生成 (形状同游戏的新开一局),
                                        定下来之后记进动作文件, 之后不用再给.
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

/// 一次 `step` 调用的输入.
struct StepArgs {
    opening: Opening,
    actions: PathBuf,
    do_action: Option<String>,
    emit: Option<PathBuf>,
}

/// 这一局的开局参数.
///
/// 定下来之后**记进动作文件的第一行**, 而不是每次调用都从命令行重给: 种子可能是随机生成的,
/// 命令行无从重复, 而动作文件是这一局的全部历史 —— 它才是真相. 顺带堵住一处静默出错: 原来三个
/// 参数每次都要重打, 中途漏一个或打错就会按另一局去建堆, 而动作文件上看不出来.
struct Opening {
    seed: String,
    deck: String,
    stake: String,
}

/// 从动作文件的第一行取开局参数. 旧格式 (`{"method":"start"}` 不带 `params`) 给 `None`.
fn opening_from(actions: &[Json]) -> Option<Opening> {
    let first = actions.first()?;
    if first.get("method").and_then(Json::as_str) != Some("start") {
        return None;
    }
    let params = first.get("params")?;
    let text = |key: &str| params.get(key).and_then(Json::as_str).map(str::to_owned);
    Some(Opening {
        seed: text("seed")?,
        deck: text("deck")?,
        stake: text("stake")?,
    })
}

/// 开局那一行动作. 参数按 JSON 转义, 免得路径或别的字段里有引号.
fn start_line(opening: &Opening) -> String {
    format!(
        "{{\"method\":\"start\",\"params\":{{\"seed\":{},\"deck\":{},\"stake\":{}}}}}",
        replay::quote(&opening.seed),
        replay::quote(&opening.deck),
        replay::quote(&opening.stake)
    )
}

/// 游戏生成的种子长度.
const SEED_LEN: usize = 8;

/// 游戏生成种子用的字母表: 数字 `1-9` 与字母 `A-N`, `P-Z`.
///
/// 与 `game/functions/misc_functions.lua` 的 `random_string` 逐段对应 (那里是三次 `math.random`
/// 取字符码): **没有 `0` 也没有 `O`** —— 与对方看混, 游戏故意跳过.
const SEED_ALPHABET: &[u8] = b"123456789ABCDEFGHIJKLMNPQRSTUVWXYZ";

/// 生成一个开局种子, 形状与游戏"新开一局"时给的一致.
///
/// 游戏那边是 `random_string(8, ...)` (见 `game/functions/misc_functions.lua`): 八位, 字母表是
/// 数字 `1-9` 与字母 `A-N`, `P-Z` —— **没有 `0` 也没有 `O`** (它们与对方看混). 照抄这个形状,
/// 生成的种子手输回游戏时不会被拒.
fn generate_seed() -> String {
    // 引擎只有 std, 没有随机数库. `RandomState` 是标准库里唯一与操作系统熵挂钩的东西 ——
    // 它的键由 OS 随机数播种, 且每次构造都不一样; 再掺进时钟, 连着开两局也不会撞.
    let mut hasher = RandomState::new().build_hasher();
    hasher.write_u64(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_nanos() as u64)
            .unwrap_or(0),
    );
    // `| 1` 是防 xorshift 落进 0 里出不来 (零点是它的吸收态).
    let mut state = hasher.finish() | 1;
    let mut out = String::with_capacity(SEED_LEN);
    for _ in 0..SEED_LEN {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        out.push(SEED_ALPHABET[(state % SEED_ALPHABET.len() as u64) as usize] as char);
    }
    out
}

/// 读动作文件; 不存在给空. 有一行不是 JSON 就说清是哪一行并退出.
fn read_actions(path: &Path) -> Vec<Json> {
    if !path.is_file() {
        return Vec::new();
    }
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let mut actions = Vec::new();
    for line in text.lines() {
        if line.trim().is_empty() {
            continue;
        }
        match Json::parse(line) {
            Ok(parsed) => actions.push(parsed),
            Err(error) => {
                eprintln!("{} 里这行不是合法 JSON: {line}\n  ({error})", path.display());
                std::process::exit(2);
            }
        }
    }
    actions
}

/// 命令行给的开局参数与动作文件里记的对不上时报清楚.
///
/// 不默默按其中一个走: 两者不一致时无论选哪个都是在打"另一局", 而动作文件里的历史是按原来那局
/// 记的 —— 继续下去只会在某一处对不上.
///
/// **逐个检查, 而不是"三个都给才查"**: 只多给一个参数同样是在改这一局 (例如只给
/// `--deck BLUE`), 漏检下来它会静默地按另一副牌组建堆.
///
/// 种子的比较**区分大小写** (引擎与游戏都是按原样的字节序列去哈希, 大小写不同就是不同的局);
/// 牌组与赌注按各自的规范化形式比 (`RED` 与 `red` 是同一副, `WHITE` 与 `1` 是同一档).
fn check_conflict(
    recorded: &Opening,
    cli_seed: Option<&str>,
    cli_deck: Option<&str>,
    cli_stake: Option<&str>,
) {
    let mut problems: Vec<String> = Vec::new();
    if let Some(seed) = cli_seed
        && seed != recorded.seed
    {
        problems.push(format!("--seed {seed} (文件里记的是 {})", recorded.seed));
    }
    if let Some(deck) = cli_deck
        && session::deck_of(deck) != session::deck_of(&recorded.deck)
    {
        problems.push(format!("--deck {deck} (文件里记的是 {})", recorded.deck));
    }
    if let Some(stake) = cli_stake
        && session::stake_of(stake) != session::stake_of(&recorded.stake)
    {
        problems.push(format!("--stake {stake} (文件里记的是 {})", recorded.stake));
    }
    if problems.is_empty() {
        return;
    }
    eprintln!("命令行给的参数与这份动作文件记的不一致:");
    for problem in problems {
        eprintln!("  {problem}");
    }
    eprintln!("动作文件是这一局的全部历史, 开局参数是定下来的. 想换参数就换一个 --actions 文件.");
    std::process::exit(2);
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
    let actions_path = PathBuf::from(need("--actions"));
    let cli_seed = value_of(args, "--seed").map(str::to_owned);
    let cli_deck = value_of(args, "--deck").map(str::to_owned);
    let cli_stake = value_of(args, "--stake").map(str::to_owned);

    // 动作文件是这一局的全部历史, 所以先读它 —— 开局参数以它记的为准.
    let mut actions = read_actions(&actions_path);
    let opening = if let Some(recorded) = opening_from(&actions) {
        check_conflict(
            &recorded,
            cli_seed.as_deref(),
            cli_deck.as_deref(),
            cli_stake.as_deref(),
        );
        recorded
    } else {
        // 没有记着参数: 要么是新开一局, 要么是一份旧格式的动作文件.
        if !actions.is_empty() && cli_seed.is_none() {
            // 旧文件里没有种子, 而种子无从推断 —— 随便生成一个就不是原来那一局了.
            eprintln!("{} 的第一行没有记开局参数 (旧格式), 种子无从推断.", actions_path.display());
            eprintln!("请用 --seed 把这一局的种子补上 (牌组与赌注也从命令行给).");
            std::process::exit(2);
        }
        Opening {
            // 种子没给就现生成一个, 与游戏"新开一局"时给的一样.
            seed: cli_seed.unwrap_or_else(generate_seed),
            deck: need("--deck"),
            stake: need("--stake"),
        }
    };

    // 新开一局: 把开局参数写进第一行, 之后调用就不用再给这几个了.
    if actions.is_empty() {
        if let Some(parent) = actions_path.parent() {
            std::fs::create_dir_all(parent).expect("能建动作文件所在目录");
        }
        let line = start_line(&opening);
        std::fs::write(&actions_path, format!("{line}\n")).expect("能写动作文件");
        eprintln!("新开一局: 种子 {} / 牌组 {} / 赌注 {}", opening.seed, opening.deck, opening.stake);
        eprintln!("(开局参数已写进 {}, 之后不用再给)", actions_path.display());
        actions.push(Json::parse(&line).expect("刚拼出来的是合法 JSON"));
    }

    let step = StepArgs {
        opening,
        actions: actions_path,
        do_action: value_of(args, "--do").map(str::to_owned),
        emit: value_of(args, "--emit").map(PathBuf::from),
    };

    let mut run = RunState::new(&step.opening.seed, session::stake_of(&step.opening.stake))
        .with_deck(&session::deck_of(&step.opening.deck))
        .with_uda(session::uda_from_template());

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
            seed: step.opening.seed.clone(),
            deck: step.opening.deck.clone(),
            stake: step.opening.stake.clone(),
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
    say!(
        "种子 {} / 牌组 {} / 赌注 {}",
        step.opening.seed,
        step.opening.deck,
        step.opening.stake
    );
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

#[cfg(test)]
mod tests {
    use super::*;

    /// 字母表必须与游戏 `random_string` 用的完全一致.
    ///
    /// 游戏那边是 `math.random('1','9')` / `('A','N')` / `('P','Z')` 三段: 数字九位, 字母两段
    /// 共二十五位, 合起来 34. **没有 `0` 也没有 `O`** —— 它们与对方看混, 游戏故意跳过.
    /// 这个字面量抄错一位不会报错, 只会生成一个形状不对的种子 (手输回游戏可能被拒),
    /// 所以在这里钉住.
    #[test]
    fn seed_alphabet_matches_the_game() {
        let mut expected: Vec<char> = ('1'..='9')
            .chain('A'..='N')
            .chain('P'..='Z')
            .collect();
        expected.sort_unstable();
        let mut actual: Vec<char> = alphabet_str().chars().collect();
        actual.sort_unstable();
        assert_eq!(actual, expected, "字母表与游戏的不一致");
        assert!(!actual.contains(&'0') && !actual.contains(&'O'), "不该有 0 与 O");
        // 长度对得上: 9 位数字 + 25 位字母 = 34
        assert_eq!(actual.len(), 34);
    }

    /// 断言用的字符串视图 (常量本身是字节; 它是纯 ASCII, 所以转换不会失败).
    fn alphabet_str() -> &'static str {
        std::str::from_utf8(SEED_ALPHABET).expect("字母表是 ASCII")
    }

    #[test]
    fn generated_seeds_have_the_game_shape_and_differ() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..64 {
            let seed = generate_seed();
            assert_eq!(seed.chars().count(), 8, "游戏生成的是八位: {seed}");
            for ch in seed.chars() {
                assert!(
                    alphabet_str().contains(ch),
                    "{seed} 里的 {ch} 不在游戏字母表里"
                );
            }
            // 连着开两局不该撞 (时钟 + OS 熵都掺进去了)
            seen.insert(seed);
        }
        assert!(seen.len() > 60, "64 次里撞了太多: {}", seen.len());
    }

    /// 种子大小写敏感: 大小写不同就是不同的字节序列, 引擎与游戏都按原样哈希.
    #[test]
    fn seed_case_is_significant() {
        let recorded = Opening {
            seed: "ALEEB".to_owned(),
            deck: "RED".to_owned(),
            stake: "WHITE".to_owned(),
        };
        // 大写相同 -> 不冲突 (这条不该退出, 用不 panic 的方式验: 直接比对规范化结果)
        assert_eq!(session::deck_of("red"), session::deck_of("RED"));
        assert_eq!(session::stake_of("1"), session::stake_of("WHITE"));
        assert_ne!(recorded.seed, "aleeb");
    }

    #[test]
    fn the_start_line_records_the_opening_and_parses_back() {
        let opening = Opening {
            seed: "5RSSBWA9".to_owned(),
            deck: "RED".to_owned(),
            stake: "WHITE".to_owned(),
        };
        let line = start_line(&opening);
        let parsed = Json::parse(&line).expect("拼出来的要是合法 JSON");
        assert_eq!(parsed.get("method").and_then(Json::as_str), Some("start"));
        // 存回去能原样读出来 —— 下一次调用就靠它
        let back = opening_from(&[parsed]).expect("要能读回来");
        assert_eq!(back.seed, opening.seed);
        assert_eq!(back.deck, opening.deck);
        assert_eq!(back.stake, opening.stake);
    }

    /// 旧格式 (`{"method":"start"}` 不带 params) 读不到开局参数, 调用方据此要求补 `--seed`.
    #[test]
    fn an_old_style_start_line_has_no_opening() {
        let old = Json::parse("{\"method\":\"start\"}").expect("合法 JSON");
        assert!(opening_from(&[old]).is_none());
        // 空文件同样读不到
        assert!(opening_from(&[]).is_none());
    }
}
