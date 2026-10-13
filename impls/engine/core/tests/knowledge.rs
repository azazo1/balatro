//! 面向 agent 的知识层: 卡牌查询与手册.
//!
//! 这里的断言刻意挑**能抓住数据接错**的点, 而不是把 catalog.json 抄一遍:
//! 名称与效果的对应关系一旦错位 (例如按错字段读, 或索引串了行), 查出来的名字和效果
//! 就会张冠李戴, 而这种错不会报错, 只会让 agent 按错的信息决策.

use balatro_engine::data::knowledge;

#[test]
fn lookup_by_id_name_and_english_name_agree() {
    let by_id = knowledge::describe("j_odd_todd").expect("有这张");
    let by_zh = knowledge::describe("奇数托德").expect("中文名也认得");
    let by_en = knowledge::describe("Odd Todd").expect("英文名也认得");
    assert_eq!(by_id, by_zh, "三种查法要给同一张");
    assert_eq!(by_id, by_en);
    assert_eq!(by_id.0, "奇数托德");

    // 名称忽略大小写, 也忽略空格与标点.
    assert!(knowledge::describe("odd todd").is_some(), "小写也认得");
}

#[test]
fn describe_reads_the_effect_of_the_right_card() {
    // 效果与名字必须来自同一条记录. 用两张效果差别明显的牌交叉验:
    // 读串了字段的话, 这两张的效果会互换或者都取到同一个.
    let odd = knowledge::describe("j_odd_todd").expect("有这张").1;
    let duo = knowledge::describe("j_duo").expect("有这张").1;
    assert!(odd.contains("筹码"), "奇数托德给的是筹码: {odd}");
    assert!(!odd.contains("倍率"), "奇数托德不给倍率: {odd}");
    assert!(duo.contains("倍率"), "二人组给的是倍率: {duo}");

    // 中文名与英文名要属于同一张牌, 不是各读各的.
    let cards = knowledge::find_cards("j_blueprint");
    let card = cards.first().expect("有这张");
    assert_eq!(card.name_en, "Blueprint");
    assert!(!card.name_zh.is_empty(), "中文名不该是空的");
    assert_eq!(card.category, "Joker");
}

#[test]
fn every_card_has_a_name() {
    // 360 个原型都应当有中英名; 有一个读漏 (例如 effect 是数组而 name 是字符串, 只处理了一种),
    // 摘要里那张牌就会显示成内部键名, agent 只能靠猜.
    for key in ["j_joker", "c_sun", "p_arcana_normal_1", "v_magic_trick", "bl_goad", "m_mult", "tag_double"] {
        let (name, _) = knowledge::describe(key).unwrap_or_else(|| panic!("{key} 查不到"));
        assert!(!name.is_empty(), "{key} 的名字是空的");
        assert_ne!(name, key, "{key} 退回了内部键名, 说明没读到名字");
    }
}

#[test]
fn unknown_key_gives_candidates_not_a_crash() {
    assert!(knowledge::find_cards("j_not_a_real_card").is_empty());
    let hints = knowledge::candidates("j_odd");
    assert!(!hints.is_empty(), "应当给几个相近的候选");
    assert!(hints.iter().any(|hint| hint.contains("j_odd_todd")), "候选里要有它: {hints:?}");
}

#[test]
fn manual_is_complete_and_searchable() {
    let docs = knowledge::manual();
    assert!(docs.len() > 20, "手册文件数不对: {}", docs.len());
    for doc in docs {
        assert!(!doc.body.is_empty(), "{} 是空的", doc.path);
        assert!(!knowledge::manual_title(doc.body).is_empty(), "{} 没有标题", doc.path);
    }
    // 阅读顺序: README 在前, 规则在条目目录之前.
    assert_eq!(docs[0].path, "README.md");
    let position = |needle: &str| docs.iter().position(|doc| doc.path == needle).expect(needle);
    assert!(position("rules/run-flow.md") < position("cards/jokers.md"), "规则应当排在条目目录之前");

    // 路径可以省略 `.md`, 也可以只给文件名.
    for spelling in ["rules/economy.md", "rules/economy", "economy", "docs/game/rules/economy.md"] {
        assert_eq!(
            knowledge::find_manual(spelling).map(|doc| doc.path),
            Some("rules/economy.md"),
            "{spelling} 应当能找到"
        );
    }
    assert!(knowledge::find_manual("rules/not-there").is_none());

    let hits = knowledge::search_manual("利息", None, 100);
    assert!(!hits.is_empty(), "手册里搜不到利息");
    assert!(hits.iter().any(|(path, _, _)| *path == "rules/economy.md"), "利息应当在经济那一节: {hits:?}");
    // 行号要对得上: 拿命中的行号回去查那一行, 必须真的含这个词.
    let (path, line_no, _) = hits[0];
    let body = knowledge::find_manual(path).expect("路径来自手册").body;
    let line = body.lines().nth(line_no - 1).expect("行号在范围内");
    assert!(line.contains("利息"), "行号对不上: {path}:{line_no} -> {line}");

    // 限定路径时只搜那一份.
    let limited = knowledge::search_manual("利息", Some("rules/blinds.md"), 10);
    assert!(limited.iter().all(|(path, _, _)| *path == "rules/blinds.md"));
}
