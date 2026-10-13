import type { CSSProperties, DragEvent, ReactNode } from 'react';
import type { Item } from '../lib/types';
import { lookup, soulOf, spriteCss } from '../assets/sprites';
import { number } from '../lib/game';
import { Tooltip } from './Tooltip';

export type CardSize = 'xs' | 'sm' | 'md' | 'lg';

function Layer({ css, className = '' }: { css: CSSProperties | null; className?: string }) {
  return css ? <div className={`card-layer ${className}`} style={css} aria-hidden="true" /> : null;
}

/** 牌面图层, 顺序同 card.lua Card:draw: 底 -> 正面 -> 魂层 -> 蜡封 -> 贴纸 -> 版本 -> 削弱. */
export function CardFace({ item, back }: { item: Item; back: string }) {
  if (item.hidden) {
    return <div className="card-face"><Layer css={spriteCss(lookup(back))} /></div>;
  }
  const isPlaying = item.suit != null;
  const base = isPlaying ? spriteCss(lookup(item.enhancement ?? 'c_base')) : spriteCss(lookup(item.key));
  const front = isPlaying && item.enhancement !== 'm_stone' ? spriteCss(lookup(item.key)) : null;
  const soul = isPlaying ? null : spriteCss(soulOf(item.key));
  const seal = item.seal ? spriteCss(lookup(`seal_${item.seal}`)) : null;
  return <div className={`card-face ${item.edition ? `edition-${item.edition}` : ''}`}>
    {base ? <Layer css={base} /> : <div className={`card-fallback set-${item.category ?? 'Default'}`}><span>{item.name}</span></div>}
    <Layer css={front} />
    <Layer css={soul} className="soul" />
    <Layer css={seal} />
    {(item.stickers ?? []).map(s => <Layer key={s} css={spriteCss(lookup(`sticker_${s}`))} />)}
    {item.edition && <div className="card-layer edition-sheen" aria-hidden="true" />}
    {item.debuffed && <div className="card-layer debuffed" aria-hidden="true" />}
  </div>;
}

export interface DragInfo { area: string; index: number; onMove: (from: number, to: number) => void; enabled: boolean }

export function Card({ item, back, size = 'md', selected = false, active = false, disabled = false, price, onClick, tip = 'top', drag, children }: {
  item: Item; back: string; size?: CardSize; selected?: boolean; active?: boolean; disabled?: boolean; price?: number;
  onClick?: () => void; tip?: 'top' | 'bottom' | 'none'; drag?: DragInfo; children?: ReactNode;
}) {
  const label = item.hidden ? '背面朝上的牌' : `${item.name}${item.modifiers ?? ''}`;
  const dragProps = drag?.enabled ? {
    draggable: true,
    onDragStart: (e: DragEvent) => { e.dataTransfer.setData('text/x-balatro', `${drag.area}:${drag.index}`); e.dataTransfer.effectAllowed = 'move'; },
    onDragOver: (e: DragEvent) => { if (e.dataTransfer.types.includes('text/x-balatro')) e.preventDefault(); },
    onDrop: (e: DragEvent) => {
      const [area, from] = e.dataTransfer.getData('text/x-balatro').split(':');
      if (area === drag.area) { e.preventDefault(); drag.onMove(Number(from), drag.index); }
    },
  } : {};
  return <div className={`card-slot size-${size} ${selected ? 'selected' : ''} ${active ? 'active' : ''}`} {...dragProps}>
    {price != null && <div className="price-tag">${number(price)}</div>}
    <button className="card" disabled={disabled} onClick={onClick} aria-pressed={selected || active} aria-label={label}>
      <CardFace item={item} back={back} />
    </button>
    {tip !== 'none' && !item.hidden && <Tooltip item={item} placement={tip} />}
    {children && <div className="card-actions">{children}</div>}
  </div>;
}
