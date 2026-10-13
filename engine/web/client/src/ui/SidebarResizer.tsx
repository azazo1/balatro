import { useEffect, useState, type PointerEvent } from 'react';

const KEY = 'engine-lab-sidebar-width';
const MIN = 240;
/** 舞台至少保留的宽度, 防止侧栏把棋盘挤没. */
const STAGE_RESERVE = 420;

function clamp(width: number) {
  return Math.round(Math.min(Math.max(width, MIN), Math.max(MIN, window.innerWidth - STAGE_RESERVE)));
}

/** 侧栏宽度 (px), 记在 localStorage, 窗口缩小时自动收回到合法范围. */
export function useSidebarWidth() {
  const [width, setWidth] = useState(() => clamp(Number(localStorage.getItem(KEY)) || 380));
  useEffect(() => { localStorage.setItem(KEY, String(width)); }, [width]);
  useEffect(() => {
    const onResize = () => setWidth(w => clamp(w));
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);
  return [width, (w: number) => setWidth(clamp(w))] as const;
}

/** 贴在侧栏左边界的拖动条: 按住左右拖改宽度, 双击恢复默认. */
export function SidebarResizer({ width, setWidth }: { width: number; setWidth: (w: number) => void }) {
  const [dragging, setDragging] = useState(false);
  function down(e: PointerEvent<HTMLDivElement>) {
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    setDragging(true);
  }
  function move(e: PointerEvent<HTMLDivElement>) {
    if (dragging) setWidth(window.innerWidth - e.clientX);
  }
  return <div className={`sidebar-resizer ${dragging ? 'dragging' : ''}`} style={{ right: width - 3 }}
    role="separator" aria-orientation="vertical" aria-label="拖动调整调试栏宽度" aria-valuenow={width}
    tabIndex={0} title="拖动调整宽度, 双击恢复"
    onPointerDown={down} onPointerMove={move}
    onPointerUp={() => setDragging(false)} onPointerCancel={() => setDragging(false)}
    onDoubleClick={() => setWidth(380)}
    onKeyDown={e => {
      if (e.key === 'ArrowLeft') setWidth(width + 20);
      else if (e.key === 'ArrowRight') setWidth(width - 20);
    }} />;
}
