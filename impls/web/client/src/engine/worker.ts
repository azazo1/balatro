import log from '../lib/log';
import type { Command, Opening } from '../lib/types';

interface WasmGame {
  observe(): string; dispatch(command: string): string; preview(request: string): string; save(): string; actions(): string; free(): void;
}
interface WasmModule {
  default: () => Promise<unknown>;
  info(): string;
  Game: { new(opening: string): WasmGame; restore(file: string): WasmGame };
}
let wasm: WasmModule | null = null;
let game: WasmGame | null = null;

self.onmessage = async (event: MessageEvent<{ id: number; operation: string; payload?: unknown }>) => {
  const { id, operation, payload } = event.data;
  try {
    let result: unknown;
    if (operation === 'init') {
      const url = String(payload);
      wasm = await import(/* @vite-ignore */ url) as WasmModule;
      await wasm.default();
      result = JSON.parse(wasm.info());
      log.info('WASM 引擎就绪', { version: (result as { version: string }).version });
    } else {
      if (!wasm) throw new Error('WASM 尚未加载');
      if (operation === 'create' || operation === 'restore') {
        const start = performance.now();
        log.info(operation === 'restore' ? '开始重建会话' : '新建对局');
        const candidate = operation === 'create' ? new wasm.Game(JSON.stringify(payload as Opening)) : wasm.Game.restore(String(payload));
        // 全部成功后才释放旧会话.
        game?.free();
        game = candidate;
        result = JSON.parse(game.observe());
        log.info('会话准备完成', { ms: Math.round(performance.now() - start) });
      } else {
        if (!game) throw new Error('当前没有会话');
        switch (operation) {
          case 'observe': result = JSON.parse(game.observe()); break;
          case 'dispatch': {
            const command = payload as Command;
            log.info('对局操作', { kind: command.kind, revision: command.revision });
            result = JSON.parse(game.dispatch(JSON.stringify(command)));
            break;
          }
          case 'preview': result = JSON.parse(game.preview(JSON.stringify(payload))); break;
          case 'save': result = game.save(); break;
          case 'actions': result = game.actions(); break;
          default: throw new Error('未知 Worker 操作');
        }
      }
    }
    self.postMessage({ id, result });
  } catch (e) {
    let error = { status: 500, error: e instanceof Error ? e.message : String(e) };
    if (typeof e === 'string') { try { error = JSON.parse(e); } catch { /* 保留原错误. */ } }
    log.error('WASM 操作失败', error);
    self.postMessage({ id, error });
  }
};
