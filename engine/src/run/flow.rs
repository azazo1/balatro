//! 回合流程: 建堆, 洗牌, 发牌, 弃牌, 出牌.
//!
//! 对应 `Game:start_run` 的建堆洗牌, 与 `G.FUNCS.select_blind` / `draw_from_deck_to_hand` /
//! `discard_cards_from_highlighted` / `play_cards_from_highlighted` 这几个入口.
//!
//! 取牌方向是游戏定的, 弄反了整局都会错:
//!
//! - `CardArea:remove_card` 对 `deck` 与 `discard` 取**尾部**, 其余区域取**头部**.
//! - 所以发牌与补抽都从牌堆末尾拿, 手牌是"牌堆末 n 张的倒序".
//! - 每次抽牌之后 `draw_card` 的 `sort` 参数会让手牌按 `get_nominal` 降序重排一遍.
//!
//! 盲注的目标分数在 `blind.rs`, 出牌本身只累计本回合分数; 判胜负与领钱走 `end_round`
//! 与 `cash_out`, 商店与开包在 `shop.rs`, 快照与回滚在 `snapshot.rs`.

use crate::cards::{CardInstance, Enhancement, PlayingCard, Rank, Seal, Suit, standard_deck};
use crate::jokers::TriggerContext;
use crate::scoring::{
    BackEffect, EvalEnv, PokerHand, ScoreResult, evaluate_poker_hand,
};

use super::blind::{BlindKind, RoundEval, eligible_bosses, interest, make_blind, plain_blind_key};
use super::shop::ShopCard;
use super::state::RunState;
use crate::jokers::Joker;

/// 一局所处的阶段, 对应 `G.STATES` 里与游玩有关的几项.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Phase {
    /// 选盲注 (`BLIND_SELECT`).
    BlindSelect,
    /// 出牌与弃牌 (`SELECTING_HAND`).
    SelectingHand,
    /// 回合结算 (`ROUND_EVAL`).
    RoundEval,
    /// 商店 (`SHOP`).
    Shop,
    /// 开了补充包, 正在挑里面的牌 (`SMODS_BOOSTER_OPENED`).
    BoosterOpened,
    /// 结束 (`GAME_OVER`).
    GameOver,
}

/// 动作被拒绝的原因. 对应端点返回的 `BAD_REQUEST` 与 `INVALID_STATE`.
///
/// 没有 `Eq`: 里面有 `f64` (钱与价格), 而浮点没有全序.
#[derive(Clone, PartialEq, Debug)]
pub enum ActionError {
    /// 当前阶段不能做这个动作.
    NotInPhase { expected: Phase, actual: Phase },
    /// 下标越界.
    BadIndex(usize),
    /// 超出一次能选的张数.
    TooManyCards { limit: usize, got: usize },
    /// 少于一次至少要选的张数.
    TooFewCards { least: usize, got: usize },
    /// 一张都没选.
    NoCards,
    /// 没有弃牌次数了.
    NoDiscardsLeft,
    /// 没有出牌次数了.
    NoHandsLeft,
    /// 钱不够.
    NotEnoughMoney { cost: f64, have: f64 },
    /// 持有区没空位.
    NoRoom { what: &'static str, slots: usize },
    /// 认不出的原型键.
    UnknownCard(String),
    /// 规则上不允许这么做 —— 这是**游戏本身**禁止的, 不是"引擎还不会".
    ///
    /// 与 [`ActionError::NotImplemented`] 分开是必要的: 混在一起时调用方 (批量跑对局的策略)
    /// 会把"这一步本来就非法"当成"引擎有缺口", 于是走上完全不同的分支 ——
    /// 前者重试多少次都一样, 后者换个实现就能做.
    NotAllowed(&'static str),
    /// 这条路还没实现. 引擎不做静默降级, 遇到就明说.
    NotImplemented(&'static str),
}

impl RunState {
    /// 建开局那副牌堆. 对应游戏里 `card_protos` 那一段 (`game/game.lua` L2338 起) 与随后的
    /// `card_from_control`.
    ///
    /// 形状是三步, 顺序不能换:
    ///
    /// 1. **列出这副牌有哪些牌面**. 无面牌组 (`remove_faces`) 在这一步把 K/Q/J 剔掉;
    ///    错乱牌组 (`randomize_rank_suit`) 则在这一步把**每一次**都换成随机抽来的一张 ——
    ///    注意它抽的是 `P_CARDS`, 也就是"52 张里随便挑", 所以同一张牌面会出现多次,
    ///    而张数仍然是 52.
    /// 2. **按 `花色..点数` 排序**. 这一步决定了 `sort_id` 的分配顺序, 而 `sort_id` 是
    ///    洗牌前的定序依据, 所以它不是装饰. 排序键是拼接后的字符串 (`'C'..'2'` = `"C2"`),
    ///    于是点数按**字符码**排 —— `2..9` 之后是 `A/J/K/Q/T`, 而不是 A 到 K 的通常顺序.
    /// 3. **棋盘牌组换花色**: 梅花改黑桃, 方块改红桃. 它在游戏里挂在事件上 (建堆之后才跑),
    ///    作用在整副牌上, 所以是一个后置步骤.
    pub fn build_deck(&mut self) {
        let config = self.deck_config.clone();
        let flag = |field: &str| {
            config
                .get(field)
                .and_then(crate::data::json::Json::as_bool)
                .unwrap_or(false)
        };
        let no_faces = flag("remove_faces");
        let erratic = flag("randomize_rank_suit");

        let mut faces = standard_deck();
        if no_faces {
            faces.retain(|card| !card.rank.is_face());
        }
        if erratic {
            // 每一次都**重掷一张牌面**, 键是 `erratic` (游戏那行是
            // `pseudorandom_element(G.P_CARDS, pseudoseed('erratic'))`).
            // `pseudorandom_element` 收的是哈希表, 会先按**键的字符串升序**排好再取下标,
            // 所以候选表就是那 52 个键按升序 —— 这也是本引擎 `standard_deck` 已经排好的顺序.
            let pool: Vec<PlayingCard> = standard_deck();
            faces = (0..faces.len())
                .map(|_| {
                    let seed = self.rng.pseudoseed("erratic");
                    let index = self.rng.pick_index(pool.len(), seed);
                    pool[index]
                })
                .collect();
        }
        // 排序键与游戏一致: 花色字符接点数字符.
        faces.sort_by_key(|card| card.key());
        // 取名字与花色都全新的引用 (重复抽到的牌面会共用同一个原型, 所以要各自造一份).
        self.deck = faces
            .iter()
            .enumerate()
            .map(|(index, face)| {
                let mut card = CardInstance::plain(*face);
                card.card.sort_id = index as u32 + 1;
                card
            })
            .collect();

        // 棋盘牌组: 梅花 -> 黑桃, 方块 -> 红桃, 于是这副牌只有黑红两种花色.
        if self.deck_key == "b_checkered" {
            for card in self.deck.iter_mut() {
                match card.card.suit {
                    Suit::Clubs => card.change_suit(Suit::Spades),
                    Suit::Diamonds => card.change_suit(Suit::Hearts),
                    _ => {}
                }
            }
        }

        // 记下开局那副牌有多少张 —— 侵蚀那类"比开局少了几张"的小丑要看它
        // (`G.GAME.starting_deck_size`). 它在建堆之后就不变了.
        self.starting_deck_size = self.deck.len();
        // 建牌序号从这里往上数, 之后每造一张牌都加一 (见 `next_sort_id`).
        self.next_card_id = self
            .deck
            .iter()
            .map(|card| card.card.sort_id)
            .max()
            .unwrap_or(0);
    }

    /// 按 `sort_id` 排序, 对应 `pseudoshuffle` 开头那一次 `table.sort`.
    ///
    /// 这里用同一份 Lua 排序: 建牌序号在正常路径上互不相同 (排序结果与算法无关), 但少了
    /// "万一有重号"这条兜底时, 差异会以"整副牌洗完对不上"的形式出现, 很难追. 统一用一份实现,
    /// 就不必再分情况判断.
    fn sort_deck_by_sort_id(&mut self) {
        crate::lua::table_sort::sort_by(&mut self.deck, |a, b| {
            a.card.sort_id < b.card.sort_id
        });
    }

    /// 开局那次洗牌 (`self.deck:shuffle()`).
    ///
    /// 牌组自带的额外牌与修饰还没做, 所以这里就是一副标准牌.
    pub fn shuffle_opening(&mut self) {
        self.sort_deck_by_sort_id();
        self.rng.pseudoshuffle(&mut self.deck, "shuffle");
    }

    /// 选盲注: 回合数加一, 摆上盲注, 重置本回合的次数, 第二次洗牌再发牌.
    ///
    /// 洗牌用的键是 `'nr'..底注`; 底注不变时两个回合会用到同一个键, 而 `pseudoseed` 是递推的,
    /// 所以第二次调用给出的是另一组结果 —— 每个回合都能洗出新牌序靠的就是这个.
    ///
    /// **只在选盲注阶段能做** —— 端点的 `requires_state` 就是 `BLIND_SELECT`.
    /// 少了这一条, 在商店或开包时调它会"成功地"把下一个盲注摆上: 引擎多走了一步,
    /// 而游戏那边会拒绝, 于是从那一步起两边的阶段就错开了.
    /// (XXWF71H9 那份录像第 40 步就是这么露出来的: 商店里连着来了个 `select`.)
    pub fn select_blind(&mut self) -> Result<(), ActionError> {
        if self.phase != Phase::BlindSelect {
            return Err(ActionError::NotInPhase {
                expected: Phase::BlindSelect,
                actual: self.phase,
            });
        }
        self.round += 1;
        // 杂耍标签在真正开始下一盲注时才触发, 跳过盲注或开标签包不消耗它.
        self.temporary_hand_size_bonus = self.tags.iter().filter(|tag| *tag == "tag_juggle")
            .map(|tag| tag_config_number(tag, "h_size") as i64).sum();
        self.tags.retain(|tag| tag != "tag_juggle");
        // 先把上一回合的牌全收回牌堆 —— 正常流程里 `end_round` 已经收过了, 但直接调
        // `select_blind` (换底注, 或测试) 时牌还在出牌区与弃牌堆里. 后面几个按牌生效的
        // Boss 效果要遍历**整副牌**, 收得晚了就漏掉刚打出去的那些.
        self.collect_all_cards();

        let key = match self.blind_on_deck {
            BlindKind::Boss => self
                .boss_key
                .clone()
                .expect("轮到 Boss 时应当已经抽好"),
            other => plain_blind_key(other).to_owned(),
        };
        self.blind = Some(make_blind(
            self.blind_on_deck,
            &key,
            self.ante,
            self.scaling,
            self.ante_scaling,
            self.no_blind_reward,
        ));
        self.chips = 0.0;
        // 出牌与弃牌的次数取自这一局的参数, 而不是写死 —— 蓝色牌组会多给一次出牌,
        // 而赌注 5 起少给一次弃牌, 两者都要能体现出来.
        self.hands_left = self.hands_per_round;
        self.discards_left = self.discards_per_round;
        self.discards_used = 0;
        // 盲注从这一刻起生效, 到这一回合结束为止 (对应 `Blind:set_blind` 里 Steamodded 那句).
        self.in_blind = true;
        // 眼与嘴限的是"这一回合打过的牌型", 每回合重新算.
        self.round_hand_types.clear();
        // 上一回合的削弱是"仅本盲注"的, 先全部清掉再按这一回合的 Boss 重判.
        for card in self.deck.iter_mut().chain(self.hand.iter_mut()) {
            card.debuffed = false;
        }

        // 琥珀橡果 (决战 Boss): 把小丑的顺序**洗三次** (键 `aajk`). 小丑的先后会影响计分
        // (先算谁、谁给谁加成), 所以这不是"看不见的效果".
        //
        // 每一次洗牌之前都要**按建牌序号排一遍**, 因为游戏的 `pseudoshuffle` 开头就有那一次
        // `table.sort` (`if list[1] and list[1].sort_id then ... end`) —— 小丑也是 `Card`,
        // 所以也有 `sort_id`. 少了这一步, 三次洗牌会**层层叠加** (第二次洗的是第一次的结果),
        // 而游戏每次都是从"按序号排好"的队形重新开始; 同样的随机数作用在不同队形上, 结果不同.
        if self.blind.as_ref().is_some_and(|b| b.key == "bl_final_acorn" && !b.disabled)
            && self.jokers.len() > 1
        {
            for _ in 0..3 {
                crate::lua::table_sort::sort_by(&mut self.jokers, |a, b| a.sort_id < b.sort_id);
                self.rng.pseudoshuffle(&mut self.jokers, "aajk");
            }
        }

        // 城堡那一回合盯的花色: 每回合开始都掷, 键 `cas{底注}`.
        // 抽的是"场上还没有被打成石头"的牌的花色 (`reset_castle_card`) —— 牌池只影响取值,
        // 不影响全局序列, 所以这里用整副牌里非石头牌的花色即可.
        {
            let pool: Vec<String> = self
                .deck
                .iter()
                .chain(self.hand.iter())
                .filter(|card| !card.is_stone())
                .map(|card| card.card.suit.code().to_string())
                .collect();
            let key = format!("cas{}", self.ante);
            self.castle_suit = if pool.is_empty() {
                Some(crate::cards::Suit::Spades)
            } else {
                let picked = self.rng.pick(&pool, &key).clone();
                crate::cards::Suit::from_code(picked.chars().next().unwrap_or('S'))
            };
        }

        // 上古小丑那一回合盯的花色: 每回合开始都掷, 键 `anc{底注}`,
        // 而且花色池里**去掉上一次那个** (`reset_ancient_card` 就是这么写的).
        {
            let pool: Vec<String> = ['S', 'H', 'C', 'D']
                .iter()
                .filter(|code| {
                    Some(crate::cards::Suit::from_code(**code).expect("四种花色"))
                        != self.ancient_suit
                })
                .map(|code| code.to_string())
                .collect();
            let key = format!("anc{}", self.ante);
            let picked = self.rng.pick(&pool, &key).clone();
            self.ancient_suit = crate::cards::Suit::from_code(picked.chars().next().unwrap_or('S'));
        }

        // 邮件回扣那一回合盯的点数: 每回合开始掷, 键 `mail{底注}` (抽的是场上非石头牌的点数).
        {
            let pool: Vec<String> = self
                .deck
                .iter()
                .chain(self.hand.iter())
                .filter(|card| !card.is_stone())
                .map(|card| card.card.rank.code().to_string())
                .collect();
            let key = format!("mail{}", self.ante);
            self.mail_rank = if pool.is_empty() {
                Some(crate::cards::Rank::Ace)
            } else {
                let picked = self.rng.pick(&pool, &key).clone();
                picked
                    .chars()
                    .next()
                    .and_then(crate::cards::Rank::from_code)
            };
        }

        // 爱豆那一回合盯的那张牌: 每回合开始掷, 键 `idol{底注}`,
        // 池子是场上**非石头**的牌 (石头牌没有点数可言, 游戏在 `reset_idol_card` 里就把它排除了).
        {
            let pool: Vec<String> = self
                .deck
                .iter()
                .chain(self.hand.iter())
                .filter(|card| !card.is_stone())
                .map(|card| {
                    format!(
                        "{}{}",
                        card.card.suit.code(),
                        card.card.rank.code()
                    )
                })
                .collect();
            let key = format!("idol{}", self.ante);
            self.idol_card = if pool.is_empty() {
                None
            } else {
                let picked = self.rng.pick(&pool, &key).clone();
                let mut chars = picked.chars();
                match (chars.next(), chars.next()) {
                    (Some(suit), Some(rank)) => crate::cards::Suit::from_code(suit)
                        .zip(crate::cards::Rank::from_code(rank)),
                    _ => None,
                }
            };
        }

        // 奇可 (传奇): 手里有它的时候, **Boss 盲注的效果整条不生效** ——
        // 游戏里是在 `setting_blind` 那个时机调 `G.GAME.blind:disable()`, 之后所有 Boss 效果
        // 都看 `blind.disabled`. 少了这一条, Boss 那一回合的分数会整块算错.
        //
        // 注意这里调的是 `disable_blind` 而不是直接置标志: 停用同时要**撤销盲注自己做过的
        // 改动** (墙 / 紫瓶改过目标分数). 详见 `RunState::disable_blind`.
        let chicot = self
            .jokers
            .iter()
            .any(|joker| joker.key == "j_chicot" && !joker.debuffed);
        if chicot && self.blind.as_ref().is_some_and(|b| b.kind == BlindKind::Boss) {
            self.disable_blind();
        }

        // 有几个 Boss 直接改这一回合的次数与手牌上限, 照 `Blind:get_type` 里那几支.
        match self.blind.as_ref().filter(|b| !b.disabled).map(|b| b.key.as_str()) {
            // 水: 一次弃牌都没有.
            Some("bl_water") => self.discards_left = 0,
            // 针: 只有一次出牌机会.
            Some("bl_needle") => self.hands_left = 1,
            // 镣铐: 手牌上限减一.
            Some("bl_manacle") => self.hand_size_sub = 1,
            _ => self.hand_size_sub = 0,
        }

        // 柱子 (The Pillar): 这一底注打出过的牌在这个盲注里失效. 它削的是**整副牌**里出过的,
        // 不论那张牌此刻在牌堆还是手上 (`Blind:debuff_card` 对每张牌都跑一遍).
        if self.blind.as_ref().is_some_and(|b| b.key == "bl_pillar" && !b.disabled) {
            for card in self.deck.iter_mut().chain(self.hand.iter_mut()) {
                if card.played_this_ante {
                    card.debuffed = true;
                }
            }
        }

        // 翠叶 (决战 Boss): **所有扑克牌**失效 (小丑不受影响), 直到卖掉一张小丑为止
        // (`Blind:debuff_card` 里那一支: 不是小丑区的一律 `set_debuff(true)`).
        if self
            .blind
            .as_ref()
            .is_some_and(|b| b.key == "bl_final_leaf" && !b.disabled)
        {
            for card in self.deck.iter_mut().chain(self.hand.iter_mut()) {
                card.debuffed = true;
            }
        }

        // 另一批 Boss 按**牌的性质**削: 某个花色失效, 或者人头牌失效.
        // 已禁用的盲注在这一步也要跳过 (`Blind:debuff_card` 之前会看 `disabled`).
        let pareidolia_here = self.has_pareidolia();
        if let Some(key) = self
            .blind
            .as_ref()
            .filter(|b| !b.disabled)
            .map(|b| b.key.clone())
        {
            for card in self.deck.iter_mut().chain(self.hand.iter_mut()) {
                if debuffs_card(&key, card, pareidolia_here) {
                    card.debuffed = true;
                }
            }
        }
        // `new_round` 把各牌型的"本回合打过几次"清零. 这一条不能漏: 老千小丑按
        // "本回合打过同一牌型"乘 3 倍, 计数不归零就会从第二回合起一直触发.
        self.hands.reset_round();

        self.sort_deck_by_sort_id();
        let key = format!("nr{}", self.ante);
        self.rng.pseudoshuffle(&mut self.deck, &key);
        self.draw_to_hand();
        // 发完牌之后是"回合开始"那些小丑的时机 (`context.first_hand_drawn`).
        self.apply_round_start_jokers();
        self.phase = Phase::SelectingHand;
        Ok(())
    }

    /// 回合开始时触发的小丑, 对应 `context.first_hand_drawn`.
    ///
    /// 排在发牌**之后** —— 它们改的是"这一回合还能怎么打", 而不是发什么牌.
    fn apply_round_start_jokers(&mut self) {
        // 先把手上的小丑看一遍再改局面, 免得与借用打架.
        let keys: Vec<(String, f64)> = self
            .jokers
            .iter()
            .map(|joker| (joker.key.clone(), joker.extra))
            .collect();

        // 下面几张要在**选盲注时**新建或销毁小丑, 所以先在 `keys` 快照上认一遍,
        // 把"要造几张"、"要销毁哪几个"记下来, 循环之后再动局面 (避免与借用打架).

        // 即兴小丑: 有空位就造两张**普通**小丑 (追加键 `rif`).
        let blind_ok = !self.blind.as_ref().is_some_and(|blind| blind.disabled);
        if keys.iter().any(|(key, _)| key == "j_riff_raff") && blind_ok {
            let room = self.joker_capacity().saturating_sub(self.jokers.len());
            for _ in 0..room.min(2) {
                if let Some(key) = super::shop::pick_joker_of_rarity(self, 1, "rif", false)
                    && let Some(joker) = Joker::new(&key)
                {
                    self.add_joker(joker);
                }
            }
        }

        // 塔罗师: 消耗槽有空位就造一张塔罗 (追加键 `car`).
        if keys.iter().any(|(key, _)| key == "j_cartomancer")
            && self.consumables.len() < self.consumable_capacity()
        {
            let key = super::shop::create_card(self, "Tarot", "car");
            self.consumables
                .push(super::consumable::Consumable::plain(key));
        }

        // 疯狂: 非 Boss 盲注时自己涨 0.5 乘倍率, 并销毁**一个随机**的其他小丑 (键 `madness`).
        let mut madness_destroys: Vec<usize> = Vec::new();
        if keys.iter().any(|(key, _)| key == "j_madness")
            && !self
                .blind
                .as_ref()
                .is_some_and(|blind| blind.kind == BlindKind::Boss)
        {
            let index = self.jokers.iter().position(|joker| joker.key == "j_madness");
            if let Some(index) = index {
                self.jokers[index].x_mult += self.jokers[index].extra;
            }
            let others: Vec<usize> = self
                .jokers
                .iter()
                .enumerate()
                .filter(|(i, joker)| {
                    joker.key != "j_madness" && !joker.eternal && Some(*i) != index
                })
                .map(|(i, _)| i)
                .collect();
            if !others.is_empty() {
                let seed = self.rng.pseudoseed("madness");
                let picked = self.rng.pick_index(others.len(), seed);
                madness_destroys.push(others[picked]);
            }
        }

        // 仪式匕首: 销毁它**右边**那一张 (不是随机的), 并把自己那个倍率加上对方卖价的两倍.
        let mut ceremonial_destroys: Vec<usize> = Vec::new();
        for (index, (key, _)) in keys.iter().enumerate() {
            if key != "j_ceremonial" {
                continue;
            }
            let next = index + 1;
            if next < self.jokers.len() && !self.jokers[next].eternal {
                let sell = sell_price(self.jokers[next].cost);
                self.jokers[index].mult += sell * 2.0;
                ceremonial_destroys.push(next);
            }
        }

        // 混沌小丑: **每回合**多一次免费重抽. 游戏是在 `setting_blind` 那一趟加的
        // (`G.GAME.current_round.free_rerolls + 1`), 而 `current_round` 每回合都会重置 ——
        // 所以这里要先清零再加, 而不是"拿到时加一次".
        self.free_rerolls = 0;
        if keys.iter().any(|(key, _)| key == "j_chaos") {
            self.free_rerolls += 1;
        }

        // 先把"要销毁的"落实掉 (两个来源可能撞上同一张, 去重后再按大下标先删).
        {
            let mut doomed = madness_destroys;
            doomed.extend(ceremonial_destroys);
            doomed.sort_unstable();
            doomed.dedup();
            for index in doomed.into_iter().rev() {
                if index < self.jokers.len() {
                    let key = self.jokers[index].key.clone();
                    let current = self.jokers[index].extra;
                    self.jokers.remove(index);
                    apply_joker_on_loss(self, &key, current);
                }
            }
        }

        for (key, extra) in &keys {
            match key.as_str() {
                // 窃贼: 这一回合没有弃牌, 但多给几次出牌.
                "j_burglar" => {
                    self.discards_left = 0;
                    self.hands_left += *extra as i64;
                }
                // 大理石: 给一张**石头牌** (点数固定是石头, 牌面另抽).
                "j_marble" => {
                    let card = self.random_playing_card("marb_fr", Some(Enhancement::Stone));
                    self.add_playing_card_to_deck(card);
                }
                // 证书: 给一张随机牌, 而且**必带蜡封** (种类另掷一次).
                //
                // 两点容易写错: 牌是进**手牌**而不是牌堆 (`create_playing_card(..., G.hand, ...)`),
                // 而且加完之后游戏会给手牌**排一次序** (`G.hand:sort()`), 所以这一手会变成点数降序.
                "j_certificate" => {
                    let mut card = self.random_playing_card("cert_fr", None);
                    card.seal = Some(self.random_seal("certsl"));
                    self.hand.push(card);
                    self.sort_hand();
                }
                _ => {}
            }
        }
    }

    /// 抽一张随机牌面, 可选带强化.
    ///
    /// 新牌也要一个建牌号 —— 洗牌前按它排序, 少了它会与已有的牌撞号.
    fn random_playing_card(
        &mut self,
        key: &str,
        enhancement: Option<Enhancement>,
    ) -> CardInstance {
        let roll = self.rng.pseudorandom(key);
        let suits = Suit::ALL;
        let ranks = Rank::ALL;
        let suit = suits[(roll * 4.0) as usize % 4];
        let rank_roll = self.rng.pseudorandom(key);
        let rank = ranks[(rank_roll * 13.0) as usize % 13];
        let mut card = CardInstance::from_key(&format!("{}_{}", suit.code(), rank.code()))
            .expect("花色点数都是合法的");
        card.enhancement = enhancement;
        card.card.sort_id = self.next_sort_id();
        card
    }

    /// 按同一套阈值掷一个蜡封 (证书用它).
    fn random_seal(&mut self, key: &str) -> Seal {
        let roll = self.rng.pseudorandom(key);
        if roll > 0.75 {
            Seal::Red
        } else if roll > 0.5 {
            Seal::Blue
        } else if roll > 0.25 {
            Seal::Gold
        } else {
            Seal::Purple
        }
    }

    /// 从头开始, 停在**选盲注**界面 —— 与游戏的 `start_run` 一致.
    ///
    /// 发牌要等玩家选了盲注才做 (游戏里那一步是 `select`), 所以第一个盲注也**可以跳过**.
    pub fn start_run(&mut self) {
        self.build_deck();
        // 牌组自带的消耗牌与券要在**开局洗牌之前**做完: 游戏那边它们挂在事件上, 而 `start_run`
        // 自己也是个协程 —— 它在 `delay(0.5)` 处让出, 带 0.4 秒延迟的"造消耗牌"那段就在这个
        // 缝里跑完了, 之后才轮到 `G.deck:shuffle()`. 而造牌会掷一次版本, 所以这一步
        // **动的是随机数序列**, 顺序反了整副牌的洗牌结果都会不同.
        self.apply_starting_deck_extras();
        self.shuffle_opening();
        // 开局就把这一底的 Boss 抽好, 对应 `Game:start_run` 里那次 `get_new_boss()`.
        self.boss_key = Some(self.next_boss());
        // 开局抽这一底的优惠券与两个标签, 对应 `Game:start_run` 里那几次.
        self.refresh_voucher();
        self.refresh_tags();
        self.blind_on_deck = BlindKind::Small;
        self.phase = Phase::BlindSelect;
    }

    /// 开局并把第一个盲注也选上, 直接进到能出牌的局面.
    ///
    /// 游戏里"开局"与"选盲注"是两个动作, 这里合成一步只是为了写脚本与测试方便.
    /// 要按游戏的真实节奏走 (例如第一个盲注就想跳过) 就用 `start_run`.
    pub fn start(&mut self) {
        self.start_run();
        self.select_blind().expect("在选盲注阶段");
    }

    /// 抽这一底的两个标签: 跳过小盲注与大盲注分别能拿到的.
    ///
    /// 与优惠券一样只在开局与底注提升时重抽, 底注之内固定.
    fn refresh_tags(&mut self) {
        let small = self.next_tag_key();
        let big = self.next_tag_key();
        self.blind_tags = [Some(small), Some(big)];
    }

    /// 换一批优惠券: 清掉在售的, 重抽一张.
    ///
    /// 券只在**开局**与**打败 Boss 之后**换新, 小盲注与大盲注结束时都不动它, 所以它一底只用
    /// 一个键值.
    fn refresh_voucher(&mut self) {
        // 只**作废**这一格, 键留到 `restock` 里真正摆货架时再抽 —— 因为抽券要消耗随机数,
        // 而游戏那边券是夹在"卡"与"包"之间抽的. 在这里抽就等于抽早了 (见 `restock` 的注释).
        self.shop_vouchers.clear();
        // 新底注 = 新的一张券, 所以"这一底已经买过券"这件事也跟着清掉.
        self.voucher_spent = false;
    }

    /// `get_new_boss()`: 抽这一底的 Boss.
    ///
    /// 候选是 `boss.min` 够得着这一底的 Boss, 只在被抽中次数最少的那批里取,
    /// 顺序按键的字符串升序 (游戏那边是哈希表, 取之前会先按 key 排).
    /// 重掷面前的 Boss 盲注 (导演剪辑版 / 重新规划那两张优惠券给的权利).
    ///
    /// 规则照 `G.FUNCS.reroll_boss`: 花 10 块, 用**同一个** `get_new_boss()` 重抽一个
    /// (所以候选池、用过次数、禁用名单全都照常参与), 并记下"这一底已经重掷过".
    /// 权利本身: 买了"重新规划"(`v_retcon`)就没有次数限制; 只买了"导演剪辑版"
    /// (`v_directors_cut`)则每底一次.
    pub fn reroll_boss(&mut self) -> Result<f64, ActionError> {
        const COST: f64 = 10.0;
        let unlimited = self.used_vouchers.contains("v_retcon");
        let once = self.used_vouchers.contains("v_directors_cut");
        if !unlimited && !(once && !self.boss_rerolled) {
            // 没有这张券 (或者这一底已经用过了) 就没得重掷.
            return Err(ActionError::NotAllowed("重掷 Boss: 没有那张优惠券, 或者这一底已经用过"));
        }
        if self.dollars - self.bankrupt_at < COST {
            return Err(ActionError::NotEnoughMoney {
                cost: COST,
                have: self.dollars,
            });
        }
        self.dollars -= COST;
        self.boss_rerolled = true;
        self.boss_key = Some(self.next_boss());
        Ok(COST)
    }


    /// 把一张小丑放进持有区, 顺手给它发一个建牌序号.
    ///
    /// 游戏里小丑也是 `Card`, 走 `Card:init` 时会把全局的 `G.sort_id` 加一 ——
    /// 所以小丑与扑克牌**共用同一个计数器**, 而它们的序号相对大小只取决于"谁先造出来".
    /// 引擎这边共用 `next_card_id` 就够了 (只有小丑之间的相对顺序会被用到).
    ///
    /// 收成一个入口是为了不再出现"某个新加的小丑忘了发号"—— 那种漏发的表现是
    /// 洗小丑时它的位置与游戏不同, 而中间隔着好几层, 很难追回来.
    pub fn add_joker(&mut self, mut joker: Joker) -> usize {
        joker.sort_id = self.next_sort_id();
        let is_chicot = joker.key == "j_chicot";
        self.jokers.push(joker);
        // 奇可进队时立刻停用当前的 Boss 盲注 —— 对应 `Card:add_to_deck` 里那一支:
        // 游戏里除了"摆盲注时"那一次, 还有**中途拿到它**这一条路 (在盲注内用审判开出奇可
        // 就属于这种情况). 少接这一条, 那一整局的 Boss 效果会照常生效到回合结束.
        // 在 `BLIND_SELECT` 阶段拿到它也无妨: 此时 `self.blind` 还是上一个盲注, 而
        // `select_blind` 会重建一个 (那时 `disabled` 是新的 false, 再由它自己那一处判一次).
        if is_chicot
            && self
                .blind
                .as_ref()
                .is_some_and(|blind| blind.kind == BlindKind::Boss && !blind.disabled)
        {
            self.disable_blind();
        }
        self.jokers.len() - 1
    }

    /// 往牌堆里加一张**扑克牌**, 顺手喂全息图 (它按"每加一张牌"涨 0.25 乘倍率).
    ///
    /// 游戏钩的是 `context.playing_card_added` —— 也就是"牌进了牌堆"这件事本身,
    /// 所以这里把所有"加牌进牌堆"的地方都收成同一个入口, 免得以后又加一处忘了喂它.
    ///
    /// # 插到**牌堆底**, 不是牌堆顶
    ///
    /// 牌堆这一侧的 `emplace` 是特例: `CardArea:emplace` 写的是
    /// `if location == 'front' or self.config.type == 'deck' then table.insert(self.cards, 1, card)`,
    /// 而 `G.deck.config.type` 就是 `'deck'` —— 所以进牌堆的牌一律**插到数组头部**;
    /// 而抽牌 (`remove_card`) 取的是**尾部**. 两下一合: **新牌落在牌堆最底下, 最后才抽到**.
    ///
    /// 这条语义在别处已经对齐过 (收弃牌回牌堆、标准包取出的牌都按它写), 但这里原来写的是
    /// `push` —— 那等于插到**牌堆顶**, 于是"这一回合刚加的牌"会在下一次补牌时**立刻**被抽上来.
    /// 实测确认过差别: 有大理石时 `push` 那一版补一手牌就摸到了那张石头牌.
    ///
    /// **录像抓不到这一条**: 十九份录像里大理石**只在货架上出现过, 一次都没进过队**,
    /// 所以它的效果从没触发过. 这类"实现了但没被录到"的分支只能靠读源码定, 并且由单测钉住
    /// (见 `tests/jokers.rs` 里那条"新加的牌在牌堆最底下").
    fn add_playing_card_to_deck(&mut self, card: crate::cards::CardInstance) {
        self.deck.insert(0, card);
        for joker in self.jokers.iter_mut() {
            if joker.key == "j_hologram" && !joker.debuffed {
                joker.x_mult += 0.25;
            }
        }
    }

    /// 复制一张牌, 给它**新的建牌序号** —— 对应游戏的 `copy_card`.
    ///
    /// 游戏那边复制出来的是一张**新建的 `Card`**, 所以它走一遍 `Card:init`, 拿到一个新的
    /// `G.sort_id` (最新的那个). 引擎里 `CardInstance` 是 `Copy`, 直接拷会连 `sort_id` 一起拷过去,
    /// 于是复制品与原牌**同号** —— 而两张同号的牌在洗牌前排序时的先后是随机的 (Lua 那套快排不定),
    /// 表现成"下一回合发出来的牌对不上", 与真实原因隔得很远.
    ///
    /// 凡是"游戏里会新建一张牌"的地方都要走这里: 死神 (把最右的复制给其余选中的),
    /// DNA (复制打出的那张), 神秘生物 (复制第一张选中的若干份).
    fn duplicate_card(&mut self, source: &crate::cards::CardInstance) -> crate::cards::CardInstance {
        let mut copy = *source;
        copy.card.sort_id = self.next_sort_id();
        copy
    }

    /// 手里有没有帕瑞多利亚 (它让所有牌都当人头牌).
    fn has_pareidolia(&self) -> bool {
        self.jokers
            .iter()
            .any(|joker| joker.key == "j_pareidolia" && !joker.debuffed)
    }

    pub fn next_boss(&mut self) -> String {
        let candidates = eligible_bosses(
            crate::data::catalog::Catalog::get(),
            self.ante,
            self.win_ante,
            &self.banned_keys,
            &self.bosses_used,
        );
        assert!(!candidates.is_empty(), "第 {} 底没有可用的 Boss", self.ante);
        let seed = self.rng.pseudoseed("boss");
        let index = self.rng.pick_index(candidates.len(), seed);
        let picked = candidates[index].id.clone();
        *self.bosses_used.entry(picked.clone()).or_insert(0) += 1;
        picked
    }

    /// 离开商店, 回到选盲注, 把下一个盲注摆上.
    ///
    /// 小 -> 大 -> Boss -> 下一个底注的小盲注. 与底注有关的那一笔 (底注加一, 重抽券与标签,
    /// 抽下一底的 Boss) **不在这里** —— 它在 `end_round` 里打赢 Boss 那一刻就做掉了,
    /// 见那边的注释.
    ///
    /// **只在商店里能做**: 包还开着 (或者正打牌) 的时候这一步是非法的, 游戏那边会拒绝 ——
    /// 一份真实录像里就有这种尝试 (bot 开了包又想直接走人). 半路放行的话, 引擎会带着
    /// 一个开着的包进入下一个盲注, 后面的每一步都对不上.
    pub fn next_round(&mut self) -> Result<(), ActionError> {
        if self.phase != Phase::Shop {
            return Err(ActionError::NotInPhase {
                expected: Phase::Shop,
                actual: self.phase,
            });
        }
        // 珀克奥 (传奇): **离店时**从消耗槽里随机复制一张, 给它负片.
        // 注意它**不受槽位上限限制** (游戏那边用的是 `emplace`), 所以 3 张挤在 2 格里是正常的.
        // 触发时机是 `context.ending_shop`, 也就是这一步.
        if self
            .jokers
            .iter()
            .any(|joker| joker.key == "j_perkeo" && !joker.debuffed)
            && !self.consumables.is_empty()
        {
            let keys: Vec<String> = self
                .consumables
                .iter()
                .map(|card| card.key.clone())
                .collect();
            let picked = self.rng.pick(&keys, "perkeo").clone();
            self.consumables.push(super::consumable::Consumable::with_edition(
                picked,
                Some(crate::cards::Edition::Negative),
            ));
        }
        // 离开商店就把货架收掉: 回放 digest 里这一格的 `shop` / `vouchers` / `packs` 都是空的,
        // 而下一次进商店时会重新铺一遍 (`cash_out` -> `restock`).
        // 收掉的时候顺手清"用过"的记录 —— 游戏里那些牌是被 `Card:remove()` 收走的.
        self.clear_shelf();
        self.blind_on_deck = match self.blind_on_deck {
            // Boss 的底注已经在 `end_round` 里提过了, 这里只把盲注轮到下一个小盲注.
            BlindKind::Boss => BlindKind::Small,
            BlindKind::Small => BlindKind::Big,
            BlindKind::Big => BlindKind::Boss,
        };
        self.phase = Phase::BlindSelect;
        Ok(())
    }

    /// 收下一个标签: 记进持有列表, 并跑一遍它"到位就生效"的那部分.
    fn grant_tag(&mut self, tag: &str) {
        self.tags.push(tag.to_owned());
        self.dollars += self.apply_immediate_tag(tag);
        self.apply_structural_tag(tag);
    }

    /// 标签到手时立刻结算的那部分 (原型 `config.type` 是 `immediate` 或 `eval` 的那些),
    /// 返回这次给的钱.
    ///
    /// 其余几类不在这里: `store_joker_create` / `store_joker_modify` 要挂到商店生成小丑那一刻,
    /// `new_blind_choice` 换的是盲注选择, `voucher_add` 加券, `shop_start` / `shop_final_pass`
    /// 改的是商店行为, `tag_add` 再给一个标签, `round_start_bonus` 改手牌上限.
    fn apply_immediate_tag(&mut self, key: &str) -> f64 {
        match key {
            // 投资标签: 25 块.
            "tag_investment" => 25.0,
            // 速度标签: 跳过的盲注越多给得越多.
            "tag_skip" => self.skips as f64 * 5.0,
            // 顺手 / 垃圾: 按当前剩余的出牌 / 弃牌次数给.
            "tag_handy" => self.hands_left.max(0) as f64,
            "tag_garbage" => self.discards_left.max(0) as f64,
            // 经济标签: 给当前现金那么多, 但有上限 —— 等于把现金翻倍封顶.
            "tag_economy" => self.dollars.clamp(0.0, 40.0),
            _ => 0.0,
        }
    }

    /// 标签里"改规则"的那几个: 它们不给钱, 而是改之后的局面.
    ///
    /// 与 `apply_immediate_tag` 分开是因为这两类落点不同 —— 一个进现金, 一个改状态.
    fn apply_structural_tag(&mut self, key: &str) {
        match key {
            // 杂耍标签留到 round_start_bonus 时触发.
            "tag_juggle" => {},
            // D6 标签: 这一轮的商店重抽不要钱.
            "tag_d_six" => self.free_reroll = true,
            // 代金券标签: 这一轮商店里的东西免费.
            "tag_coupon" => self.shop_free = true,
            // Boss 标签: 白重抽一次这一底的 Boss (正常重抽要花 10 块).
            "tag_boss" => self.boss_key = Some(self.next_boss()),
            // 优惠券标签: 商店的券那一格再多摆一张.
            "tag_voucher" => self.extra_voucher_key = Some(self.next_voucher_key()),
            // 标签包排队打开. 双倍标签可能给多个包, 不可覆盖正在挑选的包.
            "tag_charm" | "tag_meteor" | "tag_ethereal" | "tag_standard" | "tag_buffoon" => {},
            // 补货标签: 白送两个小丑. 稀有度由原型里那个 `_rarity = 0` 决定 ——
            // `0 > 0.95` 与 `0 > 0.7` 都不成立, 所以落在普通 (一级).
            "tag_top_up" => {
                let count = tag_config_number(key, "spawn_jokers") as i64;
                for _ in 0..count {
                    if self.jokers.len() >= self.joker_capacity() {
                        break;
                    }
                    if let Some(picked) = super::shop::pick_joker_of_rarity(self, 1, "top", false)
                        && let Some(joker) = Joker::new(&picked)
                    {
                        self.add_joker(joker);
                    }
                }
            }
            // 轨道标签: 把**某一个**牌型的等级抬三级. 抬哪个是从"已经显示出来的牌型"里抽的
            // (键 `orbital`). 游戏那边这个选择是懒算并缓存的 (第一次渲染选盲注界面时算),
            // 这里在标签到手时就算 —— 差别只影响"轨道抽到哪个牌型", 因为 `orbital` 这个键
            // 不与别处共用, 多抽少抽都不会带偏别的随机序列.
            "tag_orbital" => {
                let pool: Vec<PokerHand> = PokerHand::BY_PRIORITY
                    .into_iter()
                    .filter(|hand| self.hands.get(*hand).visible)
                    .collect();
                if !pool.is_empty() {
                    let roll = self.rng.pseudorandom("orbital");
                    let hand = pool[(roll * pool.len() as f64) as usize % pool.len()];
                    self.hands
                        .level_up(hand, tag_config_number(key, "levels") as i32);
                }
            }
            // 其余标签的原型 `type` 是 `store_joker_create` / `store_joker_modify` / `shop_start`
            // 那几类, 改的是**生成商店货那一刻**的行为 (而不是到手时改局面), 所以它们在
            // `create_card_for_shop` 与商店结账那几处生效, 不在这里.
            _ => {}
        }
    }

    /// 跳过当前盲注, 换回它对应的标签.
    ///
    /// 与"打完"的区别在于**回合数不动**: `select_blind` 里那个 `round += 1` 只有真打才算.
    /// 跳过的那个盲注会被记成 `Skipped`, 引用它的统计 (跳过几个盲注之类) 走 `skips`.
    pub fn skip_blind(&mut self) -> Result<String, ActionError> {
        if self.phase != Phase::BlindSelect {
            return Err(ActionError::NotInPhase {
                expected: Phase::BlindSelect,
                actual: self.phase,
            });
        }
        // 小盲注与大盲注各有一个预抽好的标签; Boss 不能跳.
        let index = match self.blind_on_deck {
            BlindKind::Small => 0,
            BlindKind::Big => 1,
            BlindKind::Boss => return Err(ActionError::NotAllowed("Boss 不能跳过")),
        };
        let tag = self
            .blind_tags
            .get_mut(index)
            .and_then(|slot| slot.take())
            .ok_or(ActionError::NotAllowed("这个盲注的标签已经拿过了"))?;
        self.skips += 1;
        // 双倍标签的语义是"**持有它时**, 之后拿到的标签来两份" —— 复制的是这一次拿到的那个,
        // 而不是它自己被拿到时生效. 它自己不会再被复制 (源码里那条 `~= 'tag_double'`).
        let doubles = if tag == "tag_double" { 0 } else {
            let count = self.tags.iter().filter(|held| *held == "tag_double").count();
            self.tags.retain(|held| held != "tag_double");
            count
        };
        for _ in 0..=doubles {
            self.grant_tag(&tag);
        }
        // 前进到下一个盲注, 但**不加回合数** —— 那一笔留给真正打的盲注.
        self.blind_on_deck = match self.blind_on_deck {
            BlindKind::Small => BlindKind::Big,
            _ => BlindKind::Boss,
        };
        self.open_next_tag_pack();
        Ok(tag)
    }

    /// 按获得顺序打开一份标签包, 剩余标签等待这个包关掉后再触发.
    fn open_next_tag_pack(&mut self) {
        if self.phase != Phase::BlindSelect || self.open_pack.is_some() {
            return;
        }
        let Some(index) = self.tags.iter().position(|tag| matches!(tag.as_str(),
            "tag_charm" | "tag_meteor" | "tag_ethereal" | "tag_standard" | "tag_buffoon")) else {
            return;
        };
        let tag = self.tags.remove(index);
        if let Some(key) = free_pack_key(self, &tag) {
            let contents = super::shop::open_pack(self, &key);
            self.open_pack = Some(super::shop::OpenPack {
                choices_left: super::shop::pack_choices(&key),
                size: contents.len(),
                key,
                contents,
            });
            self.pack_return_phase = Phase::BlindSelect;
            self.phase = Phase::BoosterOpened;
            self.deal_for_pack();
        }
    }

    /// 抽一张**指定稀有度**的小丑. 幽灵与灵魂用它, 键各不同.
    ///
    /// 过滤与池键都由 `shop::pick_joker_of_rarity` 统一处理 —— 包括"传奇无视解锁"与
    /// "传奇的池键不带底注"这两条.
    fn create_joker_of_rarity(&mut self, rarity: i64, append: &str) -> Option<Joker> {
        let key = super::shop::pick_joker_of_rarity(self, rarity, append, rarity == 4)?;
        Joker::new(&key)
    }

    /// 从手里**随机**挑一张彻底删掉, 对应幻灵那批的 `random_destroy`.
    ///
    /// 是删掉而不是弃掉 —— 整副牌会因此少一张, 后面的洗牌跟着变. 手里空了就什么也不做.
    fn destroy_random_hand_card(&mut self) {
        if self.hand.is_empty() {
            return;
        }
        let roll = self.rng.pseudorandom("random_destroy");
        let index = (roll * self.hand.len() as f64) as usize % self.hand.len();
        self.hand.remove(index);
    }

    /// 给新造出来的牌发一个建牌序号, 与 `build_deck` 用的是同一套.
    ///
    /// 游戏那边就是全局计数器 `G.sort_id`, 每造一张牌自增一次 (`Card:init` 里那一句),
    /// 所以它的值**与造牌顺序一致**, 而且永不重复. 这个序号有两处用:
    ///
    /// 1. 洗牌前按它排序 (`pseudoshuffle` 开头那一次 `table.sort`);
    /// 2. 手牌排序时的**兜底比较项** —— `Card:get_nominal` 最后加的是
    ///    `0.000001 * (1 - Card.ID/1603301)`, 而 `Card.ID` 是**另一条**全局计数器 (`Node:init`),
    ///    它在造牌顺序上单调递减, 所以作用等价于"**先造的排前面**".
    ///
    /// 所以这个值必须是**单调递增的计数器**, 不能写成"当前牌堆里最大的那个加一":
    /// 那样一遇到"最大的那张正拿在手里"就会发出一个比它小的号, 于是两张牌的先后关系
    /// 与造牌顺序相反 —— 而后果是*整副牌洗完的顺序都不一样*, 表现成"某一手发出的牌对不上",
    /// 与真实原因隔得很远. (第 89 步那两张 S_K 的先后就是这么来的.)
    fn next_sort_id(&mut self) -> u32 {
        self.next_card_id += 1;
        self.next_card_id
    }

    /// 手牌上限, 对应 `starting_params.hand_size` 减去 Boss 的临时扣减.
    ///
    /// 基础值是 8, 镣铐 (The Manacle) 那一类会把它压低, 最低不会低过 1.
    pub fn hand_size(&self) -> usize {
        (8 + self.hand_size_bonus + self.temporary_hand_size_bonus - self.hand_size_sub).max(1) as usize
    }

    /// 把这个盲注**停用并且把它留下的痕迹擦掉** —— 对应 `Blind:disable()`.
    ///
    /// 两条进入路径: 奇可 (摆盲注时的 `setting_blind`) 与翠叶 (卖掉一张小丑).
    /// 三件事一件都不能少, 理由写在 [`crate::run::blind::Blind::disable`] 上, 这里做的是
    /// "改分数" 之外的那两件 —— **把削掉的牌恢复, 把锁住的牌解锁**:
    /// 游戏那个函数结尾对所有牌与小丑重跑一遍 `debuff_card`, 而那时 `disabled` 已为真,
    /// 于是每条 Boss 分支都跳过, 落到最后那句 `card:set_debuff(false)`.
    ///
    /// 只置一个标志而不清削弱的话, "卖掉小丑解除翠叶"就只剩个说法 ——
    /// 卖完这一回合剩下的手牌仍然一分不出.
    fn disable_blind(&mut self) {
        let Some(blind) = self.blind.as_mut() else {
            return;
        };
        if blind.disabled {
            return;
        }
        blind.disable();
        // 所有区域的牌都要恢复: 游戏遍历的是 `G.playing_cards` (全文那一整份).
        for card in self
            .deck
            .iter_mut()
            .chain(self.hand.iter_mut())
            .chain(self.play_area.iter_mut())
            .chain(self.discard_pile.iter_mut())
        {
            card.debuffed = false;
            card.forced_selection = false;
        }
    }

    /// 从牌堆末尾抽一张到手牌. 牌堆空了返回 `false`.
    ///
    /// 每抽一张都要问一次"这张牌进来时背面朝上吗" (`Blind:stay_flipped`), 因为**轮子 (The Wheel)
    /// 在那一问里掷骰**: 它的规则是"每张抽进来的牌有 1/7 概率背面朝上", 写法就是
    /// `pseudorandom(pseudoseed('wheel')) < G.GAME.probabilities.normal/7`.
    ///
    /// # 这一掷为什么在 digest 上看不出来 (但还是要照掷)
    ///
    /// 它**不会**让别的掷骰错位 —— 游戏的 `pseudorandom` 是**按键独立**的: 每次调用先
    /// `pseudoseed(键)` (只读这个键自己的计数与开局的种子) 再 `math.randomseed`, 于是任意两个键
    /// 的序列互不影响. 实测 (LuaJIT 与本引擎一致): 先连掷 8 次 `wheel` 再掷 `joker`, 与直接掷
    /// `joker` 得到的是同一个数.
    ///
    /// 而 `'wheel'` 这个键**只在这一处**被用到 (`game/blind.lua` 里仅此一次), 背面本身又只影响
    /// 画面 (不吃计分, 也不进 digest —— 见 `token_of`). 所以这一掷目前**没有任何可观测效果**.
    ///
    /// 仍然照掷的理由: 它是 `stay_flipped` 的一个真实分支, 键的计数该像游戏一样往前走;
    /// 哪天引擎要暴露"哪些牌是背面"(agent 看不到的牌)这块状态, 图案就得来自它.
    /// 值本身已经与真 LuaJIT 对拍过 (见 `tests/luajit_parity.rs` 的 wheel 段).
    ///
    /// 另外三个"背面"Boss 不掷骰, 所以这里不需要为它们做什么:
    /// - 房子 (The House): 这一回合第一次抽牌才背面, 判据是"还没出过牌也没弃过牌";
    /// - 记号 (The Mark): 人头牌背面, 判据是牌自己;
    /// - 鱼 (The Fish): 每次出牌之后抽的都是背面, 判据是一个"准备好了"的标志.
    ///
    /// 至于**造牌**进手牌 (证书小丑, 熟悉的幻灵, 藏头诗的幻灵那种) 不走这里 —— 游戏那边它们
    /// 是 `create_playing_card(..., G.hand, ...)` 直接放的, 不经过 `draw_card`, 自然也不问这一句.
    fn draw_one(&mut self) -> bool {
        match self.deck.pop() {
            Some(card) => {
                // 掷在放牌**之前** —— 游戏里 `stay_flipped` 也是先问、再 `emplace`.
                self.roll_stay_flipped();
                self.hand.push(card);
                true
            }
            None => false,
        }
    }

    /// 抽牌时那一问 (`Blind:stay_flipped`). 只有轮子会在里面掷骰, 所以只有它需要照做.
    ///
    /// 盲注被停用 (翠叶卖小丑, 或奇可) 时不掷 —— 游戏那句是 `if not self.disabled then`.
    /// 也不在**回合之外**掷: 盲注打赢的那一刻就被清空了 (`Blind:defeat` 里把名字置成空串),
    /// 所以商店里开包补的那一手不掷 (详见 `RunState::in_blind`).
    fn roll_stay_flipped(&mut self) {
        let wheel = self.in_blind
            && self
                .blind
                .as_ref()
                .is_some_and(|blind| blind.key == "bl_wheel" && !blind.disabled);
        if wheel {
            let _ = self.rng.pseudorandom("wheel");
        }
    }

    /// 补满手牌. 对应 `draw_from_deck_to_hand`, 每次抽牌之后都重排.
    pub fn draw_to_hand(&mut self) {
        // 猩红之心 (决战 Boss): **每次发牌**换一个随机小丑失效, 键 `crimson_heart`.
        //
        // 候选名单**不含当前正失效的那一张**, 这一条容易看漏, 因为它是写在同一个循环里的:
        //
        // ```lua
        // for i = 1, #G.jokers.cards do
        //   if not G.jokers.cards[i].debuff or #G.jokers.cards < 2 then jokers[#jokers+1] = ... end
        //   G.jokers.cards[i]:set_debuff(false)          -- 清在**收集之后**
        // end
        // ```
        //
        // 两点都要照做: 判据读的是**清之前**的状态 (所以只有一张小丑时才允许它自己再被抽中),
        // 而"清"发生在**收集之后**. 名单长度因此是 `N-1` 而不是 `N` —— 而名单长度会改变
        // `pick_index` 的结果, 于是**抽到的是哪张也会不同**. 照"从全部里抽"写会连着两次
        // 抽中同一张, 而游戏不会.
        if self
            .blind
            .as_ref()
            .is_some_and(|b| b.key == "bl_final_heart" && !b.disabled)
            && !self.jokers.is_empty()
        {
            let single = self.jokers.len() < 2;
            let candidates: Vec<usize> = self
                .jokers
                .iter()
                .enumerate()
                .filter(|(_, joker)| single || !joker.debuffed)
                .map(|(index, _)| index)
                .collect();
            for joker in self.jokers.iter_mut() {
                joker.debuffed = false;
            }
            let seed = self.rng.pseudoseed("crimson_heart");
            let pick = self.rng.pick_index(candidates.len(), seed);
            self.jokers[candidates[pick]].debuffed = true;
        }

        // 蛇 (The Serpent): 出过牌或弃过牌之后, 每次都**只抽三张** (牌堆不够就抽多少算多少),
        // 而不是把手牌补满. 开局的发牌不受影响 —— 那时这一回合还没出过牌也没弃过牌.
        //
        // 前提是**正在这个盲注里** (`in_blind`): 它的效果不管商店里发生的事 ——
        // 商店里开秘术包会补满一手, 而不是三张 (XXWF71H9 第 167 步).
        let serpent = self.in_blind
            && self
                .blind
                .as_ref()
                .is_some_and(|blind| blind.key == "bl_serpent" && !blind.disabled)
            && (!self.round_hand_types.is_empty() || self.discards_used > 0);
        if serpent {
            for _ in 0..self.deck.len().min(3) {
                if !self.draw_one() {
                    break;
                }
            }
            self.sort_hand();
            return;
        }
        while self.hand.len() < self.hand_size() {
            if !self.draw_one() {
                break;
            }
            self.sort_hand();
        }
        // 蓝铃是靠 `drawn_to_hand` 那个钩子跑的 —— 也就是**发完之后**才掷;
        // 放在函数开头会看到空手牌, 于是永远不锁.
        // 蓝铃 (决战 Boss): 手里**没有**被锁定的牌时, 随机锁一张 (`pseudoseed('cerulean_bell')`).
        // 锁定的那张不能取消选中, 所以每次出牌都得带上它.
        if self
            .blind
            .as_ref()
            .is_some_and(|b| b.key == "bl_final_bell" && !b.disabled)
            && !self.hand.is_empty()
            && !self.hand.iter().any(|card| card.forced_selection)
        {
            let seed = self.rng.pseudoseed("cerulean_bell");
            let index = self.rng.pick_index(self.hand.len(), seed);
            self.hand[index].forced_selection = true;
        }

    }

    /// 手牌重排, 对应 `CardArea:sort(...)` —— **按这一区记下的排序方式**.
    ///
    /// 用的是**Lua 的 `table.sort`** (不是 Rust 的排序): 两张同点数的牌之间谁在前, 由那一份
    /// 不稳定快排的交换过程决定, 而手牌顺序会影响后面每一步用的下标.
    /// 整局对拍里 133 步那份第 89 步就是两张 K 的先后反了 —— 见 [`crate::lua::table_sort`].
    ///
    /// 游戏那边这一步是 `to:sort()` (不带参数), 于是沿用 `config.sort`; 所以这里也要看
    /// [`crate::run::state::HandSort`], 而不是永远按点数排.
    fn sort_hand(&mut self) {
        match self.hand_sort {
            crate::run::state::HandSort::Value => {
                crate::lua::table_sort::sort_by(&mut self.hand, |a, b| {
                    a.card.nominal_with_stone(a.is_stone())
                        > b.card.nominal_with_stone(b.is_stone())
                });
            }
            crate::run::state::HandSort::Suit => {
                crate::lua::table_sort::sort_by(&mut self.hand, |a, b| {
                    a.card.nominal_suit_with_stone(a.is_stone())
                        > b.card.nominal_suit_with_stone(b.is_stone())
                });
            }
        }
    }

    /// 手牌按**花色**降序重排, 对应 `G.FUNCS.sort_hand_suit` 里的 `G.hand:sort('suit desc')`.
    ///
    /// 它会**把这一区的排序方式改成按花色** —— 之后每次发牌都照这个排, 直到再按另一个按钮.
    pub fn sort_hand_by_suit(&mut self) {
        self.hand_sort = crate::run::state::HandSort::Suit;
        self.sort_hand();
    }

    /// 手牌按点数降序重排 —— 对应 `G.FUNCS.sort_hand_value` 里的 `G.hand:sort('desc')`,
    /// 同样会把这一区的排序方式改回按点数.
    pub fn sort_hand_by_value(&mut self) {
        self.hand_sort = crate::run::state::HandSort::Value;
        self.sort_hand();
    }

    /// 手动调换手牌顺序, 对应 `bbcore` 的 `rearrange` 端点.
    ///
    /// `order[k]` 说的是"新顺序里的第 k 张, 来自原来的第几张". 顺序本身**就是状态**:
    /// 出牌与弃牌用的都是下标, 所以这一步不能当成没发生 —— 少了它, 后面每一步都会指到别的牌上.
    ///
    /// 游戏那边是直接换掉 `G.hand.cards` 这个数组, 所以**不做排序**; 下一次发牌 (`sort('desc')`)
    /// 才会把它按牌面重排.
    pub fn rearrange_hand(&mut self, order: &[usize]) -> Result<(), ActionError> {
        check_permutation(order, self.hand.len())?;
        let old = std::mem::take(&mut self.hand);
        self.hand = order.iter().map(|&from| old[from]).collect();
        Ok(())
    }

    /// 同上, 但调换的是小丑的顺序 (`order[k]` 同样表示来自原来的第几张).
    pub fn rearrange_jokers(&mut self, order: &[usize]) -> Result<(), ActionError> {
        check_permutation(order, self.jokers.len())?;
        let old = std::mem::take(&mut self.jokers);
        self.jokers = order.iter().map(|&from| old[from].clone()).collect();
        Ok(())
    }

    /// 同上, 但调换的是消耗牌的顺序.
    pub fn rearrange_consumables(&mut self, order: &[usize]) -> Result<(), ActionError> {
        check_permutation(order, self.consumables.len())?;
        let old = std::mem::take(&mut self.consumables);
        self.consumables = order.iter().map(|&from| old[from].clone()).collect();
        Ok(())
    }

    /// 校验一组手牌下标.
    fn check_indices(&self, indices: &[usize], limit: usize) -> Result<(), ActionError> {
        if indices.is_empty() {
            return Err(ActionError::NoCards);
        }
        if indices.len() > limit {
            return Err(ActionError::TooManyCards {
                limit,
                got: indices.len(),
            });
        }
        for &index in indices {
            if index >= self.hand.len() {
                return Err(ActionError::BadIndex(index));
            }
        }
        Ok(())
    }

    /// 把选中的牌按手牌从左到右取出 (游戏在出牌或弃牌前会先按横坐标排一次).
    fn take_selected(&mut self, indices: &[usize]) -> Vec<CardInstance> {
        let mut sorted: Vec<usize> = indices.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        // 从后往前删, 免得下标移位.
        let mut taken = Vec::with_capacity(sorted.len());
        for &index in sorted.iter().rev() {
            taken.push(self.hand.remove(index));
        }
        taken.reverse();
        taken
    }

    /// 弃牌: 选中几张就从牌堆补几张, 消耗一次弃牌机会.
    pub fn discard(&mut self, indices: &[usize]) -> Result<(), ActionError> {
        if self.phase != Phase::SelectingHand {
            return Err(ActionError::NotInPhase {
                expected: Phase::SelectingHand,
                actual: self.phase,
            });
        }
        if self.discards_left <= 0 {
            return Err(ActionError::NoDiscardsLeft);
        }
        self.check_indices(indices, 5)?;

        let taken = self.take_selected(indices);
        // 弃牌时的那两个钩子 (绿色小丑掉倍率 / 城堡认花色长大).
        let castle_suit = self.castle_suit;
        let pareidolia = self
            .jokers
            .iter()
            .any(|joker| joker.key == "j_pareidolia" && !joker.debuffed);
        for joker in self.jokers.iter_mut() {
            joker.on_discard(&taken, castle_suit, pareidolia);
        }
        // 拉面: 掉到 1 及以下就没得掉了, 直接销毁 (游戏是先判后减, 与蛋那类一样).
        let ramen_dead: Vec<usize> = self
            .jokers
            .iter()
            .enumerate()
            .filter(|(_, joker)| joker.key == "j_ramen" && joker.x_mult <= 1.0)
            .map(|(index, _)| index)
            .collect();
        for index in ramen_dead.into_iter().rev() {
            let key = self.jokers[index].key.clone();
            let current = self.jokers[index].extra;
            self.jokers.remove(index);
            apply_joker_on_loss(self, &key, current);
        }
        // 邮件回扣: 弃掉的牌里**点数对得上本回合那个点数**的, 每张给 5 块.
        let mail_money = if let Some(rank) = self.mail_rank {
            if self
                .jokers
                .iter()
                .any(|joker| joker.key == "j_mail" && !joker.debuffed)
            {
                let hits = taken
                    .iter()
                    .filter(|card| card.card.rank == rank && !card.debuffed)
                    .count();
                hits as f64 * 5.0
            } else {
                0.0
            }
        } else {
            0.0
        };
        self.dollars += mail_money;

        // 卡牌交易: 本回合**第一次**弃牌而且只弃了一张时, 那一张被**销毁** (不进弃牌堆), 给 3 块.
        let trading = self.discards_used == 0
            && taken.len() == 1
            && self
                .jokers
                .iter()
                .any(|joker| joker.key == "j_trading" && !joker.debuffed);
        if trading {
            self.dollars += 3.0;
        }

        // 无面者给的钱: 钩子只把它记在小丑身上, 这里收上来.
        let mut faceless = 0.0;
        for joker in self.jokers.iter_mut() {
            if joker.faceless_dollars > 0.0 {
                faceless += joker.faceless_dollars;
                joker.faceless_dollars = 0.0;
            }
        }
        self.dollars += faceless;

        // 焦小丑 (`j_burnt`): **本回合第一次弃牌**时, 把弃掉那几张的牌型升一级.
        // 游戏那边是 `pre_discard` 那一步 (`get_poker_hand_info(G.hand.highlighted)` 取最好的一手),
        // 条件是 `discards_used <= 0` —— 也就是**累加之前**的值.
        if self.discards_used == 0
            && self
                .jokers
                .iter()
                .any(|joker| joker.key == "j_burnt" && !joker.debuffed)
        {
            let views: Vec<_> = taken.iter().map(|c| c.to_hand_card()).collect();
            let evaluated = crate::scoring::evaluate_poker_hand(&views, &Default::default());
            if let Some(hand) = evaluated.top() {
                self.hands.level_up(hand, 1);
            }
        }
        // 这一条原来**从来没有累加过** (只有重置与读取), 于是三处都错:
        // 蛇的"只抽三张"在弃过牌之后不生效; 延迟满足的"没用过弃牌才给钱"永远成立;
        // 焦小丑的"第一次弃牌"判不出来.
        self.discards_used += 1;
        // 紫封: 弃掉带紫封的牌时给一张塔罗 (`Card:calculate_seal` 的 discard 那一支).
        // 消耗槽满就不给, 与游戏一致.
        let purple = taken
            .iter()
            .filter(|card| card.seal == Some(Seal::Purple))
            .count();
        for _ in 0..purple {
            if self.consumables.len() >= self.consumable_capacity() {
                break;
            }
            let key = super::shop::create_card(self, "Tarot", "8ba");
            self.consumables
                .push(super::consumable::Consumable::plain(key));
        }
        // 卡牌交易销毁掉的那一张**不进弃牌堆** (游戏是 `remove = true`); 其余照常进弃牌堆.
        if !trading {
            self.discard_pile.extend(taken);
        }
        self.discards_left -= 1;

        // 补牌与出牌走的是同一条路 (游戏里两处都调 `draw_from_deck_to_hand`, 而且不传张数,
        // 由那个函数自己算该抽几张). 平常正好补回弃掉的张数, 而蛇在里面改成固定三张.
        self.draw_to_hand();
        Ok(())
    }

    /// 出牌: 选中的牌移进出牌区并计分.
    ///
    /// 达成目标就地收尾 (`end_round`), 否则补满手牌. 顺序照 `evaluate_play` 的最后一步:
    /// 先判断, 达标就不再补抽.
    pub fn play(
        &mut self,
        indices: &[usize],
        env: &EvalEnv,
        back: BackEffect,
    ) -> Result<ScoreResult, ActionError> {
        if self.phase != Phase::SelectingHand {
            return Err(ActionError::NotInPhase {
                expected: Phase::SelectingHand,
                actual: self.phase,
            });
        }
        if self.hands_left <= 0 {
            return Err(ActionError::NoHandsLeft);
        }
        self.check_indices(indices, 5)?;

        // 手里有这四张时, 它们改的是**牌型判定本身** (四指放宽同花与顺子 / 捷径允许间隔 /
        // 模糊把红黑合成两类 / 飞溅让所有打出的牌都参与计分).
        // 这四个标志 `EvalEnv` 里一直都有, 但**从来没人按手里的小丑设置过** ——
        // 也就是说拿着它们等于没拿. 这里按"有就置上"的口径补上 (调用方另外传进来的照旧保留).
        let mut env = *env;
        let active = |key: &str| {
            self.jokers
                .iter()
                .any(|joker| joker.key == key && !joker.debuffed)
        };
        if active("j_four_fingers") {
            env.four_fingers = true;
        }
        if active("j_splash") {
            env.splash = true;
        }
        if active("j_shortcut") {
            env.shortcut = true;
        }
        if active("j_smeared") {
            env.smeared = true;
        }
        // 七上八下: 概率翻倍要传给计分那一层 (血石那条路在那里掷骰).
        env.probability_extra = self.probability_scale - 1.0;
        // 消耗槽还剩几个位子也要传 —— 八号球那类"计分中造牌"的小丑是**先看位子再掷骰**,
        // 位子数传不进去的话它们会以为槽是满的, 于是永远不掷 (这个坑刚踩过一次).
        env.consumable_room = self.consumable_capacity().saturating_sub(self.consumables.len());
        env.idol_card = self.idol_card;
        // 帕瑞多利亚: 人人都是人头牌 —— 计分那一层也要知道.
        if active("j_pareidolia") {
            env.pareidolia = true;
        }
        let env = &env;

        // 通灵 (The Psychic): 出的牌少于五张算无效. 对应 `Blind:debuff_hand` 里那条.
        if self.blind.as_ref().is_some_and(|b| b.key == "bl_psychic" && !b.disabled) && indices.len() < 5 {
            return Err(ActionError::TooFewCards {
                least: 5,
                got: indices.len(),
            });
        }

        // 蓝铃锁定的那几张**不能取消选中**: 出手时自动带上它们 (游戏那边它一直是高亮状态).
        // 对回放来说这一步通常是空操作 —— 记录里的出牌本来就带着它.
        let mut wanted: Vec<usize> = indices.to_vec();
        for (index, card) in self.hand.iter().enumerate() {
            if card.forced_selection && !wanted.contains(&index) {
                wanted.push(index);
            }
        }
        wanted.sort_unstable();
        let indices = wanted.as_slice();

        let mut taken = self.take_selected(indices);
        // 打出去的牌记一笔"这一底注出过", 柱子 (The Pillar) 下个盲注就削它们.
        for card in &mut taken {
            card.played_this_ante = true;
        }
        // "这一回合还没打过牌"要在**这里**就先记下来: 往下走到算分之前那儿, 有一处会把
        // 这一手的牌型记进 `round_hand_types` (Boss "嘴" 的判定要用), 之后再查就不准了 ——
        // 第六感原来就是在那个位置查的, 于是它的第一个条件永远是假.
        let first_hand_of_round = self.round_hand_types.is_empty();

        // DNA: **这一回合的第一手**如果只打出一张牌, 就复制一张永久加进牌堆.
        // 游戏在 `context.before` 那一趟做 (`hands_played == 0` 且 `#full_hand == 1`),
        // 也就是**计分之前** —— 所以复制出来的那张不会参与这一手的计分.
        // (游戏还会把它临时摆进手牌区; 这里只做"永久进牌堆"那一半, 手牌那一半是显示用的.)
        if taken.len() == 1
            && first_hand_of_round
            && self
                .jokers
                .iter()
                .any(|joker| joker.key == "j_dna" && !joker.debuffed)
        {
            // DNA: **这一回合的第一手**如果只打出一张牌, 就复制一张永久加进牌堆.
            // 复制出来的是**新造的牌** (`copy_card`), 所以先给它新号再加 (见 `duplicate_card`).
            let copy = self.duplicate_card(&taken[0]);
            self.add_playing_card_to_deck(copy);
        }

        let views: Vec<_> = taken.iter().map(CardInstance::to_hand_card).collect();
        // 骰子不再在这里预掷 —— 幸运牌与血石那几张都是"每张计分牌各掷一次", 而且队里有几张
        // 就掷几次, 预掷既要算准张数又要按小丑区分, 索性把 `rng` 交给计分那一层自己掷.
        // 顺带修掉一个错: 以前这里给**所有打出的牌**都掷了, 而游戏只给**参与计分**的牌掷.
        // 有几张小丑要看局面 (旗帜看剩余弃牌, 斗牛看现金), 把当前值填进环境再算.
        // `EvalEnv` 是 `Copy`, 所以直接拷一份改, 不走 `clone`.
        let mut env = *env;
        env.discards_left = self.discards_left;
        env.dollars = self.dollars;
        env.deck_len = self.deck.len();
        env.discards_used = self.discards_used;
        env.joker_capacity = self.joker_capacity();
        // 整副牌的几项计数. 口径是游戏的 `G.playing_cards` —— **还活着**的全部牌:
        // 牌堆 + 手牌 + 弃牌堆 + 刚打出去的那几张 (那几张这时在 `taken` 里, 不在任何区).
        // 石头小丑 / 侵蚀 / 驾照都看它们.
        {
            let all = self
                .deck
                .iter()
                .chain(self.hand.iter())
                .chain(self.discard_pile.iter())
                .chain(taken.iter());
            env.deck_total = all.clone().count();
            env.deck_stones = all.clone().filter(|card| card.is_stone()).count();
            env.deck_enhanced = all.filter(|card| card.enhancement.is_some()).count();
            env.starting_deck_size = self.starting_deck_size;
        }
        // 出牌次数在**算分之前**就减掉 —— 游戏里 `ease_hands_played(-1)` 排在计分那一段之前,
        // 所以"最后一手"在计分时看到的 `hands_left` 已经是 0 (杂技演员靠这个判).
        self.hands_left -= 1;
        env.hands_left = self.hands_left;
        // 燧石砍的是**牌型的基础**值, 所以要在算分前告诉计分那一层.
        env.flint = self
            .blind
            .as_ref()
            .is_some_and(|blind| blind.key == "bl_flint" && !blind.disabled);

        // 手牌型只判一次, 下面几处都用它 (臂 / 牛 / 眼 / 嘴都要看这一手是什么牌型).
        let evaluated = evaluate_poker_hand(&views, &env);
        let played_hand = evaluated.top();

        // 天文台 (优惠券): 消耗区里有几张**对应本手牌型**的行星牌, 每张给一次 ×1.5.
        // 对应关系在目录里 (`config.hand_type`, 例如 "Pair"), 与牌型的英文名一致.
        if self.used_vouchers.contains("v_observatory")
            && let Some(hand) = played_hand
        {
            let key = hand.info().key;
            env.observatory_planets = self
                .consumables
                .iter()
                .filter(|consumable| {
                    crate::data::catalog::Catalog::get()
                        .record(&consumable.key)
                        .and_then(|proto| proto.config.as_ref())
                        .and_then(|config| config.get("hand_type"))
                        .and_then(|value| value.as_str())
                        .is_some_and(|hand_type| hand_type == key)
                })
                .count();
        }

        // 眼 (The Eye) 与嘴 (The Mouth) 限的是"这一回合打什么牌型", 违规时**整手不计分**:
        // 游戏里 `debuff_hand` 返回真就跳过算分那一整段 (连玻璃碎裂也在那一段里), 但这一手
        // 照样算打过了 —— `played` 是在 `debuff_hand` **之前**加的.
        //
        // **停用的 Boss 整条不生效**: 游戏那两个入口 (`Blind:debuff_hand` 与 `Blind:press_play`)
        // 开头都是 `if self.disabled then return end`, 而希科 (传奇) 正是在 `setting_blind`
        // 那一刻把这一底的 Boss 停用掉. 少了这个判断, 拿着希科照样会被 Boss 削手 ——
        // 整局对拍里 133 步那份第 72 步就是这么差的: 引擎把这手同花判成"嘴不允许的第二种牌型"
        // 而不计分, 于是回合没打掉, 而游戏那边打赢了 (它是同一手同花过的关).
        let boss_active = self.blind.as_ref().is_some_and(|blind| !blind.disabled);
        let banned_hand = if boss_active {
            match self.blind.as_ref().map(|blind| blind.key.as_str()) {
                Some("bl_eye") => {
                    played_hand.is_some_and(|hand| self.round_hand_types.contains(&hand))
                }
                Some("bl_mouth") => matches!(
                    (self.round_hand_types.first(), played_hand),
                    (Some(first), Some(now)) if *first != now
                ),
                _ => false,
            }
        } else {
            false
        };

        // 斗牛士: 这一手正好是 Boss **削弱**的牌型时给 8 块.
        // 游戏判据是 `G.GAME.blind.triggered`, 也就是"这个 Boss 把这一手削了" ——
        // 引擎里与之对应的就是上面那个 `banned_hand` (眼 / 嘴那两个"整手不计分"的 Boss),
        // 而按牌面削的那类 Boss 不属于这里 (它们削的是牌, 不是牌型).
        // 停用的 Boss 不会把 `triggered` 置上 (`debuff_hand` 提前返回了), 所以这里跟着
        // `banned_hand` 走就够了 —— 它已经被停用标志挡过一道.
        if banned_hand
            && self
                .jokers
                .iter()
                .any(|joker| joker.key == "j_matador" && !joker.debuffed)
        {
            self.dollars += 8.0;
        }

        let blocked = banned_hand;
        if let Some(hand) = played_hand {
            self.round_hand_types.push(hand);
        }

        // Boss 那几笔都记在**算分之前** (游戏里分别在 `press_play` 与 `debuff_hand` 两步):
        // 牙按打出的**张数**扣钱, 臂把这一手的等级降一级, 牛在打到最常用牌型时把钱清零.
        // 顺序要紧 —— 斗牛那类小丑算分时读的是**改过之后**的现金.
        // 同样受"停用的 Boss 整条不生效"约束 (那几笔都在 `Blind:press_play` 里).
        if boss_active {
            match self.blind.as_ref().map(|blind| blind.key.as_str()) {
                Some("bl_tooth") => self.dollars -= taken.len() as f64,
                Some("bl_arm") => {
                    if let Some(hand) = played_hand
                        && self.hands.get(hand).level > 1
                    {
                        self.hands.level_up(hand, -1);
                    }
                }
                Some("bl_ox") => {
                    if let Some(hand) = played_hand
                        && hand == self.hands.most_played()
                    {
                        self.dollars = 0.0;
                    }
                }
                _ => {}
            }
        }

        // 被眼或嘴拦下时整手不计分: 算分那一整段都不进, 所以什么都没得 ——
        // 不给钱, 也没有步骤, 玻璃牌也不碎 (玻璃那段同样在算分那一段里).
        // 牌型本身还是"打过了", 那笔账在后面记.
        // 太空小丑: 计分**之前**掷一次 (键 `space`, 概率 1/extra), 中了把这一手的牌型升一级.
        // 游戏把它放在 `context.before` 那一趟, 所以这一手就能用上升级后的数值 ——
        // 与吸血鬼同一个道理, 放运行层、调计分之前做就是精确的.
        if self
            .jokers
            .iter()
            .any(|joker| joker.key == "j_space" && !joker.debuffed)
            && let Some(hand) = evaluated.top()
        {
            let odds = self
                .jokers
                .iter()
                .find(|joker| joker.key == "j_space")
                .map(|joker| joker.extra)
                .unwrap_or(4.0);
            let roll = self.rng.pseudorandom("space");
            if odds > 0.0 && roll < self.probability_scale / odds {
                self.hands.level_up(hand, 1);
            }
        }

        // 第六感: 这一回合的**第一手**只打出一张 **6** 时, 把它**销毁**, 并造一张幽灵牌.
        // 判定三条与游戏一致 (只一张 / 点数是 6 / 本回合还没打过牌); 造牌走与别处同一个入口,
        // 销毁则是"不进弃牌堆" —— 那张牌就此消失, 不回牌堆也不进弃牌堆.
        let sixth_sense_fires = first_hand_of_round
            && taken.len() == 1
            && taken[0].card.rank == Rank::Six
            && self.consumables.len() < self.consumable_capacity()
            && self
                .jokers
                .iter()
                .any(|joker| joker.key == "j_sixth_sense" && !joker.debuffed);
        let mut sixth_sense_card = None;
        if sixth_sense_fires {
            let mut creation = super::shop::creation_from(self);
            let key = super::shop::create_consumable(&mut creation, &mut self.rng, "Spectral", "sixth", true);
            creation.merge_back(self);
            self.consumables
                .push(crate::run::consumable::Consumable::plain(key));
            sixth_sense_card = Some(taken[0].card);
        }

        // 吸血鬼: **计分之前**把这一手**计分牌**里带强化的那些吸掉 (去掉强化), 每张给自己涨 0.1 乘倍率.
        // 游戏把它放在 `context.before` 那一趟 —— 也就是计分之前, 所以成长后的倍率**这一手就生效**,
        // 由通用分支付账. 既然在计分之前, 引擎这边就不用碰"计分只读"那条约束.
        if self
            .jokers
            .iter()
            .any(|joker| joker.key == "j_vampire" && !joker.debuffed)
            && let Some(group) = evaluated.top_group().cloned()
        {
            let mut drained = 0usize;
            // 注意这里动的是**打出去的那几张** (`taken`), 不是手牌 —— 到这个位置牌已经从手上搬走了,
            // 而 `top_group` 的下标也是冲着"打出的牌"编的.
            for index in group {
                if let Some(card) = taken.get_mut(index)
                    && card.enhancement.is_some()
                    && !card.debuffed
                {
                    card.enhancement = None;
                    drained += 1;
                }
            }
            if drained > 0 {
                for joker in self.jokers.iter_mut() {
                    if joker.key == "j_vampire" && !joker.debuffed {
                        joker.x_mult += 0.1 * drained as f64;
                    }
                }
            }
        }

        let result = if blocked {
            ScoreResult {
                consumables: Vec::new(),
                hand: played_hand.expect("上面判过至少有牌型"),
                scoring_cards: Vec::new(),
                base_chips: 0.0,
                base_mult: 0.0,
                chips: 0.0,
                mult: 0.0,
                total: 0.0,
                steps: Vec::new(),
                melted: Vec::new(),
                dollars: 0.0,
                // 这一手是被封禁的, 不是"算出来零分" —— 明细靠这个标志说明原因.
                blocked: true,
            }
        } else {
            // 手里**没打出去**的那些牌也要交进去: 钢铁牌 (`h_x_mult`) 与男爵 / 射月 / 致胜之拳
            // 那类小丑看的就是它们. 以前这里没传, 等于那些效果在对局里从来没生效过.
            let held: Vec<_> = self.hand.iter().map(CardInstance::to_hand_card).collect();
            // 骰子也交进去: 幸运牌 / 血石 / 生意那几张要在算分过程里掷.
            // 走**带造牌家当**那条入口: 八号球那类会在计分过程中造一张消耗牌,
            // 而造牌自己也要掷骰 (键 `spe_card` 那几条), 必须在计分那一步照原样掷,
            // 否则**该造出来的那张**会不一样.
            // 造完之后把"用过哪些"并回运行状态.
            let mut creation = super::shop::creation_from(self);
            let result = crate::scoring::score_play_with_creation(
                &views,
                &held,
                &self.hands,
                &env,
                back,
                &mut self.jokers,
                &mut creation,
                &mut self.rng,
            )
            .expect("出牌至少有一张, 应当能识别牌型");
            creation.merge_back(self);
            // 计分过程中小丑造出来的消耗牌 (八号球那类) **由这里入槽** ——
            // 计分那一层只负责"报告造了什么", 持有区归运行层管.
            for key in &result.consumables {
                self.consumables
                    .push(crate::run::consumable::Consumable::plain(key.clone()));
            }
            result
        };

        self.chips += result.total;
        // 金封这类"打出去就给钱"的效果当场结算, 不走回合末的结算栏.
        self.dollars += result.dollars;

        // 用完就没了的小丑 (冰淇淋化完, 汽水喝完) 当场离开持有区.
        // 计分那一层只负责判定并把下标报出来, 真正挪走是这里的事 ——
        // **只判定不挪走的话, 它们会一直待在队里** (这一段以前就漏了, 而且不报错).
        // 下标从后往前删, 免得前面的错位.
        for &index in result.melted.iter().rev() {
            if index < self.jokers.len() {
                self.jokers.remove(index);
            }
        }

        // 玻璃牌碎裂: 排在计分**之后** (游戏里是在出分完成那一步掷的), 每张参与计分的玻璃牌
        // 各掷一次 `pseudorandom('glass')`, 小于 1/4 就碎. 被削弱的牌不掷也不碎.
        // 碎掉的牌**不进弃牌堆**, 直接从牌堆里消失 —— 后面的洗牌与牌数会跟着变.
        let mut shattered: Vec<usize> = Vec::new();
        for &index in &result.scoring_cards {
            if taken[index].enhancement == Some(Enhancement::Glass) && !taken[index].debuffed {
                let roll = self.rng.pseudorandom("glass");
                if roll < 1.0 / 4.0 {
                    shattered.push(index);
                }
            }
        }
        // 玻璃小丑: 每碎掉一张玻璃牌就给自己涨 0.75 乘倍率 (它自己那个 `x_mult`).
        if !shattered.is_empty() {
            for joker in self.jokers.iter_mut() {
                if joker.key == "j_glass" && !joker.debuffed {
                    joker.x_mult += 0.75 * shattered.len() as f64;
                }
            }
        }

        // `scoring_cards` 是升序的, 所以从后往前删不会让前面的下标错位.
        for &index in shattered.iter().rev() {
            taken.remove(index);
        }

        // 徒步者: 每张**计分**的牌永久 +5 筹码 (`ability.perma_bonus`, 牌上那个字段早就有,
        // 只是没人往上加过). 加在被打出去的那几张上 —— 它们就是牌堆里那几个对象, 所以是永久的.
        if self
            .jokers
            .iter()
            .any(|joker| joker.key == "j_hiker" && !joker.debuffed)
        {
            for index in result.scoring_cards.iter().copied() {
                if let Some(card) = taken.get_mut(index)
                    && !card.debuffed {
                    card.perma_bonus += 5.0;
                }
            }
        }

        // 迈达斯面具: 这一手**计分的人头牌**变成黄金牌 (永久改, 与游戏一致).
        if self
            .jokers
            .iter()
            .any(|joker| joker.key == "j_midas_mask" && !joker.debuffed)
        {
            for index in result.scoring_cards.iter().copied() {
                if let Some(card) = taken.get_mut(index)
                    && !card.debuffed
                    && (card.card.rank.is_face() || self.has_pareidolia())
                {
                    card.enhancement = Some(Enhancement::Gold);
                }
            }
        }

        // 大摇大摆: 倍率 = 1 + **其他**小丑卖价之和, 每次出牌都重算.
        // 卖价是"买入价的一半向下取整, 最低一元", 与真正卖掉时用的是同一条公式.
        let others_sell: f64 = self
            .jokers
            .iter()
            .filter(|joker| joker.key != "j_swashbuckler")
            .map(Joker::sell_price)
            .sum();
        for joker in self.jokers.iter_mut() {
            if joker.key == "j_swashbuckler" {
                joker.mult = 1.0 + others_sell;
            }
        }

        // 怀旧: 乘倍率 = 1 + 跳过的盲注数 × 0.25, 每次出牌都重算 (游戏也是在每次更新时重算的).
        let skips = self.skips;
        for joker in self.jokers.iter_mut() {
            if joker.key == "j_throwback" {
                joker.x_mult = 1.0 + skips as f64 * 0.25;
            }
        }

        // 第六感销毁掉的那一张也**不进弃牌堆** (与卡牌交易同理: 那张牌就此消失).
        for card in taken {
            if Some(card.card) != sixth_sense_card {
                self.discard_pile.push(card);
            }
        }
        // 记下这一手: 牌型的等级与次数 (行星牌看等级, 超新星那类看次数),
        // 以及"最后打出的牌型" —— 蓝封在回合末要靠它挑行星牌.
        // 被拦下的那一手**照样算打过了** (游戏里 `played` 是在 `debuff_hand` 之前加的).
        // 待办清单: 打出的牌型正好是它这一回合指定的那个 ⇒ 给 4 块, 然后换一个
        // (换的时候照抄游戏的"循环掷到不同为止", 见 `shop::roll_todo`).
        let todo_hits: Vec<usize> = self
            .jokers
            .iter()
            .enumerate()
            .filter(|(_, joker)| {
                joker.key == "j_todo_list" && !joker.debuffed && joker.todo_hand == Some(result.hand)
            })
            .map(|(index, _)| index)
            .collect();
        for index in todo_hits {
            self.dollars += 4.0;
            let old = self.jokers[index].todo_hand;
            let next = super::shop::roll_todo(&mut self.rng, &self.hands, old);
            self.jokers[index].todo_hand = Some(next);
        }

        self.hands.record_played(result.hand);
        self.last_hand_played = Some(result.hand);

        if self.reached_target() || self.hands_left <= 0 {
            self.end_round();
        } else {
            // 钩子 (The Hook): 每出一手就随机弃掉手里两张. 每次都从**剩下的**牌里抽,
            // 所以两张不会重复; 要是先挑好两张再一起拿, 抽到同一张的概率就不对了.
            if self.blind.as_ref().is_some_and(|b| b.key == "bl_hook" && !b.disabled) {
                for _ in 0..2 {
                    if self.hand.is_empty() {
                        break;
                    }
                    let seed = self.rng.pseudoseed("hook");
                    let index = self.rng.pick_index(self.hand.len(), seed);
                    let card = self.hand.remove(index);
                    self.discard_pile.push(card);
                }
            }
            self.draw_to_hand();
        }
        Ok(result)
    }

    /// 本盲注的累计得分是否够过关.
    pub fn reached_target(&self) -> bool {
        match &self.blind {
            Some(blind) => self.chips >= blind.chips,
            None => false,
        }
    }

    /// 把出牌区, 手牌与弃牌堆都收回牌堆.
    ///
    /// 顺序照 `G.FUNCS.draw_from_play_to_hand` / `draw_from_hand_to_deck` /
    /// `draw_from_discard_to_deck`: 先回手牌, 手牌与弃牌堆再回牌堆. 牌堆的 `emplace` 是插到
    /// **头部**, 所以收回去的顺序是反的; 这一点不影响后续对局, 因为下一回合开打前会按 `sort_id`
    /// 重排再洗.
    fn collect_all_cards(&mut self) {
        // 顺序照游戏回合收尾那两句 ( `state_events.lua` 里 `evaluate_round` 的收尾):
        // 1. `draw_from_hand_to_discard()`: **手牌按顺序追加进弃牌堆**;
        // 2. `draw_from_discard_to_deck()`: 弃牌堆**按顺序**搬回牌堆, 而牌堆的 `emplace`
        //    每次都插到**头部**, 所以整堆是反着摞上去的.
        // 这两步不能拆成"手牌直接回牌堆、弃牌堆再回牌堆": 那样两块在牌堆里的**先后关系会反过来**,
        // 而牌堆顺序决定了下一手发什么 —— 整局对拍里第 13 步开包发的那手牌就是这么差的.
        let played = std::mem::take(&mut self.play_area);
        self.discard_pile.extend(played);
        self.discard_pile.extend(std::mem::take(&mut self.hand));

        // 弃牌堆整堆搬到牌堆**头部**, 而且**保持原顺序**:
        // 游戏那边是"从弃牌堆**尾部**逐张取出, 插到牌堆**头部**" (`remove_card` 对弃牌堆取尾部,
        // `emplace` 对牌堆插头部), 于是最后插进去的那张 —— 也就是弃牌堆的**第一张** —— 落在最前.
        // 逐张 `insert(0, ...)` 按原顺序插会把这堆**整个反过来**, 而牌堆顺序决定了下一步发什么.
        let discarded = std::mem::take(&mut self.discard_pile);
        self.deck.splice(0..0, discarded);
    }

    /// 回合收尾: 收牌, 算结算栏, 进入 `ROUND_EVAL`; 没达标就直接结束.
    ///
    /// 小丑的 `end_of_round` 救场, 租金与易腐倒计时都还没做, 所以这里只有"分数够不够"这一条.
    pub fn end_round(&mut self) {
        // 这一回合的盲注到此为止 —— 游戏里盲注是**在打赢那一刻就被清空的**
        // (`Blind:defeat()` 收尾的 `set_blind(nil, nil, true)` 把 `name` 置成空串),
        // 于是"回合之间 (商店 / 开包)"不再有任何生效的盲注. 引擎保留盲注对象 (结算要读目标分数),
        // 所以用一个标志表达同一件事. 详细缘由见 `RunState::in_blind`.
        self.in_blind = false;
        // 分数够不够要**先**算, 因为租金扣不扣取决于这一局活不活得下来 —— 缘由见
        // `end_of_round_hand_effects` 的说明.
        let passed = self.reached_target();
        // 骨先生能在分数不够时保住这一局, 它也算"活下来了" (游戏那边它会置 `saved`, 于是
        // `game_over` 变回假, 租赁那笔事件照常执行).
        let bones_would_save = !passed
            && self
                .jokers
                .iter()
                .any(|joker| joker.key == "j_mr_bones" && !joker.debuffed)
            && self
                .blind
                .as_ref()
                .is_some_and(|blind| blind.chips > 0.0 && self.chips / blind.chips >= 0.25);
        // 手牌效果随后跑 —— 蓝封生成的行星牌要用 `last_hand_played`, 而收牌与换手牌都不改它.
        let hand_dollars = self.end_of_round_hand_effects(passed || bones_would_save);

        // 礼物卡: 每回合给**所有**小丑的卖出价涨 1 块 (包括它自己).
        if self
            .jokers
            .iter()
            .any(|joker| joker.key == "j_gift" && !joker.debuffed)
        {
            for joker in self.jokers.iter_mut() {
                joker.extra_value += 1.0;
            }
        }

        // 流浪汉: 回合结束时, 钱不多的化就给一张塔罗 (`create_card('Tarot', ..., 'vag')`).
        if self.dollars <= 4.0
            && self.consumables.len() < self.consumable_capacity()
            && self
                .jokers
                .iter()
                .any(|joker| joker.key == "j_vagabond" && !joker.debuffed)
        {
            let key = super::shop::create_card(self, "Tarot", "vag");
            self.consumables
                .push(super::consumable::Consumable::plain(key));
        }

        // 骨先生: 没达标但分数到了目标的 25% 就**保住这一局** (它自己销毁).
        // 游戏是在 `context.game_over` 那一刻拦下来的, 拦完之后流程照常往前走.
        //
        // 这里直接用上面早算好的 `bones_would_save`: 它只读状态, 而骨先生自己在回合末没有
        // 任何效果 (不会因"销毁骰"而消失), 所以两次判定必然一致 —— 同一套判定写两处,
        // 迟早会有一处被改漏.
        let bones_saves = bones_would_save;
        if bones_saves {
            let index = self
                .jokers
                .iter()
                .position(|joker| joker.key == "j_mr_bones");
            if let Some(index) = index {
                self.jokers.remove(index);
            }
        }
        let passed = passed || bones_saves;

        if !passed {
            self.phase = Phase::GameOver;
            self.round_eval = Some(RoundEval::default());
            return;
        }

        // 收牌放在**通过之后** —— 输局时游戏不会走"手牌进弃牌堆、弃牌堆回牌堆"那两句,
        // 牌就留在各区里 (整局对拍里第 39 步那盘输局, 记录里牌堆还是 28、手牌还有 7 张).
        self.collect_all_cards();
        // 盲注成功结束时撤销本轮的临时手牌变化, 商店开包不应继承这些变化.
        self.temporary_hand_size_bonus = 0;
        self.hand_size_sub = 0;

        // 篝火: 打赢 Boss 就归零 (它的说明写着"打赢 Boss 盲注时重置").
        if self.blind.as_ref().is_some_and(|blind| blind.kind == BlindKind::Boss) {
            for joker in self.jokers.iter_mut() {
                if joker.key == "j_campfire" {
                    joker.x_mult = 1.0;
                }
            }
        }

        // **通关判定要排在底注递增之前**: 游戏判的是"刚打完的那一底的底注 == 通关底注",
        // 而 `ease_ante` 在那个判定之后才跑 (`end_round` 与 `cash_out` 是两段).
        //
        // 这一笔原来**漏了** —— `RunState::won` 声明了却从没被赋过值, 于是批量对局的
        // `RunOutcome.won` 永远是假: 一个跑完八个底注、赢下决战 Boss 的流程, 在结果里
        // 看起来和"半路输掉"一模一样. 是接口文档 (`/// 通关了没有`) 与实现不一致,
        // 而这种不一致不会报错, 只会让所有基于它的统计整体偏.
        //
        // 判据里的"盲注是 Boss"用 `blind_on_deck` 而不是 `blind`: 与上面那句递增同一个依据.
        if self.blind_on_deck == BlindKind::Boss && self.ante == self.win_ante {
            self.won = true;
        }

        // 打赢 **Boss** 就在**这里**进下一底, 而不是等离开商店再进.
        //
        // 这一点很要紧: 商店的货架是用**当时的底注**生成出来的 (键里都带底注, 例如
        // `cdt{底注}` / `Joker{稀有度}sho{底注}` / 券 / 包), 所以底注晚一步加,
        // 打完 Boss 之后那个商店整面货架都会算错.
        // 游戏里这一段 (`ease_ante(1)`) 就在回合收尾里, 排在回合末的小丑效果之后、
        // 进入 ROUND_EVAL 之前.
        if self.blind_on_deck == BlindKind::Boss {
            self.ante += 1;
            // 重掷 Boss 的权利也是每底一次 (游戏那边挂在 `round_resets` 上).
            self.boss_rerolled = false;
            // 换底注时"这一底注出过没有"要清空, 柱子只认当前这一底.
            for card in self.deck.iter_mut().chain(self.hand.iter_mut()) {
                card.played_this_ante = false;
            }
            // 券与标签只在换底注时换新, 所以这两笔跟着底注走.
            self.refresh_voucher();
            self.refresh_tags();
            self.boss_key = Some(self.next_boss());
        }

        // 结算栏. 利息按**领取前**的现金算, 不含同一栏里的盲注奖金与余手钱.
        let blind_reward = self.blind.as_ref().map(|b| b.dollars).unwrap_or(0.0);
        let eval = RoundEval {
            blind_reward,
            hand_bonus: self.hands_left.max(0) as f64 * self.money_per_hand,
            discard_bonus: self.discards_left.max(0) as f64 * self.money_per_discard,
            // 绿色牌组没有利息 (`G.GAME.modifiers.no_interest`) —— 游戏那边判的是
            // `G.GAME.dollars >= 5 and not modifiers.no_interest`, 也就是**连本金门槛一起跳过**.
            interest: if self.no_interest {
                0.0
            } else {
                interest(self.dollars, self.interest_rate, self.interest_cap)
            },
            card_bonus: hand_dollars,
        };
        self.round_eval = Some(eval);
        self.phase = Phase::RoundEval;
    }

    /// 回合末的手牌效果, 返回这一轮额外拿到的钱.
    ///
    /// 对应 `Card:get_end_of_round_effect` 与 `get_p_dollars`: 黄金牌与金封各给三块,
    /// 蓝封给一张"最后打出的牌型"对应的行星牌 (消耗槽有空位时才给). 逐张按手牌从左到右走.
    ///
    /// `survived` 是"这一局还活得下去吗" (分数够了, 或者骨先生会救). **只有活下来才扣租金** ——
    /// 游戏那边租金走的是 `ease_dollars`, 它不改钱, 而是把改钱排成一个事件; 而一旦这一局输掉,
    /// `update_game_over` 会把 `G.SETTINGS.paused` 置真, 事件队列随即跳过所有"创建时没在暂停中"
    /// 的事件 (`engine/event.lua` 的 `pause_skip`), 那笔钱就永远不执行了.
    ///
    /// 这一条是反向对拍抓到的: 一局完整的 73 步里前 72 步全对, 最后一步 (输掉的那手) 游戏的钱
    /// 比引擎多 3 —— 正好是一张租赁小丑的租金. 探针记下的现场是"`calculate_rental` 确实被调用了,
    /// 但它前后钱都是 3", 与 `ease_dollars` 排队 + `pause_skip` 丢弃这条链完全吻合.
    ///
    /// 易腐倒计时**不受这个标志影响**: `Card:calculate_perishable` 是直接改 `perish_tally` 的
    /// 同步代码, 没有排队, 所以输局时照样往下走.
    fn end_of_round_hand_effects(&mut self, survived: bool) -> f64 {
        let mut dollars = 0.0;
        // 先把手牌的信息取出来, 后面要改 `self` (加行星牌).
        let hand: Vec<(bool, Option<Enhancement>, Option<Seal>)> = self
            .hand
            .iter()
            .map(|card| (card.debuffed, card.enhancement, card.seal))
            .collect();

        // 小丑那几笔 (黄金小丑 / 9 霄云外 / 火箭 / 卫星 / 延迟满足) 走 `dollar_bonus`.
        // 它们只看局面, 与手里有哪些牌无关, 所以先算一次.
        let ctx = TriggerContext {
            hand: PokerHand::HighCard,
            hands: &Default::default(),
            cards: &[],
            scoring: &[],
            held: &[],
            full_hand_len: 0,
            joker_capacity: self.joker_capacity(),
            stencil_count: 0,
            hands_left: self.hands_left,
            discards_left: self.discards_left,
            dollars: self.dollars,
            joker_count: self.jokers.len(),
            played_this_round: 0,
            ancient_suit: self.ancient_suit,
            idol_card: self.idol_card,
            pareidolia: self
                .jokers
                .iter()
                .any(|joker| joker.key == "j_pareidolia" && !joker.debuffed),
            probability_extra: self.probability_scale - 1.0,
            consumable_room: self.consumable_capacity().saturating_sub(self.consumables.len()),
            deck_len: self.deck.len(),
            deck_total: 0,
            deck_stones: 0,
            deck_enhanced: 0,
            starting_deck_size: self.starting_deck_size,
            deck_nines: self
                .deck
                .iter()
                .chain(self.hand.iter())
                .filter(|card| card.card.rank == Rank::Nine)
                .count(),
            planets_used: self.planets_used,
            discards_used: self.discards_used,
            table: &self.hands,
            };
        for joker in &self.jokers {
            dollars += joker.dollar_bonus(&ctx);
        }

        // 租金与易腐的倒计时也是**回合末**跑的, 而且游戏里是逐个小丑连着的
        // (`calculate_joker` -> `calculate_rental` -> `calculate_perishable`).
        // 租金是**当场扣钱** (不是记进结算栏), 而且这一段排在利息之前 ——
        // 所以租赁小丑会连带把这一轮的利息压低, 这一点与游戏一致.
        //
        // 输掉的那一局不扣租金 (`survived` 为假): 游戏那笔钱排在事件队列里, 而输局会把
        // `G.SETTINGS.paused` 置真, 队列随即丢掉它. 详见本函数的文档注释.
        //
        // 每张小丑自己的回合末效果 (`end_of_round_effect`: 大麦克的销毁骰, 爆米花的退化)
        // 排在这一格的最前面, 与游戏的顺序一致. 判定要销毁的先记下标, 循环完了再挪.
        //
        // 销毁骰与易腐倒计时都**不**受 `survived` 影响: 它们在游戏里是同步代码, 不排队.
        let mut doomed: Vec<usize> = Vec::new();
        for (index, joker) in self.jokers.iter_mut().enumerate() {
            if joker.end_of_round_effect(&mut self.rng, self.probability_scale) {
                doomed.push(index);
            }
            if joker.rental && survived {
                self.dollars -= RENTAL_RATE;
            }
            if joker.perish_tally > 0 {
                joker.perish_tally -= 1;
                // 减到 0 就变成被削弱: 小丑还留在队里, 但效果全部停用.
                if joker.perish_tally == 0 {
                    joker.debuffed = true;
                }
            }
        }
        // 从后往前删, 免得前面的下标错位. 顺手记下"大麦克烂了"这件事 ——
        // 游戏在破坏那张牌的时候置 `pool_flags.gros_michel_extinct`, 于是大麦克退出池子、
        // 卡文迪什进场 (`no_pool_flag` / `yes_pool_flag` 那一对).
        for index in doomed.iter().rev() {
            if self.jokers[*index].key == "j_gros_michel" {
                self.pool_flags.insert("gros_michel_extinct".to_owned());
            }
            self.jokers.remove(*index);
        }

        for (debuffed, enhancement, seal) in hand {
            if debuffed {
                continue;
            }
            // 只有黄金牌在这里给 —— 金封是"被打出时"给, 走的是计分那条路 (`ScoreResult::dollars`).
            if enhancement == Some(Enhancement::Gold) {
                dollars += 3.0;
            }
            // 蓝封: 消耗槽有空位时给一张行星牌.
            if seal == Some(Seal::Blue)
                && self.consumables.len() < self.consumable_capacity()
                && let Some(played) = self.last_hand_played
                && let Some(key) = planet_for_hand(played)
            {
                self.consumables
                    .push(super::consumable::Consumable::plain(key));
            }
        }
        dollars
    }

    /// 领取结算栏并进商店. 返回这次领到多少.
    ///
    /// 进商店的同时铺一次货架, 所以调用方不用自己排列顺序 —— 货架的顺序会影响后面所有的
    /// 随机数 (两张小丑先后用同一个键递推, 卡包又吃它们的残留), 顺序错了整局都会偏.
    /// 收结算栏进商店.
    ///
    /// **只在这一回合结算时能做** —— 这一条不能省成"不在结算阶段就什么都不做":
    /// 那样它会返回成功, 而游戏那边(`bbcore` 的 `cash_out` 端点)会拒绝, 于是对拍里
    /// "游戏拒绝了、引擎却接受了". 一份真实录像里本来就包含这种重复的尝试
    /// (bot 在商店或输局之后又点了一次), 引擎得照同样的规矩拒绝.
    pub fn cash_out(&mut self) -> Result<f64, ActionError> {
        if self.phase != Phase::RoundEval {
            return Err(ActionError::NotInPhase {
                expected: Phase::RoundEval,
                actual: self.phase,
            });
        }
        let total = self.round_eval.map(|e| e.total()).unwrap_or(0.0);
        self.dollars += total;
        self.round_eval = None;
        self.phase = Phase::Shop;
        {
            // 结算屏上那一下会**先洗一次牌** (`G.FUNCS.cash_out` 开头那句
            // `G.deck:shuffle('cashout'..底注)`), 键是 `cashout{底注}`.
            //
            // 这一步对牌堆的**顺序**是隐形的 —— `pseudoshuffle` 开头会按 `sort_id` 排序,
            // 所以洗之前那堆怎么摊着都一样, 下一轮开局 (`nr{底注}`) 那次洗牌自然也照旧.
            // 但店里的**秘术包与幽灵包开的时候要补一手牌** (见 `deal_for_pack`), 那一手是从
            // 牌堆顶上抽的: 少了这次洗牌, 那份牌面就对不上, 后面"包里用塔罗指定手牌目标"
            // 那几步会指到别的牌上.
            self.sort_deck_by_sort_id();
            let key = format!("cashout{}", self.ante);
            self.rng.pseudoshuffle(&mut self.deck, &key);
            // 重抽的涨价计数与新一底的免费次数都从零开始.
            self.rerolls = 0;
            // 标签给的那两个"这一轮商店"的优惠也在这里开, 上一次的作废.
            self.free_reroll = self.tags.iter().any(|t| t == "tag_d_six");
            self.shop_free = self.tags.iter().any(|t| t == "tag_coupon");
            self.shop = Some(super::shop::Shop::restock(self));
            // 商店的区域在游戏里是 `G.UIDEF.shop()` 建出来的, 之后一直留着 —— 摘要里的
            // `shop` / `vouchers` / `packs` 三项从此开始出现, 见 `RunState::shop_seen`.
            self.shop_seen = true;
        }
        Ok(total)
    }

    /// 重抽小丑那两格, 返回花掉的钱. 对应 `reroll` 端点.
    pub fn reroll_shop(&mut self) -> Result<f64, ActionError> {
        let cost = self.pay_for_reroll()?;
        // 闪光: 在商店里每重掷一次涨 2 点倍率 (它自己那个 `ability.mult` 就是涨出来的).
        for joker in self.jokers.iter_mut() {
            if joker.key == "j_flash" && !joker.debuffed {
                joker.mult += 2.0;
            }
        }
        // 先取出来再放回去, 否则 `shop` 与 `self` 会同时被可变借用.
        if let Some(mut shop) = self.shop.take() {
            shop.reroll_jokers(self);
            self.shop = Some(shop);
        }
        Ok(cost)
    }

    /// 用一张消耗牌, 例如塔罗或行星.
    ///
    /// `index` 是它在持有区里的位置, `targets` 是手牌里被选中的牌. 用完那张牌就没了.
    /// 上限照原型的 `max_highlighted`, 超过就拒绝而不是悄悄截断.
    pub fn use_consumable(&mut self, index: usize, targets: &[usize]) -> Result<(), ActionError> {
        // 消耗牌**不只在出牌阶段能用**: 商店里照样能嗑塔罗 (游戏那边消耗牌那一栏在商店里也在,
        // "使用"按钮是可点的), 开包时也一样 —— 而且 bbcore 的 `pack` 端点就是"取出来直接用".
        // 原本这里只放行 `SelectingHand`, 等于**禁止了一个合法操作**.
        if !matches!(
            self.phase,
            Phase::SelectingHand | Phase::Shop | Phase::BoosterOpened
        ) {
            return Err(ActionError::NotInPhase {
                expected: Phase::SelectingHand,
                actual: self.phase,
            });
        }
        let key = self
            .consumables
            .get(index)
            .map(|card| card.key.clone())
            .ok_or(ActionError::BadIndex(index))?;

        // 塔罗: 记一笔全局用量, 顺手把场上的占卜师推一格.
        // 这一段必须放在 `match` **之前** —— 写成 match 的一个分支就会被更早的分支吃掉
        // (八张强化塔罗各自有分支, 排在后头的按类别判就永远轮不到).
        if crate::data::catalog::Catalog::get()
            .record(&key)
            .is_some_and(|proto| proto.category == "Tarot")
        {
            self.tarots_used += 1;
            for joker in self.jokers.iter_mut() {
                if joker.key == "j_fortune_teller" && !joker.debuffed {
                    joker.mult += 1.0;
                }
            }
        }

        match key.as_str() {
            // 力量: 最多两张, 每张点数升一级 (A 绕回 2, K 升到 A).
            "c_strength" => {
                self.check_indices(targets, 2)?;
                for &target in targets {
                    self.hand[target].up_rank();
                }
            }
            // 八张"强化型"塔罗: 给选中的牌加一种强化, 前四张最多两张, 后四张一张.
            // 这几张原来**一张都没实现** —— 用掉之后什么也不会发生 (按名字分发, 名字不在表里).
            "c_magician" | "c_empress" | "c_heirophant" => {
                let enhancement = match key.as_str() {
                    "c_magician" => Enhancement::Lucky,
                    "c_empress" => Enhancement::Mult,
                    _ => Enhancement::Bonus,
                };
                self.check_indices(targets, 2)?;
                for &target in targets {
                    self.hand[target].enhancement = Some(enhancement);
                }
            }
            "c_lovers" | "c_chariot" | "c_justice" | "c_devil" | "c_tower" => {
                let enhancement = match key.as_str() {
                    "c_lovers" => Enhancement::Wild,
                    "c_chariot" => Enhancement::Steel,
                    "c_justice" => Enhancement::Glass,
                    "c_devil" => Enhancement::Gold,
                    _ => Enhancement::Stone,
                };
                self.check_indices(targets, 1)?;
                for &target in targets {
                    self.hand[target].enhancement = Some(enhancement);
                }
            }
            // 星星 / 月亮 / 太阳 / 世界: 改花色, 各换一种, 最多三张.
            // 四张的参数只差 `suit_conv` 指向哪个花色, 逻辑是同一套.
            "c_star" | "c_moon" | "c_sun" | "c_world" => {
                let suit = match key.as_str() {
                    "c_star" => Suit::Diamonds,
                    "c_moon" => Suit::Clubs,
                    "c_sun" => Suit::Hearts,
                    _ => Suit::Spades,
                };
                self.check_indices(targets, 3)?;
                for &target in targets {
                    self.hand[target].change_suit(suit);
                }
            }
            // 倒吊人: 直接删掉选中的牌, 不补抽, 所以手牌会变少.
            "c_hanged_man" => {
                self.check_indices(targets, 2)?;
                // 从后往前删, 否则前面的下标会错位.
                let mut doomed = targets.to_vec();
                doomed.sort_unstable_by(|a, b| b.cmp(a));
                for target in doomed {
                    self.hand.remove(target);
                }
            }
            // 死神: 选中的牌里最靠右的那张复制给其余选中的牌, 至少选两张.
            // 手牌顺序就是屏幕从左到右, 所以"最靠右"就是下标最大的那张.
            "c_death" => {
                self.check_indices(targets, 2)?;
                if targets.len() < 2 {
                    return Err(ActionError::TooFewCards {
                        least: 2,
                        got: targets.len(),
                    });
                }
                let source = *targets.iter().max().expect("上面判过至少两张");
                let source_card = self.hand[source];
                // **序号保留目标牌自己的** —— 这一处与 DNA / 神秘生物不一样, 别一起改.
                //
                // 游戏那行是 `copy_card(rightmost, G.hand.highlighted[i])`: `copy_card` 收两个参数,
                // 第二个是"要写进哪张牌", 给了它就 `local new_card = new_card or Card(...)` 里的
                // **前一支** —— 复用的是**目标牌那个对象**, 只把牌面与能力写过去 (`set_ability` /
                // `set_base`), `sort_id` 从头到尾没动过. 而那两处传的是 `nil`, 才真的新建一张牌,
                // 才吃掉一个新的 `G.sort_id`.
                //
                // 写成"给复制品发一个新号"会把这副牌洗乱: 那张牌的号从它原来在牌堆里的位置
                // 跳到**最新**, 于是排序后整副牌的顺序都变了 —— 表现成"下一回合发出来的牌几乎
                // 全不对", 与真实原因隔得很远.
                let mut copies: Vec<(usize, crate::cards::CardInstance)> = Vec::new();
                for &target in targets {
                    if target != source {
                        let mut copy = source_card;
                        copy.card.sort_id = self.hand[target].card.sort_id;
                        copies.push((target, copy));
                    }
                }
                for (target, copy) in copies {
                    self.hand[target] = copy;
                }
            }
            // 魔术师, 皇后, 教皇那八张: 换一种强化.
            // 各张的差别只在 `mod_conv` 指向哪个 `m_` 原型与上限, 逻辑相同.
            _ if enhancement_of(&key).is_some() => {
                let enhancement = enhancement_of(&key).expect("上面刚判过");
                self.check_indices(targets, enhancement_limit(&key))?;
                for &target in targets {
                    self.hand[target].set_enhancement(enhancement);
                }
            }
            // 光环: 给第一张选中的牌加一个版本. 它用的是"必定出版本"的那一档
            // (`poll_edition` 的 guaranteed 分支, 阈值乘 25), 所以不会空手而归.
            "c_aura" => {
                self.check_indices(targets, 1)?;
                let edition = super::shop::poll_edition_guaranteed(self, "aura");
                if let Some(card) = self.hand.get_mut(targets[0]) {
                    card.edition = edition;
                }
            }
            // 幽灵: 白送一张**稀有**小丑 (原型里那个 0.99 是伪随机值, `> 0.95` 落到 3 级).
            // 灵魂: 白送一张**传奇**小丑 (第 4 级).
            "c_wraith" | "c_soul" => {
                let (rarity, append) = if key == "c_soul" {
                    (4, "sou")
                } else {
                    (3, "wra")
                };
                if self.jokers.len() < self.joker_capacity() {
                    let new = self.create_joker_of_rarity(rarity, append);
                    if let Some(joker) = new {
                        self.add_joker(joker);
                    }
                }
            }
            // 黑洞: 所有牌型各升一级.
            "c_black_hole" => {
                for hand in PokerHand::BY_PRIORITY {
                    self.hands.level_up(hand, 1);
                }
            }
            // 幻灵里改小丑的三张.
            //
            // 生命十字章: 随机挑一张小丑留下并复制一份, 其余**非永恒**的全部删掉.
            // 它挑的是**全部**小丑 (含永恒的), 只是永恒的那张删不掉.
            "c_ankh" => {
                if self.jokers.is_empty() {
                    return Ok(());
                }
                let roll = self.rng.pseudorandom("ankh_choice");
                let chosen = (roll * self.jokers.len() as f64) as usize % self.jokers.len();
                // 选中的那张要**复制**一份留下来; 其余的只保留永恒的 (那些删不掉).
                let copy = self.jokers[chosen].clone();
                self.jokers = self
                    .jokers
                    .drain(..)
                    .enumerate()
                    .filter(|(index, joker)| *index == chosen || joker.eternal)
                    .map(|(_, joker)| joker)
                    .collect();
                // 复制品排在最后, 顺序与"留下的那些"一致.
                if self.jokers.len() < self.joker_capacity() {
                    self.add_joker(copy);
                }
            }
            // 妖法与灵质: 从"还没有版本"的小丑里随机挑一个, 给它加版本.
            // 一个都没有就什么也不做 (游戏那边会把牌退回来).
            // 妖法 (给一张小丑加多彩, **其余全部销毁**) 与灵质 (给一张加负片, 并永久减手牌上限).
            //
            // 三处都得照原文:
            // 1. 掷的**键按牌分**: 妖法是 `hex`, 灵质是 `ectoplasm`, 命运之轮才是
            //    `wheel_of_fortune`. 用同一个键会让抽到的是另一张 (键不同, 抽出的下标就不同).
            // 2. **妖法要销毁其余的**: `for k, v in pairs(G.jokers.cards) do if v ~= eligible_card
            //    and (not v.ability.eternal) then v:start_dissolve() end end` ——
            //    永恒的那张留着. 少了这一条, 用完妖法手里会凭空多留一堆小丑.
            // 3. **灵质每次永久减手牌上限**, 而且减得越来越多: 先减 1, 再减 2, 再减 3...
            //    (`ecto_minus` 从 1 起, 每用一次加一).
            "c_hex" | "c_ectoplasm" => {
                let hex = key == "c_hex";
                let pool: Vec<usize> = self
                    .jokers
                    .iter()
                    .enumerate()
                    .filter(|(_, joker)| joker.edition.is_none())
                    .map(|(index, _)| index)
                    .collect();
                if pool.is_empty() {
                    return Ok(());
                }
                let seed_key = if hex { "hex" } else { "ectoplasm" };
                let roll = self.rng.pseudorandom(seed_key);
                let index = pool[(roll * pool.len() as f64) as usize % pool.len()];
                self.jokers[index].edition = Some(if hex {
                    crate::cards::Edition::Polychrome
                } else {
                    crate::cards::Edition::Negative
                });
                super::shop::refresh_costs(self);
                if hex {
                    // 销毁其余的小丑, **永恒的除外** —— 抽中的那一张当然也留着
                    // (`if v ~= eligible_card and (not v.ability.eternal)`).
                    //
                    // 按**下标从后往前**删: 直接 `retain` 会连抽中的那一张一起删掉 (它未必是永恒的),
                    // 而按下标删能明确地把那一个下标排除在外.
                    let victims: Vec<usize> = (0..self.jokers.len())
                        .filter(|other| *other != index && !self.jokers[*other].eternal)
                        .collect();
                    let doomed: Vec<String> = victims
                        .iter()
                        .map(|other| self.jokers[*other].key.clone())
                        .collect();
                    for other in victims.into_iter().rev() {
                        self.jokers.remove(other);
                    }
                    // 被销毁的要从池子的"用过"记录里清掉 —— 游戏那边是 `Card:remove()` 干的,
                    // 判据是持有区里还有没有同名卡.
                    for dead in doomed {
                        self.forget_used_if_gone(&dead);
                    }
                } else {
                    let minus = self.ecto_minus.max(1);
                    self.hand_size_bonus -= minus;
                    self.ecto_minus = minus + 1;
                }
            }
            // 幻灵里"销毁一张再补新牌"的四张: 使魔 / 严峻 / 咒语 / 火祭.
            //
            // 销毁的那张是**从手里随机**挑的 (键 `random_destroy`), 而且是彻底删掉 ——
            // 不进弃牌堆, 所以整副牌会变少. 补的新牌各有各的键.
            "c_familiar" | "c_grim" | "c_incantation" => {
                self.destroy_random_hand_card();
                let count = super::shop::consumable_count(&key, "extra");
                let append = match key.as_str() {
                    "c_familiar" => "familiar_create",
                    "c_grim" => "grim_create",
                    _ => "incantation_create",
                };
                for _ in 0..count {
                    // 掷骰的顺序照源码: 先点数 (严峻跳过这一掷, 它的点数固定是 A),
                    // 再花色, 最后**强化** —— 三掷都用自己那把键.
                    let rank = match key.as_str() {
                        // 使魔给人头牌.
                        "c_familiar" => {
                            const FACES: [Rank; 3] = [Rank::Jack, Rank::Queen, Rank::King];
                            let roll = self.rng.pseudorandom(append);
                            FACES[(roll * 3.0) as usize % 3]
                        }
                        // 严峻只给 A, **不掷点数** —— 多掷一次会把花色取到第二个值.
                        "c_grim" => Rank::Ace,
                        // 咒语给数字牌.
                        _ => {
                            const NUMBERS: [Rank; 9] = [
                                Rank::Two,
                                Rank::Three,
                                Rank::Four,
                                Rank::Five,
                                Rank::Six,
                                Rank::Seven,
                                Rank::Eight,
                                Rank::Nine,
                                Rank::Ten,
                            ];
                            let roll = self.rng.pseudorandom(append);
                            NUMBERS[(roll * 9.0) as usize % 9]
                        }
                    };
                    let suit_roll = self.rng.pseudorandom(append);
                    let suit = Suit::ALL[(suit_roll * 4.0) as usize % 4];
                    let mut card = CardInstance::from_key(&format!(
                        "{}_{}",
                        suit.code(),
                        rank.code()
                    ))
                    .expect("花色点数都是合法的");
                    // 这三张幻灵造出来的牌**都带一个随机强化** (键 `spe_card`),
                    // 池子是全部强化**去掉石头牌** (石头牌的点数由自己顶掉, 不给) ——
                    // 漏掉这一掷不光这几张牌少了个强化, `spe_card` 那条序列也会偏.
                    let pool_roll = self.rng.pseudorandom("spe_card");
                    card.enhancement =
                        Some(SUMMON_ENHANCEMENTS[pool_roll as usize % SUMMON_ENHANCEMENTS.len()]);
                    card.card.sort_id = self.next_sort_id();
                    self.hand.push(card);
                }
            }
            // 火祭: 随机销毁五张手牌, 换二十块.
            "c_immolate" => {
                for _ in 0..5 {
                    self.destroy_random_hand_card();
                }
                self.dollars += super::shop::nested_number(&key, "extra", "dollars");
            }
            // 幻灵里"加蜡封"的四张: 与塔罗那一批同构, 只是给的封不同.
            "c_talisman" | "c_deja_vu" | "c_trance" | "c_medium" => {
                let seal = match key.as_str() {
                    "c_talisman" => Seal::Gold,
                    "c_deja_vu" => Seal::Red,
                    "c_trance" => Seal::Blue,
                    _ => Seal::Purple,
                };
                self.check_indices(targets, 1)?;
                for &index in targets {
                    if let Some(card) = self.hand.get_mut(index) {
                        card.seal = Some(seal);
                    }
                }
            }
            // 神秘生物: 复制**第一张**选中的牌若干次, 加进手牌 (手牌因此会变多).
            "c_cryptid" => {
                self.check_indices(targets, 1)?;
                let count = super::shop::consumable_count(&key, "extra");
                let source = self
                    .hand
                    .get(targets[0])
                    .cloned()
                    .ok_or(ActionError::BadIndex(targets[0]))?;
                for _ in 0..count {
                    // 每一份都是新造的牌, 各拿一个新号 (游戏的 `copy_card`) —— 见 `duplicate_card`.
                    let copy = self.duplicate_card(&source);
                    self.hand.push(copy);
                }
            }
            // 符印: 整手牌换成同一个**随机**花色.
            "c_sigil" => {
                let roll = self.rng.pseudorandom("sigil");
                let suit = Suit::ALL[(roll * 4.0) as usize % 4];
                for card in &mut self.hand {
                    card.change_suit(suit);
                }
            }
            // 占卜: 整手牌点数**统一成一个随机点数**, 并且手牌上限减一.
            // 名字容易让人以为是"点数降一级", 实际不是 —— 看源码才知道是统一.
            "c_ouija" => {
                let roll = self.rng.pseudorandom("ouija");
                let rank = Rank::ALL[(roll * 13.0) as usize % 13];
                for card in &mut self.hand {
                    card.change_rank(rank);
                }
                self.hand_size_bonus -= 1;
            }
            // 女祭司与皇帝: 白送若干张行星牌 / 塔罗. 数量受消耗槽空位限制.
            // 它们不看选中的牌.
            "c_high_priestess" | "c_emperor" => {
                let (kind, field, append) = if key == "c_emperor" {
                    ("Tarot", "tarots", "emp")
                } else {
                    ("Planet", "planets", "pri")
                };
                let want = super::shop::consumable_count(&key, field);
                // 位置要按"这张牌已经走了"来算 —— 它正在被用掉, 游戏那边它已经离场,
                // 所以**不能占着格子**: 槽位 2、手上 2 张(含它自己)时要能造满 2 张.
                // 少了这一条, 高女祭司只会造出一张行星 (整局对拍里第 41 步就是这么差的).
                let room = self
                    .consumable_capacity()
                    .saturating_sub(self.consumables.len().saturating_sub(1));
                for _ in 0..want.min(room) {
                    let new = super::shop::create_card(self, kind, append);
                    self.consumables
                        .push(super::consumable::Consumable::plain(new));
                }
            }
            // 审判: 白送一张小丑.
            "c_judgement" => {
                if self.jokers.len() < self.joker_capacity() {
                    let key = super::shop::create_card(self, "Joker", "jud");
                    if let Some(joker) = Joker::new(&key) {
                        self.add_joker(joker);
                    }
                }
            }
            // 行星牌: 升对应牌型一级. 它不看选中的牌, 所以不该带 targets.
            _ if planet_hand(&key).is_some() => {
                let hand = planet_hand(&key).expect("上面刚判过");
                self.hands.level_up(hand, 1);
                self.planets_used += 1;
                // 星座: 每用一张行星牌就把自己的乘倍率加 0.1 (它靠通用分支付账).
                for joker in self.jokers.iter_mut() {
                    if joker.key == "j_constellation" && !joker.debuffed {
                        joker.x_mult += 0.1;
                    }
                }
            }
            // 隐者: 把钱翻倍, 最多加 `extra` (20).
            "c_hermit" => {
                let cap = super::shop::consumable_count(&key, "extra") as f64;
                self.dollars += self.dollars.min(cap);
            }
            // 节制: 拿所有小丑的**卖出价**之和, 上限 `extra` (50).
            // (游戏里这个数是在牌的更新里算好存进 `ability.money` 的; 这里按用的时候现算.)
            "c_temperance" => {
                let total: f64 = self.jokers.iter().map(Joker::sell_price).sum();
                let cap = super::shop::consumable_count(&key, "extra") as f64;
                self.dollars += total.min(cap);
            }
            // 命运之轮: 从"还没有版本"的小丑里挑一个, 先掷 1/4 决定给不给,
            // 中了再用**同一条键**的下一枚挑是谁, 最后走"保证给版本"那条链.
            "c_wheel_of_fortune" => {
                let odds = super::shop::consumable_count(&key, "extra") as f64;
                let eligible: Vec<String> = self
                    .jokers
                    .iter()
                    .filter(|joker| joker.edition.is_none())
                    .map(|joker| joker.key.clone())
                    .collect();
                if !eligible.is_empty() && self.rng.pseudorandom("wheel_of_fortune") < 1.0 / odds {
                    let picked = self.rng.pick(&eligible, "wheel_of_fortune").clone();
                    if let Some(edition) =
                        super::shop::poll_edition_guaranteed(self, "wheel_of_fortune")
                    {
                        // 同名的小丑可能不止一张, 取第一张没版本的 —— 游戏挑的是"某一张牌",
                        // 这里用键回找, 够用.
                        if let Some(joker) = self
                            .jokers
                            .iter_mut()
                            .find(|joker| joker.key == picked && joker.edition.is_none())
                        {
                            joker.edition = Some(edition);
                        }
                    }
                }
                super::shop::refresh_costs(self);
            }
            // 愚者: 把**上一次用掉的**塔罗或行星复制一张进消耗槽 (不能复制自己).
            "c_fool" => {
                let last = self.last_tarot_planet.clone();
                if let Some(last) = last
                    && last != "c_fool"
                    && self.consumables.len() < self.consumable_capacity() + 1
                {
                    self.consumables
                        .push(super::consumable::Consumable::plain(last));
                }
            }
            // 其余塔罗与行星还没做, 明说而不是假装成功.
            _ => return Err(ActionError::NotImplemented("这张消耗牌的效果")),
        }

        let used = self.consumables.remove(index);
        // 记下"上一次用掉的塔罗 / 行星", 愚者要复制它 (游戏在用的那一刻就记, 任何消耗牌都记).
        self.last_tarot_planet = Some(used.key.clone());
        // 用掉之后要把"用过"的记录清掉 —— 游戏在 `Card:remove()` 里做这件事, 条件是
        // **场上没有同名卡**. 所以灵魂 / 黑洞用掉之后, 后面还能再刷到 (那一骰也会重新掷).
        self.forget_used_if_gone(&used.key);
        Ok(())
    }

    /// 一张牌离场之后, 把"本局用过它"的记录清掉 —— 判据是**持有区里还有没有同名卡**.
    ///
    /// 游戏在 `Card:remove()` 里做这件事, 而它查的是 `find_joker(名字)`, 那个函数只搜
    /// **持有区** (`G.jokers` 与 `G.consumeables`), **不搜牌堆, 也不搜货架** ——
    /// 所以货架上那张被收走时, 只要手上没有第二张同名卡, 记录就该清掉.
    ///
    /// 少了这一步, 那张牌会一直占着池子里的一个格子 (`get_current_pool` 把用过的键换成
    /// `UNAVAILABLE` 占位, 抽中它要重抽). 整局对拍里 133 步那份第 75 步的天体包第三张
    /// 就是这么偏的: 货架上那张行星牌在第 64 步生成、第 67 步随商店一起收走, 而引擎没清记录.
    pub(crate) fn forget_used_if_gone(&mut self, key: &str) {
        if !self.jokers.iter().any(|joker| joker.key == key)
            && !self.consumables.iter().any(|card| card.key == key)
        {
            self.used_jokers.remove(key);
        }
    }

    /// 把货架上的东西**收走**, 顺手按上面的规矩清掉"用过"的记录.
    fn clear_shelf(&mut self) {
        let Some(shop) = self.shop.take() else {
            return;
        };
        let mut keys: Vec<String> = Vec::new();
        keys.extend(shop.jokers.iter().map(|card| card.key.clone()));
        keys.extend(shop.packs.iter().map(|card| card.key.clone()));
        if let Some(voucher) = &shop.voucher {
            keys.push(voucher.key.clone());
        }
        if let Some(extra) = &shop.extra_voucher {
            keys.push(extra.key.clone());
        }
        for key in keys {
            self.forget_used_if_gone(&key);
        }
    }

    /// 券把货架变大了之后, 立刻把缺的那几格补上.
    ///
    /// 用的是与小丑格同样的键 (`cdt` / `rarity...sho` / 池子 / 三个标记 / 版本), 顺序也照旧 ——
    /// 所以补出来的那张与"下一次铺货架时第一张"是同一张, 随机序列也对得上.
    fn top_up_shelf(&mut self) {
        let rates = super::voucher::rates_of(self);
        let want = super::shop::JOKER_SLOTS + self.shop_size_bonus;
        loop {
            let short = match self.shop.as_ref() {
                Some(shop) => shop.jokers.len() < want,
                None => false,
            };
            if !short {
                break;
            }
            let card = super::shop::create_card_for_shop(self, &rates);
            if let Some(shop) = self.shop.as_mut() {
                shop.jokers.push(card);
            }
        }
    }

    /// **装消耗牌的包**开的时候会发一手牌 (从牌堆顶), 关包时再收回.
    ///
    /// 这条是量出来的: 两份记录里 `BOOSTER_OPENED` 那几步的手牌**不一致** ——
    /// 小人包 (小丑) 那几步是"牌堆 52 / 手牌 0", 而秘术包那几步是"牌堆 44 / 手牌 8".
    ///
    /// **只有秘术包与幽灵包发牌**, 不是"凡是装消耗牌的包都发": 天体包 (行星) 与标准包、
    /// 小人包一样不发手牌. 这一点直接写在游戏里 —— 秘术包与幽灵包那两条开包路径各自有一句
    /// `G.FUNCS.draw_from_deck_to_hand()` (Steamodded 那侧对应的开关是 `Booster.draw_hand`,
    /// 也只有这两类包被置成 `true`), 天体包那条路径没有.
    /// 按"装消耗牌就发"来判会把天体包也算进去, 于是商店里每开一次天体包就凭空多一手牌,
    /// 整局对拍里 133 步那份第 75 步就是这么差的.
    ///
    /// 关包时收回 (`end_consumeable` 里那句 `draw_from_hand_to_deck`), 所以有借有还、净效果为零,
    /// 但那一手在包里那几步是真实存在的 —— 整局对拍里第 34 步那张 `c_strength` 就靠它.
    fn deal_for_pack(&mut self) {
        let needs_hand = self.open_pack.as_ref().is_some_and(|pack| {
            matches!(
                super::shop::pack_kind_of(&pack.key),
                Some("Tarot") | Some("Spectral")
            )
        });
        if needs_hand {
            self.draw_to_hand();
        }
    }

    /// 把补充包收掉: 没取走的那些牌从"用过"表里去掉.
    ///
    /// 游戏里包一关, 剩下的牌会被 `Card:remove()` 收掉, 而它里面有一句"场上没有同名卡就把记录去掉"
    /// (`used_jokers[k] = nil`) —— 于是**没取走的牌会重新回到池子里**.
    /// 少了这一步, 它们会一直占着池子里的格子: 整局对拍里那份 68 步的记录就是这么偏的
    /// (秘术包里没取走的两张塔罗一直挂着, 后面的塔罗池整池被判成不可用, 兜底值冒了出来).
    fn close_pack(&mut self) {
        // 关包时把手牌**收回牌堆** —— 游戏里就是 `end_consumeable` 里那句
        // `draw_from_hand_to_deck`. 所以"开包发一手牌"是**有借有还**的:
        // 净效果为零, 但那一手牌在包里那几步是**真实存在**的 (塔罗可以指定它们做目标).
        let hand = std::mem::take(&mut self.hand);
        for card in hand {
            self.deck.insert(0, card);
        }
        if let Some(pack) = self.open_pack.take() {
            for card in &pack.contents {
                let still_owned = self.consumables.iter().any(|own| own.key == card.key)
                    || self.jokers.iter().any(|joker| joker.key == card.key)
                    || self.deck.iter().any(|c| c.card.key() == card.key);
                if !still_owned {
                    self.used_jokers.remove(&card.key);
                }
            }
        }
        self.phase = self.pack_return_phase;
        self.open_next_tag_pack();
    }

    /// 不取任何东西, 直接把这个补充包收掉 (游戏里那个"跳过"按钮).
    ///
    /// 包里剩下的东西一样都不拿. 注意它**不影响随机数序列** —— 包的内容在买下那一刻就已经
    /// 全部掷好了, 与取不取哪张无关.
    pub fn skip_pack(&mut self) -> Result<(), ActionError> {
        if self.phase != Phase::BoosterOpened {
            return Err(ActionError::NotInPhase {
                expected: Phase::BoosterOpened,
                actual: self.phase,
            });
        }
        // 红牌: 跳过补充包时给自己涨 3 点倍率 (游戏在 `context.skipping_booster` 那一支里做).
        for joker in self.jokers.iter_mut() {
            if joker.key == "j_red_card" && !joker.debuffed {
                joker.mult += 3.0;
            }
        }
        self.close_pack();
        Ok(())
    }

    /// 从开好的包里挑走一张, 返回挑到的那张的键. 对应 `pack` 端点.
    ///
    /// 挑完 `choose` 张就回商店, 包里剩下的牌直接弃掉 —— 它们在开包那一刻就已经消耗过随机数,
    /// 所以弃掉不影响后面的序列.
    pub fn pick_from_pack(&mut self, index: usize) -> Result<String, ActionError> {
        let key = self.take_from_pack(index)?;
        self.close_pack_if_done();
        Ok(key)
    }

    /// 从包里取一张**并当场用掉**, 返回取到的键 (本仓库 `bbcore` 的 `pack` 端点那条路).
    ///
    /// 顺序是这条路径的要点, 而且**顺序反了就会静默出错**:
    /// 游戏那边是"把牌从包里拿出来 -> 立刻用在**手牌**上 -> 用完再看包是不是取够了",
    /// 而取够的那一刻关包会把整手牌收回牌堆 (`draw_from_hand_to_deck`). 塔罗改的正是手牌,
    /// 所以先后必须是"先用手牌, 再收牌", 改过的牌才会带着强化回到牌堆 ——
    /// 整局对拍里第 41 步那张圣职者(给两张牌加强化)就是这么落在 `S_4` 上的, 而那一张
    /// 下一回合发牌时又回到了手里.
    ///
    /// 先关包再用的写法在这一处会**报错** (手牌已经空了, 目标下标越界), 但那是运气:
    /// 目标下标若恰好落在空手牌范围内, 就会安静地什么都不做.
    pub fn take_and_use_from_pack(
        &mut self,
        index: usize,
        targets: &[usize],
    ) -> Result<String, ActionError> {
        // **先在副本上做, 成了才落到自己身上.**
        //
        // 这一步不能省: 游戏拒绝了这次尝试时 (选中张数不对, 那张牌的"使用"按钮是灰的),
        // 局面必须**一点没动** —— 牌还在包里, 可取的张数也没减, 包也还开着.
        // 直接在身上做的话, `take_from_pack` 已经把可取的张数减了, 用不成再补回去也补不回
        // "取了几张"这件事, 而且最后那句 `close_pack_if_done` 会把包关掉 ——
        // 表现成"下一步又说不在包里了", 与真实原因隔得很远.
        let mut trial = self.clone();
        let key = trial.take_from_pack(index)?;
        // 只有**消耗牌**走"取出来直接用"这条路; 小丑与扑克牌取出来就是收下, 没有"用"这一步.
        if is_consumable(&key) {
            // 取出来的消耗牌放在槽的最后, 就是刚取出来的那张.
            let slot = trial.consumables.len() - 1;
            // 关包由下面那句负责, 所以这里阶段还在包里, 手牌也还在.
            trial.use_consumable(slot, targets)?;
        }
        trial.close_pack_if_done();
        *self = trial;
        Ok(key)
    }

    /// 从开着的包里取一张放好, 并把可取的张数减一. **不管关包** —— 关包由调用方决定时机,
    /// 因为"什么时候关"决定了手牌还在不在 (见 `take_and_use_from_pack`).
    fn take_from_pack(&mut self, index: usize) -> Result<String, ActionError> {
        if self.phase != Phase::BoosterOpened {
            return Err(ActionError::NotInPhase {
                expected: Phase::BoosterOpened,
                actual: self.phase,
            });
        }
        let pack = self.open_pack.as_ref().expect("阶段对就一定有包");
        let picked = pack
            .contents
            .get(index)
            .cloned()
            .ok_or(ActionError::BadIndex(index))?;
        let key = picked.key.clone();

        // 按卡的类型放进对应的位置.
        if is_consumable(&key) {
            // **包里的牌不限槽位**: 游戏那边用 `emplace` 直接放 (与珀克奥的复制品同一个机制),
            // 所以槽位满了照样取得出来 —— 于是会出现"3 张挤在 2 格里".
            // 整局对拍里第 48 步就是这样: 消耗槽满着, 里面那张灵魂照样被取走并当场用掉.
            // (商店那条路不一样: 那边槽位满了"使用"按钮就是灰的, 所以 `buy` 里仍然查槽位.)
            self.consumables.push(super::consumable::Consumable::with_edition(
                key.clone(),
                picked.edition,
            ));
        } else if key.starts_with("j_") {
            if self.jokers.len() >= self.joker_capacity() {
                return Err(ActionError::NoRoom {
                    what: "小丑",
                    slots: self.joker_capacity(),
                });
            }
            let mut joker = Joker::new(&key).ok_or(ActionError::UnknownCard(key.clone()))?;
            // 包里的小丑也会带版本 / 永恒 / 易腐 / 租赁 (与商店货架上的一样, 只是掷骰的键不同),
            // 取的时候要一起带过去 —— 少带一项, 那张牌就"少了它该有的特性", 而且不报错.
            joker.edition = picked.edition;
            joker.eternal = picked.eternal;
            joker.rental = picked.rental;
            joker.cost = super::shop::shop_cost(joker.cost, joker.edition, joker.rental,
                self.inflation, self.discount_percent);
            // 待办清单的牌型在包里那张牌被**造出来**时就掷好了, 取的时候一路带过来.
            if key == "j_todo_list" {
                joker.todo_hand = picked.todo;
            }
            if picked.perishable {
                joker.perish_tally = PERISHABLE_ROUNDS;
            }
            let current = joker.extra;
            self.add_joker(joker);
            // 占卜师: 它算的是"本赛局用过几张塔罗", 所以进队时要取全局现值, 而不是从 0 起.
            if key == "j_fortune_teller"
                && let Some(last) = self.jokers.last_mut()
            {
                last.mult = self.tarots_used as f64;
            }
            apply_joker_on_gain(self, &key, current);
        } else {
            // 标准包里开出来的扑克牌进牌堆, 版本, 蜡封与强化一起带过去.
            let mut card =
                CardInstance::from_key(&key).ok_or(ActionError::UnknownCard(key.clone()))?;
            card.edition = picked.edition;
            card.seal = picked.seal;
            card.enhancement = picked.enhancement;
            // **建牌序号必须发一个**: 游戏里每造一张牌都会把全局计数器加一 (`Card:init` 里
            // `G.sort_id = (G.sort_id or 0) + 1`), 所以从包里取出的这张是**最新**的, 洗牌前
            // 按序号排序时排在**最后**. `CardInstance::from_key` 给的是 0 (那是给"只用牌面"的
            // 场合准备的), 照 0 排它就跑到最前面, 整副牌洗完的顺序全变 ——
            // 整局对拍里 133 步那份第 59 步那手牌就是这么差的 (张数一样, 牌面全不同).
            card.card.sort_id = self.next_sort_id();
            // 进牌堆的位置: 游戏那边是 `G.deck:emplace(card)`, 而 `CardArea:emplace` 对
            // **牌堆**是插到数组**第 1 位** —— 牌堆的取牌端在数组**末尾** (`remove_card` 取
            // `_cards[#_cards]`), 所以插第 1 位就是"塞到最底下".
            // 用 `push` 反而是塞到**顶上**, 会先被发出来 —— 洗牌前的排序能抹平这个差别,
            // 但**同一个底注里**再开一次发牌的包 (秘术 / 幽灵包) 时, 那时牌堆还没排序,
            // 差别就直接显出来了.
            self.deck.insert(0, card);
        }

        let pack = self.open_pack.as_mut().expect("刚刚还在这里");
        // **取走的那张要从包里拿掉** —— 记录里的 `pack=` 记的是包里**还剩**什么,
        // 不拿掉就一直是原来那几张. 巨型包 (取完一次还开着) 会当场露出来:
        // 引擎那边用掉一张之后包里还留着它, 与记录只差一张.
        if index < pack.contents.len() {
            pack.contents.remove(index);
        }
        pack.choices_left -= 1;
        Ok(key)
    }

    /// 包里的张数取够了就关包 (没取够就继续开着).
    fn close_pack_if_done(&mut self) {
        if self
            .open_pack
            .as_ref()
            .is_some_and(|pack| pack.choices_left == 0)
        {
            self.close_pack();
        }
    }

    /// 这一手重抽商店要花多少, 对应 `calculate_reroll_cost`.
    ///
    /// 基础价加"这回合已经抽过几次", 所以越抽越贵; 免费重抽 (混沌小丑给的) 会把它压到 0.
    pub fn reroll_cost(&self) -> f64 {
        // D6 标签让这一轮的商店重抽免费; 混沌小丑给的是"免费重抽几次".
        if self.free_reroll || self.free_rerolls > 0 {
            return 0.0;
        }
        self.reroll_base_cost + self.rerolls as f64
    }

    /// 记一次重抽并把钱扣掉, 返回花掉的数.
    ///
    /// 货架本身由调用方管理 (它要按 `ShopRates` 与当前底注重新生成), 这里只管账与计数.
    pub fn pay_for_reroll(&mut self) -> Result<f64, ActionError> {
        if self.phase != Phase::Shop {
            return Err(ActionError::NotInPhase {
                expected: Phase::Shop,
                actual: self.phase,
            });
        }
        let cost = self.reroll_cost();
        // 判据是"钱减掉能欠的额度": 默认 `bankrupt_at` 为 0, 也就是必须付得起.
        if cost > self.dollars - self.bankrupt_at {
            return Err(ActionError::NotEnoughMoney {
                cost,
                have: self.dollars,
            });
        }
        self.dollars -= cost;
        // 免费重抽不累计涨价, 与 `calculate_reroll_cost` 里那一支一致.
        if self.free_rerolls > 0 {
            self.free_rerolls -= 1;
        } else {
            self.rerolls += 1;
        }
        Ok(cost)
    }

    /// 卖掉一张小丑, 返回到手的钱.
    ///
    /// 价钱照 `Card:set_cost` 里的 `sell_cost`: 买入价的一半向下取整, 最低一元.
    pub fn sell_joker(&mut self, index: usize) -> Result<f64, ActionError> {
        let joker = self
            .jokers
            .get(index)
            .ok_or(ActionError::BadIndex(index))?;
        if joker.eternal {
            return Err(ActionError::NotAllowed("永恒小丑不能卖掉"));
        }
        let price = joker.sell_price();
        let key = joker.key.clone();
        // 离场时要用"当前"那个成长值 (海龟豆的手牌上限每回合会掉).
        let current_extra = joker.extra;

        // 隐形小丑: 攒够回合之后卖掉, 它会把**另一个**随机小丑复制一份 (`pseudoseed('invisible')`).
        // 判在**移除之前** —— 移除之后再按下标取, 取到的就是别人了 (这里踩过一次).
        if joker.key == "j_invisible" && joker.invis_rounds >= joker.extra {
            let others: Vec<String> = self
                .jokers
                .iter()
                .enumerate()
                .filter(|(i, _)| *i != index)
                .map(|(_, joker)| joker.key.clone())
                .collect();
            // 游戏那边的条件写的是 `#G.jokers.cards <= card_limit`, 也就是**卖掉之前**还有位子.
            if !others.is_empty() && self.jokers.len() <= self.joker_capacity() {
                let picked = self.rng.pick(&others, "invisible").clone();
                if let Some(source) = self.jokers.iter().find(|joker| joker.key == picked).cloned()
                    && let Some(mut copy) = Joker::new(&picked)
                {
                    copy.edition = source.edition;
                    copy.eternal = source.eternal;
                    copy.rental = source.rental;
                    copy.extra = source.extra;
                    copy.chips = source.chips;
                    copy.mult = source.mult;
                    copy.x_mult = source.x_mult;
                    self.add_joker(copy);
                }
            }
        }

        // 减肥可乐: 卖掉它就换一个"双倍"标签 (它自己的说明就是"卖掉这牌就可以...").
        if key == "j_diet_cola" {
            self.tags.push("tag_double".to_owned());
        }

        self.dollars += price;
        self.jokers.remove(index);
        // 篝火: 每卖掉一张牌就涨 0.25 倍 (游戏在 `context.selling_card` 那一支里做).
        if key != "j_campfire" {
            for joker in self.jokers.iter_mut() {
                if joker.key == "j_campfire" && !joker.debuffed {
                    joker.x_mult += joker.extra;
                }
            }
        }
        // 摔角手: 把它卖掉就**直接禁用当前的 Boss 盲注** (与奇可 / 翠叶同一个开关).
        if key == "j_luchador"
            && self
                .blind
                .as_ref()
                .is_some_and(|blind| blind.kind == BlindKind::Boss && !blind.disabled)
        {
            self.disable_blind();
        }
        // 翠叶: 卖掉一张小丑就把这个盲注的效果关掉 (它的说明就是"直到卖掉一张小丑").
        // 游戏那边这一步是 `G.GAME.blind:disable()`, 而那里面会**把整副牌恢复** ——
        // 所以卖完小丑之后剩下的手牌立刻又能得分了. 见 `disable_blind`.
        if self
            .blind
            .as_ref()
            .is_some_and(|b| b.key == "bl_final_leaf" && !b.disabled)
        {
            self.disable_blind();
        }
        // 卖掉之后它带来的规则变化也要撤掉.
        apply_joker_on_loss(self, &key, current_extra);
        // 同时把"用过"的记录清掉 (`Card:remove()` 里那句: 场上没有同名卡就去掉记录) ——
        // 于是卖掉的小丑**还能再刷出来**. 整局对拍里那张重复的传奇就是这么来的:
        // 先卖掉一张, 后面灵魂又开出一张同样的.
        if !self.jokers.iter().any(|joker| joker.key == key) {
            self.used_jokers.remove(&key);
        }

        Ok(price)
    }

    /// 卖掉一张消耗牌. 价钱按原型的基础价算.
    pub fn sell_consumable(&mut self, index: usize) -> Result<f64, ActionError> {
        let card = self.consumables.get(index).ok_or(ActionError::BadIndex(index))?;
        let key = card.key.clone();
        let base = crate::data::catalog::Catalog::get()
            .record(&key)
            .and_then(|proto| proto.base_cost)
            .unwrap_or(0.0);
        let astronomer = self.jokers.iter().any(|joker| joker.key == "j_astronomer" && !joker.debuffed)
            && crate::data::catalog::Catalog::get().record(&key).is_some_and(|proto| proto.category == "Planet");
        let cost = if astronomer { 0.0 } else {
            super::shop::shop_cost(base, card.edition, false, self.inflation, self.discount_percent)
        };
        let price = sell_price(cost);
        self.dollars += price;
        self.consumables.remove(index);
        // 同上: 卖掉之后记录也去掉.
        if !self.consumables.iter().any(|card| card.key == key) {
            self.used_jokers.remove(&key);
        }
        Ok(price)
    }

    /// 从商店买一件东西, 返回花掉的钱.
    ///
    /// 照 `G.FUNCS.buy_from_shop` 的顺序: 先看有没有空位, 扣钱, 再把卡从货架上挪进持有区.
    /// 钱不够或没空位就报错, 不做静默降级 —— 引擎是拿来做基准的, 悄悄放过一笔坏账比报错更糟.
    pub fn buy(&mut self, card: &ShopCard) -> Result<f64, ActionError> {
        // **先在副本上做, 成了才落到自己身上** —— 与 `take_and_use_from_pack` 同一个道理.
        //
        // 这里踩过的坑更具体: 下面把"那一格从货架上拿掉"排在各项校验**之前**, 于是钱不够
        // 或者持有区没空位时, 那一格照样没了 —— 引擎拒绝了这次购买, 货架却被改了.
        // 一份真实录像里就有这种尝试 (消耗槽满了还想买第三张塔罗), 于是下一步的 digest
        // 里少了一件商品. 与其把校验一条条往前挪 (以后加一条就可能再错), 不如整段放在副本上.
        let mut trial = self.clone();
        let cost = trial.take_from_shelf_for_purchase(card)?;
        let price = trial.place_purchase(card, cost)?;
        *self = trial;
        Ok(price)
    }

    /// 买下一张消耗牌并**当场用掉** —— 对应商店里那个"买并使用"按钮 (`buy_and_use`).
    ///
    /// 与"买下来放进消耗槽"是**两条不同的规矩**, 差别不只是省一步:
    ///
    /// - 它**不占消耗牌格子**, 所以槽满的时候照样能买 (端点 `buy.lua` 里那句
    ///   "Pass use=true to buy and use it immediately without taking a slot").
    ///   这一条最容易写漏, 写漏了就是"引擎说没空位, 游戏却买成了".
    /// - **那张牌本身不留在场上**: 它直接生效, 留下的是它的产物 (高等女祭司爆出两张行星牌).
    /// - 用不成的时候整笔不算 (端点先查 `can_use_consumeable` 再动手), 钱与货架都不动.
    ///
    /// 商店阶段手牌是空的, 所以需要指定手牌目标的塔罗在这里本来就用不成 (端点也会先拒掉),
    /// 于是这里不接 `targets`.
    pub fn buy_and_use(&mut self, card: &ShopCard) -> Result<f64, ActionError> {
        let mut trial = self.clone();
        let cost = trial.buy_and_use_inner(card)?;
        *self = trial;
        Ok(cost)
    }

    fn buy_and_use_inner(&mut self, card: &ShopCard) -> Result<f64, ActionError> {
        if !is_consumable(&card.key) {
            return Err(ActionError::NotAllowed("只有消耗牌能'买并使用'"));
        }
        // 付钱与离架那一半与普通购买完全一样, 但**槽位检查要跳过** ——
        // 所以不能直接借 `buy_on_shelf` (它把检查带在里边).
        let cost = self.take_from_shelf_for_purchase(card)?;
        // 临时放进最后一格再用掉: 商店那张牌本身并不真的占格子.
        //
        // **用完不用自己撤** —— `use_consumable` 结尾会 `remove(index)` 把那一格拿掉,
        // 而且它排在"造产物"之后, 所以下标仍然指着这张牌 (产物都追加在它后面).
        // 这里再撤一次就会删掉一张**刚造出来的**产物: 女祭司该爆两张行星牌, 结果只剩一张.
        self.consumables
            .push(super::consumable::Consumable::with_edition(
                card.key.clone(),
                card.edition,
            ));
        let slot = self.consumables.len() - 1;
        self.use_consumable(slot, &[])?;
        Ok(cost)
    }

    /// `buy` 的前半段: 查阶段, 算价 (含免费的那些), 查钱, 把那一格**从货架上拿掉**.
    ///
    /// 单独抽出来是因为"买并使用"要走同一半, 但它**不能**带走后半段里的槽位检查.
    fn take_from_shelf_for_purchase(&mut self, card: &ShopCard) -> Result<f64, ActionError> {
        if self.phase != Phase::Shop {
            return Err(ActionError::NotInPhase {
                expected: Phase::Shop,
                actual: self.phase,
            });
        }
        // 代金券标签让这一轮商店的东西免费, 所以先把它记的价抹掉.
        // 天文学家: 行星牌与"天体包"在他手里**不要钱** (游戏的 `Card:set_cost` 里那一句).
        let astronomer_free = self
            .jokers
            .iter()
            .any(|joker| joker.key == "j_astronomer" && !joker.debuffed)
            && (crate::data::catalog::Catalog::get()
                .record(&card.key)
                .is_some_and(|proto| proto.category == "Planet")
                || card.key.starts_with("p_celestial"));
        let cost = if self.shop_free || astronomer_free {
            0.0
        } else {
            card.cost
        };
        // 同 reroll: 能欠多少看 `bankrupt_at`, 信用卡会把它推开 20 元.
        if cost > self.dollars - self.bankrupt_at {
            return Err(ActionError::NotEnoughMoney {
                cost,
                have: self.dollars,
            });
        }

        // 买下的那一格要从货架上拿掉. 少了这一步的后果不只是"能再买一次":
        // 回放 digest 里的 `shop` / `vouchers` / `packs` 记的是**货架当前有什么**,
        // 不拿掉就会一直多出那一样, 于是从"买下第一件东西"那一步开始每一步都对不上.
        if let Some(shop) = self.shop.as_mut() {
            if let Some(index) = shop.packs.iter().position(|item| item == card) {
                shop.packs.remove(index);
            } else if let Some(index) = shop.jokers.iter().position(|item| item == card) {
                shop.jokers.remove(index);
            } else if shop.voucher.as_ref() == Some(card) {
                shop.voucher = None;
            }
        }
        Ok(cost)
    }

    /// `buy` 的后半段: 按类型把买下的东西落位 (含各项空位检查).
    fn place_purchase(&mut self, card: &ShopCard, cost: f64) -> Result<f64, ActionError> {
        match card.key.as_str() {
            // 优惠券买下就生效, 不进持有区.
            // **记下买了哪张券**与**施加它的效果**是两件事: 只记不施加的话, 券就是白买的.
            key if key.starts_with("v_") => {
                self.used_vouchers.insert(key.to_owned());
                super::voucher::apply(self, key);
                // 券那一格是**这一底**的: 买下之后它就空着, 这一底剩下的商店里都不会再摆券,
                // 直到下一个底注开局才换新 (`Card:redeem` 里那两句
                // `G.GAME.current_round.voucher = nil`, 而铺货时"没有键就不摆券").
                // 只清货架上那张 (`shop.voucher`) 是不够的 —— 键还在 `shop_vouchers` 里,
                // 下一次铺货会照着它把**已经买过**的那张又摆回去.
                // 清空之后还要立个"这一底买过了"的标志, 否则铺货会当成"还没摆券"再抽一张新的.
                // 整局对拍里第 52 步买完券、第 57 步进商店时就是这么差的.
                self.shop_vouchers.clear();
                self.voucher_spent = true;
                // **只有"库存过剩"那两张券**会当场把货架多摆一件: 游戏里那两张各有一句
                // `change_shop_size(1)`, 而那个函数把 `joker_max` 加一之后才把货架补到新的上限.
                //
                // 不能"买完券就补一次" —— 货架因为**买走东西**而少于上限时是不补的:
                // XXWF71H9 第 81 步买的是别的券, 货架上前一步刚买走一张小丑只剩一格,
                // 无条件补货会让它变回两格, 而游戏那边一直只有一格.
                if matches!(key, "v_overstock_norm" | "v_overstock_plus") {
                    self.top_up_shelf();
                }
            }
            // 补充包买下会立刻打开, 包里的牌当场定下来, 然后进"挑牌"状态.
            key if key.starts_with("p_") => {
                let contents = super::shop::open_pack(self, key);
                let choices = super::shop::pack_choices(key);
                self.dollars -= cost;
                self.open_pack = Some(super::shop::OpenPack {
                    key: key.to_owned(),
                    size: contents.len(),
                    choices_left: choices,
                    contents,
                });
                self.pack_return_phase = Phase::Shop;
                self.phase = Phase::BoosterOpened;
                self.deal_for_pack();
                return Ok(cost);
            }
            key => {
                // 位子够不够看的是游戏的 `G.FUNCS.check_for_buy_space`, 它写的是
                // `#G.jokers.cards < G.jokers.config.card_limit + ((card.edition and card.edition.negative) and 1 or 0)` ——
                // **正在买的这张**如果是负片, 就多给一个位子: 它一进队就会把上限抬高一格
                // (见 `Card:add_to_deck`), 所以"队里 5 张、上限 5"时照样买得下第 6 张负片小丑.
                // 少了这半句, 引擎会在游戏点头的地方报"没位置" —— XXWF71H9 第 78 步就是这样:
                // 队里 5 张小丑, 商店那张色欲小丑是负片版, 游戏让买, 引擎不让.
                let extra_room = usize::from(card.edition == Some(crate::cards::Edition::Negative));
                if is_consumable(key) {
                    if self.consumables.len() >= self.consumable_capacity() + extra_room {
                        return Err(ActionError::NoRoom {
                            what: "消耗牌",
                            slots: self.consumable_capacity(),
                        });
                    }
                    // 商店里买下的消耗牌也**带上它的版本**.
                    self.consumables.push(super::consumable::Consumable::with_edition(
                        key.to_owned(),
                        card.edition,
                    ));
                } else if is_playing_card_key(key) {
                    // **扑克牌进牌堆, 不进小丑区** —— 游戏里那一段写的是
                    // `if c1.ability.set == 'Default' or c1.ability.set == 'Enhanced' then ... G.deck:emplace(c1)`.
                    // 少了这一支, 买扑克牌会被当成小丑去查原型表, 报 `UnknownCard`
                    // (而这是幻象券 / 魔法把戏券开了之后**每一局**都会遇到的操作).
                    //
                    // 顺序也要紧: 强化与版本一起带过去, 而且新的牌要拿一个**新的建牌序号**
                    // (`G.playing_card` 那个全局计数), 否则它插进牌堆的位置会跟游戏不同.
                    //
                    // 走 `add_playing_card_to_deck` 而不是自己插 —— 游戏在 `G.deck:emplace` 之后紧跟
                    // 一句 `playing_card_joker_effects({c1})` (也就是 `playing_card_added` 这个钩子,
                    // 全息图靠它涨乘倍率). 自己插会漏掉这个钩子, 而且插入位置那条特例也重复写了一遍.
                    let mut instance = crate::cards::CardInstance::from_key(key)
                        .ok_or(ActionError::UnknownCard(key.to_owned()))?;
                    instance.enhancement = card.enhancement;
                    instance.edition = card.edition;
                    instance.card.sort_id = self.next_sort_id();
                    self.add_playing_card_to_deck(instance);
                } else {
                    if self.jokers.len() >= self.joker_capacity() + extra_room {
                        return Err(ActionError::NoRoom {
                            what: "小丑",
                            slots: self.joker_capacity(),
                        });
                    }
                    let mut joker = Joker::new(key).ok_or(ActionError::UnknownCard(key.to_owned()))?;
                    // 卖出价按实际花的钱算, 不是原型的基础价 (可能带版本加价或折扣).
                    // 商店免费时这一份记 0, 卖掉也就不值钱 —— 与游戏的 `set_cost` 一致.
                    joker.cost = cost;
                    // 商店给的三个标记要带到买下来的那张上, 否则之后没人知道它是租赁还是易腐的.
                    // **版本也要带** —— 货架上那张是闪箔 / 镭射 / 多彩 / 负片的时候, 买下来
                    // 就是那张带版本的 (引擎原来漏了这一项, 于是版本在买的那一刻凭空消失,
                    // 整局对拍里 133 步那份第 74 步买的那张 `j_droll+f!e` 就是这么差的).
                    joker.edition = card.edition;
                    joker.eternal = card.eternal;
                    joker.rental = card.rental;
                    if card.perishable {
                        joker.perish_tally = PERISHABLE_ROUNDS;
                    }
                    // 待办清单的牌型在货架上就掷好了 (见 `ShopCard::todo`), 买下来一路带着.
                    if key == "j_todo_list" {
                        joker.todo_hand = card.todo;
                    }
                    let current = joker.extra;
                    self.add_joker(joker);
            // 占卜师: 它算的是"本赛局用过几张塔罗", 所以进队时要取全局现值, 而不是从 0 起.
            if key == "j_fortune_teller"
                && let Some(last) = self.jokers.last_mut()
            {
                last.mult = self.tarots_used as f64;
            }
                    // 有几张小丑买进来就改规则, 这里统一处理.
                    apply_joker_on_gain(self, key, current);
                }
            }
        }

        // 扣钱放在挪动之后, 与游戏一致.
        if cost != 0.0 {
            self.dollars -= cost;
        }
        Ok(cost)
    }
}

/// 这张货架上的牌是不是**扑克牌** (拿 `C_T` 这种记号), 而不是小丑 / 消耗牌 / 券 / 包.
///
/// 判据就用"能不能按记号建出牌来": 记号的形状是 `花色_点数`, 而小丑 (`j_`) / 消耗牌 (`c_`) /
/// 券 (`v_`) / 包 (`p_`) 的首段都不是花色字符, 所以这个判据不会认错.
///
/// 这类牌买下来进**牌堆** (`G.deck:emplace`), 与小丑 / 消耗牌的落点不同 —— 见
/// `place_purchase` 里那一支.
fn is_playing_card_key(key: &str) -> bool {
    crate::cards::CardInstance::from_key(key).is_some()
}

/// 塔罗与行星属于消耗牌, 买下进消耗槽而不是小丑槽.
/// 这张消耗牌是不是行星牌, 是的话升级哪个牌型.
///
/// 行星牌的原型都带 `config.hand_type`, 值是牌型的名字.
fn planet_hand(key: &str) -> Option<PokerHand> {
    crate::data::catalog::Catalog::get()
        .record(key)
        .and_then(|proto| proto.config.as_ref())
        .and_then(|config| config.get("hand_type"))
        .and_then(crate::data::json::Json::as_str)
        .and_then(PokerHand::from_key)
}

/// 反过来: 升这个牌型的行星牌是哪一张. 蓝封在回合末要拿它.
///
/// 每种牌型只有一张行星牌, 线性找一遍就行.
fn planet_for_hand(hand: PokerHand) -> Option<String> {
    crate::data::catalog::Catalog::get()
        .pool("Planet")
        .iter()
        .find(|proto| {
            proto
                .config
                .as_ref()
                .and_then(|config| config.get("hand_type"))
                .and_then(crate::data::json::Json::as_str)
                .and_then(PokerHand::from_key)
                == Some(hand)
        })
        .map(|proto| proto.id.clone())
}

/// 这个"白送包"标签给哪个包, 认不出来返回 `None`.
///
/// 吊饰与流星要随机挑一号, 这里用掉一个**全局**随机数 —— 游戏那边是 `math.random(1,2)`,
/// 不是 `pseudorandom`, 所以不走 `pseudoseed` 那条线.
fn free_pack_key(run: &mut RunState, tag: &str) -> Option<String> {
    Some(match tag {
        "tag_charm" => format!("p_arcana_mega_{}", run.rng.random_int_range(1.0, 2.0)),
        "tag_meteor" => format!("p_celestial_mega_{}", run.rng.random_int_range(1.0, 2.0)),
        // 这三个是固定的普通包, 没有随机.
        "tag_ethereal" => "p_spectral_normal_1".to_owned(),
        "tag_standard" => "p_standard_mega_1".to_owned(),
        "tag_buffoon" => "p_buffoon_mega_1".to_owned(),
        _ => return None,
    })
}

/// 标签原型里某个数值字段 (`spawn_jokers` / `levels` 这类).
fn tag_config_number(key: &str, field: &str) -> f64 {
    crate::data::catalog::Catalog::get()
        .record(key)
        .map(|proto| proto.config_number(field))
        .unwrap_or(0.0)
}

/// 这个 Boss 会不会削掉某张牌. 对应 `Blind:debuff_card` 里那几种按性质判的分支.
///
/// 削掉的牌仍参与牌型识别, 但自身不再计分 (筹码, 倍率, 版本, 蜡封都停用).
fn debuffs_card(boss_key: &str, card: &CardInstance, pareidolia: bool) -> bool {
    match boss_key {
        // 四个花色 Boss: 那个花色的牌全废.
        "bl_club" => card.card.suit == Suit::Clubs,
        "bl_goad" => card.card.suit == Suit::Spades,
        "bl_head" => card.card.suit == Suit::Hearts,
        "bl_window" => card.card.suit == Suit::Diamonds,
        // 植物: 人头牌全废.
        // 植物 (The Plant): 人头牌失效 —— 有帕瑞多利亚时**所有牌**都算人头牌, 于是全都失效.
        "bl_plant" => card.card.rank.is_face() || pareidolia,
        _ => false,
    }
}

/// 小丑**进场**时对局面做的改动 (改的是规则而不是这一次计分).
///
/// 与信用卡同类: 买入或从包里拿到就生效, 卖掉要撤回来. 所以这里成对写,
/// 两个函数的 `match` 必须一模一样 —— 少写一边就会越攒越多.
fn apply_joker_on_gain(run: &mut RunState, key: &str, current: f64) {
    match key {
        // 信用卡: 把破产线推开 20 元.
        "j_credit_card" => run.bankrupt_at -= CREDIT_CARD_LIMIT,
        // 杂耍师: 手牌上限加一.
        "j_juggler" => run.hand_size_bonus += 1,
        // 七上八下: 所有概率翻倍 (游戏是把 `G.GAME.probabilities` 整表乘二).
        "j_oops" => run.probability_scale *= 2.0,
        // 月亮: 每 5 块钱多拿 1 块利息 —— 也就是把利息率从 1 提到 2.
        "j_to_the_moon" => run.interest_rate += current,
        // 海龟豆: 拿到时把手牌上限加上它**当前**那个值 (初值 5, 之后每回合掉一点).
        "j_turtle_bean" => run.hand_size_bonus += current as i64,
        // 醉汉: 弃牌次数加一.
        "j_drunkard" => run.discards_per_round += 1,
        // 快乐安迪: 弃牌加三, 手牌减一.
        "j_merry_andy" => {
            run.discards_per_round += 3;
            run.hand_size_bonus -= 1;
        }
        // 特技演员: 手牌上限减二 (它那 +250 筹码走计分那条路, 不在这里).
        "j_stuntman" => run.hand_size_bonus -= 2,
        // 游吟诗人: 出牌次数减一, 手牌上限加二.
        "j_troubadour" => {
            run.hands_per_round -= 1;
            run.hand_size_bonus += 2;
        }
        _ => {}
    }
}

/// 小丑**离场**时把上面那些改回来.
fn apply_joker_on_loss(run: &mut RunState, key: &str, current: f64) {
    match key {
        "j_credit_card" => run.bankrupt_at += CREDIT_CARD_LIMIT,
        "j_juggler" => run.hand_size_bonus -= 1,
        // 七上八下: 丢掉就把概率还回去.
        "j_oops" => run.probability_scale /= 2.0,
        // 月亮: 丢掉/卖掉就把利息率还回去.
        "j_to_the_moon" => run.interest_rate = (run.interest_rate - 1.0).max(1.0),
        // 海龟豆的手牌上限是**动态**的 (每回合掉一点), 所以撤掉的是它**当前**那个值,
        // 不是配置里的初值 —— 少了这一条, 卖掉/自毁之后手牌上限会多留几点.
        "j_turtle_bean" => run.hand_size_bonus -= current as i64,
        "j_drunkard" => run.discards_per_round -= 1,
        "j_merry_andy" => {
            run.discards_per_round -= 3;
            run.hand_size_bonus += 1;
        }
        "j_stuntman" => run.hand_size_bonus += 2,
        "j_troubadour" => {
            run.hands_per_round += 1;
            run.hand_size_bonus -= 2;
        }
        _ => {}
    }
}

/// 卖出价: 买入价的一半向下取整, 最低一元. 对应 `Card:set_cost` 末尾那两行.
fn sell_price(cost: f64) -> f64 {
    (cost / 2.0).floor().max(1.0)
}

/// 信用卡小丑把破产线推开多少, 对应原型的 `config.extra`.
const CREDIT_CARD_LIMIT: f64 = 20.0;

/// 租赁小丑每回合末扣多少 (`G.GAME.rental_rate`).
const RENTAL_RATE: f64 = 3.0;

/// 易腐小丑能撑几个回合 (`G.GAME.perishable_rounds`).
const PERISHABLE_ROUNDS: i64 = 5;

/// 使魔 / 严峻 / 咒语造出来的牌从哪些强化里抽 (对应 `G.P_CENTER_POOLS["Enhanced"]`,
/// 按原型里的 `order` 排, 只是**去掉石头牌** —— 石头牌的点数由强化自己顶掉, 不在这条路上).
const SUMMON_ENHANCEMENTS: [Enhancement; 7] = [
    Enhancement::Bonus,
    Enhancement::Mult,
    Enhancement::Wild,
    Enhancement::Glass,
    Enhancement::Steel,
    Enhancement::Gold,
    Enhancement::Lucky,
];

/// 塔罗与行星属于消耗牌, 买下进消耗槽而不是小丑槽.
/// 这张牌是不是消耗牌 (塔罗 / 行星 / 幻灵).
///
/// **三类都要认** —— 少认一类不会报错, 只会把它当成扑克牌去建, 于是"从包里拿一张幻灵牌"
/// 变成 `UnknownCard`. 这三类正好就是消耗牌的三个 `set`.
fn is_consumable(key: &str) -> bool {
    crate::data::catalog::Catalog::get()
        .record(key)
        .map(|proto| matches!(proto.category.as_str(), "Tarot" | "Planet" | "Spectral"))
        .unwrap_or(false)
}

/// 这张塔罗换的是哪种强化, 没有 `mod_conv` 或它指向的不是 `m_` 原型就给 `None`.
fn enhancement_of(key: &str) -> Option<crate::cards::Enhancement> {
    crate::cards::Enhancement::from_key(&mod_conv_of(key)?)
}

/// 原型上的 `max_highlighted`: 一次最多选中几张牌.
fn enhancement_limit(key: &str) -> usize {
    crate::data::catalog::Catalog::get()
        .record(key)
        .and_then(|proto| proto.config.as_ref())
        .and_then(|config| config.get("max_highlighted"))
        .and_then(crate::data::json::Json::as_f64)
        .map(|n| n as usize)
        .unwrap_or(1)
}

/// 原型上的 `mod_conv` 字段.
fn mod_conv_of(key: &str) -> Option<String> {
    crate::data::catalog::Catalog::get()
        .record(key)
        .and_then(|proto| proto.config.as_ref())
        .and_then(|config| config.get("mod_conv"))
        .and_then(crate::data::json::Json::as_str)
        .map(str::to_owned)
}

/// 校验 `order` 是 `0..len` 的一个排列: 长度对得上, 下标都在范围内, 且不重复.
///
/// 端点那边就是这么查的 (长度 / 范围 / 重复各报一种错), 这里照做 —— 少查一项就会出现
/// "同一张牌被排进两次, 另一张凭空消失"这种安静的状态损坏.
fn check_permutation(order: &[usize], len: usize) -> Result<(), ActionError> {
    if order.len() != len {
        return Err(ActionError::BadIndex(order.len()));
    }
    let mut seen = vec![false; len];
    for &index in order {
        if index >= len || seen[index] {
            return Err(ActionError::BadIndex(index));
        }
        seen[index] = true;
    }
    Ok(())
}
