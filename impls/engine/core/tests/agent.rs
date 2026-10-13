//! agent 层: 局面摘要, 动态值, 提示词.
//!
//! 这一层的价值全在"信息有没有给到", 而它的失效方式是**静默**的: 少一项不会报错, 只是 agent
//! 悄悄按缺了信息的前提决策. 所以这里的断言挑的都是"少了就会让 agent 做错决定"的点:
//! 牌的中文名与效果是否真取到, 目标分在选盲注阶段能不能提前看到, 跳过奖励有没有报,
//! 会变的值有没有落到具体那张小丑上.
//!
//! 不测措辞. 文案改了不该让测试红, 所以断言都落在"含不含某个数 / 某张牌的名字"上.

mod common;

use balatro_engine::agent::{dynamics, prompt, summary};
use balatro_engine::run::RunState;
use balatro_engine::scoring::EvalEnv;

/// 停在**选盲注**阶段的局. `start()` 会顺手把第一个盲注也选了, 而这一层有好几项信息
/// (预告的目标分, 跳过奖励) 只有停在选盲注时才看得到.
fn at_blind_select() -> RunState {
    let mut run = common::aleeb_run();
    run.start_run();
    run
}

/// 已经进到出牌阶段的局.
fn in_round() -> RunState {
    let mut run = at_blind_select();
    run.select_blind().expect("能选盲注");
    run
}

#[test]
fn opening_summary_shows_the_blind_target_and_skip_reward() {
    // 选盲注阶段最要紧的两个数: 这一局要打多少分, 以及跳过能拿到什么.
    // 目标分要在**还没 select** 时就能看到 —— 看得到才能决定跳不跳.
    let run = at_blind_select();
    let text = summary::render(&run, &summary::Extras::default());
    assert!(text.contains("选择盲注"), "要看得出阶段: {text}");
    assert!(text.contains("小盲注"), "要报小盲注: {text}");
    assert!(text.contains("目标"), "要有目标分: {text}");
    assert!(text.contains("跳过奖励"), "要报跳过能拿到什么: {text}");

    // 预告的目标分必须与**真的选下去之后**拿到的那个一致.
    //
    // 这条是这一段最容易错的地方: 盲注对象要等 `select` 才造出来, 所以预告那一份是照着同样的
    // 规则另算的. 两份算法一旦分叉, agent 会按一个错的分数决定跳不跳 —— 而且不报错, 只是算错.
    let announced: f64 = text
        .lines()
        .find(|line| line.contains("小盲注"))
        .and_then(|line| line.split("目标 ").nth(1))
        .and_then(|rest| rest.split(|ch: char| !ch.is_ascii_digit() && ch != '.').next())
        .and_then(|digits| digits.parse().ok())
        .unwrap_or_else(|| panic!("小盲注那一行没有目标分: {text}"));

    let mut selected = at_blind_select();
    selected.select_blind().expect("能选盲注");
    let real = selected.blind.as_ref().expect("选完就有盲注").chips;
    assert_eq!(announced, real, "预告的目标分与真正建出来的不一致");
}

#[test]
fn hand_and_jokers_carry_chinese_names_and_effects() {
    // 每张牌都要有中文名与效果文本. 只写内部键名 (`j_odd_todd`) 时 agent 不知道它干什么,
    // 而卡面效果又是它做决定的主要依据.
    let mut run = in_round();

    let text = summary::render(&run, &summary::Extras::default());
    assert!(text.contains("手牌"), "要有手牌: {text}");
    // 手牌要带花色点数的中文, 而不是 `C_T` 这种.
    assert!(text.contains("梅花") || text.contains("黑桃") || text.contains("红桃"));
    // 每张手牌都要带下标, 因为出牌与弃牌都用下标.
    assert!(text.contains("[0]"), "手牌要有下标: {text}");

    // 塞一张效果文字明确的牌, 摘要里要出现它的中文名与效果, 而不是键名.
    use balatro_engine::jokers::Joker;
    run.jokers.push(Joker::new("j_odd_todd").expect("有这张"));
    let text = summary::render(&run, &summary::Extras::default());
    assert!(text.contains("奇数托德"), "要显示中文名: {text}");
    assert!(text.contains("筹码"), "要显示效果: {text}");
    assert!(!text.contains("j_odd_todd"), "不该露出内部键名: {text}");
}

#[test]
fn dynamic_values_are_reported_against_the_joker_that_uses_them() {
    // 会随局面变的值是这个引擎最容易"给了名字但没给值"的地方:
    // 手册里这些是占位符, 实际值只有引擎知道, 报不出来 agent 就只能猜.
    use balatro_engine::jokers::Joker;
    let mut run = in_round();

    // 没有这些牌时不该冒出这些行 —— 否则 agent 会以为手上有一张并不存在的牌.
    let before = dynamics::render(&run);
    for absent in ["古老小丑", "偶像", "邮件回扣", "城堡", "盲注公牛"] {
        assert!(!before.contains(absent), "没这张牌就不该报它: {absent} in {before}");
    }
    // 摸牌堆统计一直要有: 算同花顺子的命中率靠它.
    assert!(before.contains("摸牌堆"), "要有摸牌堆统计: {before}");
    assert!(before.contains("点数"), "点数分布是凑顺子的依据: {before}");

    // 塞进认花色点数的那几张, 每张都要报出它认的目标; 还没掷的时候要说明还没掷.
    for key in ["j_ancient", "j_idol", "j_mail", "j_castle"] {
        run.jokers.push(Joker::new(key).expect("有这张"));
    }
    let after = dynamics::render(&run);
    for expected in ["古老小丑认的花色", "偶像认的牌", "邮件回扣认的点数", "城堡认的花色"] {
        assert!(after.contains(expected), "缺了这一项: {expected}\n{after}");
    }
    // 值本身要落地: 要么给出中文花色点数, 要么明说这一回合还没掷, 不能只有冒号.
    assert!(
        after.contains("还没掷") || after.contains("梅花") || after.contains("黑桃"),
        "认的目标要有真值或明说没有: {after}"
    );
}

#[test]
fn joker_growth_is_reported_only_where_it_exists() {
    // "已成长到 X" 这类值报错是双输: 报在没有成长的小丑上会让 agent 以为它很强,
    // 报漏了又会让 agent 低估它. 所以既要在有值的牌上报出来, 也要在别的牌上不出现.
    use balatro_engine::jokers::Joker;
    let mut run = in_round();

    let mut plain = Joker::new("j_joker").expect("有这张");
    plain.mult = 0.0;
    run.jokers.push(plain);
    let text = summary::render(&run, &summary::Extras::default());
    assert!(
        !text.contains("已成长到"),
        "普通小丑不该被报成有成长值: {text}"
    );

    // 卡尼奥 (传奇) 才是那张按成长值给倍率的牌, 它的当前值必须出现.
    let caino = Joker::new("j_caino").expect("有这张");
    run.jokers.push(caino);
    let text = summary::render(&run, &summary::Extras::default());
    let caino_line = text
        .lines()
        .find(|line| line.contains("卡尼奥"))
        .unwrap_or_else(|| panic!("摘要里要有卡尼奥这一行: {text}"));
    assert!(
        caino_line.contains("已成长到"),
        "卡尼奥要报当前成长值: {caino_line}"
    );

    // 会长的倍率也要报出来: 给一张有 +倍率的小丑, 那个数必须出现在它自己那一行.
    let mut grown = Joker::new("j_joker").expect("有这张");
    grown.mult = 7.0;
    run.jokers.push(grown);
    let text = summary::render(&run, &summary::Extras::default());
    assert!(text.contains("+7 倍率"), "成长出来的倍率要报: {text}");
}

#[test]
fn shop_summary_lists_prices_and_remaining_money() {
    // 商店里要能直接看到"买得起什么": 价格, 现有金钱, 以及花完会不会跌破利息档.
    let mut run = in_round();
    run.chips = 999_999.0;
    run.end_round();
    run.cash_out().expect("能领结算");

    let text = summary::render(&run, &summary::Extras::default());
    assert!(text.contains("商店"), "要看得出在商店: {text}");
    assert!(text.contains("$"), "要有价格: {text}");
    if run.shop.as_ref().is_some_and(|shop| !shop.jokers.is_empty()) {
        assert!(text.contains("商店:"), "货架上有牌就要列出来: {text}");
    }
    // 容量与刷新价都在动态值那一段里 —— 买之前要看.
    let dyn_text = dynamics::render(&run);
    assert!(dyn_text.contains("小丑位"), "要报容量: {dyn_text}");
}

#[test]
fn rejections_explain_what_is_allowed_now() {
    // agent 最常撞的就是阶段不对. 光说"阶段不符"它没法继续, 得告诉它现在能做什么.
    let mut run = at_blind_select();
    // 选盲注阶段不能出牌.
    let error = run
        .play(&[0, 1], &EvalEnv::default(), balatro_engine::scoring::BackEffect::Plain)
        .expect_err("选盲注阶段不能出牌");
    let text = balatro_engine::agent::action::explain(&error, &run);
    assert!(text.contains("select"), "要指出现在能做 select: {text}");
    assert!(!text.contains("NotInPhase"), "不要暴露内部变体名: {text}");
}

#[test]
fn system_prompt_states_the_rules_an_agent_gets_wrong() {
    // 提示词里必须有的几条, 都是"少了就会系统性打错"的:
    // 筹码不是钱, 出牌次数不是手牌数, 乘倍率不能和加倍率乱合并, 跳过盲注有代价.
    let text = prompt::system(false, None);
    for (needle, why) in [
        ("筹码", "筹码与倍率的关系是算分的基础"),
        ("钱", "要说清筹码不是钱"),
        ("出牌次数", "这个数最容易被当成手牌数"),
        ("手牌上限", "它与出牌次数不同, 要并列说明"),
        ("乘倍率", "乘倍率不能和加倍率无序合并"),
        ("跳过", "跳过盲注的代价 (不进商店) 要写"),
        ("底注 8", "通关条件要写"),
    ] {
        assert!(text.contains(needle), "提示词缺了 {needle} (因为{why})");
    }
    // 手册与查询工具要提到, 否则 agent 会凭记忆猜.
    assert!(text.contains("lookup") && text.contains("docs"), "要告诉它怎么查手册");
    assert!(text.contains("dynamics"), "要要求它会变的值一律现查");
}

#[test]
fn system_prompt_appends_settings_and_player_strategy() {
    let endless = prompt::system(true, None);
    let menu = prompt::system(false, None);
    assert!(endless.contains("无尽模式"), "无尽模式要写清: {endless}");
    assert!(!menu.contains("继续无尽模式"), "不玩无尽就不该这么写");
    assert_ne!(endless, menu, "两种走向的提示词应当不同");

    let with_strategy = prompt::system(false, Some("只买成长型小丑"));
    assert!(with_strategy.contains("只买成长型小丑"), "玩家策略要拼进去");
    assert!(with_strategy.contains("规则要点"), "拼了策略也仍要保留规则要点");
    // 空策略不该拼出一段空标题.
    assert!(!prompt::system(false, Some("   ")).contains("玩家指定的策略"));
}
