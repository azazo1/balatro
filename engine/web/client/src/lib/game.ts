import type { Action, Item } from './types';

export function randomSeed(): string {
  const alphabet = '123456789ABCDEFGHIJKLMNPQRSTUVWXYZ';
  const bytes = new Uint8Array(32);
  let out = '';
  // 拒绝超出完整区间的字节, 避免取模偏差.
  while (out.length < 8) {
    crypto.getRandomValues(bytes);
    for (const n of bytes) if (n < Math.floor(256 / alphabet.length) * alphabet.length && out.length < 8) out += alphabet[n % alphabet.length];
  }
  return out;
}

export function toggleSelection(selected: number[], index: number): number[] {
  return selected.includes(index) ? selected.filter(i => i !== index) : [...selected, index];
}
export function selectionAction(method: 'play' | 'discard', selected: number[]): Action {
  return { method, params: { cards: [...selected] } };
}
export function reorderAction(area: 'hand' | 'jokers' | 'consumables', length: number, index: number, direction: -1 | 1): Action | null {
  const other = index + direction;
  if (other < 0 || other >= length) return null;
  const order = Array.from({ length }, (_, i) => i);
  [order[index], order[other]] = [order[other], order[index]];
  return { method: 'rearrange', params: { [area]: order } };
}
export function number(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return '-';
  if (Math.abs(value) >= 1e9) return value.toExponential(3);
  return new Intl.NumberFormat('zh-CN', { maximumFractionDigits: 2 }).format(value);
}
export const suitSymbol: Record<string, string> = { Spades: '♠', Hearts: '♥', Clubs: '♣', Diamonds: '♦' };
export const rankSymbol: Record<string, string> = { Two: '2', Three: '3', Four: '4', Five: '5', Six: '6', Seven: '7', Eight: '8', Nine: '9', Ten: '10', Jack: 'J', Queen: 'Q', King: 'K', Ace: 'A' };
export function isRed(card: Item) { return card.suit === 'Hearts' || card.suit === 'Diamonds'; }
export function canSelect(phase: string) { return phase === 'SelectingHand' || phase === 'BoosterOpened' || phase === 'Shop'; }
export const fieldNames: Record<string, string> = {
  dollars: '金钱', chips: '当前得分', hands_left: '剩余出牌', discards_left: '剩余弃牌',
  hands_per_round: '每回合出牌', discards_per_round: '每回合弃牌', hand_size_bonus: '手牌上限加成',
  base_joker_slots: '基础小丑槽位', base_consumable_slots: '基础消耗牌槽位',
  ante: '底注', round: '回合', hand_size: '手牌上限', deck_count: '摸牌堆张数', discard_count: '弃牌堆张数',
  joker_capacity: '小丑容量', consumable_capacity: '消耗牌容量',
};
export const methodNames: Record<string, string> = { start: '开局', select: '选盲注', skip: '跳过', play: '出牌', discard: '弃牌', edit: '修改', buy: '购买', buy_and_use: '买并使用', use: '使用', sell: '出售', pack: '开包', reroll: '刷新', rearrange: '重排', cash_out: '结算', next_round: '下一回合', endless: '无尽', sort_hand_suit: '花色排序', sort_hand_value: '点数排序', reroll_boss: '重掷 Boss' };
