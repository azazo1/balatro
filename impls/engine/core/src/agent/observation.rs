//! 面向 agent 的观察权限和盲注状态, 不改变内部规则状态.

use crate::run::{BlindKind, Phase, RunState};
use crate::scoring::ScoreSource;

/// 在出牌前冻结可见性, 避免结算收牌或解除 Boss 后泄露计分时的隐藏来源.
#[derive(Default)]
pub struct ScoreVisibility {
    hidden_held: Vec<u32>,
    hidden_jokers: bool,
}

impl ScoreVisibility {
    pub fn capture(run: &RunState) -> Self {
        Self {
            hidden_held: run.hand.iter().filter(|card| card.face_down)
                .map(|card| card.card.sort_id).collect(),
            hidden_jokers: run.jokers_face_down(),
        }
    }

    pub fn hides(&self, source: &ScoreSource) -> bool {
        match source {
            ScoreSource::Held { card } => self.hidden_held.contains(&card.sort_id),
            ScoreSource::Joker { .. } => self.hidden_jokers,
            _ => false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlindStatus {
    Select,
    Upcoming,
    Active,
    Defeated,
    Skipped,
    Failed,
}

fn visible_phase(run: &RunState) -> Phase {
    if run.phase == Phase::BoosterOpened { run.pack_return_phase } else { run.phase }
}

/// 结算和失败界面显示实际打过的 Boss, 不能把已预抽的下底 Boss 当作旧 Boss.
pub fn blind_key(run: &RunState, index: usize) -> Option<String> {
    match index {
        0 => Some(crate::run::blind::plain_blind_key(BlindKind::Small).to_owned()),
        1 => Some(crate::run::blind::plain_blind_key(BlindKind::Big).to_owned()),
        2 if matches!(visible_phase(run), Phase::RoundEval | Phase::GameOver)
            && run.blind_on_deck == BlindKind::Boss => run.blind.as_ref().map(|blind| blind.key.clone()),
        2 => run.boss_key.clone(),
        _ => None,
    }
}

pub fn blind_status(run: &RunState, index: usize) -> BlindStatus {
    let phase = visible_phase(run);
    // Boss 后的商店属于新底注, 新 Boss 还没打. 旧格只在结算界面保留.
    if phase == Phase::Shop && run.blind_on_deck == BlindKind::Boss {
        return BlindStatus::Upcoming;
    }
    let current = match run.blind_on_deck {
        BlindKind::Small => 0,
        BlindKind::Big => 1,
        BlindKind::Boss => 2,
    };
    match index.cmp(&current) {
        std::cmp::Ordering::Less => {
            if run.skipped_blinds.get(index).copied().unwrap_or(false) {
                BlindStatus::Skipped
            } else {
                BlindStatus::Defeated
            }
        }
        std::cmp::Ordering::Greater => BlindStatus::Upcoming,
        std::cmp::Ordering::Equal => match phase {
            Phase::BlindSelect => BlindStatus::Select,
            Phase::SelectingHand => BlindStatus::Active,
            Phase::RoundEval | Phase::Shop => BlindStatus::Defeated,
            Phase::GameOver => BlindStatus::Failed,
            Phase::BoosterOpened => BlindStatus::Upcoming,
        },
    }
}
