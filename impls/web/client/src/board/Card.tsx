import type { CSSProperties, ReactNode, SyntheticEvent } from 'react';
import { useCardDrag, type DragInfo } from './useCardDrag';
import type { Item } from '../lib/types';
import { lookup, soulOf, spriteCss } from '../assets/sprites';
import { number } from '../lib/game';
import { Tooltip } from './Tooltip';
import { usePeek } from './usePeek';

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

export type { DragInfo };

type Handlers = Record<string, ((e: never) => void) | undefined>;
/** 合并两组事件处理器, 同名事件依次调用. 拖动与按住说明都听指针事件. */
function merge(a: Handlers, b: Handlers): Handlers {
  const out: Handlers = { ...a };
  for (const [name, fn] of Object.entries(b)) {
    const first = out[name];
    out[name] = first && fn ? (e: never) => { first(e); if (!(e as SyntheticEvent).isPropagationStopped()) fn(e); } : fn ?? first;
  }
  return out;
}

export function Card({ item, back, size = 'md', selected = false, active = false, disabled = false, price, onClick, tip = 'top', drag, children, overlay, mark = '' }: {
  item: Item; back: string; size?: CardSize; selected?: boolean; active?: boolean; disabled?: boolean; price?: number;
  onClick?: () => void; tip?: 'top' | 'bottom' | 'none'; drag?: DragInfo; children?: ReactNode;
  /** 计分预览的飘字等, 叠在牌上方. */
  overlay?: ReactNode;
  /** 计分预览标记: scoring 参与计分, idle 打出但不计分, firing 正在触发. */
  mark?: string;
}) {
  const label = item.hidden ? '背面朝上的牌' : `${item.name}${item.modifiers ?? ''}`;
  // 拖动排序 (鼠标与触控通用) + 触控按住显示说明框; 鼠标的说明框仍走 CSS 悬停.
  const dragging = useCardDrag(drag);
  const { peek, handlers } = usePeek();
  const moving = dragging.offset != null;
  const style = moving ? { translate: `${dragging.offset!.x}px ${dragging.offset!.y}px` } : undefined;
  return <div className={`card-slot size-${size} ${selected ? 'selected' : ''} ${active ? 'active' : ''} ${peek && !moving ? 'peek' : ''} ${moving ? 'moving' : ''} ${drag?.enabled ? 'movable' : ''} ${mark}`}
    style={style} {...dragging.attrs} {...merge(dragging.handlers as Handlers, handlers as Handlers)}>
    {price != null && <div className="price-tag">${number(price)}</div>}
    {overlay}
    <button className="card" disabled={disabled} onClick={onClick} aria-pressed={selected || active} aria-label={label}>
      <CardFace item={item} back={back} />
    </button>
    {tip !== 'none' && !item.hidden && <Tooltip item={item} placement={tip} />}
    {children && <div className="card-actions">{children}</div>}
  </div>;
}
