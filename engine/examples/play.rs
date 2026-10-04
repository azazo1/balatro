//! 让 **agent 自己在引擎里对局**: 读局面, 下一条指令, 再看新局面.
//!
//! # 为什么需要它
//!
//! `gen_replay` 里写死了一套贪心策略 (能买就买, 打最左几张), 引擎自己跑完就吐一个回放文件.
//! 那**没有判断**: 它走得浅 (常在底注 1-3 就输掉), 也碰不到需要取舍的分支.
//!
//! 这个工具把决策权交出去: 每调用一次, 它把之前记下的动作**从头重放一遍** (引擎是确定性的,
//! 同种子同动作必然得到同局面), 然后打印当前局面与可选动作. agent 看清之后自己决定下一步,
//! 把那条动作追加到动作文件里, 再调一次. 一路打到终局, 就得到一份**由 agent 亲自打出来**的
//! 完整对局记录.
//!
//! 从头重放而不是常驻进程, 是因为 agent 的一步就是**一次独立的命令调用** ——
//! 不需要长连接, 也不怕中途断开. 一局几十步, 每步重放一次也就几十毫秒.
//!
//! # 用法
//!
//! ```shell
//! # 1. 开局 (动作文件还不存在时会自动开始并写第一行)
//! engine/target/release/examples/play --seed AGENT1 --deck RED --stake GOLD \
//!     --actions .tmp/agent/AGENT1.actions.jsonl
//!
//! # 2. 追加一条动作 (动作会写进动作文件, 然后重放并打印新局面)
//! engine/target/release/examples/play --seed AGENT1 --deck RED --stake GOLD \
//!     --actions .tmp/agent/AGENT1.actions.jsonl --do '{"method":"select"}'
//! ```
//!
//! 动作的 `method` / `params` 与回放文件里的一致 (见 `docs/agent-api.md`):
//! `select` / `skip` / `reroll_boss` / `play` / `discard` / `rearrange` / `sort_hand_suit` /
//! `sort_hand_value` / `cash_out` / `next_round` / `reroll` / `buy` / `sell` / `use` / `pack`.
//!
//! 中文提示会打印在 stderr, 局面与动作清单在 stdout, 所以 `--do` 的脚本可以只读 stdout.

use std::collections::HashMap;
use std::path::PathBuf;

use balatro_engine::data::json::Json;
use balatro_engine::run::blind::{make_blind, plain_blind_key};
use balatro_engine::run::digest::{digest, state_name};
use balatro_engine::run::BlindKind;
use balatro_engine::run::{ActionError, Phase, RunState};
use balatro_engine::scoring::EvalEnv;

struct Args {
    seed: String,
    deck: String,
    stake: String,
    actions: PathBuf,
    do_action: Option<String>,
    show_packs: bool,
    /// 给了就把这局导出成游戏能回放的文件 (用于对拍).
    emit: Option<PathBuf>,
}

fn parse_args() -> Args {
    let (mut seed, mut deck, mut stake, mut actions, mut do_action) = (None, None, None, None, None);
    let (mut show_packs, mut emit) = (false, None);
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().unwrap_or_else(|| panic!("{arg} 后面缺一个值"));
        match arg.as_str() {
            "--seed" => seed = Some(value()),
            "--deck" => deck = Some(value()),
            "--stake" => stake = Some(value()),
            "--actions" => actions = Some(PathBuf::from(value())),
            "--do" => do_action = Some(value()),
            "--packs" => show_packs = true,
            "--emit" => emit = Some(PathBuf::from(value())),
            other => panic!("不认识的参数 {other}"),
        }
    }
    Args {
        seed: seed.expect("要给 --seed"),
        deck: deck.expect("要给 --deck"),
        stake: stake.expect("要给 --stake"),
        actions: actions.expect("要给 --actions"),
        do_action,
        show_packs,
        emit,
    }
}

fn stake_of(name: &str) -> i64 {
    for (index, candidate) in
        ["WHITE", "RED", "GREEN", "BLACK", "BLUE", "PURPLE", "ORANGE", "GOLD"]
            .iter()
            .enumerate()
        {
        if candidate.eq_ignore_ascii_case(name) {
            return index as i64 + 1;
        }
    }
    name.parse().expect("赌注要么是档位数字, 要么是 WHITE..GOLD")
}

fn deck_of(name: &str) -> String {
    if name.starts_with("b_") {
        name.to_owned()
    } else {
        format!("b_{}", name.to_lowercase())
    }
}

/// 从模板录像里取存档进度表 (`snapshot.uda`) —— 它记的是"这个档解锁了什么",
/// 与种子 / 牌组 / 赌注都无关, 而少了它池子里会多出占位格子, 抽出来的东西整体偏.
fn uda_from_template() -> HashMap<String, String> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../recordings/20261003-222131-ALEEB/20261003-222131-ALEEB.replay.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("读不到模板 {}: {error}", path.display()));
    let parsed = Json::parse(&text).expect("模板能解析");
    match parsed.get("snapshot").and_then(|s| s.get("uda")) {
        Some(Json::Object(entries)) => entries
            .iter()
            .filter_map(|(key, value)| value.as_str().map(|flags| (key.clone(), flags.to_owned())))
            .collect(),
        other => panic!("模板的 uda 应当是个对象, 实际 {other:?}"),
    }
}

fn numbers_of(value: Option<&Json>) -> Vec<usize> {
    match value {
        Some(Json::Array(items)) => items
            .iter()
            .filter_map(|item| item.as_f64().map(|n| n as usize))
            .collect(),
        _ => Vec::new(),
    }
}

fn amount(params: Option<&Json>, field: &str) -> Option<f64> {
    params.and_then(|p| p.get(field)).and_then(Json::as_f64)
}

/// 执行一条动作. 与 `dump_replay` 里那个 `apply_step` 是同一套语义 ——
/// 这里刻意保持一致的参数键 (`pack` 用单数 `card`, 与 `play` 的复数 `cards` 不同),
/// 否则同一条记录在两边会解释成不同的意思.
fn apply_step(step: &Json, run: &mut RunState, env: &EvalEnv) -> Result<String, ActionError> {
    let method = step.get("method").and_then(Json::as_str).expect("有 method");
    let back = run.back_effect();
    let params = step.get("params");
    let cards = numbers_of(params.and_then(|p| p.get("cards")));
    match method {
        "start" => {
            run.start_run();
            Ok("开局".to_owned())
        }
        "select" => run.select_blind().map(|()| "选了这个盲注".to_owned()),
        "skip" => run.skip_blind().map(|tag| format!("跳过盲注, 拿到标签 {tag}")),
        "reroll_boss" => run.reroll_boss().map(|cost| format!("重掷 Boss, 花了 {cost}")),
        "discard" => run
            .discard(&cards)
            .map(|()| format!("弃掉 {cards:?}")),
        "play" => run.play(&cards, env, back).map(|result| {
            // 把牌型与筹码/倍率的分项都打出来 —— agent 靠这个才能"学会"这一手为什么是这个分,
            // 而不是只看一个总数去猜.
            format!(
                "打 {cards:?} -> {:.0} 分 | 牌型 {:?} | 筹码 {:.0} 倍率 {:.1} (基础 {:.0}/{:.1}, 计分牌 {:?})",
                result.total,
                result.hand,
                result.chips,
                result.mult,
                result.base_chips,
                result.base_mult,
                result.scoring_cards
            )
        }),
        "rearrange" => {
            if let Some(order) = params.and_then(|p| p.get("hand")) {
                run.rearrange_hand(&numbers_of(Some(order)))
                    .map(|()| "重排手牌".to_owned())
            } else if let Some(order) = params.and_then(|p| p.get("jokers")) {
                run.rearrange_jokers(&numbers_of(Some(order)))
                    .map(|()| "重排小丑".to_owned())
            } else {
                let order = params.and_then(|p| p.get("consumables"));
                run.rearrange_consumables(&numbers_of(order))
                    .map(|()| "重排消耗牌".to_owned())
            }
        }
        "sort_hand_suit" => {
            run.sort_hand_by_suit();
            Ok("按花色排手牌".to_owned())
        }
        "sort_hand_value" => {
            run.sort_hand_by_value();
            Ok("按点数排手牌".to_owned())
        }
        "cash_out" => run.cash_out().map(|gained| format!("结算, 进账 {gained}")),
        "next_round" => run.next_round().map(|()| "离开商店".to_owned()),
        "reroll" => run.reroll_shop().map(|cost| format!("重抽货架, 花了 {cost}")),
        "buy" => {
            let Some(shop) = run.shop.as_ref() else {
                return Err(ActionError::NotInPhase {
                    expected: Phase::Shop,
                    actual: run.phase,
                });
            };
            // 三种目标: `card` (小丑 / 消耗牌那一格), `voucher`, `pack`.
            let picked = if let Some(slot) = amount(params, "voucher") {
                shop.voucher
                    .clone()
                    .or_else(|| shop.extra_voucher.clone())
                    .ok_or(ActionError::BadIndex(slot as usize))
            } else if let Some(slot) = amount(params, "pack") {
                shop.packs
                    .get(slot as usize)
                    .cloned()
                    .ok_or(ActionError::BadIndex(slot as usize))
            } else {
                let slot = amount(params, "card").unwrap_or(0.0) as usize;
                shop.jokers
                    .get(slot)
                    .cloned()
                    .ok_or(ActionError::BadIndex(slot))
            }?;
            let _ = method;
            run.buy(&picked)
                .map(|cost| format!("买下 {} (花了 {cost})", picked.key))
        }
        "sell" => {
            if let Some(slot) = amount(params, "joker") {
                run.sell_joker(slot as usize)
                    .map(|gain| format!("卖掉小丑, 回收 {gain}"))
            } else {
                let slot = amount(params, "consumable").unwrap_or(0.0) as usize;
                run.sell_consumable(slot)
                    .map(|gain| format!("卖掉消耗牌, 回收 {gain}"))
            }
        }
        "use" => {
            let slot = amount(params, "consumable").unwrap_or(0.0) as usize;
            let targets = numbers_of(params.and_then(|p| p.get("cards")));
            run.use_consumable(slot, &targets)
                .map(|()| format!("用掉第 {slot} 张消耗牌 (目标 {targets:?})"))
        }
        "pack" => {
            if params.and_then(|p| p.get("skip")).and_then(Json::as_bool) == Some(true) {
                return run.skip_pack().map(|()| "跳过这个包".to_owned());
            }
            let slot = amount(params, "card").unwrap_or(0.0) as usize;
            let targets = numbers_of(params.and_then(|p| p.get("targets")));
            // `bbcore` 的 `pack` 端点是"取出来并**立即使用**", 所以这里走同一条:
            // 塔罗改的是手牌, 而关包会把整手牌收回牌堆, 所以顺序反了那两张就改不到.
            run.take_and_use_from_pack(slot, &targets)
                .map(|key| format!("从包里取走并使用 {key}"))
        }
        _ => Err(ActionError::NotImplemented("这个动作")),
    }
}

fn main() {
    let args = parse_args();
    let mut run = RunState::new(&args.seed, stake_of(&args.stake))
        .with_deck(&deck_of(&args.deck))
        .with_uda(uda_from_template());

    // 动作文件是**这份对局的全部历史**. 不存在就当开局: 建堆 + 写第一行 `start`.
    let mut actions: Vec<Json> = Vec::new();
    if args.actions.is_file() {
        for line in std::fs::read_to_string(&args.actions).unwrap_or_default().lines() {
            if line.trim().is_empty() {
                continue;
            }
            actions.push(Json::parse(line).unwrap_or_else(|e| panic!("动作文件里这行不是 JSON: {line} ({e})")));
        }
    } else if let Some(parent) = args.actions.parent() {
        std::fs::create_dir_all(parent).expect("能建动作文件所在目录");
        actions.push(Json::parse("{\"method\":\"start\"}").expect("内建的是合法 JSON"));
        std::fs::write(&args.actions, "{\"method\":\"start\"}\n").expect("能写动作文件");
    }

    let env = EvalEnv::default();

    // 导出用: 每一步一个片段 (动作 + **引擎预测的这一步之后的状态**).
    //
    // `digest` 就是回放器逐步核对的那个字符串 —— 游戏重放这局时, 每做完一步都拿它和文件里的
    // 对比, 对不上就判定"状态不一致"并停下. 所以这一份导出的回放同时也是对拍用的**断言集**.
    let mut records: Vec<String> = Vec::new();
    let mut wall = 0.0f64;

    // 先重放已有历史. 任何一步失败都直接停下 —— 那说明动作文件与引擎对不上,
    // 继续往下走只会把错误叠加到后面每一步.
    // 每一步的结果都打一行 —— `PLAY_VERBOSE` 设了就打往 stderr, 便于复盘"这一手为什么是这个分".
    let verbose = std::env::var("PLAY_VERBOSE").is_ok();
    for (index, step) in actions.iter().enumerate() {
        let method = step.get("method").and_then(Json::as_str).unwrap_or("?");
        match apply_step(step, &mut run, &env) {
            Ok(what) => {
                if verbose {
                    eprintln!("  [{}] {method}: {what}", index + 1);
                }
                // `start` 不进回放文件: 游戏那边开局参数走 `run` 段, 不认这条动作.
                if method != "start" {
                    wall += 1.5;
                    records.push(record_of(step, &run, wall));
                }
            }
            Err(error) => {
                // 重放失败意味着这个动作文件**已经不是**能被引擎复现的历史了. 这是最要命的一类
                // 错误 (继续往下走会把偏差叠加到后面每一步), 所以这里要停, 并且直接把修复命令
                // 给出来 —— 调用方多半是个 agent, 它需要的是"做什么", 不是"哪里错了".
                eprintln!("重放第 {} 步 ({method}) 失败: {error:?}", index + 1);
                eprintln!("{}", explain(&error, &run));
                eprintln!(
                    "这份动作文件的前 {} 步是好的. 想从这里继续, 就把它截断到前 {} 行:\n  \
                     head -n {} {} > 新文件 && mv 新文件 {}",
                    index,
                    index,
                    index,
                    args.actions.display(),
                    args.actions.display()
                );
                std::process::exit(2);
            }
        }
    }

    // 新动作: **先执行, 成功了才落盘**.
    //
    // 反过来的话 (先写再执行), 一条被引擎拒绝的动作会留在历史里, 之后每次重放都会在同一个位置
    // 失败, 对局就废了 —— 得手工去删那一行. agent 犯错是常态 (我第一遍就误传了一条"没有弃牌
    // 次数时弃牌"的动作), 所以这里必须保证: 动作文件里永远只装**真的生效过**的动作.
    if let Some(text) = &args.do_action {
        let step = Json::parse(text).unwrap_or_else(|e| panic!("--do 不是合法 JSON: {e}"));
        match apply_step(&step, &mut run, &env) {
            Ok(what) => {
                use std::io::Write;
                let mut file = std::fs::OpenOptions::new()
                    .append(true)
                    .open(&args.actions)
                    .expect("能追加动作文件");
                writeln!(file, "{}", text.trim()).expect("能写动作文件");
                wall += 1.5;
                records.push(record_of(&step, &run, wall));
                eprintln!("刚做: {what}");
            }
            Err(error) => {
                // 报错要**说清这一步为什么不成立**, 并且明确告诉调用方历史没被污染 ——
                // agent 下一步就是照着这个反馈换一条动作, 它不该去猜要不要修文件.
                eprintln!("这一步没有生效: {error:?}");
                eprintln!("{}", explain(&error, &run));
                eprintln!("动作文件没有变化, 直接换一条动作重试即可.");
                std::process::exit(1);
            }
        }
    }

    if let Some(path) = &args.emit {
        let text = render_replay(&args, &records);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("能建回放文件所在目录");
        }
        std::fs::write(path, &text).expect("能写回放文件");
        eprintln!(
            "已导出回放: {} ({} 步, {} 字节)",
            path.display(),
            records.len(),
            text.len()
        );
        // 写出去就够了, 不再打印局面 —— 这一步的用途是拿文件去对拍.
        return;
    }

    print_state(&run, &args, actions.len() + usize::from(args.do_action.is_some()));
}

/// 拼一条动作记录: 动作本身 + 这一步**之后**引擎给出的 digest.
///
/// `digest` 是回放器拿去逐步核对的字符串, 所以它必须是"这一步做完之后"的状态 ——
/// 取早一步或晚一步都会让游戏在正确的地方报"状态不一致".
fn record_of(step: &Json, run: &RunState, wall: f64) -> String {
    let method = step.get("method").and_then(Json::as_str).unwrap_or("?");
    let mut parts = vec![format!("\"method\":{}", quote(method))];
    if let Some(params) = step.get("params") {
        parts.push(format!("\"params\":{}", json_of(params)));
    }
    parts.push(format!("\"digest\":{}", quote(&digest(run))));
    parts.push(format!("\"wall\":{wall}"));
    parts.push("\"ok\":true".to_owned());
    format!("{{{}}}", parts.join(","))
}

/// 拼出整份回放文件, 结构对齐真实录像.
///
/// `snapshot` 与版本号这类字段**原样取自模板**: 那是 LÖVE 自己的存档格式, 引擎既造不出也不该造.
/// 只覆盖 `run` (这局的开局参数), `actions` (agent 打的每一步) 与 `result`.
fn render_replay(args: &Args, records: &[String]) -> String {
    let template_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../recordings/20261003-222131-ALEEB/20261003-222131-ALEEB.replay.json");
    let template = std::fs::read_to_string(&template_path)
        .unwrap_or_else(|error| panic!("读不到模板 {}: {error}", template_path.display()));
    let parsed = Json::parse(&template).expect("模板能解析");
    let Json::Object(entries) = parsed else {
        panic!("模板顶层应当是个对象");
    };

    let mut fields: Vec<String> = Vec::new();
    for (key, value) in entries {
        match key.as_str() {
            "run" | "actions" | "result" | "recorded_at" | "source" => continue,
            // 快照里的 `settings` 要改一项, 不能整段照抄.
            "snapshot" => fields.push(format!("{}:{}", quote(&key), snapshot_of(&value))),
            _ => fields.push(format!("{}:{}", quote(&key), json_of(&value))),
        }
    }
    fields.push(format!(
        "\"run\":{{\"deck\":{},\"stake\":{},\"seed\":{},\"seeded\":true,\"resumed\":false,\
         \"deck_key\":{},\"tutorial\":false}}",
        quote(&args.deck.to_uppercase()),
        quote(&args.stake.to_uppercase()),
        quote(&args.seed),
        quote(&deck_of(&args.deck)),
    ));
    // 标 `agent-played` 而不是 `engine-generated`: 这两者的区别是**谁做的决定**.
    // `engine-generated` 是引擎里那套写死的贪心策略自己跑的; 这一份的每一步都是 agent
    // 看过局面之后选的. 混成一个标记就分不出产物的来源了.
    fields.push(format!("\"source\":{}", quote("agent-played")));
    fields.push("\"result\":{\"reason\":\"engine\",\"won\":false}".to_owned());
    fields.push(format!("\"actions\":[{}]", records.join(",\n")));
    format!("{{{}}}", fields.join(",\n"))
}

/// 快照照抄, 但把 `settings.GAMESPEED` 换成 4.
///
/// 回放开始时会用这里的 `settings` 覆盖游戏当前设置 (见 `mods/bbreplay/replay/snapshot.lua`
/// 的 `SETTING_KEYS` 与 `M.apply`), 所以**存档里改成 4 也没用** —— 只要这份快照写着 1,
/// 回放就还是 1 倍速. 模板来自一局正常速度的录像, 于是它记的就是 1.
///
/// 一局回放有几十上百步, 每一步都等完整动画就太慢了; 而倍率只影响动画快慢, 不改变任何状态,
/// 逐步比对的摘要因此不受影响. 所以这里明确写成 4.
fn snapshot_of(value: &Json) -> String {
    const GAMESPEED: f64 = 4.0;
    let Json::Object(entries) = value else {
        panic!("模板的 snapshot 应当是个对象");
    };
    let mut fields: Vec<String> = Vec::new();
    for (key, item) in entries {
        if key != "settings" {
            fields.push(format!("{}:{}", quote(key), json_of(item)));
            continue;
        }
        let Json::Object(settings) = item else {
            panic!("模板的 snapshot.settings 应当是个对象");
        };
        let mut inner: Vec<String> = Vec::new();
        let mut seen = false;
        for (name, setting) in settings {
            if name == "GAMESPEED" {
                seen = true;
                inner.push(format!("{}:{}", quote(name), GAMESPEED as i64));
            } else {
                inner.push(format!("{}:{}", quote(name), json_of(setting)));
            }
        }
        if !seen {
            inner.push(format!("{}:{}", quote("GAMESPEED"), GAMESPEED as i64));
        }
        fields.push(format!("{}:{{{}}}", quote(key), inner.join(",")));
    }
    format!("{{{}}}", fields.join(","))
}

fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
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

/// 把一个动作错误翻译成"该怎么办".
///
/// 引擎的 `ActionError` 是给实现者看的 (变体名 + 期望/实际的阶段), 而调用它的是个要**接着做决定**
/// 的 agent: 它需要知道"这个阶段允许哪些动作". 比如 `NoDiscardsLeft` 光看名字只会让人以为
/// 参数写错了, 实际是"这一回合的弃牌次数已经用光, 该出牌了".
fn explain(error: &ActionError, run: &RunState) -> String {
    let allowed = match run.phase {
        Phase::BlindSelect => "select | skip | reroll_boss",
        Phase::SelectingHand => "play | discard | rearrange | sort_hand_suit | sort_hand_value | use",
        Phase::RoundEval => "cash_out",
        Phase::Shop => "buy | reroll | sell | use | next_round",
        Phase::BoosterOpened => "pack | sell",
        Phase::GameOver => "这一局已经结束, 没有可做的动作",
    };
    match error {
        ActionError::NoDiscardsLeft => format!(
            "这一回合的弃牌次数用光了 (还剩 {} 次出牌). 直接出牌, 或换一张牌打.",
            run.hands_left
        ),
        ActionError::NoHandsLeft => "这一回合的出牌次数用光了, 这一局到此为止.".to_owned(),
        ActionError::NotInPhase { expected, actual } => format!(
            "动作要求处在 {expected:?}, 而现在是 {actual:?}. 当前可做: {allowed}"
        ),
        ActionError::BadIndex(index) => format!(
            "下标 {index} 越界了. 手牌 {} 张 (0..{}), 小丑 {} 张 (0..{}), 消耗牌 {} 张 (0..{}).",
            run.hand.len(),
            run.hand.len().saturating_sub(1),
            run.jokers.len(),
            run.jokers.len().saturating_sub(1),
            run.consumables.len(),
            run.consumables.len().saturating_sub(1)
        ),
        ActionError::NotEnoughMoney { cost, have } => {
            format!("钱不够: 要 {cost:.0}, 只有 {have:.0}.")
        }
        ActionError::NoCards => "一张牌都没选. 出牌与弃牌都要给 `cards`, 里面是手牌下标.".to_owned(),
        ActionError::TooManyCards { limit, got } => {
            format!("一次最多选 {limit} 张, 你给了 {got} 张.")
        }
        ActionError::TooFewCards { least, got } => {
            format!("一次至少要选 {least} 张, 你给了 {got} 张.")
        }
        ActionError::NoRoom { what, slots } => {
            format!("{what}没空位了 (共 {slots} 个). 先卖一张, 或换别的动作.")
        }
        ActionError::NotAllowed(why) => format!("这一步游戏本身不允许: {why}."),
        other => format!("引擎拒绝了这条动作 ({other:?}). 当前可做: {allowed}"),
    }
}

/// 把局面打成 agent 能读的样子. 只打**决策需要**的东西:
/// 阶段, 钱, 盲注与还差多少分, 手牌 (带下标 —— 出牌弃牌都用下标), 小丑, 消耗牌, 商店.
fn print_state(run: &RunState, args: &Args, steps: usize) {
    let phase = state_name(run.phase);
    // 选盲注阶段还没有盲注对象 (它是 select 那一刻才造的), 所以这里要**预告**下一步要打的
    // 那个盲注与它的目标 —— 不然这一行显示的是上一局的残留, 读的人会以为目标还是旧的.
    let blind = match run.blind.as_ref() {
        Some(blind) if run.phase != Phase::BlindSelect => format!(
            "{} ({}) 目标 {:.0} 已得 {:.0} 奖金 {}",
            blind.key,
            blind.kind.name(),
            blind.chips,
            run.chips,
            blind.dollars
        ),
        _ => {
            let kind = run.blind_on_deck;
            let key = match kind {
                BlindKind::Boss => run
                    .boss_key
                    .clone()
                    .unwrap_or_else(|| "(还没抽)".to_owned()),
                other => plain_blind_key(other).to_owned(),
            };
            let target = make_blind(
                kind,
                &key,
                run.ante,
                run.scaling,
                run.ante_scaling,
                run.no_blind_reward,
            );
            format!(
                "下一个待打: {} ({}) 目标 {:.0} 奖金 {}",
                key,
                kind.name(),
                target.chips,
                target.dollars
            )
        }
    };

    println!("=== 第 {steps} 步 | {phase} ===");
    println!("种子 {} / 牌组 {} / 赌注 {}", args.seed, args.deck, args.stake);
    println!(
        "底注 {} 回合 {} | 钱 {:.0} | 盲注: {blind}",
        run.ante, run.round, run.dollars
    );
    // 选盲注阶段**这一回合还没开始**, 那两项是上一回合的残留 (游戏那边同样是残留).
    // 显示残留会让人以为"这一回合只有这么几次", 所以这里改报这一回合**将要**拿到的次数.
    if run.phase == Phase::BlindSelect {
        println!(
            "这一回合会给: 出牌 {} 次, 弃牌 {} 次 | 手牌上限 {}",
            run.hands_per_round,
            run.discards_per_round,
            run.hand_size()
        );
    }
    println!(
        "出牌次数 {} 弃牌次数 {} | 小丑位 {}/{} 消耗位 {}/{}",
        run.hands_left,
        run.discards_left,
        run.jokers.len(),
        run.joker_capacity(),
        run.consumables.len(),
        run.consumable_capacity()
    );
    println!("牌堆 {} 张 | 弃牌堆 {} 张", run.deck.len(), run.discard_pile.len());

    if !run.hand.is_empty() {
        println!("手牌 (下标: 牌):");
        for (index, card) in run.hand.iter().enumerate() {
            println!("  {index}: {}", card_of(card));
        }
    }
    if !run.jokers.is_empty() {
        println!("小丑 (下标: 牌):");
        for (index, joker) in run.jokers.iter().enumerate() {
            println!("  {index}: {}", joker_token(joker));
        }
    }
    if !run.consumables.is_empty() {
        println!("消耗牌 (下标: 牌):");
        for (index, card) in run.consumables.iter().enumerate() {
            println!("  {index}: {}", card.key);
        }
    }

    match run.phase {
        Phase::Shop => {
            if let Some(shop) = run.shop.as_ref() {
                println!("商店:");
                for (index, card) in shop.jokers.iter().enumerate() {
                    println!("  card {index}: {} 价 {:.0}{}", card.key, card.cost, marks(card));
                }
                if let Some(voucher) = shop.voucher.as_ref() {
                    println!("  voucher: {} 价 {:.0}", voucher.key, voucher.cost);
                }
                if let Some(voucher) = shop.extra_voucher.as_ref() {
                    println!("  voucher(额外): {} 价 {:.0}", voucher.key, voucher.cost);
                }
                for (index, card) in shop.packs.iter().enumerate() {
                    println!("  pack {index}: {} 价 {:.0}", card.key, card.cost);
                }
                println!("  (重抽价 {:.0})", run.reroll_cost());
            }
        }
        Phase::BoosterOpened => {
            let left = run.open_pack.as_ref().map(|pack| pack.choices_left).unwrap_or(0);
            println!("包里 (还能挑 {left} 张, 下标: 牌):");
            let contents = run
                .open_pack
                .as_ref()
                .map(|pack| pack.contents.clone())
                .unwrap_or_default();
            for (index, card) in contents.iter().enumerate() {
                println!("  {index}: {}", pack_card_token(card));
            }
        }
        _ => {}
    }

    if args.show_packs {
        println!("(把所有包的内容都摊开看 —— 仅 --packs 时打印, 会消耗随机数, 只适合事后核对)");
    }

    println!("----");
    println!("digest: {}", digest(run));
    println!(
        "可选动作: {}",
        match run.phase {
            Phase::BlindSelect => "select | skip | reroll_boss",
            Phase::SelectingHand => "play {\"cards\":[..]} | discard {\"cards\":[..]} | rearrange | sort_hand_suit | sort_hand_value | use {\"consumable\":n,\"cards\":[..]}",
            Phase::RoundEval => "cash_out",
            Phase::Shop => "buy {\"card\":n} / buy {\"voucher\":true} / buy {\"pack\":n} | reroll | sell {\"joker\":n} | use {\"consumable\":n} | next_round",
            Phase::BoosterOpened => "pack {\"card\":n,\"targets\":[..]} | pack {\"skip\":true} | sell {\"joker\":n}",
            Phase::GameOver => "这一局结束了",
        }
    );
    println!("动作文件: {}", args.actions.display());
}

/// 这张牌计分时贡献多少筹码.
///
/// Balatro 里 J / Q / K 都是 10, A 是 11, 其余按点数 —— 我第一遍玩的时候按"K 是 13"去估分,
/// 结果每一步都估高, 于是判断全偏. 把它直接打出来, agent 就不用记这些数.
fn chip_value(card: &balatro_engine::cards::CardInstance) -> f64 {
    // 走 `to_hand_card` 而不是自己按点数算 —— 石头牌算 0, 加成牌的 +30 也算在里面,
    // 自己算会把这两种都算错.
    card.to_hand_card().chip_bonus()
}

fn marks(card: &balatro_engine::run::ShopCard) -> String {
    let mut marks = Vec::new();
    if card.eternal {
        marks.push("永恒");
    }
    if card.perishable {
        marks.push("易腐");
    }
    if card.rental {
        marks.push("租赁");
    }
    if let Some(edition) = card.edition {
        marks.push(match edition {
            balatro_engine::cards::Edition::Foil => "闪箔",
            balatro_engine::cards::Edition::Holo => "镭射",
            balatro_engine::cards::Edition::Polychrome => "多彩",
            balatro_engine::cards::Edition::Negative => "负片",
        });
    }
    if let Some(enh) = card.enhancement {
        marks.push(enh.key());
    }
    if marks.is_empty() {
        String::new()
    } else {
        format!(" [{}]", marks.join(" "))
    }
}

fn card_of(card: &balatro_engine::cards::CardInstance) -> String {
    let mut text = format!("{} (筹码 {})", card.card.key(), chip_value(card));
    if let Some(enh) = card.enhancement {
        text.push_str(&format!(" ({})", enh.key()));
    }
    if let Some(edition) = card.edition {
        text.push_str(&format!(" [{}]", match edition {
            balatro_engine::cards::Edition::Foil => "闪箔",
            balatro_engine::cards::Edition::Holo => "镭射",
            balatro_engine::cards::Edition::Polychrome => "多彩",
            balatro_engine::cards::Edition::Negative => "负片",
        }));
    }
    if let Some(seal) = card.seal {
        text.push_str(&format!(" [{}-封]", seal.key()));
    }
    if card.debuffed {
        text.push_str(" [被削]");
    }
    text
}

fn joker_token(joker: &balatro_engine::jokers::Joker) -> String {
    let mut text = joker.key.clone();
    if joker.x_mult > 1.0 {
        text.push_str(&format!(" x{:.1}", joker.x_mult));
    }
    if joker.mult != 0.0 {
        text.push_str(&format!(" +{:.0}倍率", joker.mult));
    }
    if joker.chips != 0.0 {
        text.push_str(&format!(" +{:.0}筹码", joker.chips));
    }
    if joker.eternal {
        text.push_str(" [永恒]");
    }
    // `Joker` 上只有 `perish_tally` —— 大于 0 就说明它是易腐的, 那个数就是还剩几回合.
    if joker.perish_tally > 0 {
        text.push_str(&format!(" [易腐 剩{}回合]", joker.perish_tally));
    }
    if joker.rental {
        text.push_str(" [租赁]");
    }
    if joker.debuffed {
        text.push_str(" [已失效]");
    }
    text
}

fn pack_card_token(card: &balatro_engine::run::shop::PackCard) -> String {
    let mut text = card.key.clone();
    if let Some(enh) = card.enhancement {
        text.push_str(&format!(" ({})", enh.key()));
    }
    if let Some(edition) = card.edition {
        text.push_str(&format!(" +{:?}", edition));
    }
    if card.eternal {
        text.push_str(" [永恒]");
    }
    // 易腐**必须**显示: 它到期后效果全停, 而包里的牌看不见这一项的话, 就会把一张
    // 马上要失效的小丑当成长期资产来规划 (踩过: j_odd_todd 是易腐的, 到期后我还在按
    // "奇数牌 +31" 算分).
    if card.perishable {
        text.push_str(" [易腐]");
    }
    if card.rental {
        text.push_str(" [租赁]");
    }
    text
}
