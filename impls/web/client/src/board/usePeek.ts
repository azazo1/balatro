import { useEffect, useRef, useState, type MouseEvent, type PointerEvent } from 'react';

/** 按住多久算长按, 毫秒. 短于它是普通点按, 照常选牌. */
const HOLD_MS = 280;
/** 手指移动超过这个距离 (像素) 就当作滑动, 不再显示说明. */
const MOVE_PX = 10;

/**
 * 触控设备上按住显示说明框, 松开隐藏.
 * 只处理 pointerType 为 touch 的指针, 鼠标仍走 CSS 的 :hover.
 * 长按松开后会紧跟一次 click, 这里把它吞掉, 免得看一眼说明就把牌选上了.
 */
export function usePeek() {
  const [peek, setPeek] = useState(false);
  const timer = useRef<number | null>(null);
  const start = useRef<{ x: number; y: number } | null>(null);
  const swallow = useRef(false);

  const clear = () => { if (timer.current != null) { window.clearTimeout(timer.current); timer.current = null; } };
  const end = () => { clear(); start.current = null; setPeek(false); };
  useEffect(() => clear, []);

  return {
    peek,
    handlers: {
      onPointerDown: (e: PointerEvent) => {
        if (e.pointerType !== 'touch') return;
        swallow.current = false;
        start.current = { x: e.clientX, y: e.clientY };
        clear();
        timer.current = window.setTimeout(() => { timer.current = null; swallow.current = true; setPeek(true); }, HOLD_MS);
      },
      onPointerMove: (e: PointerEvent) => {
        const s = start.current;
        if (!s || e.pointerType !== 'touch') return;
        if (Math.hypot(e.clientX - s.x, e.clientY - s.y) > MOVE_PX) end();
      },
      onPointerUp: end,
      onPointerCancel: end,
      onPointerLeave: end,
      // 长按会触发系统菜单 (Android) 或拖拽预览, 一律拦掉.
      onContextMenu: (e: MouseEvent) => e.preventDefault(),
      // 捕获阶段吞掉长按后的 click, 子元素 (牌按钮) 收不到.
      onClickCapture: (e: MouseEvent) => {
        if (!swallow.current) return;
        swallow.current = false;
        e.preventDefault(); e.stopPropagation();
      },
    },
  };
}
