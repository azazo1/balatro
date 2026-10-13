import { useMemo, useState } from 'react';
import type { HistoryNode, View } from '../lib/types';
import { methodNames } from '../lib/game';

export function History({ view, busy, jump }: { view: View; busy: boolean; jump: (node: number) => void }) {
  const [target, setTarget] = useState('0');
  const nodes = view.history;
  const current = nodes[view.current];
  const children = useMemo(() => {
    const map = new Map<number, HistoryNode[]>();
    for (const node of nodes) if (node.parent != null) {
      const siblings = map.get(node.parent);
      if (siblings) siblings.push(node); else map.set(node.parent, [node]);
    }
    return map;
  }, [nodes]);
  const rows = useMemo(() => {
    const stack = [{ node: nodes[0], depth: 0 }];
    const result: { node: HistoryNode; depth: number }[] = [];
    while (stack.length) {
      const next = stack.pop()!; result.push(next);
      for (const child of [...(children.get(next.node.id) ?? [])].reverse()) stack.push({ node: child, depth: next.depth + 1 });
    }
    return result;
  }, [nodes, children]);
  const path = new Set<number>();
  let node: HistoryNode | undefined = current;
  while (node) { path.add(node.id); node = node.parent == null ? undefined : nodes[node.parent]; }
  const forward = children.get(view.current) ?? [];
  return <aside className="history panel">
    <div className="panel-title"><h2>历史与分支</h2><span className="badge">{nodes.length} / {view.max_nodes}</span></div>
    <div className="history-toolbar"><button disabled={busy || view.current === 0} onClick={() => jump(0)}>开局</button><button disabled={busy || current.parent == null} onClick={() => current.parent != null && jump(current.parent)}>上一步</button></div>
    {forward.length > 0 && <label className="forward-label">前进路线<select aria-label="前进路线" value="" disabled={busy} onChange={e => jump(Number(e.target.value))}><option value="">选择下一步 ({forward.length})</option>{forward.map(n => <option key={n.id} value={n.id}>#{n.id} {methodNames[n.kind] ?? n.kind}</option>)}</select></label>}
    <div className="input-row jump-input"><input aria-label="历史节点编号" type="number" min="0" max={nodes.length - 1} value={target} onChange={e => setTarget(e.target.value)} /><button disabled={busy || !Number.isInteger(Number(target)) || Number(target) < 0 || Number(target) >= nodes.length} onClick={() => jump(Number(target))}>跳转</button></div>
    <p className="muted small">从历史节点继续操作会创建新分支, 不覆盖原路线.</p>
    {nodes.length >= view.max_nodes * 0.9 && <p className="warning">历史接近上限, 请导出保存.</p>}
    <div className="history-list" role="list" aria-label="历史节点">{rows.map(({ node: n, depth }) => <button role="listitem" key={n.id} disabled={busy} className={`history-node ${n.id === view.current ? 'current' : ''} ${path.has(n.id) ? 'on-path' : ''}`} style={{ paddingLeft: `${12 + Math.min(depth, 10) * 9}px` }} onClick={() => jump(n.id)} title={n.label}>
      <div><span className="node-dot" /><strong>#{n.id}</strong> {methodNames[n.kind] ?? n.kind}{n.edited && <span className="edit-dot" title="路径含调试修改">D</span>}</div>
      <small>{n.phase} / 底注 {n.ante}</small><span className="node-label">{n.label}</span>
      {(children.get(n.id)?.length ?? 0) > 1 && <small className="branch-count">{children.get(n.id)!.length} 条分支</small>}
    </button>)}</div>
  </aside>;
}
