import { useEffect, useMemo, useRef } from 'react';
import type { HistoryNode, View } from '../lib/types';
import { methodNames } from '../lib/game';

/** 节点的子节点表与当前路径, 供树与快捷键共用. */
export function useTree(view: View) {
  const nodes = view.history;
  const children = useMemo(() => {
    const map = new Map<number, HistoryNode[]>();
    for (const node of nodes) if (node.parent != null) {
      const list = map.get(node.parent);
      if (list) list.push(node); else map.set(node.parent, [node]);
    }
    return map;
  }, [nodes]);
  const path = useMemo(() => {
    const set = new Set<number>();
    let node: HistoryNode | undefined = nodes[view.current];
    while (node) { set.add(node.id); node = node.parent == null ? undefined : nodes[node.parent]; }
    return set;
  }, [nodes, view.current]);
  return { nodes, children, path };
}

export function HistoryTree({ view, busy, jump }: { view: View; busy: boolean; jump: (node: number) => void }) {
  const { nodes, children, path } = useTree(view);
  const current = nodes[view.current];
  const rows = useMemo(() => {
    const stack = [{ node: nodes[0], depth: 0 }];
    const result: { node: HistoryNode; depth: number }[] = [];
    while (stack.length) {
      const next = stack.pop()!; result.push(next);
      for (const child of [...(children.get(next.node.id) ?? [])].reverse()) stack.push({ node: child, depth: next.depth + 1 });
    }
    return result;
  }, [nodes, children]);
  const forward = children.get(view.current) ?? [];
  const list = useRef<HTMLDivElement>(null);
  // 当前节点保持在可见区域.
  useEffect(() => { list.current?.querySelector('.current')?.scrollIntoView({ block: 'nearest' }); }, [view.current]);
  return <div className="history">
    <div className="history-nav">
      <button className="btn grey small" disabled={busy || view.current === 0} onClick={() => jump(0)} title="回到开局">开局</button>
      <button className="btn blue small" disabled={busy || current.parent == null} onClick={() => current.parent != null && jump(current.parent)} title="快捷键 Z">上一步</button>
      <button className="btn blue small" disabled={busy || forward.length === 0} onClick={() => forward[0] && jump(forward[0].id)} title="快捷键 X">下一步{forward.length > 1 && ` (${forward.length})`}</button>
    </div>
    <div className="history-meta"><span>{nodes.length} / {view.max_nodes} 节点</span><span>从旧节点继续会新建分支</span></div>
    <div className="history-list" role="list" aria-label="历史节点" ref={list}>
      {rows.map(({ node: n, depth }) => {
        const branches = children.get(n.id)?.length ?? 0;
        return <button role="listitem" key={n.id} disabled={busy} title={n.label}
          className={`history-node ${n.id === view.current ? 'current' : ''} ${path.has(n.id) ? 'on-path' : ''} ${n.edited ? 'edited' : ''}`}
          style={{ paddingLeft: `calc(var(--su) * ${0.5 + Math.min(depth, 12) * 0.6})` }} onClick={() => jump(n.id)}>
          <span className={`node-kind kind-${n.kind}`}>{methodNames[n.kind] ?? n.kind}</span>
          <span className="node-label">{n.label}</span>
          <span className="node-meta">#{n.id} · 底注{n.ante}{branches > 1 && <b> ⑂{branches}</b>}</span>
        </button>;
      })}
    </div>
  </div>;
}
