import type { Blind, Item, View } from '../lib/types';
import { lookup, spriteCss } from '../assets/sprites';
import { number, parseReport } from '../lib/game';
import { Card } from './Card';
import { TagSlot } from './Tooltip';
import { BlindChip, blindColour } from './Hud';
import { ScorePreview } from '../preview/ScorePreview';
import type { Scoring } from '../preview/usePreview';

type Act = (method: string, params?: Record<string, unknown>) => void;
const statusName: Record<string, string> = { Select: '选择', Upcoming: '即将到来', Active: '进行中', Defeated: '已击败', Skipped: '已跳过', Failed: '失败' };
/** 原版结算栏用一串 $ 表示金额, 太多时改写数字. */
const dollars = (amount: number) => amount > 0 && amount <= 10 ? '$'.repeat(amount) : `$${number(amount)}`;
const kindName: Record<string, string> = { Small: '小盲注', Big: '大盲注', Boss: 'Boss 盲注' };

/** 盲注选择卡, 对照 UI_definitions.lua create_UIBox_blind_choice. */
function BlindCard({ blind, view, locked, act }: { blind: Blind; view: View; locked: boolean; act: Act }) {
  const selectable = blind.status === 'Select';
  const canReroll = blind.kind === 'Boss' && view.observation.vouchers.some(v => v.key === 'v_directors_cut' || v.key === 'v_retcon');
  return <div className={`blind-card status-${blind.status}`} style={{ ['--blind' as string]: blindColour(blind) }}>
    <button className={`btn ${selectable ? 'orange' : 'grey'} blind-select`} disabled={!selectable || locked} onClick={() => act('select')}>
      {statusName[blind.status] ?? blind.status}</button>
    <div className="blind-card-name">{blind.name}</div>
    <BlindChip blind={blind} size={3} />
    <div className="blind-card-info">
      <span>至少得分</span>
      <strong className="mult-text">{blind.target != null ? number(blind.target) : '?'}</strong>
      {blind.reward != null && <span>奖励: <b className="money">{'$'.repeat(Math.min(blind.reward, 8))}+</b></span>}
      {blind.effect && blind.kind === 'Boss' && <p className="blind-effect">{blind.effect}</p>}
    </div>
    {blind.tag && <div className="blind-skip">
      <TagSlot tag={blind.tag} placement="top" />
      <button className="btn red small" disabled={!selectable || locked} onClick={() => act('skip')}>跳过盲注</button>
    </div>}
    {canReroll && <button className="btn red small" disabled={locked} onClick={() => act('reroll_boss')}>重掷 Boss</button>}
    <div className="blind-kind">{kindName[blind.kind] ?? blind.kind}</div>
  </div>;
}

function Shelf({ items, area, view, locked, act, label }: { items: Item[]; area: 'card' | 'voucher' | 'pack'; view: View; locked: boolean; act: Act; label: string }) {
  const spendable = view.observation.stats.spendable;
  return <div className={`shelf shelf-${area}`} aria-label={label}>
    {items.length === 0 && <span className="shelf-empty">{label}</span>}
    {items.map((card, index) => {
      const afford = spendable >= (card.cost ?? 0);
      const consumable = area === 'card' && ['Planet', 'Tarot', 'Spectral'].includes(card.category ?? '');
      return <Card key={`${area}-${index}`} item={card} back={view.observation.deck_back} size={area === 'card' ? 'md' : 'sm'} price={card.cost} tip="bottom">
        <button className="btn green small" disabled={locked || !afford} onClick={() => act('buy', { [area]: index })}>
          {area === 'pack' ? '打开' : area === 'voucher' ? '兑换' : '购买'}</button>
        {consumable && <button className="btn red small" disabled={locked || !afford} onClick={() => act('buy_and_use', { card: index })}>买并使用</button>}
      </Card>;
    })}
  </div>;
}

export function Phase({ view, busy, locked, selected, act, scoring }: { view: View; busy: boolean; locked: boolean; selected: number[]; act: Act; scoring: Scoring | null }) {
  const o = view.observation;
  if (o.win_overlay) return <div className="panel-box center-panel">
    <h2 className="big-title gold">胜利!</h2><p>已通过第 8 底注. 可以进入无尽模式, 或在历史里回溯换一条路线.</p>
    <button className="btn orange big" disabled={busy} onClick={() => act('endless')}>无尽模式</button>
  </div>;
  if (o.phase === 'GameOver') return <div className="panel-box center-panel">
    <h2 className="big-title mult-text">游戏结束</h2><p>按 Z 回到上一步, 或在右侧历史中选择分歧点重新尝试.</p>
  </div>;
  if (o.phase === 'BlindSelect') return <div className="blind-row">{o.blinds.map(b => <BlindCard key={b.kind} blind={b} view={view} locked={locked} act={act} />)}</div>;
  if (o.phase === 'RoundEval') {
    // 盲注取自结算栏本身 (刚打完的那一个), 而不是从三张盲注里猜.
    const ev = o.round_eval;
    const chip = ev?.blind_key ? { key: ev.blind_key, name: ev.blind ?? '', effect: '', kind: '', status: '' } : undefined;
    return <div className="panel-box center-panel cash-out">
      {ev && <>
        <div className="cash-blind">
          <BlindChip blind={chip} size={2.4} />
          <span>{ev.blind}</span>
          {ev.target != null && <span>至少得分 <strong className="mult-text">{number(ev.target)}</strong></span>}
          {ev.blind_reward > 0 && <b className="money cash-amount">{dollars(ev.blind_reward)}</b>}
        </div>
        <ul className="cash-rows">{ev.rows.map((row, i) => <li key={i}>
          <span>{row.label}</span><b className="money cash-amount">{dollars(row.amount)}</b>
        </li>)}</ul>
      </>}
      <button className="btn orange big" disabled={locked} onClick={() => act('cash_out')}>提现: ${number(ev?.total ?? 0)}</button>
    </div>;
  }
  if (o.phase === 'Shop' && o.shop) return <div className="shop">
    <div className="shop-sign" style={spriteCss(lookup('shop_sign')) ?? {}} role="img" aria-label="商店" />
    <div className="shop-body panel-box">
      <div className="shop-buttons">
        <button className="btn red tall" disabled={locked} onClick={() => act('next_round')}>下一<br />回合</button>
        <button className="btn green tall" disabled={locked || o.stats.spendable < o.shop.reroll_cost} onClick={() => act('reroll')}>重掷<br /><b>${number(o.shop.reroll_cost)}</b></button>
      </div>
      <Shelf items={o.shop.cards} area="card" view={view} locked={locked} act={act} label="货架" />
      <div className="shop-lower">
        <Shelf items={o.shop.vouchers} area="voucher" view={view} locked={locked} act={act} label="优惠券" />
        <Shelf items={o.shop.packs} area="pack" view={view} locked={locked} act={act} label="补充包" />
      </div>
    </div>
  </div>;
  if (o.phase === 'BoosterOpened' && o.pack) return <div className="pack">
    <div className="pack-cards">{o.pack.cards.map((card, index) => <Card key={`pack-${index}`} item={card} back={o.deck_back} size="md" tip="bottom">
      <button className="btn green small" disabled={locked} onClick={() => act('pack', { card: index, targets: selected })}>选择</button>
    </Card>)}</div>
    <div className="pack-footer"><span className="pack-name">{o.pack.name}</span><span>还可选 {o.pack.choices_left} 张</span>
      <button className="btn grey small" disabled={locked} onClick={() => act('pack', { skip: true })}>跳过</button></div>
  </div>;
  // 调试模式选了牌: 中部换成计分预览.
  if (scoring) return <div className="play-area"><ScorePreview scoring={scoring} /></div>;
  // 出牌阶段: 中部显示上一手计分结果.
  const hand = parseReport(o.last_hand);
  return <div className="play-area">{hand && <div className="last-hand">
    <span className="last-hand-name">{hand.hand}{hand.level > 1 && <small> 等级{hand.level}</small>}</span>
    <span className="last-hand-total">{hand.total}</span>
  </div>}</div>;
}
