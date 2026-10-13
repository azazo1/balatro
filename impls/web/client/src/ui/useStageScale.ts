import { useEffect, type RefObject } from 'react';

/** 横屏舞台逻辑尺寸, 单位 u. 高度固定, 宽度在 [MIN_W, MAX_W] 内随窗口比例伸缩, 窄屏不再上下留大片空白. */
export const STAGE_MIN_W = 31;
export const STAGE_MAX_W = 48;
export const STAGE_H = 22.5;

/** 竖屏舞台: HUD 压成顶部横条, 棋盘在下. 宽度固定, 高度在 [MIN_H, MAX_H] 内伸缩, 多出的高度给中部. */
export const PORTRAIT_W = 23;
export const PORTRAIT_MIN_H = 32;
export const PORTRAIT_MAX_H = 52;
/** 可用区域 高/宽 超过这个比例就改用竖屏布局. */
const PORTRAIT_RATIO = 1.15;

/** 根据舞台父容器的可用空间计算 --u (1u 的像素数), --sw / --sh (舞台宽高, 单位 u), 并切换竖屏布局. */
export function useStageScale(stage: RefObject<HTMLElement | null>) {
  useEffect(() => {
    const el = stage.current;
    const parent = el?.parentElement;
    if (!el || !parent) return;
    const update = () => {
      const w = parent.clientWidth, h = parent.clientHeight;
      if (w <= 0 || h <= 0) return;
      const portrait = h / w > PORTRAIT_RATIO;
      let u: number, sw: number, sh: number;
      if (portrait) {
        // 优先撑满宽度; 只有屏幕比最矮舞台还扁时才按高度缩小.
        u = Math.max(Math.min(w / PORTRAIT_W, h / PORTRAIT_MIN_H), 8);
        sw = PORTRAIT_W;
        sh = Math.min(Math.max(h / u, PORTRAIT_MIN_H), PORTRAIT_MAX_H);
      } else {
        // 优先撑满高度; 只有窗口比最窄舞台还窄时才按宽度缩小. 超宽屏 (21:9 横屏手机) 宽度封顶, 两侧留边.
        u = Math.max(Math.min(h / STAGE_H, w / STAGE_MIN_W), 8);
        sw = Math.min(Math.max(w / u, STAGE_MIN_W), STAGE_MAX_W);
        sh = STAGE_H;
      }
      el.classList.toggle('portrait', portrait);
      el.style.setProperty('--u', `${u.toFixed(3)}px`);
      el.style.setProperty('--sw', sw.toFixed(3));
      el.style.setProperty('--sh', sh.toFixed(3));
    };
    update();
    const observer = new ResizeObserver(update);
    observer.observe(parent);
    return () => observer.disconnect();
  }, [stage]);
}
