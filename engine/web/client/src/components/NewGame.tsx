import { useState } from 'react';
import type { Info, Opening } from '../lib/types';
import { randomSeed } from '../lib/game';

const stakeNames = ['白色', '红色', '绿色', '黑色', '蓝色', '紫色', '橙色', '金色'];
export function NewGame({ info, initial, busy, onStart, onClose }: {
  info: Info | null; initial?: Opening; busy: boolean; onStart: (opening: Opening) => void; onClose?: () => void;
}) {
  const [seed, setSeed] = useState(initial?.seed ?? randomSeed());
  const [deck, setDeck] = useState(initial?.deck ?? 'b_red');
  const [stake, setStake] = useState(initial?.stake ?? 1);
  const [profile, setProfile] = useState(initial?.profile ?? 'all');
  const selected = info?.decks.find(d => d.key === deck);
  return <div className="modal-backdrop"><section className="new-game modal" role="dialog" aria-modal="true" aria-labelledby="new-title">
    <div className="eyebrow">NEW EXPERIMENT</div><h2 id="new-title">开始一局, 探索每一种可能</h2>
    <p className="muted">由真实 Rust engine 计算规则. 每一步都能回溯, 每条路线都可以保留.</p>
    <form onSubmit={e => { e.preventDefault(); onStart({ seed: seed || randomSeed(), deck, stake, profile }); }}>
      <label>种子<div className="input-row"><input aria-label="种子" maxLength={128} value={seed} onChange={e => setSeed(e.target.value)} placeholder="留空生成随机种子" autoFocus /><button type="button" onClick={() => setSeed(randomSeed())}>随机生成</button></div></label>
      <div className="form-grid"><label>牌组<select value={deck} onChange={e => setDeck(e.target.value)}>{info?.decks.map(d => <option key={d.key} value={d.key}>{d.name}</option>)}</select></label>
        <label>赌注<select value={stake} onChange={e => setStake(Number(e.target.value))}>{stakeNames.map((name, i) => <option key={name} value={i + 1}>{i + 1}. {name}</option>)}</select></label></div>
      <div className="deck-description">{selected?.effect || '正在加载引擎...'}</div>
      <label>解锁进度<select value={profile} onChange={e => setProfile(e.target.value)}><option value="all">全解锁 - 完整候选池</option><option value="new">新存档 - 原型初始解锁内容</option></select></label>
      <p className="muted small">手动种子区分大小写. 配置只在开局生效. 此处不会修改游戏存档.</p>
      <div className="modal-actions">{onClose && <button type="button" onClick={onClose} disabled={busy}>取消</button>}<button className="primary" type="submit" disabled={busy || !info}>开始对局</button></div>
    </form>
  </section></div>;
}
