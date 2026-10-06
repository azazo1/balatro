//! 生成域审计的关键回归, 期望依据带 Steamodded 的游戏分支.

fn lua_slice<'a>(source: &'a str, start: &str, end: &str) -> &'a str {
    let (_, tail) = source.split_once(start).expect("上游函数入口缺失");
    let length = tail.find(end).expect("上游函数边界缺失");
    let offset = source.len() - tail.len() - start.len();
    &source[offset..offset + start.len() + length]
}

fn luajit_eval(script: &str) -> String {
    use std::io::Write;
    use std::process::{Command, Stdio};
    // 优先用已构建游戏的 Lua.framework, 不启动窗口. brew ARM64 LuaJIT 的原生播种
    // 使用 FMA, 与本仓库游戏框架的非融合运算并非同一个随机数基准.
    let bundled = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../dist/macos/Balatro-Modded.app/Contents/Frameworks/Lua.framework/Versions/A/Lua");
    let runtime = std::env::var_os("BALATRO_AUDIT_LUA").map(std::path::PathBuf::from)
        .or_else(|| bundled.is_file().then_some(bundled));
    let python = r#"
import ctypes,sys
lib=ctypes.CDLL(sys.argv[1])
lib.luaL_newstate.restype=ctypes.c_void_p
lib.luaL_openlibs.argtypes=[ctypes.c_void_p]
lib.luaL_loadstring.argtypes=[ctypes.c_void_p,ctypes.c_char_p]
lib.lua_pcall.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int]
lib.lua_tolstring.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_size_t)]
lib.lua_tolstring.restype=ctypes.c_void_p
lib.lua_close.argtypes=[ctypes.c_void_p]
state=lib.luaL_newstate();lib.luaL_openlibs(state)
capture="local out={}; print=function(...) local p={} for i=1,select('#',...) do p[i]=tostring(select(i,...)) end out[#out+1]=table.concat(p,'\\t') end\n"
source=capture+sys.stdin.read()+"\nreturn table.concat(out,'\\n')"
status=lib.luaL_loadstring(state,source.encode())
if not status: status=lib.lua_pcall(state,0,1,0)
length=ctypes.c_size_t();pointer=lib.lua_tolstring(state,-1,ctypes.byref(length))
text=ctypes.string_at(pointer,length.value).decode() if pointer else 'Lua 无返回文本'
lib.lua_close(state)
if status: sys.stderr.write(text);sys.exit(1)
sys.stdout.write(text+'\n')
"#;
    let mut command = if let Some(runtime) = runtime {
        let mut command = Command::new("python3");
        command.arg("-c").arg(python).arg(runtime);
        command
    } else {
        let mut command = Command::new("luajit");
        command.arg("-");
        command
    };
    let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().expect("外部 oracle 需要游戏 Lua.framework 或本机 LuaJIT");
    child.stdin.take().unwrap().write_all(script.as_bytes()).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap()
}

#[test]
#[ignore = "需要本机 LuaJIT, 不经过 Rust 期望公式而直接执行 Steamodded 函数"]
fn editions_match_actual_steamodded_lua_functions_with_vouchers_and_bans() {
    let misc = include_str!("../../game/functions/misc_functions.lua");
    let objects = include_str!("../../mods/Steamodded/src/game_object.lua");
    let overrides = include_str!("../../mods/Steamodded/src/overrides.lua");
    let mut script = String::from("G={SETTINGS={},GAME={},P_CENTERS={}}; SMODS={optional_features={},Edition={}}\nfunction SMODS.Edition:take_ownership(key,obj) G.P_CENTERS['e_'..key]=obj end\n");
    script.push_str(lua_slice(misc, "function pseudohash(str)", "function tprint("));
    script.push_str(lua_slice(objects, "SMODS.Edition:take_ownership('foil'", "    SMODS.Keybinds = {}"));
    script.push_str(lua_slice(overrides, "function poll_edition(", "-- local cge ="));
    script.push_str(r#"
function get_current_pool()
  local pool={}
  for _, key in ipairs({'e_foil','e_holo','e_polychrome','e_negative'}) do
    pool[#pool+1] = G.GAME.banned_keys[key] and 'UNAVAILABLE' or key
  end
  return pool
end
for n=0,80 do for _, rate in ipairs({1,2,4}) do for _, modifier in ipairs({1,2}) do
for _, no_neg in ipairs({false,true}) do for _, banned in ipairs({'none','e_foil'}) do
  local seed='ORACLE'..n
  G.GAME={pseudorandom={seed=seed,hashed_seed=pseudohash(seed)},edition_rate=rate,banned_keys={[banned]=true}}
  local edition=poll_edition('edi',modifier,no_neg)
  print(n,rate,modifier,tostring(no_neg),banned,edition or 'none',string.format('%.17g',math.random()))
end end end end end
"#);
    let output = luajit_eval(&script);
    for row in output.lines() {
        let fields: Vec<&str> = row.split('\t').collect();
        let mut run = RunState::new(&format!("ORACLE{}", fields[0]), 1);
        run.edition_rate = fields[1].parse().unwrap();
        if fields[4] != "none" { run.banned_keys.insert(fields[4].to_owned()); }
        let got = poll_edition(&mut run, "edi", fields[2].parse().unwrap(), fields[3] != "true");
        let key = match got { Some(Edition::Foil) => "e_foil", Some(Edition::Holo) => "e_holo", Some(Edition::Polychrome) => "e_polychrome", Some(Edition::Negative) => "e_negative", None => "none" };
        assert_eq!(key, fields[5], "Lua 行 {row}");
        let random: f64 = fields[6].parse().unwrap();
        assert_eq!(run.rng.random(), random, "Lua 全局 RNG 行 {row}");
    }
    assert_eq!(output.lines().count(), 1944);
}

#[test]
#[ignore = "需要本机 LuaJIT, 逐层检查随机数浮点数与全局状态"]
fn keyed_rng_matches_live_luajit_across_generated_seeds() {
    let misc = include_str!("../../game/functions/misc_functions.lua");
    let mut script = String::from("G={SETTINGS={},GAME={}}\n");
    script.push_str(lua_slice(misc, "function pseudohash(str)", "function tprint("));
    script.push_str(r#"
for n=0,80 do
  local seed='ORACLE'..n
  G.GAME={pseudorandom={seed=seed,hashed_seed=pseudohash(seed)}}
  local ps=pseudoseed('edi'); math.randomseed(ps)
  print(n,string.format('%.17g',G.GAME.pseudorandom.hashed_seed),string.format('%.17g',ps),string.format('%.17g',math.random()),string.format('%.17g',math.random()))
end
"#);
    for row in luajit_eval(&script).lines() {
        let f: Vec<&str> = row.split('\t').collect();
        let mut rng = balatro_engine::rng::Rng::new(&format!("ORACLE{}", f[0]));
        assert_eq!(rng.hashed_seed(), f[1].parse::<f64>().unwrap(), "hash {row}");
        let ps = rng.pseudoseed("edi");
        assert_eq!(ps, f[2].parse::<f64>().unwrap(), "pseudoseed {row}");
        rng.seed_prng(ps);
        assert_eq!(rng.random(), f[3].parse::<f64>().unwrap(), "random 1 {row}");
        assert_eq!(rng.random(), f[4].parse::<f64>().unwrap(), "random 2 {row}");
    }
}

#[test]
#[ignore = "需要本机 LuaJIT, 直接执行 Steamodded 蜡封函数"]
fn standard_seals_match_actual_steamodded_lua_function_and_banned_seals() {
    // 必须使用完整 Lovely 补丁树, 原版初始化表不是 modded 游戏的候选池基准.
    let patched_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.tmp/engine-audit/modded-tree");
    let game = std::fs::read_to_string(patched_root.join("game.lua")).expect("外部 oracle 需要最新完整补丁树 game.lua");
    let events = std::fs::read_to_string(patched_root.join("functions/common_events.lua")).expect("外部 oracle 需要最新完整补丁树 common_events.lua");
    let misc = include_str!("../../game/functions/misc_functions.lua");
    let utils = include_str!("../../mods/Steamodded/src/utils.lua");
    let objects = include_str!("../../mods/Steamodded/src/game_object.lua");
    let mut script = String::from(r#"
G={SETTINGS={},GAME={},P_CENTER_POOLS={Seal={}},shared_seals={},C={}}
SMODS={optional_features={},GameObject={},ObjectTypes={}}
function SMODS.GameObject:extend(obj) obj.super=self;obj.__index=obj;return setmetatable(obj,{__index=self}) end
function SMODS.GameObject.check_duplicate_register() return false end
function SMODS.add_prefixes() end
function SMODS._save_d_u() end
function SMODS.create_sprite() return {} end
function SMODS.get_atlas() end
function HEX() return {} end
function find_joker() return {} end
function EMPTY(pool) for k in pairs(pool) do pool[k]=nil end;return pool end
local self=G
"#);
    script.push_str(lua_slice(&game, "self.P_SEALS = {", "    self.P_TAGS = {"));
    script.push_str("for k,v in pairs(G.P_SEALS) do v.key=k;table.insert(G.P_CENTER_POOLS.Seal,v);G.shared_seals[k]={sprite_pos={}};G.C[k:upper()]={} end\n");
    script.push_str(game.lines().find(|line| line.contains("table.sort(self.P_CENTER_POOLS[\"Seal\"]")).unwrap());
    script.push('\n');
    script.push_str(lua_slice(misc, "function pseudohash(str)", "function tprint("));
    script.push_str(lua_slice(utils, "function SMODS.insert_pool(", "function SMODS.remove_pool("));
    script.push_str(lua_slice(objects, "function SMODS.GameObject:__internal_register(", "function SMODS.GameObject:process_loc_text("));
    script.push_str(lua_slice(objects, "function SMODS.GameObject:take_ownership(", "function SMODS.injectObjects("));
    script.push_str(lua_slice(objects, "SMODS.Seals = {}", "    -------------------------------------------------------------------------------------------------\n    ----- API CODE GameObject.Suit"));
    script.push_str("for _,key in ipairs(SMODS.Seal.obj_buffer) do SMODS.Seals[key]:inject() end\nlocal order={} for _,seal in ipairs(G.P_CENTER_POOLS.Seal) do order[#order+1]=seal.key end print('pool',table.concat(order,','))\n");
    script.push_str(lua_slice(utils, "function SMODS.add_to_pool(", "function SMODS.hide_from_collection("));
    script.push_str(lua_slice(utils, "function SMODS.find_card(", "function SMODS.create_card("));
    script.push_str(lua_slice(utils, "function SMODS.showman(", "function SMODS.four_fingers("));
    script.push_str(lua_slice(&events, "function get_current_pool(", "-- Function overridden by SMODS in src/overrides.lua"));
    script.push_str(lua_slice(utils, "function SMODS.poll_seal(", "function SMODS.get_blind_amount("));
    script.push_str(r#"
for n=0,100 do for _,banned in ipairs({'none','Red'}) do
  local seed='SEAL'..n
  G.ARGS={TEMP_POOL={}}
  G.GAME={pseudorandom={seed=seed,hashed_seed=pseudohash(seed)},round_resets={ante=1},banned_keys={[banned]=true},used_jokers={},pool_flags={}}
  for i=1,3 do print(n,banned,i,SMODS.poll_seal({mod=10}) or 'none') end
end end
"#);
    let output = luajit_eval(&script);
    let mut rows = output.lines();
    assert_eq!(rows.next(), Some("pool\tRed,Blue,Gold,Purple"));
    for n in 0..=100 {
        for banned in ["none", "Red"] {
            let mut run = RunState::new(&format!("SEAL{n}"), 1);
            if banned != "none" { run.banned_keys.insert(banned.to_owned()); }
            for card in open_pack(&mut run, "p_standard_normal_1") {
                let row = rows.next().unwrap();
                let fields: Vec<&str> = row.split('\t').collect();
                let got = card.seal.map(|seal| seal.key()).unwrap_or("none");
                assert_eq!(got, fields[3].to_ascii_lowercase(), "Lua 行 {row}");
            }
        }
    }
    assert!(rows.next().is_none());
}

use balatro_engine::cards::Edition;
use balatro_engine::data::catalog::Catalog;
use balatro_engine::jokers::Joker;
use balatro_engine::run::{RunState, open_pack};
use balatro_engine::run::shop::{create_joker, create_card_inner, pick_joker_of_rarity, poll_edition, roll_todo};
use balatro_engine::scoring::{HandTable, PokerHand};

#[test]
fn generated_stock_and_all_pack_choices_have_birth_order_ids() {
    let mut run = RunState::new("BIRTHORDER", 1);
    let first = create_joker(&mut run, "test");
    let second = create_joker(&mut run, "test");
    assert!(first.sort_id > 0 && first.sort_id < second.sort_id);
    let mut last = second.sort_id;
    for pack in ["p_standard_mega_1", "p_buffoon_mega_1", "p_celestial_mega_1", "p_arcana_mega_1", "p_spectral_mega_1"] {
        for card in open_pack(&mut run, pack) {
            assert!(card.sort_id > last, "未选包牌同样出生, 且每实体只分配一次");
            last = card.sort_id;
        }
    }
    let shop = balatro_engine::run::shop::Shop::restock(&mut run);
    let mut ids: Vec<u32> = shop.jokers.iter().chain(shop.packs.iter()).chain(shop.vouchers.iter()).map(|card| card.sort_id).collect();
    assert!(ids.iter().all(|id| *id > last));
    ids.sort_unstable();
    assert!(ids.windows(2).all(|pair| pair[1] == pair[0] + 1));
}

#[test]
fn rarity_tags_create_free_stickered_jokers_and_consume_only_one_tag() {
    let mut run = RunState::new("RARITYTAG", 8);
    run.tags = vec!["tag_uncommon".to_owned(), "tag_uncommon".to_owned()];
    let card = balatro_engine::run::create_card_for_shop(&mut run, &Default::default());
    assert_eq!(card.cost, 0.0);
    assert_eq!(run.tags, vec!["tag_uncommon".to_owned()]);
    let mut expected_rng = balatro_engine::rng::Rng::new("RARITYTAG");
    expected_rng.pseudorandom("etperpoll1");
    assert_eq!(run.rng.pseudoseed("etperpoll1"), expected_rng.pseudoseed("etperpoll1"));
}

#[test]
fn edition_tags_apply_to_normal_jokers_and_only_consume_the_first_tag() {
    let rates = balatro_engine::run::ShopRates { joker: 1.0, tarot: 0.0, planet: 0.0, playing_card: 0.0, spectral: 0.0 };
    let mut run = RunState::new("EDITIONTAG", 1);
    run.tags = vec!["tag_foil".to_owned(), "tag_negative".to_owned()];
    let card = balatro_engine::run::create_card_for_shop(&mut run, &rates);
    assert_eq!(card.edition, Some(Edition::Foil));
    assert_eq!(card.cost, 0.0);
    assert_eq!(run.tags, vec!["tag_negative".to_owned()]);
}

#[test]
fn standard_pack_rng_finishes_with_the_front_draw_after_edition_seal_and_soul_gate() {
    let mut run = RunState::new("STANDARD", 1);
    let mut expected = run.rng.clone();
    for _ in 0..3 {
        expected.pseudorandom("standard_edition1");
        if expected.pseudorandom("stdseal1") > 0.8 { expected.pseudorandom("stdsealtype1"); }
        let enhanced = expected.pseudorandom("stdset1") > 0.6;
        expected.pseudorandom(if enhanced { "soul_smods_Enhanced1" } else { "soul_smods_Base1" });
        if enhanced { expected.pseudorandom("Enhancedsta1"); }
        expected.pseudorandom("frontsta1");
    }
    let _ = open_pack(&mut run, "p_standard_normal_1");
    assert_eq!(run.rng.peek_prng(), expected.peek_prng());
}

#[test]
fn creation_enhancement_gates_see_the_hand_and_discard_pile() {
    let mut run = RunState::new("ENHANCEMENT", 1);
    run.start_run();
    let mut held = run.deck.pop().unwrap();
    held.enhancement = Some(balatro_engine::cards::Enhancement::Steel);
    run.hand.push(held);
    let mut discarded = run.deck.pop().unwrap();
    discarded.enhancement = Some(balatro_engine::cards::Enhancement::Stone);
    run.discard_pile.push(discarded);
    let creation = balatro_engine::run::shop::creation_from(&run);
    assert!(creation.enhanced.contains("m_steel"));
    assert!(creation.enhanced.contains("m_stone"));
}

#[test]
fn an_empty_booster_pool_uses_the_game_fallback_instead_of_panicking() {
    let mut run = RunState::new("BANNEDBOOSTERS", 1);
    run.banned_keys.extend(Catalog::get().pool("Booster").iter().map(|proto| proto.id.clone()));
    assert_eq!(balatro_engine::run::get_pack(&mut run, "shop_pack"), "p_buffoon_normal_1");
}

#[test]
fn hallucination_rolls_once_per_live_instance_and_blueprint_with_capacity_buffer() {
    for seed in 0..20 {
        let mut run = RunState::new(&format!("HAL{seed}"), 1);
        let mut inactive = Joker::new("j_hallucination").unwrap();
        inactive.debuffed = true;
        inactive.extra = 100.0;
        run.jokers = vec![inactive, Joker::new("j_blueprint").unwrap(), Joker::new("j_hallucination").unwrap(), Joker::new("j_hallucination").unwrap()];
        let mut expected = run.rng.clone();
        let mut reserved = 0;
        for _ in 0..3 {
            if reserved < run.consumable_capacity() && expected.pseudorandom("halu1") < 0.5 { reserved += 1; }
        }
        open_pack(&mut run, "p_buffoon_normal_1");
        assert_eq!(run.consumables.len(), reserved, "种子 HAL{seed}");
        assert_eq!(run.rng.pseudoseed("halu1"), expected.pseudoseed("halu1"), "种子 HAL{seed}");
    }
}

#[test]
fn pseudoseed_seed_uses_the_unkeyed_global_stream() {
    let mut rng = balatro_engine::rng::Rng::new("UNKEYED");
    rng.pseudorandom("edi");
    let mut expected = rng.clone();
    assert_eq!(rng.pseudoseed("seed"), expected.random());
    assert_eq!(rng.random(), expected.random());
}

#[test]
fn enhanced_cards_keep_banned_prototypes_as_unavailable_slots() {
    for seed in 0..50 {
        let mut run = RunState::new(&format!("ENHBAN{seed}"), 1);
        run.banned_keys.extend(Catalog::get().pool("Enhanced").iter().filter(|p| p.id != "m_bonus").map(|p| p.id.clone()));
        for card in open_pack(&mut run, "p_standard_mega_1") {
            assert!(card.enhancement.is_none() || card.enhancement == Some(balatro_engine::cards::Enhancement::Bonus));
        }
        run.used_vouchers.insert("v_illusion".to_owned());
        let rates = balatro_engine::run::ShopRates { joker: 0.0, tarot: 0.0, planet: 0.0, playing_card: 1.0, spectral: 0.0 };
        for _ in 0..10 {
            let card = balatro_engine::run::create_card_for_shop(&mut run, &rates);
            assert!(card.enhancement.is_none() || card.enhancement == Some(balatro_engine::cards::Enhancement::Bonus));
        }
    }
}

#[test]
fn astronomer_prices_generated_planets_and_celestial_packs_at_zero() {
    let rates = balatro_engine::run::ShopRates { joker: 0.0, tarot: 0.0, planet: 1.0, playing_card: 0.0, spectral: 0.0 };
    let mut celestial = 0;
    for seed in 0..40 {
        let mut run = RunState::new(&format!("ASTRO{seed}"), 1);
        run.jokers.push(Joker::new("j_astronomer").unwrap());
        let card = balatro_engine::run::create_card_for_shop(&mut run, &rates);
        assert_eq!(card.cost, 0.0);
        let shop = balatro_engine::run::shop::Shop::restock(&mut run);
        for card in shop.packs {
            if card.key.starts_with("p_celestial") { celestial += 1; assert_eq!(card.cost, 0.0); }
        }
    }
    assert!(celestial > 0);
}

#[test]
fn voucher_tags_use_their_independent_key_without_ante_suffix() {
    for ante in [1, 3] {
        for seed in 0..30 {
            let mut run = RunState::new(&format!("VTAG{seed}"), 1);
            run.ante = ante;
            let (pool, _) = balatro_engine::run::voucher_pool(&run);
            let mut expected_rng = run.rng.clone();
            let expected = balatro_engine::run::pick_or_resample(&mut expected_rng, &pool, "Voucher_fromtag");
            assert_eq!(run.next_voucher_key_from_tag(), expected);
            assert_eq!(run.rng.pseudoseed("Voucher_fromtag"), expected_rng.pseudoseed("Voucher_fromtag"));
        }
    }
}

#[test]
#[ignore = "需要实际游戏 Lua 框架, 核验 Tarot_Planet 的同 order 排序"]
fn combined_consumable_pool_has_correct_membership_but_ambiguous_order_ties() {
    let game = include_str!("../../game/game.lua");
    let mut script = String::from("local self={}\n");
    script.push_str(lua_slice(game, "self.P_CENTERS = {", "    self.P_CENTER_POOLS = {"));
    script.push_str("self.P_CENTER_POOLS={Tarot_Planet={}}\nfor k,v in pairs(self.P_CENTERS) do v.key=k;if not v.wip and (v.set=='Tarot' or v.set=='Planet') then table.insert(self.P_CENTER_POOLS.Tarot_Planet,v) end end\n");
    let sort = game.lines().find(|line| line.contains("table.sort(self.P_CENTER_POOLS[\"Tarot_Planet\"]")).unwrap();
    script.push_str(sort);
    script.push_str("\nfor _,v in ipairs(self.P_CENTER_POOLS.Tarot_Planet) do print(v.key) end\n");
    let actual = luajit_eval(&script);
    let combined = Catalog::get().tarot_planet();
    let mut expected: Vec<&str> = combined.iter().map(|p| p.id.as_str()).collect();
    let mut actual_keys = actual.lines().collect::<Vec<_>>();
    expected.sort();
    actual_keys.sort();
    assert_eq!(expected, actual_keys);
    let orders: Vec<f64> = actual.lines().map(|key| Catalog::get().record(key).unwrap().order).collect();
    assert!(orders.windows(2).all(|pair| pair[0] <= pair[1]));
    assert!(orders.windows(2).any(|pair| pair[0] == pair[1]), "组合池确实存在跨类别同 order, Lua 不保证 tie 次序");
}

#[test]
#[should_panic(expected = "Tarot_Planet")]
fn combined_pool_is_explicitly_unsupported_instead_of_silently_omitting_planets() {
    let mut run = RunState::new("COMBINED", 1);
    create_card_inner(&mut run, "Tarot_Planet", "test", false, None);
}

#[test]
fn stickers_respect_every_vanilla_compatibility_flag_in_shop_and_packs() {
    let source = include_str!("../../game/game.lua");
    let denied = |key: &str, flag: &str| source.lines().find(|line| line.trim_start().starts_with(&format!("{key}=")))
        .is_some_and(|line| line.contains(&format!("{flag} = false")));
    let mut checked = 0;
    for seed in 0..80 {
        let mut run = RunState::new(&format!("GEN{seed}"), 8);
        for _ in 0..20 {
            let card = create_joker(&mut run, "sho");
            assert!(!card.eternal || !denied(&card.key, "eternal_compat"), "{} 错误永恒", card.key);
            assert!(!card.perishable || !denied(&card.key, "perishable_compat"), "{} 错误易腐", card.key);
            assert!(!(card.eternal && card.perishable));
            checked += 1;
        }
        for card in open_pack(&mut run, "p_buffoon_mega_1") {
            assert!(!card.eternal || !denied(&card.key, "eternal_compat"), "包内 {} 错误永恒", card.key);
            assert!(!card.perishable || !denied(&card.key, "perishable_compat"), "包内 {} 错误易腐", card.key);
            checked += 1;
        }
    }
    assert_eq!(checked, 1920);
}

#[test]
fn banned_jokers_and_debuffed_showman_do_not_bypass_pool_culling() {
    for seed in 0..30 {
        let mut run = RunState::new(&format!("BAN{seed}"), 1);
        for proto in Catalog::get().jokers_by_rarity(1) {
            if proto.id != "j_joker" { run.banned_keys.insert(proto.id.clone()); }
        }
        assert_eq!(pick_joker_of_rarity(&mut run, 1, "sho", false).as_deref(), Some("j_joker"));
    }
    let mut run = RunState::new("SHOWMAN", 1);
    run.used_jokers.extend(Catalog::get().jokers_by_rarity(1).iter().map(|p| p.id.clone()));
    let mut showman = Joker::new("j_ring_master").unwrap();
    showman.debuffed = true;
    run.jokers.push(showman);
    assert_eq!(pick_joker_of_rarity(&mut run, 1, "sho", false).as_deref(), Some("j_joker"));
}

#[test]
fn edition_vouchers_scale_non_negative_thresholds_without_extra_rng_calls() {
    for seed in 0..500 {
        let mut run = RunState::new(&format!("EDI{seed}"), 1);
        run.edition_rate = 4.0;
        let mut expected_rng = run.rng.clone();
        let poll = expected_rng.pseudorandom("edi");
        let expected = if poll > 0.997 { Some(Edition::Negative) }
            else if poll > 1.0 - 0.006 * 4.0 { Some(Edition::Polychrome) }
            else if poll > 1.0 - 0.02 * 4.0 { Some(Edition::Holo) }
            else if poll > 1.0 - 0.04 * 4.0 { Some(Edition::Foil) } else { None };
        assert_eq!(poll_edition(&mut run, "edi", 1.0, true), expected);
        assert_eq!(run.rng.random(), expected_rng.random());
    }
}

#[test]
fn todo_resamples_the_original_visible_pool_and_advances_each_failed_draw() {
    let table = HandTable::default();
    let pool: Vec<PokerHand> = PokerHand::BY_PRIORITY.into_iter().filter(|hand| table.get(*hand).visible).collect();
    for seed in 0..30 {
        let mut run = RunState::new(&format!("TODO{seed}"), 1);
        let old = Some(PokerHand::HighCard);
        let mut expected_rng = run.rng.clone();
        let expected = loop {
            let picked = *expected_rng.pick(&pool, "to_do");
            if Some(picked) != old { break picked; }
        };
        assert_eq!(roll_todo(&mut run.rng, &table, old), expected);
        assert_eq!(run.rng.pseudoseed("to_do"), expected_rng.pseudoseed("to_do"));
    }
}

#[test]
fn forced_consumables_are_registered_as_used_without_drawing_a_pool() {
    let mut run = RunState::new("FORCED", 1);
    let mut expected_rng = run.rng.clone();
    assert_eq!(create_card_inner(&mut run, "Planet", "pl1", true, Some("c_pluto")), "c_pluto");
    assert!(run.used_jokers.contains("c_pluto"));
    assert_eq!(run.rng.random(), expected_rng.random());
}

#[test]
fn tags_respect_minimum_ante_and_discovered_prerequisites_without_shrinking_pool() {
    let mut run = RunState::new("TAGS", 1);
    let (pool, _) = balatro_engine::run::tag_pool(&run);
    assert_eq!(pool.len(), Catalog::get().pool("Tag").len());
    assert!(!pool.iter().any(|key| matches!(key.as_str(), "tag_negative" | "tag_meteor" | "tag_rare" | "tag_foil")));
    run.ante = 2;
    run.uda.insert("j_blueprint".to_owned(), "ud".to_owned());
    let (pool, _) = balatro_engine::run::tag_pool(&run);
    assert!(pool.contains(&"tag_meteor".to_owned()));
    assert!(pool.contains(&"tag_rare".to_owned()));
    assert!(!pool.contains(&"tag_foil".to_owned()));
}

#[test]
fn spectral_soul_hit_still_draws_the_second_black_hole_roll() {
    let seed = (0..5000).map(|n| format!("SOUL{n}")).find(|seed| {
        let mut rng = balatro_engine::rng::Rng::new(seed);
        rng.pseudorandom("soul_Spectral1") > 0.997
    }).unwrap();
    let mut run = RunState::new(&seed, 1);
    let mut expected_rng = run.rng.clone();
    expected_rng.pseudorandom("soul_Spectral1");
    expected_rng.pseudorandom("soul_Spectral1");
    let _ = create_card_inner(&mut run, "Spectral", "spe", true, None);
    assert_eq!(run.rng.pseudoseed("soul_Spectral1"), expected_rng.pseudoseed("soul_Spectral1"));
}

#[test]
fn banning_soul_skips_the_whole_soul_gate_including_black_hole() {
    let mut run = RunState::new("BANSOUL", 1);
    run.banned_keys.insert("c_soul".to_owned());
    let mut expected_rng = run.rng.clone();
    let _ = create_card_inner(&mut run, "Planet", "pl1", true, None);
    assert_eq!(run.rng.pseudoseed("soul_Planet1"), expected_rng.pseudoseed("soul_Planet1"));
}

#[test]
fn smods_soul_poll_is_consumed_for_every_soulable_type_even_without_modded_souls() {
    for kind in ["Tarot", "Planet", "Spectral", "Joker"] {
        let mut run = RunState::new("SMODSSOUL", 1);
        let mut expected_rng = run.rng.clone();
        let key = format!("soul_smods_{kind}1");
        expected_rng.pseudorandom(&key);
        let _ = create_card_inner(&mut run, kind, "test", true, None);
        assert_eq!(run.rng.pseudoseed(&key), expected_rng.pseudoseed(&key));
    }
}
