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
