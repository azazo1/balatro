//! 一局的流程与状态.

pub mod blind;
pub mod consumable;
pub mod flow;
pub mod pool;
pub mod shop;
pub mod snapshot;
pub mod state;
pub mod voucher;

pub use blind::{
    Blind, BlindKind, RoundEval, blind_amount, interest, make_blind, scaling_for_stake,
};
pub use flow::{ActionError, Phase};
pub use pool::{tag_pool, voucher_pick_index, voucher_pool};
pub use shop::{
    ShopCard, ShopRates, consumable_count, create_card, create_card_for_shop, get_pack,
    nested_number, open_pack, pack_kind_of, pick_or_resample, poll_edition,
    poll_edition_guaranteed, shop_cost,
};
pub use snapshot::{Snapshot, StateSize, Timeline};
pub use state::{Modifiers, RunState};

// 卡牌版本在卡牌层定义 (商店里的小丑也带), 这里转出去便于调用方只 use 一个模块.
pub use crate::cards::Edition;
