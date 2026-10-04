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
use balatro_engine::scoring::{BackEffect, EvalEnv};

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
    let verbose = std::env::var("GEN_REPLAY_VERBOSE").is_ok();
    let mut record = |run: &RunState, method: &str, params: Option<String>, actions: &mut Vec<String>| {
        wall += 1.5;
        if verbose {
            // 诊断用: 看清每一步的分数与目标差多少, 免得只看到"这一局输了"。
            eprintln!(
                "  {method:10} 分 {} / 目标 {} 手 {} 弃 {} 钱 {} 小丑 {}",
                run.chips,
                run.blind.as_ref().map(|blind| blind.chips).unwrap_or(0.0),
                run.hands_left,
                run.discards_left,
                run.dollars,
                run.jokers.len()
            );
        }
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
                run.select_blind().expect("在选盲注阶段");
                record(&run, "select", None, &mut actions);
            }
            Phase::SelectingHand => {
                // 先问引擎"这一手最好是哪几张, 能打多少分"。
                let (cards, gain) = choose_play(&run, &env, back);
                if cards.is_empty() {
                    eprintln!("第 {step} 步: 手里没牌了");
                    break;
                }
                // 还差多少分, 按剩下几次出牌摊平 —— 摊不到的平均值就说明这一手不够好,
                // 该弃牌换牌了 (还有弃牌次数的话). 弃掉的是**没进这一手里**的牌: 它们本来
                // 就不参与计分, 换掉不亏. 次数是有限的, 所以这个循环一定会停.
                let needed = (run.blind.as_ref().map(|blind| blind.chips).unwrap_or(0.0)
                    - run.chips)
                    .max(0.0);
                let hands_left = run.hands_left.max(1) as f64;
                let throw_away = choose_discard(&run, &cards);
                if gain < needed / hands_left
                    && run.discards_left > 0
                    && !throw_away.is_empty()
                {
                    let params = cards_params(&throw_away);
                    run.discard(&throw_away).expect("弃得成 (上面查过还有次数)");
                    record(&run, "discard", Some(params), &mut actions);
                    continue;
                }
                let params = cards_params(&cards);
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
                // 店里有买得起的小丑、且队里还有位置就买下来 —— **小丑是分数的来源**,
                // 不买的话每手就是牌型那点分, 底注 1 的 Boss (600) 都过不去, 回放就停在
                // 二十来步. 这条规则只看"买得起 + 有位置", 不做取舍, 所以它既短又确定.
                //
                // 注意买**不消耗**随机数 (商店的随机数在铺货那一步就用完了), 所以这里多买
                // 一件不会让后面的预测偏掉 —— 这也是能把它加进来的前提.
                if run.jokers.len() < run.joker_capacity()
                    && let Some((slot, card)) = run
                        .shop
                        .as_ref()
                        .and_then(|shop| {
                            shop.jokers
                                .iter()
                                .enumerate()
                                // 货架上那一格可能是小丑, 也可能是塔罗 / 行星 / 基础牌 ——
                                // 这一版只买**小丑** (其余类型要走槽位与"用掉"的规矩, 先不碰).
                                .filter(|(_, card)| card.key.starts_with("j_"))
                                .find(|(_, card)| card.cost <= run.dollars - run.bankrupt_at)
                        })
                        .map(|(slot, card)| (slot, card.clone()))
                {
                    match run.buy(&card) {
                        Ok(_) => {
                            record(&run, "buy", Some(format!("{{\"card\":{slot}}}")), &mut actions);
                            continue;
                        }
                        Err(error) => eprintln!("第 {step} 步: 买 {slot} 失败 {error:?}"),
                    }
                }
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

/// 挑一手要出的牌: **每个候选都在副本上真打一遍, 按打出来的分挑最好的一手**.
///
/// 这里不写启发式, 而是让引擎自己算 —— 它本来就会计分, 而 `RunState` 是 `Clone`,
/// `play` 又是纯状态转移, 所以"在副本上试一手, 看结果"是既忠实又省事的做法:
/// 走的是**真计分路径** (牌型, 小丑, 版本, 削弱, 牌背效果全都在内), 不会因为启发式
/// 漏看某个组合而与实际不符. 顺带这也是快照 / 回滚这个能力的一个自然用法.
///
/// 候选是手里 1..5 张的全部组合 (八张手牌一共 218 种) —— 张数少于五张有时更划算
/// (同花之外, 少带两张杂牌不影响牌型, 但少两张牌就少两份筹码; 反过来凑不成的组合
/// 还不如出一张小牌), 所以不固定五张.
fn choose_play(run: &RunState, env: &EvalEnv, back: BackEffect) -> (Vec<usize>, f64) {
    let size = run.hand.len();
    if size == 0 {
        return (Vec::new(), 0.0);
    }
    let before = run.chips;
    let mut best: Vec<usize> = Vec::new();
    let mut best_score = f64::NEG_INFINITY;
    // 按张数从多到少试, 同样分数时**优先要张数多的** (更多牌参与计分); 因为只有严格更大
    // 才替换, 所以把张数多的排前面即可.
    for count in (1..=size.min(5)).rev() {
        let mut combination: Vec<usize> = (0..count).collect();
        loop {
            let mut trial = run.clone();
            if trial.play(&combination, env, back).is_ok() {
                // 这一手打出来的分看本回合累计的筹码 —— 它已经加进去了.
                let score = trial.chips;
                if score > best_score {
                    best_score = score;
                    best = combination.clone();
                }
            }
            // 下一个组合 (字典序).
            let mut at = count;
            let mut advanced = false;
            while at > 0 {
                at -= 1;
                if combination[at] != at + size - count {
                    combination[at] += 1;
                    for next in at + 1..count {
                        combination[next] = combination[next - 1] + 1;
                    }
                    advanced = true;
                    break;
                }
            }
            if !advanced {
                break;
            }
        }
    }
    // 返回**增量**而不是累计分: 调用方要拿它跟"还差多少分"比.
    (best, (best_score - before).max(0.0))
}

/// 挑一组要弃掉的牌: **奔着一个牌型去**, 而不是随手丢。
///
/// 这一步很要紧: 只弃"当前最好组合之外的牌"是一种保守换法, 它永远不会把一手散牌
/// 换成同花 —— 于是每手都只有五六十分, 底注 1 的 Boss (600 分) 都过不去, 生成出来的
/// 回放就只有二十来步, 覆盖不到后面的商店与包。
///
/// 顺序照玩家的常规打法:
///
/// 1. 手上同一花色有 4 张以上 → 留那几张, 弃掉别的 (追同花; 同花是 35 筹码 x4 倍率);
/// 2. 否则手上同一点数有两张以上 → 留那些对子 / 三条, 弃掉别的 (追葫芦或两对);
/// 3. 都没有 → 弃掉点数最小的几张 (至少换掉一半, 牌才可能变好)。
///
/// `keep` 是引擎刚算出来的"当前最好的一手" —— 它已经算过一遍了, 那就**别把它丢了**:
/// 追牌型的同时至少保住这一手, 免得弃完还不如原来。
fn choose_discard(run: &RunState, keep: &[usize]) -> Vec<usize> {
    use std::collections::BTreeMap;
    let size = run.hand.len();
    if size < 2 {
        return Vec::new();
    }
    // 1) 追同花: 按花色分组, 取最多的那一组.
    let mut suits: BTreeMap<char, Vec<usize>> = BTreeMap::new();
    for (index, card) in run.hand.iter().enumerate() {
        suits
            .entry(card.card.suit.code())
            .or_default()
            .push(index);
    }
    let best_suit = suits.values().max_by_key(|indexes| indexes.len());
    let mut planned: Vec<usize> = match best_suit {
        Some(indexes) if indexes.len() >= 4 => indexes.clone(),
        _ => {
            // 2) 追对子 / 三条: 按点数分组, 把所有"两张以上"的都留着.
            let mut ranks: BTreeMap<u8, Vec<usize>> = BTreeMap::new();
            for (index, card) in run.hand.iter().enumerate() {
                ranks
                    .entry(card.card.rank.nominal() as u8)
                    .or_default()
                    .push(index);
            }
            let grouped: Vec<usize> = ranks
                .values()
                .filter(|indexes| indexes.len() >= 2)
                .flatten()
                .copied()
                .collect();
            if grouped.is_empty() {
                // 3) 什么都没有: 弃掉点数最小的一半.
                let mut order: Vec<usize> = (0..size).collect();
                order.sort_by(|a, b| run.hand[*a].card.nominal().total_cmp(&run.hand[*b].card.nominal()));
                order.truncate(size / 2);
                return order;
            }
            grouped
        }
    };
    // 保住引擎刚算出来的那一手.
    planned.extend(keep.iter().copied());
    let keep: std::collections::BTreeSet<usize> = planned.into_iter().collect();
    let mut throw_away: Vec<usize> = (0..size).filter(|index| !keep.contains(index)).collect();
    // 一次最多弃五张 (游戏那边有上限); 要弃的多了就先弃点数小的.
    throw_away.sort_by(|a, b| run.hand[*a].card.nominal().total_cmp(&run.hand[*b].card.nominal()));
    throw_away.truncate(5);
    throw_away
}

/// 把一组手牌下标写成动作参数.
fn cards_params(cards: &[usize]) -> String {
    format!(
        "{{\"cards\":[{}]}}",
        cards
            .iter()
            .map(|card| card.to_string())
            .collect::<Vec<_>>()
            .join(",")
    )
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
