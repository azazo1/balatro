import { Fragment, useEffect, useMemo, useRef } from 'react';
import type { HistoryNode, View } from '../lib/types';
import { methodNames } from '../lib/game';

/**
 * 每个节点记住"上次走的是哪个子节点", 用来决定当前节点之后显示哪条未来路线.
 * 以开局区分会话; 记录失效 (子节点不存在) 时退回最新的子节点.
 */
const preferred = new Map<string, Map<number, number>>();
function memory(view: View) {
  const o = view.opening;
  const key = `${view.session_id ?? ''}|${o.seed}|${o.deck}|${o.stake}|${o.profile}`;
  let map = preferred.get(key);
  if (!map) { map = new Map(); preferred.set(key, map); }
  return map;
}

function childrenOf(nodes: HistoryNode[]) {
  const map = new Map<number, HistoryNode[]>();
  for (const node of nodes) if (node.parent != null) {
    const list = map.get(node.parent);
    if (list) list.push(node); else map.set(node.parent, [node]);
  }
  return map;
}

/** 当前路线: 开局 -> 当前节点 -> 沿记住的分支走到末端. */
function routeOf(view: View, children: Map<number, HistoryNode[]>) {
  const nodes = view.history, remember = memory(view);
  const back: HistoryNode[] = [];
  for (let n: HistoryNode | undefined = nodes[view.current]; n; n = n.parent == null ? undefined : nodes[n.parent]) back.push(n);
  back.reverse();
  // 走过的路径就是各节点的首选分支.
  for (let i = 1; i < back.length; i++) remember.set(back[i - 1].id, back[i].id);
  const route = [...back];
  for (let tail = back[back.length - 1]; ;) {
    const kids = children.get(tail.id);
    if (!kids?.length) break;
    const want = remember.get(tail.id);
    tail = kids.find(k => k.id === want) ?? kids[kids.length - 1];
    route.push(tail);
  }
  return { route, past: back.length };
}

/** 当前节点的下一步 (快捷键 X 使用), 与列表显示的未来路线一致. */
export function nextNode(view: View): number | null {
  const kids = view.history.filter(n => n.parent === view.current);
  if (!kids.length) return null;
  const want = memory(view).get(view.current);
  return (kids.find(k => k.id === want) ?? kids[kids.length - 1]).id;
}

/** 分支长度: 沿最新子节点走到末端的步数, 用于提示分支有多长. */
function depthOf(node: HistoryNode, children: Map<number, HistoryNode[]>) {
  let steps = 1;
  for (let kids = children.get(node.id); kids?.length; kids = children.get(kids[kids.length - 1].id)) steps++;
  return steps;
}

export function HistoryTree({ view, busy, jump }: { view: View; busy: boolean; jump: (node: number) => void }) {
  const nodes = view.history;
  const children = useMemo(() => childrenOf(nodes), [nodes]);
  const { route, past } = useMemo(() => routeOf(view, children), [view, children]);
  const current = nodes[view.current];
  const next = nextNode(view);
  const branchCount = useMemo(() => nodes.filter(n => (children.get(n.id)?.length ?? 0) > 1).length, [nodes, children]);
  const list = useRef<HTMLDivElement>(null);
  // 当前节点保持在可见区域.
  useEffect(() => { list.current?.querySelector('.current')?.scrollIntoView({ block: 'nearest' }); }, [view.current]);
  // 切到另一分支: 记住选择, 然后跳到该分支第一步.
  const switchTo = (parent: number, child: number) => { memory(view).set(parent, child); jump(child); };

  return <div className="history">
    <div className="history-nav">
      <button className="btn grey small" disabled={busy || view.current === 0} onClick={() => jump(0)} title="回到开局">开局</button>
      <button className="btn blue small" disabled={busy || current.parent == null} onClick={() => current.parent != null && jump(current.parent)} title="快捷键 Z">上一步</button>
      <button className="btn blue small" disabled={busy || next == null} onClick={() => next != null && jump(next)} title="快捷键 X">下一步</button>
    </div>
    <div className="history-meta"><span>第 {past - 1} 步 / 路线共 {route.length - 1} 步</span><span>{nodes.length} 节点 · {branchCount} 处分叉</span></div>
    <div className="history-list" role="list" aria-label="当前路线" ref={list}>
      {route.map((n, i) => {
        const prev = route[i - 1];
        const kids = children.get(n.id) ?? [];
        const onRoute = route[i + 1]?.id;
        const others = kids.filter(k => k.id !== onRoute);
        return <Fragment key={n.id}>
          {(!prev || prev.ante !== n.ante) && <div className="history-ante" role="presentation">底注 {n.ante}</div>}
          <button role="listitem" disabled={busy} title={n.label} onClick={() => jump(n.id)}
            className={`history-node ${n.id === view.current ? 'current' : ''} ${i >= past ? 'future' : ''} ${n.edited ? 'edited' : ''}`}>
            <span className="node-step">{i}</span>
            <span className={`node-kind kind-${n.kind}`}>{methodNames[n.kind] ?? n.kind}</span>
            <span className="node-label">{n.label}</span>
          </button>
          {others.length > 0 && <div className="history-branches" role="group" aria-label={`第 ${i} 步之后的其他分支`}>
            <span className="branch-mark">⑂</span>
            {others.map(k => <button key={k.id} className={`branch-chip ${k.edited ? 'edited' : ''}`} disabled={busy}
              title={`切换到这条分支: ${k.label}`} onClick={() => switchTo(n.id, k.id)}>
              <span className={`node-kind kind-${k.kind}`}>{methodNames[k.kind] ?? k.kind}</span>
              <span className="branch-label">{k.label}</span>
              <span className="branch-len">{depthOf(k, children)} 步</span>
            </button>)}
          </div>}
        </Fragment>;
      })}
    </div>
  </div>;
}
