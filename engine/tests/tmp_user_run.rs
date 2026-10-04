//! 临时: 用 user 手动那局的参数 (RED / WHITE / LG7RIX92) 验证开局发牌.

use balatro_engine::run::RunState;

fn keys(run: &RunState) -> String {
    run.hand
        .iter()
        .map(|c| c.token())
        .collect::<Vec<_>>()
        .join(",")
}

#[test]
fn user_run_opening_deal() {
    let mut run = RunState::new("LG7RIX92", 1);
    run.start();
    println!("开局手牌: {}", keys(&run));
    println!("牌堆剩: {}", run.deck.len());
    assert_eq!(keys(&run), "S_K,D_K,D_Q,S_T,S_9,S_8,C_7,H_3");
    assert_eq!(run.deck.len(), 44);
}
