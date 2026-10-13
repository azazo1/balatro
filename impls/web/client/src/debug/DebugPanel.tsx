import { useState } from 'react';
import type { View } from '../lib/types';
import { fieldNames, number } from '../lib/game';
import { Card } from '../board/Card';
import { HistoryTree } from './HistoryTree';

/** 原版 G.C.HAND_LEVELS, 等级越高颜色越暖. */
const levelColours = ['#efefef', '#95acff', '#65efaf', '#fae37e', '#ffc052', '#f87d75', '#caa0ef'];
const diffTone: Record<string, string> = { chips: 'chip-text', dollars: 'money', hands_left: 'chip-text', discards_left: 'mult-text' };

function Editor({ values, busy, edit }: { values: Record<string, number>; busy: boolean; edit: (changes: Record<string, number>) => void }) {
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [error, setError] = useState('');
  return <form className="debug-editor" onSubmit={e => {
    e.preventDefault();
    const changes: Record<string, number> = {};
    for (const [key, raw] of Object.entries(draft)) {
      const value = Number(raw);
      if (!raw.trim() || !Number.isFinite(value)) { setError(`${fieldNames[key] ?? key} 必须是有限数字`); return; }
      if (value !== values[key]) changes[key] = value;
    }
    if (Object.keys(changes).length === 0) { setError('没有需要提交的修改'); return; }
    setError(''); edit(changes);
  }}>
    {Object.entries(values).map(([key, value]) => <label key={key}><span>{fieldNames[key] ?? key}</span>
      <input aria-label={`修改${fieldNames[key] ?? key}`} type="text" inputMode="decimal" value={draft[key] ?? String(value)} disabled={busy}
        onChange={e => setDraft({ ...draft, [key]: e.target.value })} /></label>)}
    {error && <p className="error-text" role="alert">{error}</p>}
    <p className="hint">修改会生成独立的调试节点, 并标记其后继路径. 修改得分不会自动结算.</p>
    <button className="btn orange small" disabled={busy || Object.keys(draft).length === 0}>记录修改</button>
  </form>;
}

type Tab = 'history' | 'score' | 'state' | 'debug';
const tabs: [Tab, string][] = [['history', '历史'], ['score', '计分'], ['state', '局面'], ['debug', '调试']];

export function DebugPanel({ view, busy, jump, debug, edit }: {
  view: View; busy: boolean; jump: (node: number) => void; debug: (enabled: boolean) => void; edit: (changes: Record<string, number>) => void;
}) {
  const [tab, setTab] = useState<Tab>('history');
  const o = view.observation;
  return <aside className="debug-panel" aria-label="调试侧栏">
    <div className="debug-tabs" role="tablist">{tabs.map(([key, label]) =>
      <button key={key} role="tab" aria-selected={tab === key} className={`tab ${tab === key ? 'active' : ''}`} onClick={() => setTab(key)}>{label}</button>)}</div>
    <div className="debug-body">
      {tab === 'history' && <HistoryTree view={view} busy={busy} jump={jump} />}
      {tab === 'score' && <div className="scroll">
        <h3>上一手计分</h3>
        {o.last_hand ? <pre className="report">{o.last_hand}</pre> : <p className="hint">出牌后显示逐来源计分明细.</p>}
        {o.note !== o.last_hand && <><h3>当前节点</h3><pre className="report">{o.note}</pre></>}
        <h3>相对父节点的变化</h3>
        {o.differences.length === 0 ? <p className="hint">公开指标没有变化.</p> : <div className="diff-list">{o.differences.map(d =>
          <div key={d.field}><span>{fieldNames[d.field] ?? d.field}</span><code className={diffTone[d.field] ?? ''}>{number(d.before)} → {number(d.after)}</code></div>)}</div>}
      </div>}
      {tab === 'state' && <div className="scroll">
        <h3>牌型等级</h3>
        <div className="levels">{o.levels.map(l => <div key={l.name}>
          <span className="level-badge" style={{ background: levelColours[Math.min(l.level - 1, 6)] ?? levelColours[0] }}>Lv{l.level}</span>
          <span className="level-name">{l.name}</span>
          <span className="level-value"><b className="chips-box mini">{number(l.chips)}</b>×<b className="mult-box mini">{number(l.mult)}</b></span>
          <span className="level-played">#{l.played}</span>
        </div>)}</div>
        {o.vouchers.length > 0 && <><h3>已兑换优惠券</h3><div className="mini-cards">{o.vouchers.map((v, i) => <Card key={i} item={v} back={o.deck_back} size="xs" tip="bottom" />)}</div></>}
        <h3>动态值与牌堆统计</h3><pre className="report">{o.dynamics}</pre>
        <details><summary>完整公开局面</summary><pre className="report">{o.summary}</pre></details>
      </div>}
      {tab === 'debug' && <div className="scroll">
        <label className="switch"><input type="checkbox" checked={view.debug} disabled={busy} onChange={e => debug(e.target.checked)} /><span>调试模式</span></label>
        {view.edited && <p className="hint warn">当前路径包含调试修改, 不能导出为普通动作记录.</p>}
        {view.debug && o.debug ? <>
          <Editor key={`${view.current}-${view.revision}`} values={o.debug.values} busy={busy} edit={edit} />
          <h3>真实摸牌顺序 (下一张在最前) · {o.debug.deck.length}</h3>
          <div className="mini-cards">{o.debug.deck.map((c, i) => <Card key={i} item={c} back={o.deck_back} size="xs" tip="bottom" />)}</div>
          <h3>弃牌堆 · {o.debug.discard.length}</h3>
          <div className="mini-cards">{o.debug.discard.map((c, i) => <Card key={i} item={c} back={o.deck_back} size="xs" tip="bottom" />)}</div>
          <details><summary>随机状态</summary><pre className="report">{o.debug.rng}</pre></details>
          <details><summary>内部 digest</summary><pre className="report">{o.debug.digest}</pre></details>
        </> : <p className="hint">正常模式不显示暗牌身份, 真实摸牌顺序与随机状态. 开启后可查看内部信息并修改白名单状态.</p>}
      </div>}
    </div>
  </aside>;
}
