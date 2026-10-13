import type { CSSProperties } from 'react';
import log from '../lib/log';

/** 由 scripts/engine_web_assets.py 从 game/game.lua 生成的贴图清单. */
export interface Atlas { file: string; w: number; h: number; cols: number; rows: number }
export interface SpriteEntry { a: string; x: number; y: number; soul?: [number, number] | [number, number, string]; colour?: string }
export interface Manifest { format_version: number; atlases: Record<string, Atlas>; stakes: string[]; sprites: Record<string, SpriteEntry> }
export interface SpriteRef { atlas: string; x: number; y: number }

const EMPTY: Manifest = { format_version: 1, atlases: {}, stakes: [], sprites: {} };
let manifest: Manifest = EMPTY;

/** 注册原版像素字体; 失败时回退到系统字体. */
async function loadFont() {
  try {
    const face = new FontFace('m6x11', `url("${new URL('game/m6x11plus.ttf', new URL('./', location.href)).href}")`);
    document.fonts.add(await face.load());
  } catch (e) { log.warn('原版字体加载失败, 使用系统字体', e); }
}

export async function loadSprites(): Promise<void> {
  void loadFont();
  try {
    const response = await fetch(new URL('game/sprites.json', new URL('./', location.href)));
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json() as Manifest;
    if (data.format_version !== 1) throw new Error(`不支持的贴图清单版本 ${data.format_version}`);
    manifest = data;
    log.info('原版贴图清单已加载', { sprites: Object.keys(data.sprites).length });
  } catch (e) {
    // 没有贴图时退回文字卡, 页面仍可使用.
    log.warn('原版贴图清单加载失败, 使用文字卡', e);
  }
}
export function sprites(): Manifest { return manifest; }

/** 物品自身的贴图位置. */
export function lookup(key: string | undefined, data: Manifest = manifest): SpriteRef | null {
  const entry = key ? data.sprites[key] : undefined;
  return entry ? { atlas: entry.a, x: entry.x, y: entry.y } : null;
}
/** 魂层 (传奇小丑与灵魂牌), 第三项是图集名, 缺省与本体同图集. */
export function soulOf(key: string | undefined, data: Manifest = manifest): SpriteRef | null {
  const entry = key ? data.sprites[key] : undefined;
  if (!entry?.soul) return null;
  return { atlas: entry.soul[2] ?? entry.a, x: entry.soul[0], y: entry.soul[1] };
}
export function colourOf(key: string | undefined): string | undefined { return key ? manifest.sprites[key]?.colour : undefined; }

/** 按百分比定位, 元素尺寸任意都能正确取格. */
export function spriteCss(ref: SpriteRef | null, data: Manifest = manifest): CSSProperties | null {
  const atlas = ref ? data.atlases[ref.atlas] : undefined;
  if (!ref || !atlas) return null;
  const px = atlas.cols > 1 ? (ref.x / (atlas.cols - 1)) * 100 : 0;
  const py = atlas.rows > 1 ? (ref.y / (atlas.rows - 1)) * 100 : 0;
  return {
    backgroundImage: `url("game/${atlas.file}")`,
    backgroundSize: `${atlas.cols * 100}% ${atlas.rows * 100}%`,
    backgroundPosition: `${px}% ${py}%`,
  };
}
