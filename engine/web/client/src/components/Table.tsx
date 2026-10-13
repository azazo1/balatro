import type { Action, Item, View } from '../lib/types';
import { canSelect, isRed, number, rankSymbol, reorderAction, selectionAction, suitSymbol } from '../lib/game';

export function Card({ card, selected = false, disabled = false, onClick }: { card: Item; selected?: boolean; disabled?: boolean; onClick: () => void }) {
  const symbol = card.hidden ? '?' : card.suit ? suitSymbol[card.suit] : card.category === 'Joker' ? 'J' : card.category === 'Planet' ? 'P' : card.category === 'Tarot' ? 'T' : card.category === 'Spectral' ? 'S' : '+';
  return <button className={`card ${selected ? 'selected' : ''} ${card.hidden ? 'face-down' : ''} ${isRed(card) ? 'red-card' : ''} ${card.suit ? 'playing-card' : 'item-card'}`} disabled={disabled} onClick={onClick} title={`${card.name}\n${card.effect}\n${card.modifiers ?? ''}`} aria-pressed={selected}>
    <div className="card-top"><span>{card.index != null ? `#${card.index}` : ''}</span>{card.cost != null && <b>${number(card.cost)}</b>}</div>
    <div className="card-symbol">{card.rank ? rankSymbol[card.rank] : ''}<span>{symbol}</span></div>
    <strong>{card.name}</strong>{card.modifiers && <small className="card-modifiers">{card.modifiers}</small>}
    {card.current && <small>{card.current}</small>}
  </button>;
}

export function Table({ view, busy, selected, toggle, clear, act, inspect }: {
  view: View; busy: boolean; selected: number[]; toggle: (index: number) => void; clear: () => void;
  act: (action: Action) => void; inspect: (item: Item) => void;
}) {
  const o = view.observation, stats = o.stats;
  const phase = o.phase;
  const locked = busy || o.win_overlay || phase === 'GameOver';
  const playing = phase === 'SelectingHand';
  const rearrange = canSelect(phase) && !locked;
  const sellable = ['SelectingHand', 'Shop', 'BoosterOpened'].includes(phase) && !locked;
  const usable = ['SelectingHand', 'Shop'].includes(phase) && !locked;
  const action = (method: string, params: Record<string, unknown> = {}) => act({ method, params });
  const move = (area: 'hand' | 'jokers' | 'consumables', length: number, index: number, direction: -1 | 1) => {
    const next = reorderAction(area, length, index, direction); if (next) act(next);
  };
  const canPay = (cost: number) => stats.spendable >= cost;
  const target = o.blinds.find(b => b.status === 'Active' || b.status === 'Select')?.target;
  const owned = (cards: Item[], area: 'jokers' | 'consumables', heading: string, capacity: number) => <section className="zone">
    <div className="zone-title"><h3>{heading}</h3><span>{cards.length} / {capacity}</span></div>
    <div className="cards-row">{cards.length === 0 && <div className="empty-slots">空槽位 - 在商店和卡包中收集</div>}{cards.map((card, index) => <div className="card-wrap" key={`${area}-${index}`}>
      <Card card={card} onClick={() => inspect(card)} />
      <div className="card-controls"><button disabled={!rearrange || index === 0} onClick={() => move(area, cards.length, index, -1)} aria-label={`${heading} ${index} 左移`}>←</button><button disabled={!rearrange || index === cards.length - 1} onClick={() => move(area, cards.length, index, 1)} aria-label={`${heading} ${index} 右移`}>→</button>
        {area === 'consumables' && <button disabled={!usable} onClick={() => action('use', { consumable: index, cards: selected })}>使用</button>}
        <button className="danger-text" disabled={!sellable || card.eternal} onClick={() => action('sell', { [area === 'jokers' ? 'joker' : 'consumable']: index })}>出售</button>
      </div>
    </div>)}</div>
  </section>;
  const shelf = (cards: Item[], area: 'card' | 'voucher' | 'pack', title: string) => <section className="zone shelf">
    <div className="zone-title"><h3>{title}</h3><span>{cards.length} 件</span></div>
    <div className="cards-row">{cards.map((card, index) => <div className="card-wrap" key={`${area}-${index}`}>
      <Card card={card} onClick={() => inspect(card)} />
      <div className="card-controls"><button disabled={locked || !canPay(card.cost ?? 0)} onClick={() => action('buy', { [area]: index })}>{area === 'pack' ? '购买并开包' : '购买'}</button>
        {area === 'card' && ['Planet', 'Tarot', 'Spectral'].includes(card.category ?? '') && <button disabled={locked || !canPay(card.cost ?? 0)} onClick={() => action('buy_and_use', { card: index })}>买并使用</button>}
      </div>
    </div>)}</div>
  </section>;
  return <main className="table">
    <section className="run-banner"><div><div className="eyebrow">ANTE {stats.ante} / ROUND {stats.round}</div><h1>{o.win_overlay ? '已通关' : o.phase_name}</h1><p className="muted">{view.edited ? '这条路径包含调试修改' : '确定性对局 / 可复现路径'}</p></div><div className="phase-controls">
      {o.win_overlay ? <button className="primary" disabled={busy} onClick={() => action('endless')}>继续无尽模式</button> : <>
        {phase === 'BlindSelect' && <><button className="primary" disabled={locked} onClick={() => action('select')}>选择当前盲注</button><button disabled={locked || o.blinds.some(b => b.kind === 'Boss' && b.status === 'Select')} onClick={() => action('skip')}>跳过盲注</button><button disabled={locked || !o.vouchers.some(v => v.key === 'v_directors_cut' || v.key === 'v_retcon')} onClick={() => action('reroll_boss')}>重掷 Boss</button></>}
        {phase === 'RoundEval' && <button className="primary" disabled={locked} onClick={() => action('cash_out')}>兑现结算, 进入商店</button>}
        {phase === 'Shop' && <><button disabled={locked || !canPay(o.shop?.reroll_cost ?? Infinity)} onClick={() => action('reroll')}>刷新 ${number(o.shop?.reroll_cost)}</button><button className="primary" disabled={locked} onClick={() => action('next_round')}>离开商店</button></>}
        {phase === 'BoosterOpened' && <button disabled={locked} onClick={() => action('pack', { skip: true })}>跳过卡包</button>}
        {phase === 'GameOver' && <p className="warning">对局结束. 可在历史面板回溯, 尝试另一条路线.</p>}
      </>}
    </div></section>
    <div className="metrics"><div><span>金钱</span><strong className="money">${number(stats.dollars)}</strong></div><div><span>累计得分 / 目标</span><strong className="score">{number(stats.chips)} <small>/ {number(target)}</small></strong></div><div><span>出牌</span><strong>{number(stats.hands_left)}</strong></div><div><span>弃牌</span><strong>{number(stats.discards_left)}</strong></div></div>
    <div className="blinds">{o.blinds.map(blind => <button className={`blind ${['Select', 'Active'].includes(blind.status) ? 'active' : ''}`} key={blind.kind} onClick={() => inspect(blind)}><span className="eyebrow">{blind.kind} / {({ Select: '待选择', Upcoming: '未到', Active: '进行中', Defeated: '已击败', Skipped: '已跳过', Failed: '失败' } as Record<string,string>)[blind.status]}</span><strong>{blind.name}</strong>{blind.target != null && <span>目标 {number(blind.target)} / 奖金 ${number(blind.reward)}</span>}{blind.tag && <small>跳过奖励: {blind.tag.name}</small>}</button>)}</div>
    {owned(o.jokers, 'jokers', '小丑', stats.joker_capacity)}
    {owned(o.consumables, 'consumables', '消耗牌', stats.consumable_capacity)}
    {o.hand.length > 0 && <section className="zone hand-zone"><div className="zone-title"><h3>手牌</h3><span>{o.hand.length} / {stats.hand_size} 张</span><div className="hand-sort"><button disabled={!rearrange} onClick={() => action('sort_hand_value')}>点数排序</button><button disabled={!rearrange} onClick={() => action('sort_hand_suit')}>花色排序</button></div></div>
      <div className="cards-row hand">{o.hand.map((card, index) => <div className="card-wrap" key={`hand-${index}`}><Card card={card} selected={selected.includes(index)} disabled={!canSelect(phase) || locked} onClick={() => { toggle(index); inspect(card); }} /><div className="card-controls"><button disabled={!rearrange || index === 0} onClick={() => move('hand', o.hand.length, index, -1)} aria-label={`手牌 ${index} 左移`}>←</button><button disabled={!rearrange || index === o.hand.length - 1} onClick={() => move('hand', o.hand.length, index, 1)} aria-label={`手牌 ${index} 右移`}>→</button></div></div>)}</div>
      <div className="hand-actions"><span>已选 {selected.length} 张{selected.length > 0 && `: ${selected.join(', ')}`}</span><button disabled={busy || selected.length === 0} onClick={clear}>清空选择</button>{playing && <><button className="primary" disabled={locked || selected.length === 0 || selected.length > 5 || stats.hands_left <= 0} onClick={() => act(selectionAction('play', selected))}>出牌</button><button disabled={locked || selected.length === 0 || selected.length > 5 || stats.discards_left <= 0} onClick={() => act(selectionAction('discard', selected))}>弃牌</button></>}</div>
      {!playing && <p className="muted small">先选择手牌, 再点击消耗牌的使用按钮或卡包内的选取按钮.</p>}
    </section>}
    {o.shop && <section className="shop-area"><div className="section-heading"><h2>商店</h2><span className="muted">购买后可随时回溯</span></div>{shelf(o.shop.cards, 'card', '货架')}{shelf(o.shop.vouchers, 'voucher', '优惠券')}{shelf(o.shop.packs, 'pack', '补充包')}</section>}
    {o.pack && <section className="zone pack-area"><div className="zone-title"><h3>{o.pack.name}</h3><span>还可选 {o.pack.choices_left} 张</span></div><div className="cards-row">{o.pack.cards.map((card, index) => <div className="card-wrap" key={`pack-${index}`}><Card card={card} onClick={() => inspect(card)} /><div className="card-controls"><button className="primary" disabled={locked} onClick={() => action('pack', { card: index, targets: selected })}>选取并使用</button></div></div>)}</div></section>}
    <div className="pile-footer"><span>摸牌堆 {stats.deck_count} 张</span><span>弃牌堆 {stats.discard_count} 张</span>{o.tags.map((t,i) => <button key={`tag-${i}`} onClick={() => inspect(t)} className="tag">{t.name}</button>)}</div>
  </main>;
}
