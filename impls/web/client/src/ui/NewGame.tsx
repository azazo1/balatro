import { useState } from 'react';
import type { Info, Opening } from '../lib/types';
import { randomSeed } from '../lib/game';
import { lookup, sprites, spriteCss } from '../assets/sprites';

const stakeNames = ['白注', '红注', '绿注', '黑注', '蓝注', '紫注', '橙注', '金注'];

/** 新局面板, 对照原版 "新比赛" 页: 牌组翻页, 赌注筹码, 种子. */
export function NewGame({ info, initial, busy, replacing, onStart, onClose }: {
  info: Info | null; initial?: Opening; busy: boolean; replacing: boolean; onStart: (opening: Opening) => void; onClose?: () => void;
}) {
  const decks = info?.decks ?? [];
  const [deckIndex, setDeckIndex] = useState(() => Math.max(0, decks.findIndex(d => d.key === (initial?.deck ?? 'b_red'))));
  const [stake, setStake] = useState(initial?.stake ?? 1);
  const [seed, setSeed] = useState(initial?.seed ?? randomSeed());
  const [profile, setProfile] = useState(initial?.profile ?? 'all');
  const deck = decks[deckIndex];
  const turn = (d: number) => setDeckIndex(i => (i + d + decks.length) % Math.max(decks.length, 1));
  const stakeKeys = sprites().stakes;
  return <div className="modal-backdrop" onKeyDown={e => { if (e.key === 'Escape' && onClose) onClose(); }}>
    <section className="modal panel-box new-game" role="dialog" aria-modal="true" aria-labelledby="new-title">
      <h2 id="new-title" className="modal-title">新比赛</h2>
      <form onSubmit={e => { e.preventDefault(); if (deck) onStart({ seed: seed.trim() || randomSeed(), deck: deck.key!, stake, profile }); }}>
        <div className="deck-picker">
          <button type="button" className="btn red arrow" onClick={() => turn(-1)} aria-label="上一个牌组">‹</button>
          <div className="deck-show">
            <div className="deck-back" style={spriteCss(lookup(deck?.key)) ?? {}} role="img" aria-label={deck?.name ?? '牌组'} />
            <div className="deck-text"><strong>{deck?.name ?? '正在加载引擎'}</strong><p>{deck?.effect}</p>
              <span className="dim">{deckIndex + 1} / {decks.length}</span></div>
          </div>
          <button type="button" className="btn red arrow" onClick={() => turn(1)} aria-label="下一个牌组">›</button>
        </div>
        <div className="stake-picker" role="radiogroup" aria-label="赌注">
          {stakeNames.map((name, i) => <button type="button" key={name} role="radio" aria-checked={stake === i + 1} aria-label={`${i + 1}. ${name}`} title={name}
            className={`stake-chip ${stake === i + 1 ? 'active' : ''}`} onClick={() => setStake(i + 1)}>
            <span style={spriteCss(lookup(stakeKeys[i])) ?? {}} />
          </button>)}
          <span className="stake-name">{stakeNames[stake - 1]}</span>
        </div>
        <div className="form-row">
          <label className="seed-input"><span>种子</span><input aria-label="种子" maxLength={128} value={seed} onChange={e => setSeed(e.target.value)} placeholder="留空随机" autoFocus /></label>
          <button type="button" className="btn grey small" onClick={() => setSeed(randomSeed())}>随机</button>
          <div className="segmented" role="radiogroup" aria-label="解锁进度">
            <button type="button" role="radio" aria-checked={profile === 'all'} className={profile === 'all' ? 'active' : ''} onClick={() => setProfile('all')}>全解锁</button>
            <button type="button" role="radio" aria-checked={profile === 'new'} className={profile === 'new' ? 'active' : ''} onClick={() => setProfile('new')}>新存档</button>
          </div>
        </div>
        {replacing && <p className="hint warn">开始新局会替换当前会话, 未下载的路线请先保存.</p>}
        <div className="modal-actions">
          {onClose && <button type="button" className="btn grey" onClick={onClose} disabled={busy}>返回</button>}
          <button className="btn blue big" type="submit" disabled={busy || !deck}>开始</button>
        </div>
      </form>
    </section>
  </div>;
}
