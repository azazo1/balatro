//! 与真 LuaJIT 的 `table.sort` 对拍.
//!
//! 期望值由 `tests/lua/dump_sort.lua` 在本机 LuaJIT 上生成, 存成 `tests/data/luajit_sort.tsv`.
//! 重新生成:
//!
//! ```shell
//! luajit engine/tests/lua/dump_sort.lua > engine/tests/data/luajit_sort.tsv
//! ```
//!
//! # 这份数据为什么要记"下标"
//!
//! `table.sort` **不稳定**: 比较函数说相等的两个元素, 谁排前面由快排的交换过程决定.
//! 所以对拍必须让"相等的那些元素"带上身份 —— 数据里排的是**下标数组**, 比较函数只看键,
//! 输出也是下标序列. 只记值序列的话 (这份数据的初版就是这样) 相等的元素在输出里长得一模一样,
//! 那半边等于没验: 换成任何一份稳定排序都会全过.
//!
//! 值域故意取小 (1..3), 好让相等频繁出现.

use balatro_engine::lua::table_sort;

const FIXTURE: &str = include_str!("data/luajit_sort.tsv");

fn parse(line: &str) -> Vec<usize> {
    line.split(',')
        .map(|part| part.parse().expect("fixture 里都是整数"))
        .collect()
}

/// 排一组"下标", 比较函数只看 `keys`: 返回的序列就是"每个位置取自原来的第几个" (1 基, 与 fixture 一致).
fn order_by_keys(keys: &[usize], descending: bool) -> Vec<usize> {
    let mut order: Vec<usize> = (1..=keys.len()).collect();
    table_sort::sort_by(&mut order, |a, b| {
        let (left, right) = (keys[*a - 1], keys[*b - 1]);
        if descending { left > right } else { left < right }
    });
    order
}

fn dump(values: &[usize]) -> String {
    values
        .iter()
        .map(|value| value.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

/// 每一条都要与 LuaJIT 逐位相同 —— 不只看"排好了", 还要看**相等的那些谁在前**.
#[test]
fn table_sort_matches_luajit_including_ties() {
    let mut checked = 0;
    // 有多少条里**存在相等元素** —— 只有这些条才真正在验"不稳定"那一半.
    let mut with_ties = 0;
    for line in FIXTURE.lines() {
        let Some((keys, want)) = line.split_once('\t') else {
            continue;
        };
        let keys = parse(keys);
        let mut sorted_keys = keys.clone();
        sorted_keys.sort_unstable();
        sorted_keys.dedup();
        if sorted_keys.len() != keys.len() {
            with_ties += 1;
        }

        let got = dump(&order_by_keys(&keys, true));
        assert_eq!(got, want, "输入 {keys:?} 排出来与 LuaJIT 不同");
        checked += 1;
    }
    assert!(checked > 400, "fixture 看起来不完整, 只对上了 {checked} 条");
    // 没有这一条, 上面那 406 条可能与"稳定排序"的结论相同, 而这份数据就白记了.
    assert!(
        with_ties > 300,
        "带等值元素的样本太少 ({with_ties}/{checked}), 这份数据验不出不稳定排序"
    );
}
