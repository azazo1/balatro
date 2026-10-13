import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react';
import type { Action, Backend, Info, Mode, Opening, View } from './lib/types';
import { HttpBackend, OperationError, WasmBackend } from './engine/backend';
import { download, readAutosave, writeAutosave } from './lib/storage';
import { toggleSelection } from './lib/game';
import log from './lib/log';
import { loadSprites, lookup, spriteCss } from './assets/sprites';
import { NewGame } from './ui/NewGame';
import { Hud } from './board/Hud';
import { Board } from './board/Board';
import { DebugPanel } from './debug/DebugPanel';
import { nextNode } from './debug/HistoryTree';
import { useStageScale } from './ui/useStageScale';
import { SidebarResizer, useSidebarWidth } from './ui/SidebarResizer';

export function App() {
  const [mode, setMode] = useState<Mode>(localStorage.getItem('engine-lab-mode') === 'http' ? 'http' : 'wasm');
  const [info, setInfo] = useState<Info | null>(null);
  const [view, setView] = useState<View | null>(null);
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState('');
  const [status, setStatus] = useState('正在加载引擎');
  const [selected, setSelected] = useState<number[]>([]);
  const [newGame, setNewGame] = useState(false);
  const [pendingFile, setPendingFile] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);
  const [sidebar, setSidebar] = useState(localStorage.getItem('engine-lab-sidebar') !== 'off');
  const [spritesReady, setSpritesReady] = useState(false);
  const backend = useRef<Backend | null>(null);
  const current = useRef<View | null>(null);
  const flight = useRef(false);
  const transfer = useRef<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const stage = useRef<HTMLDivElement>(null);
  useStageScale(stage);
  const [sidebarWidth, setSidebarWidth] = useSidebarWidth();

  useEffect(() => { void loadSprites().then(() => setSpritesReady(true)); }, []);
  useEffect(() => { localStorage.setItem('engine-lab-sidebar', sidebar ? 'on' : 'off'); }, [sidebar]);
  // 错误弹条几秒后自动消失.
  useEffect(() => { if (!error) return; const t = setTimeout(() => setError(''), 6000); return () => clearTimeout(t); }, [error]);

  function accept(next: View) {
    current.current = next; setView(next); setSelected([]); setDirty(true);
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
    setView(null); current.current = null; setSelected([]);
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
    if (flight.current || !backend.current) return false;
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
  const command = (build: (revision: number) => Parameters<Backend['dispatch']>[0], label: string) => {
    const revision = current.current?.revision;
    if (revision != null) void run(b => b.dispatch(build(revision)), label);
  };
  const act = (action: Action) => command(revision => ({ kind: 'action', revision, action }), '正在执行动作');
  const jump = (node: number) => command(revision => ({ kind: 'jump', revision, node }), `正在恢复节点 #${node}`);
  const debug = (enabled: boolean) => command(revision => ({ kind: 'debug', revision, enabled }), '正在切换调试模式');
  const edit = (changes: Record<string, number>) => command(revision => ({ kind: 'edit', revision, changes }), '正在记录状态修改');

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
  function start(opening: Opening) { void run(b => b.create(opening), '正在创建对局').then(ok => { if (ok) setNewGame(false); }); }

  // 快捷键: 焦点在输入控件里时不生效, 打开对话框时也不生效.
  const onKey = useCallback((e: KeyboardEvent) => {
    const target = e.target as HTMLElement | null;
    if (target && (target.closest('input, textarea, select, [contenteditable=true]') || target.closest('[role=dialog]'))) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const v = current.current;
    const key = e.key.toLowerCase();
    if (key === 'd') { e.preventDefault(); setSidebar(s => !s); return; }
    if (!v || flight.current) return;
    const node = v.history[v.current];
    if ((key === 'z' || key === 'backspace') && node?.parent != null) { e.preventDefault(); jump(node.parent); }
    else if (key === 'x') {
      const next = nextNode(v);
      if (next != null) { e.preventDefault(); jump(next); }
    } else if (key === 'enter' && v.observation.phase === 'SelectingHand' && selected.length > 0) {
      e.preventDefault(); act({ method: e.shiftKey ? 'discard' : 'play', params: { cards: [...selected] } });
    } else if (key === 'escape') setSelected([]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selected]);
  useEffect(() => { window.addEventListener('keydown', onKey); return () => window.removeEventListener('keydown', onKey); }, [onKey]);

  const toggle = (i: number) => setSelected(old => old.includes(i) || old.length < 5 ? toggleSelection(old, i) : old);
  const deckName = view ? info?.decks.find(d => d.key === view.opening.deck)?.name ?? view.opening.deck : '';
  const menu = <>
    <div className="run-info">
      {view && <><span className="seed" title="种子">{view.opening.seed}</span><span>{deckName} · 赌注 {view.opening.stake}</span>{view.edited && <span className="pill warn">调试路径</span>}</>}
    </div>
    <div className="menu-buttons">
      <button className="btn orange small" disabled={busy || !info} onClick={() => setNewGame(true)}>新局</button>
      <button className="btn orange small" disabled={busy} onClick={() => fileInput.current?.click()}>载入</button>
      <button className="btn orange small" disabled={busy || !view} onClick={() => void exportFile()} title="下载全部分支会话文件">保存</button>
      <button className="btn orange small" disabled={busy || !view || view.edited} onClick={() => void exportFile(true)} title="导出 .actions.jsonl, 供 just play 使用">动作</button>
      <button className="btn grey small" disabled={busy} onClick={() => void switchMode(mode === 'wasm' ? 'http' : 'wasm')} title="切换计算后端, 会复制当前会话">{mode === 'wasm' ? 'WASM' : 'HTTP'}</button>
      <button className="btn grey small" aria-pressed={sidebar} onClick={() => setSidebar(s => !s)} title="快捷键 D">调试栏</button>
    </div>
  </>;

  return <div className={`app ${sidebar && view ? 'with-sidebar' : ''}`} data-sprites={spritesReady ? 'ready' : 'loading'}
    style={{ '--sidebar-w': `${sidebarWidth}px` } as CSSProperties}>
    <div className="stage-wrap">
      <div className="stage" ref={stage}>
        {view ? <>
          <Hud view={view} actions={menu} />
          <Board view={view} busy={busy} selected={selected} toggle={toggle} act={act} />
        </> : <div className="welcome">
          <div className="logo" style={spriteCss(lookup('logo')) ?? {}} role="img" aria-label="Balatro" />
          <p className="welcome-sub">引擎对局调试台 · 每一步都可回溯与分支</p>
          <div className="welcome-buttons">
            <button className="btn blue big" disabled={busy || !info} onClick={() => setNewGame(true)}>开始</button>
            <button className="btn orange big" disabled={busy} onClick={() => fileInput.current?.click()}>载入</button>
            <button className="btn grey big" disabled={busy} onClick={() => void backupAutosave()}>备份存档</button>
          </div>
          <p className="dim">{status}</p>
        </div>}
        {busy && <div className="busy" role="status" aria-label={status}><span className="spinner" /></div>}
        {error && <div className="alert" role="alert"><span>{error}</span><button onClick={() => setError('')} aria-label="关闭错误提示">×</button></div>}
      </div>
    </div>
    {sidebar && view && <DebugPanel view={view} busy={busy} jump={jump} debug={debug} edit={edit} />}
    {sidebar && view && <SidebarResizer width={sidebarWidth} setWidth={setSidebarWidth} />}
    <footer className="status-bar"><span className={`dot ${error ? 'failed' : ''}`} />{status}
      <span className="keys">Z 上一步 · X 下一步 · Enter 出牌 · Shift+Enter 弃牌 · D 调试栏</span>
      <span>{mode === 'wasm' ? '浏览器本地引擎' : '本地 Rust 服务'} · {info?.version ?? '加载中'}</span></footer>
    <input ref={fileInput} type="file" accept=".json,application/json" hidden onChange={e => { void chooseFile(e.target.files?.[0]); e.target.value = ''; }} />
    {newGame && <NewGame info={info} initial={view?.opening} busy={busy} replacing={!!view} onStart={start} onClose={view ? () => setNewGame(false) : undefined} />}
    {pendingFile != null && <div className="modal-backdrop"><section className="modal panel-box" role="dialog" aria-modal="true" aria-labelledby="load-title">
      <h2 id="load-title" className="modal-title">载入会话</h2>
      <p>验证全部节点后替换当前会话. 文件无效时保留原局.</p>
      {view && <p className="hint warn">当前全部分支会被替换, 如需保留请先保存.</p>}
      <div className="modal-actions">
        <button className="btn grey" disabled={busy} onClick={() => setPendingFile(null)}>取消</button>
        <button className="btn blue big" disabled={busy || !info} onClick={() => { const text = pendingFile; void run(b => b.restore(text), '正在验证并重建全部分支').then(ok => { if (ok) setPendingFile(null); }); }}>确认载入</button>
      </div>
    </section></div>}
  </div>;
}
