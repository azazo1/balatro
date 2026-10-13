//! 只读观察 DTO, 常规模式在模型层裁剪隐藏身份.
use engine::{agent::{summary,observation,dynamics}, cards::{CardInstance,Edition,Enhancement,Seal}, data::knowledge, opening, run::{BlindKind,Phase,RunState,make_blind}, scoring::PokerHand};
use serde_json::{Value,json};
use crate::{debug,session::{Event,Session,MAX_NODES}};

pub fn info() -> Value {
    json!({"version":engine::VERSION,"format_version":1,
        "decks":opening::DECKS.into_iter().map(item).collect::<Vec<_>>(),
        "stakes":opening::STAKES,
        "max_nodes":MAX_NODES,"max_file_bytes":crate::format::MAX_FILE_BYTES})
}

fn item(key: &str) -> Value {
    let (name,effect) = knowledge::describe(key).unwrap_or((key,""));
    let playing = CardInstance::from_key(key);
    json!({"key":key,"name":playing.as_ref().map_or_else(||name.to_owned(),summary::playing_card),
        "effect":effect,"category":engine::data::catalog::Catalog::get().record(key).map(|p|p.category.as_str())})
}

/// 页面叠贴图用的结构化修饰, 与 `modifiers` 文本同源. 暗牌不调用它.
struct Traits { enhancement: Option<Enhancement>, edition: Option<Edition>, seal: Option<Seal>, eternal: bool, perishable: bool, rental: bool, debuffed: bool }

impl Traits {
    fn apply(self, value: &mut Value) {
        let edition = self.edition.map(|e| match e { Edition::Foil=>"foil",Edition::Holo=>"holo",Edition::Polychrome=>"polychrome",Edition::Negative=>"negative" });
        let stickers: Vec<&str> = [(self.eternal,"eternal"),(self.perishable,"perishable"),(self.rental,"rental")]
            .into_iter().filter(|(on,_)|*on).map(|(_,k)|k).collect();
        value["enhancement"] = json!(self.enhancement.map(|e|format!("m_{}",e.key())));
        value["edition"] = json!(edition);
        value["seal"] = json!(self.seal.map(Seal::key));
        value["stickers"] = json!(stickers);
        value["debuffed"] = json!(self.debuffed);
    }
}

fn playing(card: &CardInstance, index: usize, reveal: bool) -> Value {
    if card.face_down && !reveal { return json!({"index":index,"name":"背面朝上","hidden":true,"effect":""}); }
    let mut value = json!({"index":index,"name":summary::playing_card(card),"token":card.token(),
        "key":card.card.key(),"hidden":false,"face_down":card.face_down,
        "suit":format!("{:?}",card.card.suit),"rank":format!("{:?}",card.card.rank),
        "effect":format!("计分筹码 {}",summary::number(card.to_hand_card().chip_bonus())),
        "modifiers":summary::card_modifiers(card.enhancement,card.edition,card.seal,false,0,false,card.debuffed)});
    Traits { enhancement:card.enhancement,edition:card.edition,seal:card.seal,eternal:false,perishable:false,rental:false,debuffed:card.debuffed }.apply(&mut value);
    value
}

fn shop_cards(cards: &[engine::run::ShopCard]) -> Vec<Value> {
    cards.iter().enumerate().map(|(index,card)| {
        let mut value = item(&card.key);
        value["index"] = json!(index);
        value["cost"] = json!(card.cost);
        value["modifiers"] = json!(summary::card_modifiers(card.enhancement,card.edition,None,card.eternal,if card.perishable {5} else {0},card.rental,false));
        value["current"] = json!(card.todo.map(summary::hand_zh));
        Traits { enhancement:card.enhancement,edition:card.edition,seal:None,eternal:card.eternal,perishable:card.perishable,rental:card.rental,debuffed:false }.apply(&mut value);
        value
    }).collect()
}

fn stats(run: &RunState) -> Value {
    json!({"ante":run.ante,"round":run.round,"dollars":run.dollars,"chips":run.chips,
        "hands_left":run.hands_left,"discards_left":run.discards_left,"spendable":run.dollars-run.bankrupt_at,
        "hand_size":run.hand_size(),"deck_count":run.deck.len(),"discard_count":run.discard_pile.len(),
        "joker_capacity":run.joker_capacity(),"consumable_capacity":run.consumable_capacity()})
}

pub fn render(session: &Session) -> Value {
    let run = session.state();
    let node = &session.nodes[session.current];
    let hand: Vec<Value> = run.hand.iter().enumerate().map(|(i,c)|playing(c,i,session.debug)).collect();
    let jokers: Vec<Value> = run.jokers.iter().enumerate().map(|(index,card)| {
        if run.jokers_face_down() && !session.debug { return json!({"index":index,"name":"背面朝上","hidden":true,"effect":""}); }
        let mut value = item(&card.key);
        value["index"] = json!(index);
        value["hidden"] = json!(false);
        value["cost"] = json!(card.sell_price());
        value["eternal"] = json!(card.eternal);
        value["current"] = json!(summary::joker_current(card));
        value["modifiers"] = json!(summary::card_modifiers(None,card.edition,None,card.eternal,card.perish_tally,card.rental,card.debuffed));
        Traits { enhancement:None,edition:card.edition,seal:None,eternal:card.eternal,perishable:card.perishable,rental:card.rental,debuffed:card.debuffed }.apply(&mut value);
        value
    }).collect();
    let consumables: Vec<Value> = run.consumables.iter().enumerate().map(|(index,card)| {
        let mut value = item(&card.key);
        value["index"] = json!(index);
        value["modifiers"] = json!(summary::card_modifiers(None,card.edition,None,false,0,false,false));
        Traits { enhancement:None,edition:card.edition,seal:None,eternal:false,perishable:false,rental:false,debuffed:false }.apply(&mut value);
        value
    }).collect();
    let blinds: Vec<Value> = [BlindKind::Small,BlindKind::Big,BlindKind::Boss].into_iter().enumerate().filter_map(|(i,kind)| {
        let key = observation::blind_key(run,i)?;
        let mut value = item(&key);
        let status = observation::blind_status(run,i);
        value["kind"] = json!(kind.name());
        value["status"] = json!(format!("{status:?}"));
        if matches!(status,observation::BlindStatus::Active | observation::BlindStatus::Select) {
            let blind = run.blind.as_ref().filter(|b|b.key==key).cloned()
                .unwrap_or_else(||make_blind(kind,&key,run.ante,run.scaling,run.ante_scaling,run.no_blind_reward));
            value["target"] = json!(blind.chips);
            value["reward"] = json!(blind.dollars);
        }
        if status == observation::BlindStatus::Select && i < 2 {
            value["tag"] = json!(run.blind_tags[i].as_ref().map(|k|item(k)));
        }
        Some(value)
    }).collect();
    let shop = if run.phase == Phase::Shop { run.shop.as_ref().map(|s|json!({"cards":shop_cards(&s.jokers),"vouchers":shop_cards(&s.vouchers),"packs":shop_cards(&s.packs),"reroll_cost":run.reroll_cost()})) } else {None};
    let pack = run.open_pack.as_ref().filter(|_|run.phase==Phase::BoosterOpened).map(|p| {
        json!({"name":item(&p.key)["name"],"choices_left":p.choices_left,
            "cards":p.contents.iter().enumerate().map(|(index,card)| {
                let mut value = item(&card.key);
                value["index"] = json!(index);
                value["modifiers"] = json!(summary::card_modifiers(card.enhancement,card.edition,card.seal,card.eternal,if card.perishable {5} else {0},card.rental,false));
                value["current"] = json!(card.todo.map(summary::hand_zh));
                Traits { enhancement:card.enhancement,edition:card.edition,seal:card.seal,eternal:card.eternal,perishable:card.perishable,rental:card.rental,debuffed:false }.apply(&mut value);
                value
            }).collect::<Vec<_>>()})
    });
    let levels: Vec<Value> = PokerHand::BY_PRIORITY.into_iter().rev().filter_map(|hand| {
        let level = run.hands.get(hand);
        (level.visible || session.debug).then(||json!({"name":summary::hand_zh(hand),"level":level.level,"chips":level.chips(hand),"mult":level.mult(hand),"played":level.played,"played_this_round":level.played_this_round}))
    }).collect();
    let current_stats = stats(run);
    let parent_stats = node.parent.map(|p| stats(session.nodes[p].snapshot.state()));
    let differences: Vec<Value> = parent_stats.as_ref().map(|old|current_stats.as_object().expect("指标对象").iter()
        .filter(|(k,v)|old.get(*k)!=Some(*v)).map(|(k,v)|json!({"field":k,"before":old[k],"after":v})).collect()).unwrap_or_default();
    let debug_data = session.debug.then(||json!({
        "values":debug::values(run),"digest":engine::run::digest::digest(run),"rng":run.rng.diagnostics(),
        "deck":run.deck.iter().rev().enumerate().map(|(i,c)|playing(c,i,true)).collect::<Vec<_>>(),
        "discard":run.discard_pile.iter().enumerate().map(|(i,c)|playing(c,i,true)).collect::<Vec<_>>()
    }));
    let history: Vec<Value> = session.nodes.iter().map(|n| {
        let kind = match &n.event { None=>"start",Some(Event::Action {action})=>&action.method,Some(Event::Edit {..})=>"edit" };
        // 计分报告可能很长, 历史行只保留第一行, 当前节点显示完整 note.
        json!({"id":n.id,"parent":n.parent,"kind":kind,"label":n.note.lines().next().unwrap_or(""),
            "phase":summary::phase_zh(n.snapshot.state().phase),"ante":n.snapshot.state().ante,"edited":n.edited})
    }).collect();
    let mut voucher_keys: Vec<_> = run.used_vouchers.iter().collect();
    voucher_keys.sort();
    let vouchers: Vec<_> = voucher_keys.into_iter().map(|k| item(k)).collect();
    json!({"version":engine::VERSION,"opening":session.opening,"revision":session.revision,"current":session.current,
        "debug":session.debug,"edited":node.edited,"max_nodes":MAX_NODES,"history":history,
        "observation":{"deck_back":session.opening.deck,"phase":format!("{:?}",run.phase),"phase_name":summary::phase_zh(run.phase),"won":run.won,"win_overlay":run.win_overlay,
            "stats":current_stats,"hand":hand,"jokers":jokers,"consumables":consumables,"blinds":blinds,
            "shop":shop,"pack":pack,"levels":levels,"note":node.note,"last_hand":node.report,
            "dynamics":dynamics::render(run),"summary":summary::render(run,&summary::Extras {last_hand:node.report.as_deref(),note:None}),
            "tags":run.tags.iter().map(|k|item(k)).collect::<Vec<_>>(),
            "vouchers":vouchers,
            "differences":differences,"debug":debug_data}})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Opening;

    #[test]
    fn ordinary_view_does_not_leak_hidden_identity_or_rng() {
        let mut s = Session::new(Opening { seed:"ALEEB".into(),deck:"RED".into(),stake:1,profile:"all".into() }).unwrap();
        let mut run = s.state().clone();
        run.select_blind().unwrap();
        run.hand[0].face_down = true;
        s.nodes[0].snapshot = run.snapshot("隐藏牌测试");
        let before_rng = format!("{:?}",s.state().rng);
        let normal = render(&s);
        let card = &normal["observation"]["hand"][0];
        assert_eq!(card["hidden"],true);
        assert!(card.get("token").is_none());
        assert!(card.get("suit").is_none());
        for field in ["key","enhancement","edition","seal","stickers"] { assert!(card.get(field).is_none(),"暗牌泄露 {field}"); }
        assert!(normal["observation"]["debug"].is_null());
        s.set_debug(0,true).unwrap();
        let revealed = render(&s);
        assert!(revealed["observation"]["hand"][0]["token"].is_string());
        assert_eq!(format!("{:?}",s.state().rng),before_rng);
    }
}
