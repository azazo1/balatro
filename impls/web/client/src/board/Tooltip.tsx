import type { Item } from '../lib/types';
import { lookup, spriteCss } from '../assets/sprites';
import { usePeek } from './usePeek';

/** 标签图标 + 说明框. 鼠标悬停显示, 触控按住显示. */
export function TagSlot({ tag, placement }: { tag: Item; placement: 'top' | 'right' }) {
  const { peek, handlers } = usePeek();
  return <div className={`tag-slot ${peek ? 'peek' : ''}`} {...handlers}>
    <div className="tag-icon" style={spriteCss(lookup(tag.key)) ?? {}} role="img" aria-label={tag.name} tabIndex={0} />
    <div className={`tooltip tooltip-${placement}`} role="tooltip"><div className="tooltip-title">{tag.name}</div><div className="tooltip-body"><p>{tag.effect}</p></div></div>
  </div>;
}

/** 类别徽章名与颜色, 对照 globals.lua 的 G.C.SECONDARY_SET / RARITY. */
const badges: Record<string, [string, string]> = {
  Joker: ['小丑', '#708b91'], Tarot: ['塔罗牌', '#a782d1'], Planet: ['星球牌', '#13afce'],
  Spectral: ['幻灵牌', '#4584fa'], Voucher: ['优惠券', '#fd682b'], Booster: ['补充包', '#646eb7'],
  Tag: ['标签', '#4f6367'], Back: ['牌组', '#4f6367'], Blind: ['盲注', '#4f6367'],
};

export function badgeOf(item: Item): [string, string] | null {
  if (item.suit) return null;
  if (item.key?.startsWith('bl_')) return badges.Blind;
  if (item.key?.startsWith('tag_')) return badges.Tag;
  return item.category ? badges[item.category] ?? null : null;
}

/** summary::card_modifiers 的格式是 ` (增强, 版本, ...)`. */
export function modifierList(text: string | null | undefined): string[] {
  const inner = text?.trim().replace(/^\(/, '').replace(/\)$/, '') ?? '';
  return inner ? inner.split(', ').filter(Boolean) : [];
}

/** 悬停说明框, 白底圆角, 同原版 generate_card_ui 的布局. */
export function Tooltip({ item, placement = 'top' }: { item: Item; placement?: 'top' | 'bottom' }) {
  const badge = badgeOf(item);
  return <div className={`tooltip tooltip-${placement}`} role="tooltip">
    <div className="tooltip-title">{item.name}</div>
    <div className="tooltip-body">
      {item.effect ? <p>{item.effect}</p> : <p className="dim">没有可见的效果信息</p>}
      {item.current && <p className="tooltip-current">当前: {item.current}</p>}
    </div>
    {(item.modifiers || badge) && <div className="tooltip-badges">
      {badge && <span className="pill" style={{ background: badge[1] }}>{badge[0]}</span>}
      {modifierList(item.modifiers).map(m => <span key={m} className="pill edition">{m}</span>)}
    </div>}
  </div>;
}
