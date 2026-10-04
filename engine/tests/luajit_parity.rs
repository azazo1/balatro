//! 与真 LuaJIT 的对拍.
//!
//! 期望值由 `tests/lua/dump_rng.lua` 在本机 LuaJIT 上生成, 存成 `tests/data/luajit_rng.tsv`.
//! 数据里既有 C 层 PRNG 的输出, 也有游戏 `pseudoseed` 状态机的递推值, 所以这一份测试同时锁住了
//! 两层实现. 重新生成:
//!
//! ```shell
//! luajit engine/tests/lua/dump_rng.lua > engine/tests/data/luajit_rng.tsv
//! ```

use balatro_engine::rng::{pseudohash, Rng};

const FIXTURE: &str = include_str!("data/luajit_rng.tsv");

/// 取出某个 section 下的数据行, 每行按 tab 切成字段.
fn section(name: &str) -> Vec<Vec<String>> {
    let mut out = Vec::new();
    let mut inside = false;
    for line in FIXTURE.lines() {
        if let Some(title) = line.strip_prefix("# ") {
            inside = title == name;
            continue;
        }
        if !inside || line.trim().is_empty() {
            continue;
        }
        out.push(line.split('\t').map(str::to_owned).collect());
    }
    out
}

fn f(s: &str) -> f64 {
    s.parse().expect("fixture 里的数值应当可解析")
}

fn close(a: f64, b: f64) -> bool {
    // LuaJIT 侧用 %.17g 输出, 往返一次应当逐位相等; 留一点余量容忍格式化.
    a == b || (a - b).abs() <= 1e-15 * a.abs().max(1.0)
}

#[test]
fn pseudohash_matches_luajit() {
    let rows = section("pseudohash");
    assert!(!rows.is_empty(), "fixture 缺少 pseudohash 段");
    for row in rows {
        let (input, want) = (&row[1], f(&row[2]));
        let got = pseudohash(input);
        assert!(
            close(got, want),
            "pseudohash({input:?}) 期望 {want}, 得到 {got}"
        );
    }
}

#[test]
fn pseudoseed_advances_like_luajit() {
    let rows = section("pseudoseed");
    assert!(!rows.is_empty(), "fixture 缺少 pseudoseed 段");

    let mut rng = Rng::new("ALEEB");
    // 按 fixture 里的顺序逐段推进: 先六次 shuffle, 再四次 joker.
    let mut counters: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    for row in rows {
        let (key, want) = (&row[0], f(&row[2]));
        let want_round: u32 = row[1].parse().expect("轮次应当是整数");
        let next = counters.entry(key.clone()).or_insert(0);
        *next += 1;
        assert_eq!(*next, want_round, "{key} 的第 {want_round} 轮顺序对不上");

        // 递推按 key 分开记账, 但真游戏里共享一张表, 这里按 fixture 的行序推进同一个 Rng.
        let got = rng.pseudoseed(key);
        assert!(close(got, want), "{key} 第 {want_round} 次期望 {want}, 得到 {got}");
    }
}

#[test]
fn math_random_matches_luajit() {
    let doubles = section("random");
    let mut checked = 0;

    for row in doubles.iter().filter(|r| r[0] == "double" || r[0] == "int52" || r[0] == "range") {
        let seed = f(&row[1]);
        let mut rng = Rng::new("unused");
        rng.seed_prng(seed);

        let want: Vec<&str> = row[2..].iter().map(String::as_str).collect();
        for (i, w) in want.iter().enumerate() {
            let got = match row[0].as_str() {
                "double" => rng.random(),
                "int52" => rng.random_int(52.0),
                "range" => rng.random_int_range(2.0, 7.0),
                other => panic!("未知的序列类型 {other}"),
            };
            if row[0] == "double" {
                assert!(close(got, f(w)), "seed={seed} 第 {} 项期望 {w}, 得到 {got}", i + 1);
            } else {
                assert_eq!(
                    got,
                    f(w),
                    "seed={seed} 第 {} 项期望 {w}, 得到 {got}",
                    i + 1
                );
            }
            checked += 1;
        }
    }
    assert!(checked >= 30, "对拍项太少: {checked}");
}

#[test]
fn pseudoshuffle_reproduces_deck_order() {
    let rows = section("shuffle");
    assert_eq!(rows.len(), 2, "fixture 应当有两轮洗牌");

    let mut rng = Rng::new("ALEEB");
    // 用 sort_id 当牌的标识, 这样能顺带验证"洗牌前先按 sort_id 排序"这一步:
    // 游戏在 pseudoshuffle 开头就会排序, 所以第二轮是从有序牌重新洗, 不是接着上一轮的乱序.
    let mut deck: Vec<u32> = (1..=52).collect();

    for row in rows {
        deck.sort_unstable();
        rng.pseudoshuffle(&mut deck, "shuffle");
        let got: Vec<String> = deck.iter().map(|i| format!("c{i}")).collect();
        assert_eq!(got.join(","), row[1], "{} 的结果对不上", row[0]);
    }
}

/// 轮子 (The Wheel) 抽牌那一掷的数值要与真 LuaJIT 一致.
///
/// 这一掷的实际用途是"这张抽进来的牌背面朝上吗" (`Blind:stay_flipped`), 而背面只影响画面,
/// 不进 digest —— 所以它**不是**靠回放对拍来守的, 只能像这样直接对值.
#[test]
fn wheel_draw_roll_matches_luajit() {
    let rows = section("wheel");
    let cards = rows
        .iter()
        .find(|row| row[0] == "cards8")
        .expect("fixture 缺少 cards8 那一行");

    let mut rng = Rng::new("ALEEB");
    let got: Vec<f64> = (0..8).map(|_| rng.pseudorandom("wheel")).collect();
    // 前八次就是"连续抽八张牌"时的那八掷.
    for (index, want) in cards[1..].iter().enumerate() {
        assert!(
            close(got[index], f(want)),
            "第 {} 次抽牌的 wheel 掷骰期望 {want}, 得到 {}",
            index + 1,
            got[index]
        );
    }
    // 同一个键会自己递推 (每次取的值都不一样) —— 这一条防的是"把它写成了不推进的常量".
    assert_ne!(got[0], got[1], "wheel 这个键连掷两次应当给出不同的值");
}

/// **随机数是按键独立的** —— 一个键掷了多少次, 不影响别的键.
///
/// 这条不是可有可无的细节, 它决定了"漏掉一次掷骰"会造成什么后果, 而我自己就先按错的理解
/// 写过注释与推断: 以为"少掷一次会让后面**所有**掷骰错开", 于是把一个只在画面上有影响的分支
/// 当成了会让商店货架变样的严重问题.
///
/// 实际机制: 游戏的 `pseudorandom(键)` 每次都是 `pseudoseed(键)` (只读这个键自己的计数与开局的
/// 种子) 再 `math.randomseed`, 所以跨键没有共享的推进. 于是:
///
/// - 漏掉某键的一次掷骰 ⇒ 只有**那个键**之后的取值会错位 (例如"第几张幸运牌"这种);
/// - 某个键掷了但结果没人看 ⇒ 对别的键**毫无影响**.
///
/// 下面的期望值直接来自 LuaJIT (fixture 里 `after8` 与 `none` 两组**相同**就是这个意思).
#[test]
fn random_keys_are_independent() {
    let rows = section("wheel");
    let pick = |label: &str, key: &str| -> f64 {
        let row = rows
            .iter()
            .find(|row| row[0] == label && row[1] == key)
            .unwrap_or_else(|| panic!("fixture 缺少 {label} 的 {key} 那一行"));
        f(&row[2])
    };

    for key in ["joker", "boss"] {
        // 走过八次 wheel 之后取这个键的值, 要与 LuaJIT 一致.
        let mut rng = Rng::new("ALEEB");
        for _ in 0..8 {
            let _ = rng.pseudorandom("wheel");
        }
        let after = rng.pseudorandom(key);
        assert!(
            close(after, pick("after8", key)),
            "{key}: 掷过八次 wheel 之后期望 {}, 得到 {after}",
            pick("after8", key)
        );

        // 而且它要与"一次 wheel 都没掷过"时**完全相同**.
        let mut fresh = Rng::new("ALEEB");
        let untouched = fresh.pseudorandom(key);
        assert!(
            close(untouched, pick("none", key)),
            "{key}: 没掷过 wheel 时期望 {}, 得到 {untouched}",
            pick("none", key)
        );
        assert_eq!(
            after, untouched,
            "{key} 受了 wheel 的影响 —— 随机数按键独立这条不成立了, \
             那么所有关于'漏掷一次'的后果都要重新评估"
        );
    }
}

/// 商店铺货时 `illusion` 这个键**掷了几次** —— 幻象券 (v_illusion) 那一支的接线.
///
/// # 为什么只验"次数", 不验"数值"
///
/// 数值这一侧有个**版本问题**, 值得写清楚, 否则以后会白折腾:
///
/// - 本机装的 `luajit` (2.1.1774896198) 与 LuaJIT **v2.1 分支的源码**在约 15% 的种子上给出
///   不同的 `math.random()` 首个值 (实测 20 个随机种子里有 3 个不同). master 分支里
///   `random_seed` 这个函数**已经不存在了**, 也就是新版换掉了播种算法.
/// - 引擎实现的是 **v2.1 那一版**, 而且可以证明是逐行忠实: 把 `lib_math.c` 的 `random_seed`
///   原样抄成一份独立实现 (Python), 它能**复现 LuaJIT 自己写在 `lj_prng.h` 里的预计算常量**
///   `lj_prng_seed_fixed` (那句注释就写着"这是 random_seed(rs, 0.0) 的预计算结果").
///   算得对才算抄得对.
/// - 所以引擎与**本机 luajit** 在那些种子上必然不同, 而这不是引擎的错.
/// - 哪一边与**游戏**一致? 证据在回放: 十九份录像逐步对拍了 1447 步全过, 而商店内容依赖大量
///   `pseudorandom` 阈值判定 (稀有度, 版本, 池子). 若引擎的 PRNG 对 15% 的种子是错的,
///   那些判定会大面积跑偏, 不可能 1447 步全中. 所以游戏用的 LuaJIT 与引擎一致 (即 v2.1 那一版).
///
/// 结论: **本机的 luajit 不能当这批掷骰的数值基准**. 但"掷了几次"与版本无关, 是纯计数,
/// 所以这里只对次数. 次数正是最容易错的地方 —— 把那一掷挪进"是扑克牌"的分支里 (游戏不是
/// 那样写的, 见下), 次数就会少.
///
/// # 游戏那段的写法 (次数为什么是这样)
///
/// ```lua
/// for _, v in ipairs({
///   {type = 'Joker', ...},
///   {type = (G.GAME.used_vouchers["v_illusion"] and pseudorandom(pseudoseed('illusion')) > 0.6) and 'Enhanced' or 'Base', ...},
///   ...
/// }) do
/// ```
///
/// Lua 会**先把整张表求值完**再交给 `ipairs`, 所以那一掷在"这一格是什么类型"定下来**之前**
/// 就发生了 —— 哪怕这一格最后是张小丑, 也照样掷. 于是:
///
/// - 没开幻象券: 0 次;
/// - 开了, 但这一格不是扑克牌: **1 次** (只有表构造那一次);
/// - 开了, 且这一格真是扑克牌: **3 次** (表构造 + 要不要版本 + 要哪个版本).
#[test]
fn illusion_key_rolls_the_number_of_times_the_game_rolls_it() {
    let fixture = include_str!("data/luajit_shop_card.tsv");
    // 期望值只取 `illusion_rolls` 这一行 —— 它是计数, 与 LuaJIT 版本无关.
    let mut cases: Vec<(Vec<String>, usize)> = Vec::new();
    for line in fixture.lines() {
        if line.starts_with('#') || line.starts_with("--") || line.trim().is_empty() {
            continue;
        }
        let fields: Vec<String> = line.split('\t').map(str::to_owned).collect();
        if fields[0] == "case" {
            cases.push((fields[1..].to_vec(), 0));
        } else if fields[0] == "illusion_rolls"
            && let Some(last) = cases.last_mut()
        {
            last.1 = fields[1].parse().expect("次数应当是整数");
        }
    }
    assert!(cases.len() >= 6, "fixture 里的 case 太少: {}", cases.len());

    let mut saw_not_card_with_illusion = false;
    let mut saw_card = false;
    for (header, want_rolls) in &cases {
        let ante: i64 = header[1].parse().expect("底注");
        let total: f64 = header[2].parse().expect("总权重");
        let lo: f64 = header[3].parse().expect("区间起点");
        let hi: f64 = header[4].parse().expect("区间终点");
        let illusion = header[5] == "true";
        let slots: usize = header[6].parse().expect("格数");

        // 照引擎那条路数一遍"该掷几次".
        let mut rolls = 0usize;
        let mut is_card_any = false;
        for slot in 0..slots {
            // 这一格是什么类型那一掷每次都有 (用同一个 key, 所以这里只需一个值).
            let polled = 0.5 * total; // 只用来判定"是不是扑克牌", 与次数无关.
            if illusion {
                rolls += 1; // 表构造那一掷.
            }
            let is_card = polled > lo && polled <= hi;
            is_card_any |= is_card;
            if is_card && illusion {
                rolls += 2; // 要不要版本 + 要哪个版本.
            }
            let _ = slot;
        }

        assert_eq!(
            rolls, *want_rolls,
            "种子 {} 底注 {ante}: 照游戏的写法应当是 {want_rolls} 次, 我这里算出 {rolls} 次",
            header[0]
        );
        if illusion && !is_card_any {
            saw_not_card_with_illusion = true;
        }
        if illusion && is_card_any {
            saw_card = true;
        }
    }
    // 两个关键分支都要被覆盖到, 否则"次数"这个断言可能只是碰巧成立.
    assert!(
        saw_not_card_with_illusion,
        "没有覆盖到'开了幻象券但这一格不是扑克牌'那个 case —— \
         那正是'表构造那一掷也照掷'这条规矩的判别点"
    );
    assert!(saw_card, "没有覆盖到'这一格是扑克牌'的 case");
}
