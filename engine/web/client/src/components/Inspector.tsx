import { useState } from 'react';
import type { Item, View } from '../lib/types';
import { fieldNames, number } from '../lib/game';

function Editor({ values, busy, edit }: { values: Record<string, number>; busy: boolean; edit: (changes: Record<string, number>) => void }) {
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [error, setError] = useState('');
  return <form className="debug-editor" onSubmit={e => {
    e.preventDefault(); const changes: Record<string, number> = {};
    for (const [key, raw] of Object.entries(draft)) {
      const value = Number(raw);
      if (!raw.trim() || !Number.isFinite(value)) { setError(`${fieldNames[key]} 必须是有限数字`); return; }
      if (value !== values[key]) changes[key] = value;
    }
    if (Object.keys(changes).length === 0) { setError('没有需要提交的修改'); return; }
    setError(''); edit(changes);
  }}>
    <p className="warning">修改会产生独立的调试历史节点, 并永久标记其后继路径. 修改得分不会自动触发结算.</p>
    {Object.entries(values).map(([key, value]) => <label key={key}><span>{fieldNames[key] ?? key}</span><input aria-label={`修改${fieldNames[key] ?? key}`} type="text" inputMode="decimal" value={draft[key] ?? String(value)} disabled={busy} onChange={e => setDraft({ ...draft, [key]: e.target.value })} /></label>)}
    {error && <p className="error-text" role="alert">{error}</p>}
    <button className="warning-button" disabled={busy || Object.keys(draft).length === 0}>记录状态修改</button>
  </form>;
}

export function Inspector({ view, inspected, busy, edit, enableDebug }: {
  view: View; inspected: Item | null; busy: boolean; edit: (changes: Record<string, number>) => void; enableDebug: () => void;
}) {
  const [tab, setTab] = useState('score');
  const o = view.observation;
  return <aside className="inspector panel"><div className="panel-title"><h2>检查器</h2><span className="badge">#{view.current}</span></div>
    {inspected && <section className="inspected"><div className="eyebrow">SELECTED OBJECT</div><h3>{inspected.name}</h3><p>{inspected.effect || '没有可见的效果信息'}</p>{inspected.modifiers && <p className="muted">{inspected.modifiers}</p>}{inspected.current && <p className="accent">当前: {inspected.current}</p>}{inspected.key && <code>{inspected.key}</code>}</section>}
    <div className="tabs">{[['score', '计分'], ['state', '局面'], ['debug', '调试']].map(([key, label]) => <button key={key} aria-pressed={tab === key} className={tab === key ? 'active' : ''} onClick={() => setTab(key)}>{label}</button>)}</div>
    <div className="inspector-body">
      {tab === 'score' && <><h3>上一手计分</h3>{o.last_hand ? <pre className="score-report">{o.last_hand}</pre> : <p className="muted">出牌后显示逐来源计分明细.</p>}{o.note !== o.last_hand && <><h3>当前操作</h3><pre>{o.note}</pre></>}<h3>相对父节点的变化</h3>{o.differences.length === 0 ? <p className="muted">这些公开指标没有变化.</p> : <div className="diff-list">{o.differences.map(d => <div key={d.field}><span>{fieldNames[d.field] ?? d.field}</span><code>{number(d.before)} → {number(d.after)}</code></div>)}</div>}</>}
      {tab === 'state' && <><h3>牌型等级</h3><div className="levels">{o.levels.map(l => <div key={l.name}><span>{l.name}<small>Lv{l.level} / 已打 {l.played}</small></span><code>{number(l.chips)} x {number(l.mult)}</code></div>)}</div><h3>动态值与牌堆统计</h3><pre>{o.dynamics}</pre><details><summary>完整公开局面</summary><pre>{o.summary}</pre></details></>}
      {tab === 'debug' && (view.debug && o.debug ? <><Editor key={`${view.current}-${view.revision}`} values={o.debug.values} busy={busy} edit={edit} /><details><summary>真实摸牌顺序 (下一张在最前)</summary><ol>{o.debug.deck.map((card,i) => <li key={i}>{card.name}{card.modifiers}</li>)}</ol></details><details><summary>弃牌堆</summary><ol>{o.debug.discard.map((card,i) => <li key={i}>{card.name}{card.modifiers}</li>)}</ol></details><details><summary>随机状态 (只读)</summary><pre>{o.debug.rng}</pre></details><details><summary>内部 digest (只读)</summary><pre>{o.debug.digest}</pre></details></> : <section className="debug-closed"><h3>调试模式已关闭</h3><p className="muted">正常模式不会显示暗牌身份, 真实摸牌顺序或随机状态. 开启后可观察内部信息和修改白名单状态.</p><button disabled={busy} onClick={enableDebug}>开启调试模式</button></section>)}
    </div>
  </aside>;
}
