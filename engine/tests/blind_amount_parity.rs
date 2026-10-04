//! 与真 LuaJIT 的 `get_blind_amount` 对拍 (盲注目标分数).
//!
//! 期望值由 `tests/lua/dump_blind_amount.lua` 在本机 LuaJIT 上生成, 存成
//! `tests/data/luajit_blind_amount.tsv`. 重新生成:
//!
//! ```shell
//! luajit engine/tests/lua/dump_blind_amount.lua > engine/tests/data/luajit_blind_amount.tsv
//! ```
//!
//! # 这份数据特意包含"底注 40 之后是 `nan`"
//!
//! 目标分数的算式是指数的, 底注大约 40 起就溢出了双精度, 于是游戏自己在 `nan` 上做
//! `amount % magnitude` (`inf % inf`), 结果就是 `nan`. 它**不是**引擎的 bug —— 真 Lua 也是这个数.
//!
//! 这一点值得专门钉住: `nan` 的比较永远是假, 于是 `chips >= blind.chips` 恒不成立, 那一底
//! 就永远打不过. 看上去非常像一个"该修的病", 而**修它就是引入偏离** —— 引擎的职责是复刻,
//! 不是替游戏收拾. 所以这里逐位比对 (含 `nan`), 谁想"顺手修正"一下都会在这里失败.
//!
//! 对比用十六进制浮点: 高底注下这些数大到十进制的有效位数不够, 而 `nan` 也需要逐位判等.

use balatro_engine::run::blind::blind_amount;

const FIXTURE: &str = include_str!("data/luajit_blind_amount.tsv");

/// 把 fixture 里那串十六进制浮点 (或 `nan`) 解回来.
///
/// 自己解析是因为 `f64::from_str_radix` 只吃整数, 而 C 那种 `0x1.9p+6` 的写法
/// (尾数带小数点, 指数以 2 为底) 标准库没有现成的入口.
fn parse_hex(text: &str) -> f64 {
    match text {
        "nan" => return f64::NAN,
        "-nan" => return -f64::NAN,
        "inf" => return f64::INFINITY,
        "-inf" => return f64::NEG_INFINITY,
        _ => {}
    }
    let rest = text
        .strip_prefix("0x")
        .unwrap_or_else(|| panic!("fixture 里的数看不懂: {text}"));
    let (mantissa, exponent) = rest
        .split_once('p')
        .unwrap_or_else(|| panic!("缺指数: {text}"));
    let exponent: i32 = exponent.parse().expect("指数是整数");
    // 尾数形如 `1.9`: 整数部分一位, 小数部分每位占 4 bit.
    let (whole, fraction) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    let mut value = i64::from_str_radix(whole, 16).expect("整数部分") as f64;
    for (index, digit) in fraction.chars().enumerate() {
        let digit = digit.to_digit(16).expect("小数部分") as f64;
        value += digit / 16f64.powi(index as i32 + 1);
    }
    value * 2f64.powi(exponent)
}

fn same(left: f64, right: f64) -> bool {
    // `nan != nan`, 所以先单独处理它 —— 这份数据里 `nan` 是**预期值**, 不是"缺失".
    (left.is_nan() && right.is_nan()) || left.to_bits() == right.to_bits()
}

#[test]
fn blind_amount_matches_luajit_including_the_overflow() {
    let mut checked = 0;
    let mut saw_nan = 0;
    for line in FIXTURE.lines() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split('\t').collect();
        assert_eq!(parts.len(), 4, "每行该是 底注 + 三档: {line}");
        let ante: i64 = parts[0].parse().expect("底注是整数");
        for (index, text) in parts[1..].iter().enumerate() {
            let scaling = index as i64 + 1;
            let want = parse_hex(text);
            let got = blind_amount(ante, scaling);
            assert!(
                same(got, want),
                "底注 {ante} 第 {scaling} 档: 引擎 {got} 与 LuaJIT {want} 不同"
            );
            if want.is_nan() {
                saw_nan += 1;
            }
        }
        checked += 1;
    }
    assert!(checked > 30, "fixture 看起来不完整, 只对上了 {checked} 条");
    // 没有这一条的话, fixture 哪天被"清理"掉那批 nan, 上面那几句仍然全过 ——
    // 而"忠实复刻了游戏的溢出"这件事就没人守着了.
    assert!(
        saw_nan > 15,
        "fixture 里该有成片的 nan (那份溢出), 实际只有 {saw_nan} 个"
    );
}
