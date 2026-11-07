/**
 * PhotoMorph.ets
 * 画廊 ↔ 预览器「一镜到底」转场共用的几何与渲染单元。
 *
 * 设计要点（2026-11-07 重写）：
 * - **只有照片本身参与位移**，整页不做 scale/clip。官方图库/相册打开照片时是
 *   「缩略图那块方图长成照片，标题栏和缩略图条随后淡入」；早先的实现把整个
 *   NavDestination 缩放加裁剪，标题栏、缩略图条会跟着照片一起从一个小方块里
 *   长出来（= 一个迷你版预览器在放大），观感和官方差得很远。
 * - 起点是缩略图单元格的**屏幕矩形**（方图，`Cover` 居中裁切），终点是照片在
 *   预览器里的**实际显示矩形**（`Contain` 等比放入图片区域）。因为用 `Cover`
 *   显示，矩形从方图长到照片比例的过程天然就是「从中心裁切逐渐露出全图」，
 *   结束时矩形比例 == 照片比例，`Cover` 与 `Contain` 完全重合，可以无缝交接给
 *   页面内容。
 * - 逐帧变化的只有 `PhotoMorphState` 的四个数字，且只被叶子组件
 *   `PhotoMorphLayer` 读取：页面 `build()` 不读这些字段，转场期间不会重建整页。
 */

import { image } from '@kit.ImageKit';
import { WindowUtils } from '../utils/WindowUtils';
import type { RectInfoInPx } from '../utils/ComponentAttrUtils';

/** 预览器标题栏高度（vp）：36vp 返回钮 + 上下 12/8 内边距，见 PhotoViewer.TitleBar。 */
export const VIEWER_TITLE_BAR_HEIGHT: number = 56;

/** 屏幕矩形（vp，窗口坐标）。 */
export class MorphRect {
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;

  constructor(left: number = 0, top: number = 0, width: number = 0, height: number = 0) {
    this.left = left;
    this.top = top;
    this.width = width;
    this.height = height;
  }
}

/**
 * 转场位移状态。
 * `left/top/width/height` 逐帧变化，只能被叶子组件读（否则会逐帧重建整页）。
 * 背景压暗与照片层是否在场由同一个对象承载，页面只在 `visible` 翻转时重建一次。
 */
@ObservedV2
export class PhotoMorphState {
  @Trace left: number = 0;
  @Trace top: number = 0;
  @Trace width: number = 0;
  @Trace height: number = 0;
  /** 黑色背板不透明度（0 = 透出下层画廊，1 = 纯黑）。 */
  @Trace backdrop: number = 0;
  /** 共享照片层是否在场。 */
  @Trace visible: boolean = false;

  apply(rect: MorphRect): void {
    this.left = rect.left;
    this.top = rect.top;
    this.width = rect.width;
    this.height = rect.height;
  }
}

/** 几何换算：屏幕矩形（px）→ vp、图片显示区域、`Contain` 矩形。 */
export class MorphGeometry {
  /** 图片显示区域的上边（vp）：状态栏 + 预览器标题栏。 */
  static imageAreaTop(): number {
    const top = WindowUtils.topAvoidAreaHeightPx > 0 ? px2vp(WindowUtils.topAvoidAreaHeightPx) : 0;
    return top + VIEWER_TITLE_BAR_HEIGHT;
  }

  /** 图片显示区域的高度（vp）：窗口高 - 状态栏 - 标题栏 - 底部导航条。 */
  static imageAreaHeight(): number {
    const top = WindowUtils.topAvoidAreaHeightPx > 0 ? px2vp(WindowUtils.topAvoidAreaHeightPx) : 0;
    const bottom = WindowUtils.navigationIndicatorHeightPx > 0
      ? px2vp(WindowUtils.navigationIndicatorHeightPx) : 0;
    const h = WindowUtils.windowHeightPx > 0 ? px2vp(WindowUtils.windowHeightPx) : 0;
    return Math.max(0, h - top - bottom - VIEWER_TITLE_BAR_HEIGHT);
  }

  /** 照片在预览器里的实际显示矩形（`ImageFit.Contain`，居中）。 */
  static containRect(aspect: number): MorphRect {
    const width = WindowUtils.windowWidthPx > 0 ? px2vp(WindowUtils.windowWidthPx) : 0;
    const areaTop = MorphGeometry.imageAreaTop();
    const areaHeight = MorphGeometry.imageAreaHeight();
    if (width <= 0 || areaHeight <= 0 || !(aspect > 0)) {
      return new MorphRect(0, areaTop, width, areaHeight);
    }
    let w = width;
    let h = width / aspect;
    if (h > areaHeight) {
      h = areaHeight;
      w = areaHeight * aspect;
    }
    return new MorphRect((width - w) / 2, areaTop + (areaHeight - h) / 2, w, h);
  }

  /** 屏幕矩形（px）→ vp 矩形。 */
  static fromPx(rect: RectInfoInPx): MorphRect {
    return new MorphRect(px2vp(rect.left), px2vp(rect.top), px2vp(rect.width), px2vp(rect.height));
  }

  static aspectOf(w: number, h: number): number {
    if (!(w > 0) || !(h > 0)) {
      return 1;
    }
    return w / h;
  }

  static isValid(rect: MorphRect): boolean {
    return rect.width > 0 && rect.height > 0;
  }
}

/**
 * 黑色背板。单独抽成叶子组件：转场期间它的不透明度逐帧变化，
 * 若把 opacity 写在页面 build() 里会让整页跟着重建。
 */
@ComponentV2
export struct MorphBackdrop {
  @Param alpha: number = 0;

  build() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .opacity(this.alpha)
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 共享照片层：转场期间唯一可见的照片。
 * 只读 `PhotoMorphState`，自身不持有任何状态。
 */
@ComponentV2
export struct PhotoMorphLayer {
  @Param pixelMap: image.PixelMap | null = null;
  @Param state: PhotoMorphState = new PhotoMorphState();

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.pixelMap !== null) {
        Image(this.pixelMap)
          .draggable(false)
          .objectFit(ImageFit.Cover)
          .width(this.state.width)
          .height(this.state.height)
          .position({ x: this.state.left, y: this.state.top })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}
