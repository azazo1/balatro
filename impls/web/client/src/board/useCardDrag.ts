import { useRef, useState, type MouseEvent, type PointerEvent } from 'react';

export interface DragInfo { area: string; index: number; onMove: (from: number, to: number) => void; enabled: boolean }

/** 移动超过这个距离 (像素) 才开始拖动, 小于它仍算点按. */
const START_PX = 8;

/**
 * 用指针事件拖动排序, 鼠标与触控通用 (HTML5 拖放在手机浏览器上基本不可用).
 * 松手时找指针下方同一区域的另一张牌, 把被拖的牌移到它的位置.
 * 拖动结束后紧跟的 click 会被吞掉, 免得拖一下就把牌选上.
 */
export function useCardDrag(drag?: DragInfo) {
  const [offset, setOffset] = useState<{ x: number; y: number } | null>(null);
  const start = useRef<{ x: number; y: number; id: number } | null>(null);
  const dragging = useRef(false);
  const swallow = useRef(false);

  const reset = () => { start.current = null; dragging.current = false; setOffset(null); };

  function dropTarget(e: PointerEvent): number | null {
    if (!drag) return null;
    const self = e.currentTarget;
    for (const el of document.elementsFromPoint(e.clientX, e.clientY)) {
      const slot = el.closest<HTMLElement>('[data-drag-area]');
      if (!slot || slot === self) continue;
      if (slot.dataset.dragArea !== drag.area) return null;
      return Number(slot.dataset.dragIndex);
    }
    return null;
  }

  const handlers = drag?.enabled ? {
    onPointerDown: (e: PointerEvent) => {
      if (e.button !== 0) return;
      swallow.current = false;
      start.current = { x: e.clientX, y: e.clientY, id: e.pointerId };
    },
    onPointerMove: (e: PointerEvent) => {
      const s = start.current;
      if (!s || e.pointerId !== s.id) return;
      const x = e.clientX - s.x, y = e.clientY - s.y;
      if (!dragging.current) {
        if (Math.hypot(x, y) < START_PX) return;
        dragging.current = true;
        // 捕获指针, 手指移出这张牌后仍能收到 move/up.
        e.currentTarget.setPointerCapture(s.id);
      }
      setOffset({ x, y });
    },
    onPointerUp: (e: PointerEvent) => {
      if (dragging.current && drag) {
        swallow.current = true;
        const to = dropTarget(e);
        if (to != null && to !== drag.index) drag.onMove(drag.index, to);
      }
      reset();
    },
    onPointerCancel: reset,
    onClickCapture: (e: MouseEvent) => {
      if (!swallow.current) return;
      swallow.current = false;
      e.preventDefault(); e.stopPropagation();
    },
  } : {};

  return {
    offset,
    handlers,
    attrs: drag ? { 'data-drag-area': drag.area, 'data-drag-index': drag.index } : {},
  };
}
