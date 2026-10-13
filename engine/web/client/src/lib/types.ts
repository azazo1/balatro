export type Mode = 'wasm' | 'http';
export interface Opening { seed: string; deck: string; stake: number; profile: string }
export interface Item {
  index?: number; key?: string; name: string; effect: string; category?: string | null;
  hidden?: boolean; token?: string; suit?: string; rank?: string; face_down?: boolean;
  modifiers?: string; current?: string | null; cost?: number; eternal?: boolean;
  enhancement?: string | null; edition?: 'foil' | 'holo' | 'polychrome' | 'negative' | null;
  seal?: 'red' | 'blue' | 'gold' | 'purple' | null; stickers?: string[]; debuffed?: boolean;
}
export interface Blind extends Item { kind: string; status: string; target?: number; reward?: number; tag?: Item | null }
export interface HistoryNode { id: number; parent: number | null; kind: string; label: string; phase: string; ante: number; edited: boolean }
export interface Level { name: string; level: number; chips: number; mult: number; played: number; played_this_round: number }
export interface Observation {
  deck_back: string; phase: string; phase_name: string; won: boolean; win_overlay: boolean;
  stats: Record<string, number>; hand: Item[]; jokers: Item[]; consumables: Item[]; blinds: Blind[];
  shop: { cards: Item[]; vouchers: Item[]; packs: Item[]; reroll_cost: number } | null;
  pack: { name: string; choices_left: number; cards: Item[] } | null;
  levels: Level[]; note: string; last_hand: string | null; dynamics: string; summary: string;
  tags: Item[]; vouchers: Item[]; differences: { field: string; before: number; after: number }[];
  debug: { values: Record<string, number>; digest: string; rng: string; deck: Item[]; discard: Item[] } | null;
}
export interface View {
  version: string; session_id?: string; opening: Opening; revision: number; current: number;
  debug: boolean; edited: boolean; max_nodes: number; history: HistoryNode[]; observation: Observation;
  /** 载入其他引擎构建的存档时的说明. */
  notice?: { message: string; dropped: number } | null;
}
export interface Info { version: string; format_version: number; decks: Item[]; stakes: string[]; max_nodes: number; max_file_bytes: number }
export interface Action { method: string; params: Record<string, unknown> }
export type Command =
  | { kind: 'action'; revision: number; action: Action }
  | { kind: 'jump'; revision: number; node: number }
  | { kind: 'debug'; revision: number; enabled: boolean }
  | { kind: 'edit'; revision: number; changes: Record<string, number> };
export interface Backend {
  info(): Promise<Info>; create(opening: Opening): Promise<View>; observe(): Promise<View>;
  dispatch(command: Command): Promise<View>; restore(file: string): Promise<View>;
  save(): Promise<string>; actions(): Promise<string>; dispose(): void;
}
