import type { ReactNode } from 'react';
import type { Blind, View } from '../lib/types';
import { colourOf, lookup, spriteCss } from '../assets/sprites';
import { number, parseReport } from '../lib/game';
import { valuesAt, type Scoring } from '../preview/usePreview';

/** 与 misc_functions.lua get_blind_main_colour 一致: Boss 用自身颜色, 小盲蓝, 大盲橙. */
export function blindColour(blind: Blind | undefined): string {
  if (!blind) return '#374244';
  if (blind.status === 'Defeated' || blind.status === 'Skipped') return '#374244';
  return colourOf(blind.key) ?? (blind.kind === 'Small' ? '#1d6f9e' : blind.kind === 'Big' ? '#9b6e1d' : '#374244');
}

export function BlindChip({ blind, size = 2.2 }: { blind?: Blind; size?: number }) {
  const css = spriteCss(lookup(blind?.key));
  return <div className="blind-chip" style={{ ...css, width: `calc(var(--u) * ${size})`, height: `calc(var(--u) * ${size})` }} aria-hidden="true" />;
}

function Stat({ label, children, tone = '' }: { label: string; children: ReactNode; tone?: string }) {
  return <div className="hud-stat"><span className="hud-label">{label}</span><div className={`hud-value ${tone}`}>{children}</div></div>;
}

/** 左侧信息栏, 结构对照 UI_definitions.lua create_UIBox_HUD. */
export function Hud({ view, actions, scoring }: { view: View; actions: ReactNode; scoring: Scoring | null }) {
  const o = view.observation, s = o.stats;
  // 预览时左侧牌型框与原版一样跟着计分走, 数值标记为预览色.
  const live = scoring && !scoring.preview.error ? valuesAt(scoring) : null;
  const blind = o.blinds.find(b => b.status === 'Active') ?? o.blinds.find(b => b.status === 'Select');
  const colour = blindColour(blind);
  const hand = parseReport(o.last_hand);
  const inRound = o.phase === 'SelectingHand';
  return <aside className="hud" style={{ ['--blind' as string]: colour }}>
    <div className="hud-blind">
      <div className="hud-blind-name">{o.win_overlay ? '已通关' : blind ? blind.name : o.phase_name}</div>
      <div className="hud-blind-body">
        <BlindChip blind={blind} />
        <div className="hud-blind-target">
          <span>{inRound ? '至少得分' : o.phase_name}</span>
          <strong className="chip-text">{number(blind?.target)}</strong>
          {blind?.reward != null && <span>奖励: <b className="money">{'$'.repeat(Math.min(blind.reward, 8))}</b></span>}
        </div>
      </div>
    </div>
    <div className="hud-score"><span>回合<br />分数</span><strong>{number(s.chips)}</strong></div>
    {live && scoring ? <div className="hud-hand previewing">
      <div className="hud-hand-name">{scoring.preview.hand}{(scoring.preview.level ?? 1) > 1 && <small> 等级{scoring.preview.level}</small>}</div>
      <div className="hud-chipmult">
        <div key={`c-${live.chips}`} className="chips-box bump">{number(live.chips)}</div><span className="times">X</span>
        <div key={`m-${live.mult}`} className="mult-box bump">{number(live.mult)}</div>
      </div>
    </div> : <div className="hud-hand">
      <div className="hud-hand-name">{hand ? <>{hand.hand}{hand.level > 1 && <small> 等级{hand.level}</small>}</> : <span className="dim">&nbsp;</span>}</div>
      <div className="hud-chipmult">
        <div className="chips-box">{hand?.chips ?? 0}</div><span className="times">X</span><div className="mult-box">{hand?.mult ?? 0}</div>
      </div>
    </div>}
    <div className="hud-grid">
      <Stat label="出牌" tone="chip-text">{number(s.hands_left)}</Stat>
      <Stat label="弃牌" tone="mult-text">{number(s.discards_left)}</Stat>
      <Stat label="资金" tone="money wide">${number(s.dollars)}</Stat>
      <Stat label="底注" tone="orange"><>{number(s.ante)}<small>/8</small></></Stat>
      <Stat label="回合" tone="orange">{number(s.round)}</Stat>
    </div>
    <div className="hud-actions">{actions}</div>
  </aside>;
}
