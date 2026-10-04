//! `table.sort`: Lua 5.1 / LuaJIT 的 `auxsort`.
//!
//! 抄自 LuaJIT 的 `src/lib_table.c` (那份实现与 Lua 5.1 的 `ltablib.c` 同源).
//!
//! # 为什么不能直接用 Rust 的排序
//!
//! `table.sort` **不是稳定排序**: 比较函数对两个元素都给假时 (也就是"相等"), 它们最终谁在前
//! 由算法的交换过程决定. Rust 的 `sort_by` 是稳定归并排序, `sort_unstable_by` 是模式打败排序 ——
//! 两种都会给出与 Lua 不同的结果.
//!
//! 这在本项目里是**可观测**的: 手牌按点数降序排, 手里两张同点数的 K 谁在前会影响
//! `play` / `discard` 用的下标, 于是回放记录里那一步之后全对不上. 这不是"等价实现允许的偏差",
//! 因为游戏的状态里本来就没有"这两张等价"这回事 —— 数组顺序本身就是状态.
//!
//! # 与 C 版本的对应
//!
//! C 版把待比较的两个元素压在 Lua 栈上, 再用栈位置 (`-1` / `-2`) 说"比哪两个". 这里改成
//! 显式的下标变量, 比较的**次数与顺序**与原来逐个对应 —— 那正是决定结果的唯一东西.
//! 1 基下标 (与 Lua 一致) 在内部使用, 取值时减一.
//!
//! 比较函数不合法 (`a < b` 与 `b < a` 同时成立) 时 C 版抛 "invalid order function for sorting";
//! 这里同样直接报错, 因为继续排下去只会得到垃圾顺序.

/// 用 Lua 的 `table.sort` 语义排序.
///
/// `less(a, b)` 就是传给 `table.sort` 的那个比较函数 (Lua 里收两个参数的匿名函数).
/// 注意它的参数顺序: 与 Lua 一样是 `(前, 后)`, 返回值表示**前一个要排在前面**.
pub fn sort_by<T, F>(list: &mut [T], less: F)
where
    T: Clone,
    F: Fn(&T, &T) -> bool,
{
    let n = list.len() as i64;
    if n < 2 {
        return;
    }
    auxsort(list, &less, 1, n);
}

/// `auxsort(L, l, u)`: 排 `a[l..=u]`.
///
/// 外层 `while` 就是 C 版那个"尾递归改成循环": 递归只对**较小的一半**做, 较大的那一半留在
/// 循环里 —— 这样栈深度是 `O(log n)` 而不是 `O(n)`.
fn auxsort<T, F>(a: &mut [T], less: &F, mut l: i64, mut u: i64)
where
    T: Clone,
    F: Fn(&T, &T) -> bool,
{
    // 1 基下标取值 (Lua 的 `a[i]`).
    macro_rules! at {
        ($i:expr) => {
            (($i) - 1) as usize
        };
    }

    while l < u {
        // 先把 a[l], a[u] 两个位置摆顺 (只为了保证 a[l] <= a[u], 顺便缩小区间).
        if less(&a[at!(u)], &a[at!(l)]) {
            a.swap(at!(l), at!(u));
        }
        if u - l == 1 {
            break; // 只有两个元素, 排完了.
        }

        let mut i = (l + u) / 2;
        // 把中位数挪到 a[i] 上去: 先比 a[i] 与 a[l].
        if less(&a[at!(i)], &a[at!(l)]) {
            a.swap(at!(i), at!(l));
        } else if less(&a[at!(u)], &a[at!(i)]) {
            a.swap(at!(i), at!(u));
        }
        if u - l == 2 {
            break; // 只有三个元素, 排完了.
        }

        // 取枢轴: a[l] <= P == a[u-1] <= a[u], 中间那段 (l+1 ..= u-2) 才是要划的.
        // 顺序与 C 版一致 —— 先把枢轴换到 u-1, 再拿着它的副本参与比较.
        let pivot = a[at!(i)].clone();
        a.swap(at!(i), at!(u - 1));

        let mut ii = l;
        let mut jj = u - 1;
        loop {
            // 往右找第一个不小于枢轴的.
            loop {
                ii += 1;
                if !less(&a[at!(ii)], &pivot) {
                    break;
                }
                if ii >= u {
                    panic!("排序的比较函数不合法: 右边扫过了界");
                }
            }
            // 往左找第一个不大于枢轴的.
            loop {
                jj -= 1;
                if !less(&pivot, &a[at!(jj)]) {
                    break;
                }
                if jj <= l {
                    panic!("排序的比较函数不合法: 左边扫过了界");
                }
            }
            if jj < ii {
                break;
            }
            a.swap(at!(ii), at!(jj));
        }
        // 把枢轴放到它最终的位置上 (原来是 a[u-1], 换到 a[ii]).
        a.swap(at!(u - 1), at!(ii));
        i = ii;

        // 小的一半递归, 大的一半留给外层循环.
        if i - l < u - i {
            let j = l;
            i -= 1;
            l = i + 2;
            auxsort(a, less, j, i);
        } else {
            let j = i + 1;
            i = u;
            u = j - 2;
            auxsort(a, less, j, i);
        }
    }
}
