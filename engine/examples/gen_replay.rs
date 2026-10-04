//! 生成一份回放文件, 用来**在真游戏里复现引擎走过的一局**.
//!
//! # 它解决什么
//!
//! 对拍一直以来是"游戏怎么走, 引擎跟不跟得上": 引擎只能照着录像重放, 覆盖哪条路径全看
//! 录像里恰好有什么. 这个工具把方向反过来 —— **引擎先走一遍并写下每一步的预测状态**,
//! 然后由游戏照着重放:
//!
//! ```text
//! 引擎: 选盲注 -> 出牌 -> 领结算 -> 下一回合 -> ...   每步写一条 digest
//! 游戏: just macos replay <生成的文件>                逐步核对 digest
//!       退出码 0 = 引擎全程预测正确, 1 = 在第 N 步跑偏 (日志里有差在哪)
//! ```
//!
//! 好处是**覆盖面不再受录像限制**: 换一个种子 / 牌组 / 赌注就是一条新路径, 而不用等人去玩.
//!
//! # 用法
//!
//! ```shell
//! cargo run --release --example gen_replay -- \
//!     --seed ALEEB --deck PLASMA --stake GOLD \
//!     --template recordings/20261004-021907-LG7RIX92/20261004-021907-LG7RIX92.replay.json \
//!     --out .tmp/gen/ALEEB.replay.json --steps 120
//! ```
//!
//! 然后把 `--out` 指出的那个文件夹 (或文件) 交给 `just macos replay`.
//!
//! # 为什么要 `--template`
//!
//! 回放文件里有 `snapshot` 段 (存档进度 / 解锁 / 发现), 而那是 LÖVE 自己的序列化格式 ——
//! 引擎造不出来, 也不该造. 这一份直接从**一份真实录像**里借: 它记的是"这个档解锁了什么",
//! 与种子, 牌组, 赌注都无关 (录像那份是全解锁的, 所以任何组合都能用).
//!
//! # 策略
//!
//! 只用四个动作: `select` / `play` / `cash_out` / `next_round`. 买单卖牌开包一律不做 ——
//! 这样路径最短, 而它验的正是**最容易错的那一层**: 发牌, 洗牌, 计分, 结算, 商店生成.
//! 想覆盖商店交易时再往里加动作即可 (端点的名字与参数见 `docs/agent-api.md`).

use std::collections::HashMap;
use std::path::PathBuf;

use balatro_engine::data::json::Json;
use balatro_engine::run::{Phase, RunState, digest};
use balatro_engine::scoring::EvalEnv;

/// 赌注的显示名换档位 (白 1 ... 金 8).
fn stake_of(name: &str) -> i64 {
    match name {
        "WHITE" => 1,
        "RED" => 2,
        "GREEN" => 3,
        "BLACK" => 4,
        "BLUE" => 5,
        "PURPLE" => 6,
        "ORANGE" => 7,
        "GOLD" => 8,
        other => panic!("没见过的赌注 {other}"),
    }
}

/// 牌组的显示名换内部键.
fn deck_of(name: &str) -> String {
    if name.starts_with("b_") {
        return name.to_owned();
    }
    format!("b_{}", name.to_lowercase())
}

/// 从模板里取 `snapshot.uda`, 读成引擎要的 `原型键 -> 标记`.
fn uda_from(template: &str) -> HashMap<String, String> {
    let parsed = Json::parse(template).expect("模板能解析");
    let snapshot = parsed.get("snapshot").expect("模板里有 snapshot");
    match snapshot.get("uda") {
        Some(Json::Object(entries)) => entries
            .iter()
            .filter_map(|(key, value)| value.as_str().map(|flags| (key.clone(), flags.to_owned())))
            .collect(),
        other => panic!("模板的 uda 应当是个对象, 实际 {other:?}"),
    }
}

struct Args {
    seed: String,
    deck: String,
    stake: String,
    template: PathBuf,
    out: PathBuf,
    steps: usize,
}

fn parse_args() -> Args {
    let mut seed = None;
    let mut deck = None;
    let mut stake = None;
    let mut template = None;
    let mut out = None;
    let mut steps = 120usize;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().unwrap_or_else(|| panic!("{arg} 后面缺一个值"));
        match arg.as_str() {
            "--seed" => seed = Some(value()),
            "--deck" => deck = Some(value()),
            "--stake" => stake = Some(value()),
            "--template" => template = Some(PathBuf::from(value())),
            "--out" => out = Some(PathBuf::from(value())),
            "--steps" => steps = value().parse().expect("--steps 是个整数"),
            other => panic!("不认识的参数 {other}"),
        }
    }
    Args {
        seed: seed.expect("要给 --seed"),
        deck: deck.expect("要给 --deck"),
        stake: stake.expect("要给 --stake"),
        template: template.expect("要给 --template"),
        out: out.expect("要给 --out"),
        steps,
    }
}

fn main() {
    let args = parse_args();
    let template = std::fs::read_to_string(&args.template).unwrap_or_else(|error| {
        panic!("读不到模板 {}: {error}", args.template.display())
    });

    let mut run = RunState::new(&args.seed, stake_of(&args.stake)).with_deck(&deck_of(&args.deck));
    run.uda = uda_from(&template);
    run.start_run();

    let env = EvalEnv::default();
    let back = run.back_effect();
    let mut actions: Vec<String> = Vec::new();
    let mut wall = 0.0f64;

    // 记一步: 动作 + **引擎预测的状态**. digest 就是回放文件里那种格式,
    // 游戏重放时会拿它逐步核对 (见 `mods/bbreplay/replay/player.lua` 的比较那一段).
    let mut record = |run: &RunState, method: &str, params: Option<String>, actions: &mut Vec<String>| {
        wall += 1.5;
        let mut parts = vec![format!("\"method\":\"{method}\"")];
        if let Some(params) = params {
            parts.push(format!("\"params\":{params}"));
        }
        parts.push(format!("\"digest\":{}", quote(&digest::digest(run))));
        parts.push(format!("\"wall\":{wall}"));
        parts.push("\"ok\":true".to_owned());
        actions.push(format!("{{{}}}", parts.join(",")));
    };

    for step in 0..args.steps {
        match run.phase {
            Phase::GameOver => {
                eprintln!("第 {step} 步: 这一局结束了 (底注 {})", run.ante);
                break;
            }
            Phase::BlindSelect => {
                run.select_blind();
                record(&run, "select", None, &mut actions);
            }
            Phase::SelectingHand => {
                // 手里连一对都没有、又还有弃牌次数时, 先**弃掉点数最小的几张**换牌 ——
                // 不换的话这一局基本过不了第一个盲注, 于是回放只有十来步, 覆盖不到商店.
                let cards = if !has_pair(&run) && run.discards_left > 0 {
                    match choose_discard(&run) {
                        Some(cards) => {
                            let params = format!(
                                "{{\"cards\":[{}]}}",
                                cards
                                    .iter()
                                    .map(|card| card.to_string())
                                    .collect::<Vec<_>>()
                                    .join(",")
                            );
                            run.discard(&cards).expect("弃得成 (上面查过还有次数)");
                            record(&run, "discard", Some(params), &mut actions);
                            continue;
                        }
                        None => choose_play(&run),
                    }
                } else {
                    choose_play(&run)
                };
                if cards.is_empty() {
                    eprintln!("第 {step} 步: 手里没牌了");
                    break;
                }
                let params = format!(
                    "{{\"cards\":[{}]}}",
                    cards
                        .iter()
                        .map(|card| card.to_string())
                        .collect::<Vec<_>>()
                        .join(",")
                );
                match run.play(&cards, &env, back) {
                    Ok(_) => record(&run, "play", Some(params), &mut actions),
                    Err(error) => {
                        eprintln!("第 {step} 步: 出牌失败 {error:?}");
                        break;
                    }
                }
            }
            Phase::RoundEval => {
                run.cash_out().expect("结算屏上领得成");
                record(&run, "cash_out", None, &mut actions);
            }
            Phase::Shop => {
                run.next_round().expect("在商店里走得成");
                record(&run, "next_round", None, &mut actions);
            }
            Phase::BoosterOpened => {
                // 这一版不开包 (策略里没有买包的动作), 所以走不到这里.
                eprintln!("第 {step} 步: 意外进了开包阶段");
                break;
            }
        }
    }

    let file = render(&template, &args, &actions);
    if let Some(parent) = args.out.parent() {
        std::fs::create_dir_all(parent).expect("能建输出目录");
    }
    std::fs::write(&args.out, file).expect("能写输出文件");
    eprintln!(
        "写出 {} (种子 {} / {} / {}, {} 步, 终局底注 {})",
        args.out.display(),
        args.seed,
        args.deck,
        args.stake,
        actions.len(),
        run.ante
    );
}

/// 手里有没有一对 (同点数的两张).
fn has_pair(run: &RunState) -> bool {
    let mut seen = std::collections::BTreeSet::new();
    run.hand
        .iter()
        .any(|card| !seen.insert(card.card.rank.nominal() as u8))
}

/// 弃牌策略: 丢掉点数最小的三张 (手里牌不够三张就有几张丢几张).
fn choose_discard(run: &RunState) -> Option<Vec<usize>> {
    if run.hand.len() < 3 {
        return None;
    }
    let mut order: Vec<usize> = (0..run.hand.len()).collect();
    order.sort_by(|a, b| run.hand[*a].card.nominal().total_cmp(&run.hand[*b].card.nominal()));
    order.truncate(3);
    order.sort_unstable();
    Some(order)
}

/// 出牌策略: **凑牌型**而不是随手出.
///
/// 为什么要认真挑: 随便出五张只能凑出"高牌", 底注 1 的盲注都过不去, 于是这一局十来步就结束 ——
/// 那样的回放只覆盖了开局发牌, 验不到商店与后续底注. 这里的做法是"张数最多的那个点数优先,
/// 同张数取点数大的", 补上剩下的最大的牌凑满五张 —— 能稳定出对子 / 三条 / 葫芦 / 四条.
///
/// 它**不是**要打得好看: 目标只是把流程走到更深处, 让每一步都成为一次真实的预测.
fn choose_play(run: &RunState) -> Vec<usize> {
    use std::collections::BTreeMap;
    if run.hand.is_empty() {
        return Vec::new();
    }
    // 按点数分组: 点数 -> 手里的下标.
    let mut groups: BTreeMap<u8, Vec<usize>> = BTreeMap::new();
    for (index, card) in run.hand.iter().enumerate() {
        groups
            .entry(card.card.rank.nominal() as u8)
            .or_default()
            .push(index);
    }
    // 张数最多的一组; 张数相同时取点数大的 (BTreeMap 的键是升序, 所以从后往前找).
    let mut best: Vec<usize> = Vec::new();
    for (_, indexes) in groups.iter().rev() {
        if indexes.len() > best.len() {
            best = indexes.clone();
        }
    }
    // 补上剩下点数最大的牌, 凑满五张.
    let mut rest: Vec<usize> = (0..run.hand.len())
        .filter(|index| !best.contains(index))
        .collect();
    rest.sort_by(|a, b| run.hand[*b].card.nominal().total_cmp(&run.hand[*a].card.nominal()));
    for index in rest {
        if best.len() >= 5 {
            break;
        }
        best.push(index);
    }
    best.sort_unstable();
    best
}

/// 把一段字符串写成 JSON 字面量.
fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if (ch as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

/// 拼出整份回放文件.
///
/// 除了 `run` / `actions` / `result`, 其余字段 (含 `snapshot`) **原样取自模板** ——
/// 那些是游戏自己的东西 (存档格式, 版本号, 录像元信息), 引擎既造不出也不该造.
fn render(template: &str, args: &Args, actions: &[String]) -> String {
    let parsed = Json::parse(template).expect("模板能解析");
    let Json::Object(entries) = parsed else {
        panic!("模板顶层应当是个对象");
    };
    let deck_key = deck_of(&args.deck);
    let mut fields: Vec<String> = Vec::new();
    for (key, value) in entries {
        match key.as_str() {
            // 这三样由我们提供.
            "run" | "actions" | "result" | "recorded_at" | "source" => continue,
            other => fields.push(format!("{}:{}", quote(other), json_of(&value))),
        }
    }
    // `run` 段: 开局参数. `deck_key` 是引擎认的内部键, 游戏用它加载牌组.
    fields.push(format!(
        "\"run\":{{\"deck\":{},\"stake\":{},\"seed\":{},\"seeded\":true,\
         \"resumed\":false,\"deck_key\":{},\"tutorial\":false}}",
        quote(&args.deck.to_uppercase()),
        quote(&args.stake.to_uppercase()),
        quote(&args.seed),
        quote(&deck_key),
    ));
    fields.push(format!("\"source\":{}", quote("engine-generated")));
    fields.push("\"result\":{\"reason\":\"engine\",\"won\":false}".to_owned());
    fields.push(format!("\"actions\":[{}]", actions.join(",\n")));
    format!("{{{}}}", fields.join(",\n"))
}

/// 把解析出来的 JSON 再写回去 (模板的字段原样带上).
fn json_of(value: &Json) -> String {
    match value {
        Json::Null => "null".to_owned(),
        Json::Bool(flag) => flag.to_string(),
        Json::Number(number) => {
            if number.fract() == 0.0 && number.abs() < 1e15 {
                format!("{}", *number as i64)
            } else {
                format!("{number}")
            }
        }
        Json::String(text) => quote(text),
        Json::Array(items) => format!(
            "[{}]",
            items.iter().map(json_of).collect::<Vec<_>>().join(",")
        ),
        Json::Object(entries) => format!(
            "{{{}}}",
            entries
                .iter()
                .map(|(key, value)| format!("{}:{}", quote(key), json_of(value)))
                .collect::<Vec<_>>()
                .join(",")
        ),
    }
}
