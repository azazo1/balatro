import { useEffect, useRef, useState } from 'react';
import type { Action, Backend, Info, Item, Mode, Opening, View } from './lib/types';
import { HttpBackend, OperationError, WasmBackend } from './engine/backend';
import { download, readAutosave, writeAutosave } from './lib/storage';
import { toggleSelection } from './lib/game';
import log from './lib/log';
import { NewGame } from './components/NewGame';
import { History } from './components/History';
import { Table } from './components/Table';
import { Inspector } from './components/Inspector';

export function App() {
  const [mode, setMode] = useState<Mode>(localStorage.getItem('engine-lab-mode') === 'http' ? 'http' : 'wasm');
  const [info, setInfo] = useState<Info | null>(null);
  const [view, setView] = useState<View | null>(null);
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState('');
  const [status, setStatus] = useState('正在加载引擎');
  const [selected, setSelected] = useState<number[]>([]);
  const [inspected, setInspected] = useState<Item | null>(null);
  const [newGame, setNewGame] = useState(false);
  const [pendingFile, setPendingFile] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);
  const [sides, setSides] = useState({ history: true, inspector: true });
  const backend = useRef<Backend | null>(null);
  const current = useRef<View | null>(null);
  const flight = useRef(false);
  const transfer = useRef<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  function accept(next: View) {
    current.current = next; setView(next); setSelected([]); setInspected(null); setDirty(true);
  }
  async function autosave(instance: Backend, activeMode: Mode) {
    try { await writeAutosave(activeMode, await instance.save()); setStatus('全部分支已自动保存在此浏览器'); }
    catch (e) { setStatus('自动保存失败, 请立即下载会话文件'); log.error('自动存档失败', e); }
  }

  useEffect(() => {
    let alive = true;
    const instance: Backend = mode === 'wasm' ? new WasmBackend() : new HttpBackend();
    backend.current = instance;
    flight.current = true; setBusy(true); setInfo(null); setError(''); setNewGame(false);
    setView(null); current.current = null; setSelected([]); setInspected(null);
    setStatus(mode === 'wasm' ? '正在加载浏览器本地引擎' : '正在连接本地 HTTP 服务');
    localStorage.setItem('engine-lab-mode', mode);
    void (async () => {
      try {
        const capabilities = await instance.info();
        if (!alive) return;
        setInfo(capabilities);
        let restored: View | null = null;
        const incoming = transfer.current;
        transfer.current = null;
        if (incoming) restored = await instance.restore(incoming);
        else {
          if (mode === 'http') { try { restored = await instance.observe(); } catch (e) { if (!(e instanceof OperationError) || e.status !== 404) throw e; } }
          if (!restored) {
            const saved = await readAutosave(mode);
            if (saved) restored = await instance.restore(saved.file);
          }
        }
        if (!alive) return;
        if (restored) { accept(restored); await autosave(instance, mode); }
        else { setNewGame(true); setStatus('引擎就绪, 选择配置开始对局'); }
      } catch (e) {
        if (!alive) return;
        setError(`${e instanceof Error ? e.message : String(e)}${mode === 'http' ? '. HTTP 模式需要通过本地服务打开页面, 也可以切回 WASM.' : '. 请确认 WASM 产物已构建且页面通过静态 HTTP 服务打开.'}`);
        setStatus('初始化未完成'); log.error('引擎初始化失败', e);
      } finally { if (alive) { flight.current = false; setBusy(false); } }
    })();
    return () => { alive = false; instance.dispose(); };
  }, [mode]);

  useEffect(() => {
    const warn = (event: BeforeUnloadEvent) => { if (dirty) { event.preventDefault(); event.returnValue = ''; } };
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, [dirty]);

  async function run(operation: (instance: Backend) => Promise<View>, label: string) {
    if (flight.current || !backend.current) return;
    flight.current = true; setBusy(true); setError(''); setStatus(label);
    const instance = backend.current;
    try { const next = await operation(instance); accept(next); await autosave(instance, mode); return true; }
    catch (e) {
      log.warn('操作被拒绝', e); setError(e instanceof Error ? e.message : String(e)); setStatus('操作未提交, 可以调整后重试');
      if (e instanceof OperationError && e.status === 409) {
        try { accept(await instance.observe()); await autosave(instance, mode); setStatus('已获取最新局面, 请重新选择目标'); }
        catch (refreshError) { log.error('冲突后刷新失败', refreshError); }
      }
      return false;
    } finally { flight.current = false; setBusy(false); }
  }
  function act(action: Action) { const revision = current.current?.revision; if (revision != null) void run(b => b.dispatch({ kind: 'action', revision, action }), '正在执行动作'); }
  function jump(node: number) { const revision = current.current?.revision; if (revision != null) void run(b => b.dispatch({ kind: 'jump', revision, node }), `正在恢复节点 #${node}`); }
  function debug(enabled: boolean) { const revision = current.current?.revision; if (revision != null) void run(b => b.dispatch({ kind: 'debug', revision, enabled }), '正在切换调试模式'); }
  function edit(changes: Record<string, number>) { const revision = current.current?.revision; if (revision != null) void run(b => b.dispatch({ kind: 'edit', revision, changes }), '正在记录状态修改'); }
  async function exportFile(actions = false) {
    if (flight.current || !backend.current || !view) return;
    flight.current = true; setBusy(true); setError('');
    try {
      const text = actions ? await backend.current.actions() : await backend.current.save();
      download(`${view.opening.seed}-${view.current}.${actions ? 'actions.jsonl' : 'session.json'}`, text, actions ? 'application/x-ndjson' : 'application/json');
      if (!actions) setDirty(false);
      setStatus(actions ? '已导出当前正常路径动作' : '已下载全部分支会话文件');
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { flight.current = false; setBusy(false); }
  }
  async function switchMode(next: Mode) {
    if (next === mode || flight.current) return;
    flight.current = true; setBusy(true); setError('');
    try { transfer.current = view && backend.current ? await backend.current.save() : null; setMode(next); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); flight.current = false; setBusy(false); }
  }
  async function chooseFile(file: File | undefined) {
    if (!file) return;
    if (file.size > (info?.max_file_bytes ?? 10 * 1024 * 1024)) { setError('会话文件超过 10 MiB'); return; }
    try { setPendingFile(await file.text()); } catch (e) { setError(String(e)); }
  }
  async function backupAutosave() {
    try { const saved = await readAutosave(mode); if (saved) download('engine-lab-autosave.session.json', saved.file); else setError('此模式没有自动存档'); }
    catch (e) { setError(String(e)); }
  }
  function start(opening: Opening) { void run(b => b.create(opening), '正在创建对局').then(success => { if (success) setNewGame(false); }); }
  return <div className="app">
    <header className="app-header"><div className="brand"><span className="brand-icon">B</span><div><strong>ENGINE LAB</strong><small>Balatro / 对局调试台</small></div></div>
      <div className="header-session">{view ? <><code>{view.opening.seed}</code><span>{info?.decks.find(d => d.key === view.opening.deck)?.name ?? view.opening.deck}</span><span>赌注 {view.opening.stake}</span>{view.edited && <span className="badge edited">调试路径</span>}</> : <span className="muted">配置 / 对局 / 回溯 / 分支</span>}</div>
      <div className="header-actions"><select aria-label="计算模式" value={mode} disabled={busy} onChange={e => void switchMode(e.target.value as Mode)}><option value="wasm">WASM / 浏览器本地</option><option value="http">HTTP / 本地服务</option></select><button disabled={busy || !info} onClick={() => setNewGame(true)}>新局</button><button disabled={busy || !view} onClick={() => void exportFile()}>保存会话</button><button disabled={busy} onClick={() => fileInput.current?.click()}>载入</button></div>
      <input ref={fileInput} type="file" accept=".json,application/json" hidden onChange={e => { void chooseFile(e.target.files?.[0]); e.target.value = ''; }} />
    </header>
    <div className="toolbar"><div><button aria-pressed={sides.history} onClick={() => setSides({ ...sides, history: !sides.history })}>历史面板</button><button aria-pressed={sides.inspector} onClick={() => setSides({ ...sides, inspector: !sides.inspector })}>检查器</button><button disabled={busy || !view} onClick={() => void run(b => b.observe(), '正在刷新局面')}>刷新局面</button><button disabled={busy || !view || view.edited} onClick={() => void exportFile(true)}>导出动作</button></div><label className={`debug-toggle ${view?.debug ? 'enabled' : ''}`}><input type="checkbox" checked={view?.debug ?? false} disabled={busy || !view} onChange={e => debug(e.target.checked)} />调试模式</label></div>
    {error && <div className="error-banner" role="alert"><span>{error}</span><button onClick={() => setError('')} aria-label="关闭错误提示">×</button></div>}
    {busy && <div className="busy-banner" role="status"><span className="spinner" />{status}</div>}
    {view ? <div className={`workspace ${sides.history ? '' : 'no-history'} ${sides.inspector ? '' : 'no-inspector'}`}>
      {sides.history && <History view={view} busy={busy} jump={jump} />}
      <Table view={view} busy={busy} selected={selected} toggle={i => setSelected(old => old.includes(i) || old.length < 5 ? toggleSelection(old, i) : old)} clear={() => setSelected([])} act={act} inspect={setInspected} />
      {sides.inspector && <Inspector view={view} inspected={inspected} busy={busy} edit={edit} enableDebug={() => debug(true)} />}
    </div> : <main className="welcome"><div className="eyebrow">LOCAL / DETERMINISTIC / BRANCHABLE</div><h1>看清每一步.<br />尝试每一条路线.</h1><p>选择种子与规则配置, 在引擎中进行对局.<br />没有等待动画, 不丢弃历史, 随时回到分歧点.</p><button className="primary" disabled={busy || !info} onClick={() => setNewGame(true)}>配置新对局</button><button disabled={busy} onClick={() => void backupAutosave()}>备份已有自动存档</button></main>}
    <footer className="app-footer"><span className={`status-dot ${error ? 'failed' : ''}`} /><span>{status}</span><span className="footer-mode">{mode === 'wasm' ? '规则在浏览器本地运行' : '计算在本地 Rust 服务运行'} / {info?.version ?? '加载中'}</span></footer>
    {newGame && <><NewGame info={info} initial={view?.opening} busy={busy} onStart={start} onClose={() => setNewGame(false)} />{view && <div className="replace-notice">开始新局会替换当前会话. 未下载的路线请先取消并保存.</div>}</>}
    {pendingFile != null && <div className="modal-backdrop"><section className="modal" role="dialog" aria-modal="true"><h2>载入会话文件</h2><p>验证全部节点后替换当前会话. 文件无效时保留原局.</p>{view && <p className="warning">当前全部分支会被替换. 如需保留, 请先保存会话.</p>}<div className="modal-actions"><button disabled={busy} onClick={() => setPendingFile(null)}>取消</button><button className="primary" disabled={busy || !info} onClick={() => { const text = pendingFile; void run(b => b.restore(text), '正在验证并重建全部分支').then(success => { if (success) setPendingFile(null); }); }}>确认载入</button></div></section></div>}
  </div>;
}
