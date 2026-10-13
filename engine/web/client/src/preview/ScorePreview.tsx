import type { ScoreStep } from '../lib/types';
import { number } from '../lib/game';
import { badgeOf, valuesAt, type Badge, type Scoring } from './usePreview';

/** 卡牌上方的飘字, 同原版 card_eval_status_text: 筹码蓝底, 倍率红底, 钱金色. key 变化时重放弹出动画. */
export function FloatBadge({ badge }: { badge: Badge }) {
  return <div key={badge.id} className={`float-badge tone-${badge.tone}`} aria-hidden="true">{badge.text}</div>;
}

function stepTitle(step: ScoreStep): string {
  return `${step.source.name ?? '?'}: ${badgeOf(step).text} → ${number(step.chips)} X ${number(step.mult)}`;
}

/** 出牌区中部的计分预览: 牌型名, 筹码 X 倍率 两个色块随步骤滚动, 下方一排可点的步骤芯片. */
export function ScorePreview({ scoring }: { scoring: Scoring }) {
  const p = scoring.preview;
  if (p.error) return <div className="score-preview invalid" role="status"><span className="preview-tag">预览</span><p>{p.error}</p></div>;
  const steps = p.steps ?? [];
  const { chips, mult } = valuesAt(scoring);
  const done = scoring.step >= scoring.count;
  const total = Math.floor(chips * mult);
  const after = (p.round_chips ?? 0) + (p.total ?? 0);
  const target = p.target ?? null;
  const current = scoring.step >= 0 ? steps[scoring.step] : undefined;
  return <div className="score-preview" role="status" aria-label={`预览 ${p.hand} 得分 ${number(p.total)}`}>
    <div className="preview-head">
      <span className="preview-tag">预览</span>
      <span className="preview-hand">{p.hand}{(p.level ?? 1) > 1 && <small> 等级{p.level}</small>}</span>
    </div>
    <div className="hud-chipmult preview-chipmult">
      <div key={`c-${chips}`} className="chips-box bump">{number(chips)}</div>
      <span className="times">X</span>
      <div key={`m-${mult}`} className="mult-box bump">{number(mult)}</div>
    </div>
    <div className="preview-source">{p.blocked ? '被盲注封禁, 本手不计分'
      : current ? stepTitle(current) : scoring.step < 0 ? `牌型基础 ${number(p.base_chips)} X ${number(p.base_mult)}` : '计分完成'}</div>
    <div className={`preview-total ${done ? 'done' : ''}`}>
      <span>{done ? number(p.total) : number(total)}</span>
      {target != null && <small className={after >= target ? 'reach' : ''}>
        {number(p.round_chips)} → {number(after)} / {number(target)}{after >= target ? ' 达标' : ''}</small>}
      {(p.dollars ?? 0) > 0 && <small className="money">+${number(p.dollars)}</small>}
    </div>
    <ol className="preview-steps" aria-label="计分步骤">
      <li><button className={`step-chip tone-plain ${scoring.step === -1 ? 'current' : ''}`} onClick={() => scoring.seek(-1)}
        title={`牌型基础 ${number(p.base_chips)} X ${number(p.base_mult)}`}>基础</button></li>
      {steps.map((step, i) => {
        const b = badgeOf(step);
        return <li key={i}><button className={`step-chip tone-${b.tone} ${i === scoring.step ? 'current' : ''} ${i > scoring.step ? 'future' : ''}`}
          onClick={() => scoring.seek(i)} title={stepTitle(step)}>{b.text}</button></li>;
      })}
    </ol>
    <div className="preview-controls">
      <button className="btn grey small" onClick={() => scoring.seek(scoring.step - 1)} disabled={scoring.step < 0} aria-label="上一步">◀</button>
      <button className="btn orange small" onClick={scoring.replay}>重播</button>
      <button className="btn grey small" onClick={() => scoring.seek(scoring.step + 1)} disabled={done} aria-label="下一步">▶</button>
      <button className="btn grey small" onClick={() => scoring.seek(scoring.count)} disabled={done}>结果</button>
    </div>
  </div>;
}
