import { describe, expect, it } from 'vitest';
import { selectionAction, toggleSelection, reorderAction, canSelect } from './game';

describe('局面操作参数', () => {
  it('保留 0-based 选择顺序并创建独立动作数组', () => {
    const selected = toggleSelection(toggleSelection([], 0), 3);
    const action = selectionAction('play', selected);
    selected.push(4);
    expect(action.params.cards).toEqual([0, 3]);
    expect(toggleSelection([0, 3], 0)).toEqual([3]);
  });
  it('区域重排生成完整置换且拒绝越界移动', () => {
    expect(reorderAction('jokers', 3, 1, -1)).toEqual({ method: 'rearrange', params: { jokers: [1, 0, 2] } });
    expect(reorderAction('hand', 3, 0, -1)).toBeNull();
    expect(reorderAction('consumables', 3, 2, 1)).toBeNull();
    expect(canSelect('SelectingHand')).toBe(true);
    expect(canSelect('GameOver')).toBe(false);
  });
});
