//! 快照与回滚.
//!
//! 目标里要求的"每步状态快照与回滚", 用途是先试一条路, 走不通就退回来换一条, 而不是从开局重算.
//!
//! 做法是整份 [`RunState`] 的深拷贝. 引擎里所有状态都是值类型 (整数, 浮点, `String`, `Vec`,
//! `HashMap`, `HashSet`) 与 [`Rng`](crate::rng::Rng), 没有借用关系, 也没有可变的全局量
//! (原型表是只读的 [`Catalog`](crate::data::catalog::Catalog)), 所以拷贝出来的就是一份独立局面,
//! 之后两边互不影响.
//!
//! 回滚的正确性由"同一份快照重跑同样操作得到同样结果"来保证, 见 `tests/rewind.rs`.

use super::state::RunState;

/// 一个局面. 内部持有完整状态, 与原 `RunState` 之间没有共享.
#[derive(Clone, Debug)]
pub struct Snapshot {
    label: String,
    state: RunState,
}

impl Snapshot {
    /// 打这个点时给的说明, 例如"第 3 手之前".
    pub fn label(&self) -> &str {
        &self.label
    }

    /// 只读地看一眼当时的局面.
    pub fn state(&self) -> &RunState {
        &self.state
    }

    /// 这份快照占的状态条数, 用来估内存.
    pub fn size_hint(&self) -> StateSize {
        self.state.size_hint()
    }
}

impl RunState {
    /// 记下当前局面.
    pub fn snapshot(&self, label: impl Into<String>) -> Snapshot {
        Snapshot {
            label: label.into(),
            state: self.clone(),
        }
    }

    /// 回到某个局面. 快照本身不变, 可以反复使用 (分支探索要靠这个).
    pub fn restore(&mut self, snapshot: &Snapshot) {
        *self = snapshot.state.clone();
    }
}

/// 状态的规模, 用来判断快照攒多了会不会占太多内存.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StateSize {
    /// 存档进度表的条数. 它在一局里不变, 是快照里最大的一块.
    pub uda_entries: usize,
    /// 其余几张表加起来的条数.
    pub tracked_entries: usize,
}

impl RunState {
    /// 估一下现在这份状态有多大.
    pub fn size_hint(&self) -> StateSize {
        StateSize {
            uda_entries: self.uda.len(),
            tracked_entries: self.used_vouchers.len()
                + self.used_jokers.len()
                + self.banned_keys.len()
                + self.pool_flags.len()
                + self.shop_vouchers.len()
                + self.hands_played.len(),
        }
    }
}

/// 一条按时间排的快照序列.
///
/// 典型的用法是每一步操作前 `record` 一次, 走错了 `step_back` 回来:
///
/// ```ignore
/// timeline.record(&run, "第 3 手之前");
/// run.play(...);
/// if 结果不好 {
///     timeline.step_back(&mut run);   // 回到第 3 手之前, 换一手
/// }
/// ```
#[derive(Clone, Debug, Default)]
pub struct Timeline {
    points: Vec<Snapshot>,
}

impl Timeline {
    pub fn new() -> Self {
        Timeline { points: Vec::new() }
    }

    /// 记下这个局面.
    pub fn record(&mut self, run: &RunState, label: impl Into<String>) {
        self.points.push(run.snapshot(label));
    }

    pub fn len(&self) -> usize {
        self.points.len()
    }

    pub fn is_empty(&self) -> bool {
        self.points.is_empty()
    }

    pub fn get(&self, index: usize) -> Option<&Snapshot> {
        self.points.get(index)
    }

    pub fn last(&self) -> Option<&Snapshot> {
        self.points.last()
    }

    /// 弹出最后一个局面并恢复它. 没有点可退时返回 `false`.
    pub fn step_back(&mut self, run: &mut RunState) -> bool {
        match self.points.pop() {
            Some(point) => {
                run.restore(&point);
                true
            }
            None => false,
        }
    }

    /// 回到指定下标, 并丢掉它之后的点. 保留该点本身, 所以可以反复退回同一处.
    pub fn rewind_to(&mut self, run: &mut RunState, index: usize) -> bool {
        if index >= self.points.len() {
            return false;
        }
        run.restore(&self.points[index]);
        self.points.truncate(index + 1);
        true
    }

    /// 回到指定下标, 但不丢掉它之后的点 (只是在那个局面继续往下走).
    pub fn fork_at(&self, run: &mut RunState, index: usize) -> bool {
        match self.points.get(index) {
            Some(point) => {
                run.restore(point);
                true
            }
            None => false,
        }
    }

    pub fn clear(&mut self) {
        self.points.clear();
    }
}
