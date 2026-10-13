import { useEffect, useState, type RefObject } from 'react';
import type { Backend, Preview, ScoreStep, View } from '../lib/types';
import { number } from '../lib/game';
import log from '../lib/log';

/** 预览加逐步回放的状态. step 为 -1 表示只有牌型基础值, 等于 count 表示全部算完. */
export interface Scoring { preview: Preview; step: number; count: number; seek: (step: number) => void; replay: () => void }

/** 调试模式选牌时向后端请求预览. 选择变化 120ms 后才请求, 旧 revision 的结果直接丢弃. */
export function usePreview(backend: RefObject<Backend | null>, view: View | null, selected: number[]): Preview | null {
  const [stored, setStored] = useState<{ key: string; preview: Preview } | null>(null);
  const active = !!view && view.debug && view.observation.phase === 'SelectingHand' && selected.length > 0 && selected.length <= 5;
  const key = active ? `${view.revision}:${[...selected].sort((a, b) => a - b).join(',')}` : '';
  useEffect(() => {
    if (!key || !view) { setStored(null); return; }
    let alive = true;
    const revision = view.revision, cards = [...selected];
    const timer = setTimeout(() => {
      const instance = backend.current;
      if (!instance) return;
      instance.preview(revision, cards)
        .then(preview => { if (alive) setStored({ key, preview }); })
        .catch(e => { if (alive) { log.debug('出牌预览失败', e); setStored(null); } });
    }, 120);
    return () => { alive = false; clearTimeout(timer); };
    // 只按 key 触发, key 已包含 revision 与选择.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  // 换选择后新结果到达前保留旧结果, 避免闪烁; 局面变化后立即作废.
  return stored && view && stored.preview.revision === view.revision && key ? stored.preview : null;
}

/** 按原版节奏逐步播放计分. 步数多时自动加速, 总时长约 3 秒. */
export function usePlayback(preview: Preview | null): Scoring | null {
  const count = preview?.steps?.length ?? 0;
  const [step, setStep] = useState(-1);
  const [auto, setAuto] = useState(true);
  useEffect(() => {
    const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    setStep(reduced ? count : -1); setAuto(!reduced);
  }, [preview, count]);
  useEffect(() => {
    if (!preview || !auto || step >= count) return;
    const delay = step < 0 ? 450 : Math.min(380, Math.max(90, 3000 / Math.max(count, 1)));
    const timer = setTimeout(() => setStep(s => s + 1), delay);
    return () => clearTimeout(timer);
  }, [preview, auto, step, count]);
  if (!preview) return null;
  return {
    preview, step: Math.min(step, count), count,
    seek: next => { setAuto(false); setStep(Math.max(-1, Math.min(next, count))); },
    replay: () => { setStep(-1); setAuto(true); },
  };
}

/** 当前回放位置的筹码与倍率. */
export function valuesAt(s: Scoring): { chips: number; mult: number } {
  const p = s.preview, steps = p.steps ?? [];
  if (s.step < 0 || steps.length === 0) return { chips: s.step >= s.count ? p.chips ?? 0 : p.base_chips ?? 0, mult: s.step >= s.count ? p.mult ?? 0 : p.base_mult ?? 0 };
  const at = steps[Math.min(s.step, steps.length - 1)];
  return { chips: at.chips, mult: at.mult };
}

export type Tone = 'chips' | 'mult' | 'money' | 'plain';
/** 原版飘字: 筹码蓝底 "+11", 倍率红底 "+4 倍率", 乘倍率红底 "X1.5 倍率", 钱金色 "+$3". */
export function badgeOf(step: ScoreStep): { text: string; tone: Tone } {
  const sign = step.amount >= 0 ? '+' : '';
  switch (step.kind) {
    case 'chips': return { text: `${sign}${number(step.amount)}`, tone: 'chips' };
    case 'mult': return { text: `${sign}${number(step.amount)} 倍率`, tone: 'mult' };
    case 'xmult': return { text: `X${number(step.amount)} 倍率`, tone: 'mult' };
    case 'dollars': return { text: `${sign}$${number(step.amount)}`, tone: 'money' };
    default: return { text: `${number(step.chips)} X ${number(step.mult)}`, tone: 'plain' };
  }
}

export interface Badge { id: number; text: string; tone: Tone }
/** 当前这一步落在哪张手牌或哪张小丑上. */
export function focusOf(s: Scoring | null): { hand?: number; joker?: number; badge?: Badge } {
  const step = s && s.step >= 0 ? s.preview.steps?.[s.step] : undefined;
  if (!s || !step) return {};
  const badge = { id: s.step, ...badgeOf(step) };
  const src = step.source;
  if ((src.kind === 'card' || src.kind === 'held') && src.hand != null) return { hand: src.hand, badge };
  if (src.kind === 'joker' && src.joker != null) return { joker: src.joker, badge };
  return { badge };
}
