import type { Backend, Command, Info, Opening, View } from '../lib/types';
import log from '../lib/log';

export class OperationError extends Error {
  constructor(message: string, public status: number = 500) { super(message); }
}

export class WasmBackend implements Backend {
  private worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' });
  private nextId = 0;
  private pending = new Map<number, { resolve: (value: unknown) => void; reject: (e: Error) => void }>();
  private ready: Promise<Info>;
  constructor() {
    this.worker.onmessage = ({ data }) => {
      const pending = this.pending.get(data.id);
      if (!pending) return;
      this.pending.delete(data.id);
      if (data.error) pending.reject(new OperationError(data.error.error, data.error.status));
      else pending.resolve(data.result);
    };
    this.worker.onerror = (event) => this.fail(new OperationError(`WASM Worker 异常: ${event.message}`));
    this.ready = this.call<Info>('init', new URL('wasm/engine_lab.js', new URL('./', location.href)).href);
    // 防止初始化失败在页面建立错误处理前形成未处理拒绝.
    void this.ready.catch(() => {});
  }
  private fail(error: Error) { for (const p of this.pending.values()) p.reject(error); this.pending.clear(); }
  private call<T>(operation: string, payload?: unknown): Promise<T> {
    return new Promise((resolve, reject) => {
      const id = ++this.nextId;
      this.pending.set(id, { resolve: v => resolve(v as T), reject });
      this.worker.postMessage({ id, operation, payload });
    });
  }
  async info() { return this.ready; }
  async create(opening: Opening) { await this.ready; return this.call<View>('create', opening); }
  async observe() { await this.ready; return this.call<View>('observe'); }
  async dispatch(command: Command) { await this.ready; return this.call<View>('dispatch', command); }
  async restore(file: string) { await this.ready; return this.call<View>('restore', file); }
  async save() { return this.call<string>('save'); }
  async actions() { return this.call<string>('actions'); }
  dispose() { this.worker.terminate(); this.fail(new OperationError('计算后端已关闭')); }
}

export class HttpBackend implements Backend {
  private id = localStorage.getItem('engine-lab-http-id');
  private revision = Number(localStorage.getItem('engine-lab-http-revision')) || 0;
  private async request<T>(path: string, body?: unknown, method = body == null ? 'GET' : 'POST', text = false): Promise<T> {
    const response = await fetch(new URL(`api/v1/${path}`, new URL('./', location.href)), {
      method, headers: body == null ? {} : { 'Content-Type': 'application/json' },
      body: body == null ? undefined : JSON.stringify(body), cache: 'no-store',
    });
    if (!response.ok) {
      let message = `HTTP ${response.status}`;
      try { message = (await response.json()).error ?? message; } catch { /* 框架解析错误不一定是 JSON. */ }
      throw new OperationError(message, response.status);
    }
    return (text ? await response.text() : await response.json()) as T;
  }
  private accept(view: View) {
    if (!view.session_id) throw new OperationError('HTTP 响应缺少会话 ID');
    this.id = view.session_id;
    this.revision = view.revision;
    localStorage.setItem('engine-lab-http-id', this.id);
    localStorage.setItem('engine-lab-http-revision', String(this.revision));
    return view;
  }
  private async replace(operation: () => Promise<View>) {
    const old = this.id, revision = this.revision;
    const view = this.accept(await operation());
    if (old && old !== this.id) {
      try { await this.request(`sessions/${old}`, { revision }, 'DELETE'); }
      catch (error) { log.warn('旧 HTTP 会话未关闭', error); }
    }
    return view;
  }
  async info() { return this.request<Info>('info'); }
  async create(opening: Opening) { return this.replace(() => this.request<View>('sessions', opening)); }
  async restore(file: string) { return this.replace(() => this.request<View>('import', JSON.parse(file))); }
  async observe() {
    if (!this.id) throw new OperationError('没有可恢复的 HTTP 会话', 404);
    return this.accept(await this.request<View>(`sessions/${this.id}`));
  }
  async dispatch(command: Command) {
    if (!this.id) throw new OperationError('当前没有会话', 404);
    return this.accept(await this.request<View>(`sessions/${this.id}/commands`, command));
  }
  async save() { return this.request<string>(`sessions/${this.id}/save`, undefined, 'GET', true); }
  async actions() { return this.request<string>(`sessions/${this.id}/actions`, undefined, 'GET', true); }
  dispose() { /* HTTP 会话保留在服务内, 刷新页面仍可恢复. */ }
}
