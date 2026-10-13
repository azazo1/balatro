import { useState } from 'react';
import type { Action, Item, View } from '../lib/types';
import { canSelect, moveAction, number, type Area } from '../lib/game';
import { lookup, spriteCss } from '../assets/sprites';
import { Card } from './Card';
import { Phase } from './Phase';
import { FloatBadge } from '../preview/ScorePreview';
import { focusOf, type Scoring } from '../preview/usePreview';

/** 牌区: 原版的半透明深色圆角槽, 右下角显示 n/容量. */
function Zone({ className, count, capacity, children }: { className: string; count?: number; capacity?: number; children: React.ReactNode }) {
  return <section className={`zone ${className}`}>
    <div className="zone-cards">{children}</div>
    {capacity != null && <div className="zone-count">{count}/{capacity}</div>}
  </section>;
}

export function Board({ view, busy, selected, toggle, act, scoring }: {
  view: View; busy: boolean; selected: number[]; toggle: (index: number) => void; act: (action: Action) => void;
  scoring: Scoring | null;
}) {
  const o = view.observation, s = o.stats, back = o.deck_back;
  // 计分预览: 当前步骤落在哪张牌上就让它跳一下并飘字, 同原版 juice_up + card_eval_status_text.
  const focus = focusOf(scoring);
  const scored = new Set(scoring?.preview.scoring ?? []);
  const played = new Set(scoring?.preview.error ? [] : scoring?.preview.cards ?? []);
  const handMark = (index: number) => `${played.has(index) ? (scored.has(index) ? 'scoring' : 'idle') : ''} ${focus.hand === index ? 'firing' : ''}`;
  const handOverlay = (index: number) => focus.hand === index && focus.badge ? <FloatBadge badge={focus.badge} /> : null;
  const phase = o.phase;
  const locked = busy || o.win_overlay || phase === 'GameOver';
  const rearrange = canSelect(phase) && !locked;
  const sellable = ['SelectingHand', 'Shop', 'BoosterOpened'].includes(phase) && !locked;
  const usable = ['SelectingHand', 'Shop', 'BoosterOpened'].includes(phase) && !locked;
  // 点小丑或消耗牌后在牌下方弹出操作按钮, 同原版.
  const [picked, setPicked] = useState<string | null>(null);
  const action = (method: string, params: Record<string, unknown> = {}) => { setPicked(null); act({ method, params }); };
  const move = (area: Area, length: number) => (from: number, to: number) => { const next = moveAction(area, length, from, to); if (next) act(next); };
  const pick = (id: string) => setPicked(old => old === id ? null : id);

  const owned = (cards: Item[], area: 'jokers' | 'consumables') => cards.map((card, index) => {
    const id = `${area}-${index}`;
    const firing = area === 'jokers' && focus.joker === index;
    return <Card key={id} item={card} back={back} size="md" active={picked === id} tip="bottom"
      mark={firing ? 'firing' : ''} overlay={firing && focus.badge ? <FloatBadge badge={focus.badge} /> : null}
      onClick={() => pick(id)} drag={{ area, index, enabled: rearrange, onMove: move(area, cards.length) }}>
      {picked === id && <>
        <button className="btn green small" disabled={!sellable || card.eternal} onClick={() => action('sell', { [area === 'jokers' ? 'joker' : 'consumable']: index })}>
          售出{card.cost != null && <small>${number(card.cost)}</small>}</button>
        {area === 'consumables' && <button className="btn red small" disabled={!usable} onClick={() => action('use', { consumable: index, cards: selected })}>使用</button>}
      </>}
    </Card>;
  });

  const deckCss = spriteCss(lookup(back));
  return <main className="board">
    <div className="board-top">
      <Zone className="jokers" count={o.jokers.length} capacity={s.joker_capacity}>{owned(o.jokers, 'jokers')}</Zone>
      <Zone className="consumables" count={o.consumables.length} capacity={s.consumable_capacity}>{owned(o.consumables, 'consumables')}</Zone>
    </div>
    <div className="board-middle"><Phase view={view} busy={busy} locked={locked} selected={selected} act={action} scoring={scoring} /></div>
    <div className="board-bottom">
      <div className="tags-column">{o.tags.map((t, i) => <div key={`tag-${i}`} className="tag-slot">
        <div className="tag-icon" style={spriteCss(lookup(t.key)) ?? {}} role="img" aria-label={t.name} tabIndex={0} />
        <div className="tooltip tooltip-right" role="tooltip"><div className="tooltip-title">{t.name}</div><div className="tooltip-body"><p>{t.effect}</p></div></div>
      </div>)}</div>
      <div className="hand-area">
        <Zone className="hand" count={o.hand.length} capacity={s.hand_size}>
          {o.hand.map((card, index) => <Card key={`hand-${index}-${card.token ?? card.name}`} item={card} back={back} size="lg"
            selected={selected.includes(index)} disabled={!canSelect(phase) || locked}
            mark={handMark(index)} overlay={handOverlay(index)}
            onClick={() => toggle(index)} drag={{ area: 'hand', index, enabled: rearrange, onMove: move('hand', o.hand.length) }} />)}
        </Zone>
        {o.hand.length > 0 && <HandButtons view={view} locked={locked} selected={selected} act={action} />}
      </div>
      <div className="deck-pile" title={`摸牌堆 ${s.deck_count} 张, 弃牌堆 ${s.discard_count} 张`}>
        <div className="deck-stack">{[2, 1, 0].map(i => <div key={i} className="deck-card" style={{ ...deckCss, translate: `calc(var(--u) * ${i * -0.08}) calc(var(--u) * ${i * -0.08})` }} />)}</div>
        <span>{s.deck_count}/{s.deck_count + s.discard_count + o.hand.length}</span>
      </div>
    </div>
  </main>;
}

function HandButtons({ view, locked, selected, act }: { view: View; locked: boolean; selected: number[]; act: (method: string, params?: Record<string, unknown>) => void }) {
  const o = view.observation, s = o.stats;
  const playing = o.phase === 'SelectingHand';
  const count = selected.length;
  return <div className="hand-buttons">
    {playing && <button className="btn blue big" disabled={locked || count === 0 || count > 5 || s.hands_left <= 0} onClick={() => act('play', { cards: [...selected] })}>出牌</button>}
    <div className="sort-box"><span>理牌</span>
      <button className="btn orange small" disabled={locked || !canSelect(o.phase)} onClick={() => act('sort_hand_value')}>点数</button>
      <button className="btn orange small" disabled={locked || !canSelect(o.phase)} onClick={() => act('sort_hand_suit')}>花色</button>
    </div>
    {playing && <button className="btn red big" disabled={locked || count === 0 || count > 5 || s.discards_left <= 0} onClick={() => act('discard', { cards: [...selected] })}>弃牌</button>}
  </div>;
}
