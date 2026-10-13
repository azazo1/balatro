import { useEffect, type RefObject } from 'react';

/** 舞台逻辑尺寸, 单位 u. 高度固定, 宽度在 [MIN_W, MAX_W] 内随窗口比例伸缩, 窄屏不再上下留大片空白. */
export const STAGE_MIN_W = 31;
export const STAGE_MAX_W = 48;
export const STAGE_H = 22.5;

/** 根据舞台父容器的可用空间计算 --u (1u 的像素数) 与 --sw (舞台宽度, 单位 u). */
export function useStageScale(stage: RefObject<HTMLElement | null>) {
  useEffect(() => {
    const el = stage.current;
    const parent = el?.parentElement;
    if (!el || !parent) return;
    const update = () => {
      // 优先撑满高度; 只有窗口比最窄舞台还窄时才按宽度缩小.
      const u = Math.max(Math.min(parent.clientHeight / STAGE_H, parent.clientWidth / STAGE_MIN_W), 8);
      const width = Math.min(Math.max(parent.clientWidth / u, STAGE_MIN_W), STAGE_MAX_W);
      el.style.setProperty('--u', `${u.toFixed(3)}px`);
      el.style.setProperty('--sw', width.toFixed(3));
    };
    update();
    const observer = new ResizeObserver(update);
    observer.observe(parent);
    return () => observer.disconnect();
  }, [stage]);
}
