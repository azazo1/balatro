import { describe, expect, it } from 'vitest';
import { selectionAction, toggleSelection, moveAction, canSelect, parseReport } from './game';
import { lookup, soulOf, spriteCss, type Manifest } from '../assets/sprites';
import { modifierList } from '../board/Tooltip';

describe('局面操作参数', () => {
  it('保留 0-based 选择顺序并创建独立动作数组', () => {
    const selected = toggleSelection(toggleSelection([], 0), 3);
    const action = selectionAction('play', selected);
    selected.push(4);
    expect(action.params.cards).toEqual([0, 3]);
    expect(toggleSelection([0, 3], 0)).toEqual([3]);
  });
  it('拖拽移动生成 order[新位置]=原下标 的完整置换', () => {
    // 把第 0 张拖到第 2 位: 新顺序是 原1, 原2, 原0.
    expect(moveAction('hand', 4, 0, 2)).toEqual({ method: 'rearrange', params: { hand: [1, 2, 0, 3] } });
    expect(moveAction('jokers', 3, 2, 0)).toEqual({ method: 'rearrange', params: { jokers: [2, 0, 1] } });
    expect(moveAction('hand', 3, 1, 1)).toBeNull();
    expect(moveAction('consumables', 2, 0, 2)).toBeNull();
    expect(canSelect('SelectingHand')).toBe(true);
    expect(canSelect('GameOver')).toBe(false);
  });
  it('计分报告取最后一步的筹码与倍率', () => {
    const report = '同花 Lv2 = 1,200\n出牌: [0]红桃A*\n基础 50x5\n小丑 | +4 倍率 | 60x9\n= 1,200';
    expect(parseReport(report)).toEqual({ hand: '同花', level: 2, total: '1,200', chips: '60', mult: '9' });
    expect(parseReport('一对 = 20\n基础 10x2\n= 20')?.mult).toBe('2');
    expect(parseReport(null)).toBeNull();
  });
  it('修饰文本按 summary::card_modifiers 的格式拆分', () => {
    expect(modifierList(' (倍率牌, 易腐 5 回合)')).toEqual(['倍率牌', '易腐 5 回合']);
    expect(modifierList('')).toEqual([]);
  });
});

describe('原版贴图定位', () => {
  const data: Manifest = {
    format_version: 1, stakes: [],
    atlases: { Joker: { file: 'Jokers.png', w: 71, h: 95, cols: 10, rows: 16 }, centers: { file: 'Enhancers.png', w: 71, h: 95, cols: 7, rows: 5 } },
    sprites: { j_joker: { a: 'Joker', x: 0, y: 0 }, j_hologram: { a: 'Joker', x: 4, y: 12, soul: [2, 9] }, c_soul: { a: 'Joker', x: 9, y: 15, soul: [0, 1, 'centers'] } },
  };
  it('按网格百分比取格, 魂层可跨图集', () => {
    expect(spriteCss(lookup('j_joker', data), data)?.backgroundPosition).toBe('0% 0%');
    expect(spriteCss(lookup('j_hologram', data), data)?.backgroundSize).toBe('1000% 1600%');
    expect(spriteCss({ atlas: 'Joker', x: 9, y: 15 }, data)?.backgroundPosition).toBe('100% 100%');
    expect(soulOf('j_hologram', data)).toEqual({ atlas: 'Joker', x: 2, y: 9 });
    expect(soulOf('c_soul', data)?.atlas).toBe('centers');
    expect(lookup('j_missing', data)).toBeNull();
    expect(spriteCss(null, data)).toBeNull();
  });
});
