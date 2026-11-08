import { image } from '@kit.ImageKit';
import { curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { displaySync } from '@kit.ArkGraphics2D';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry } from '../model/PhotoEntry';
import { CustomTransition } from '../CustomTransition/CustomNavigationUtils';
import {
  MorphGeometry,
  MorphRect,
  MorphBackdrop,
  PhotoMorphLayer,
  PhotoMorphState
} from '../CustomTransition/PhotoMorph';
import { RectInfoInPx } from '../utils/ComponentAttrUtils';
import { WindowUtils } from '../utils/WindowUtils';
import { FontSize, IconSize, Radius } from '../utils/UiTokens';

const TAG = 'PhotoViewer';
const DOMAIN = 0x0001;

/**
 * 预览器捏合性能探针。
 *
 * 捏合时每帧只更新 Image 的 scale/translate，JS 侧工作量极小；如果手感仍然卡，
 * 原因通常不是「缩放计算慢」，而是下面三类之一：
 *   1. 每帧有背景模糊（`backgroundBlurStyle`）要重算 —— 渲染侧，fps 会掉；
 *   2. 有整页重建（标题栏 + 两个 Swiper + Repeat 全量 diff）被别的状态触发；
 *   3. 后台预加载（USB 下载 + TaskPool 解码）把 UI 线程挤住。
 *
 * 一次捏合结束时输出一行，用来把「UI 线程节奏」和「渲染成本」分开：
 *   - fps 掉、gapMax 变大 → UI 线程被拖住（重建、GC、解码回调）
 *   - fps 正常但不跟手   → 渲染侧（模糊、图层、大位图）
 * 只在手势结束时打一行，不落在逐帧热路径上。
 */
class PinchPerf {
  private frames: number = 0;
  private lastFrameNs: number = 0;
  private maxFrameGapMs: number = 0;
  private lateFrames: number = 0;
  private updates: number = 0;
  private workMaxMs: number = 0;
  private startMs: number = 0;
  private sync: displaySync.DisplaySync | null = null;

  begin(): void {
    this.frames = 0;
    this.lastFrameNs = 0;
    this.maxFrameGapMs = 0;
    this.lateFrames = 0;
    this.updates = 0;
    this.workMaxMs = 0;
    this.startMs = Date.now();
    try {
      if (this.sync === null) {
        this.sync = displaySync.create();
        this.sync.setExpectedFrameRateRange({ expected: 60, min: 30, max: 120 });
        this.sync.on('frame', (info: displaySync.IntervalInfo) => { this.onFrame(info); });
      }
      this.sync.start();
    } catch (_e) {
      // 拿不到帧回调也不影响手势，只是少了 fps 数据
      this.sync = null;
    }
  }

  private onFrame(info: displaySync.IntervalInfo): void {
    this.frames++;
    if (this.lastFrameNs > 0) {
      const gapMs = (info.timestamp - this.lastFrameNs) / 1000000;
      if (gapMs > this.maxFrameGapMs) { this.maxFrameGapMs = gapMs; }
      if (gapMs > 20) { this.lateFrames++; }
    }
    this.lastFrameNs = info.timestamp;
  }

  /** 记录一次 onActionUpdate 的处理耗时（ms）。 */
  update(workMs: number): void {
    this.updates++;
    if (workMs > this.workMaxMs) { this.workMaxMs = workMs; }
  }

  /** 结束一次捏合，返回一行摘要；没收到捏合事件时返回空串。 */
  end(): string {
    if (this.sync !== null) {
      try { this.sync.stop(); } catch (_e) { /* ignore */ }
    }
    if (this.updates === 0) { return ''; }
    const ms = Math.max(1, Date.now() - this.startMs);
    const fps = this.frames > 0 ? this.frames * 1000 / ms : 0;
    return `updates=${this.updates}, frames=${this.frames}, fps=${fps.toFixed(0)}, ` +
      `lateFrames=${this.lateFrames}, gapMax=${this.maxFrameGapMs.toFixed(0)}ms, ` +
      `workMax=${this.workMaxMs}ms`;
  }
}

// ---- 一镜到底转场参数 ----
/** 照片长到位的时长。官方图库观感是「起步快、尾巴长」，用缓出贝塞尔而不是弹簧。 */
const PUSH_MS = 380;
/** 返回时收回缩略图的时长。比展开略短，松手即走的观感。 */
const POP_MS = 320;
/** 统一曲线：快速起步、缓慢收尾（照片不弹跳）。 */
const MORPH_CURVE = curves.cubicBezierCurve(0.2, 0.0, 0.0, 1.0);
/** 黑色背板压暗 / 恢复的时长。展开时压得快一点，避免背景长时间跟照片抢注意力。 */
const BACKDROP_IN_MS = 180;
const BACKDROP_OUT_MS = 260;
/** 加载超过这个时长才显示转圈（避免转圈在照片落地的瞬间闪一下）。 */
const SPINNER_DELAY_MS = 420;
/**
 * 收回动画的「目标格子矩形」可能因为列表虚拟化而暂时查不到：`handleBack` 会让
 * 画廊先滚到那一行，这里按帧重试，拿到就立刻开始收回。
 */
const POP_TARGET_RETRY_MS = 16;
const POP_TARGET_RETRIES = 8;
/**
 * 请求过画廊滚动后，先让列表把新布局画出一帧再透出背景：否则背景一淡，
 * 用户会看到网格「跳一下」（官方图库的网格是跟当前张同步的，回家时本来就
 * 在那个位置，所以看不到跳）。
 */
const POP_SCROLL_SETTLE_FRAMES = 1;
/** 标题栏与缩略图条：展开尾声淡入，返回开始淡出。 */
const CHROME_IN_DELAY_MS = 220;
const CHROME_IN_MS = 200;
const CHROME_OUT_MS = 140;

/**
 * 单张照片的可渲染状态。
 *
 * 预览器每进入一张照片会触发三类更新：开始加载、全尺寸解码完成、缩略图到达。
 * 这些状态以前放在页面级的 `@Local`（`fullResMap`、`loadingHandle`）上，任何
 * 一次更新都会重建整页（标题栏 + 主 Swiper + 缩略图 Swiper + Repeat 全量 diff）。
 * 后台预加载邻近照片时尤其明显：每解完一张就卡一下，捏合/拖动过程中也会撞上。
 *
 * 把状态挂到「每张照片一个对象」上之后，更新只重建对应的那一个 MainImageView。
 */
@ObservedV2
class PhotoRenderState {
  /** 已解码的全尺寸位图；null 表示还在显示缩略图或占位。 */
  @Trace fullPm: image.PixelMap | null = null;
  @Trace loading: boolean = false;
  /**
   * 是否显示「加载中」转圈。
   * 与 `loading` 分开：打开照片时已经有缩略图在显示，立刻盖个转圈会打断
   * 一镜到底落地的观感（官方图库也是先给糊图、不弹菊花）。加载超过
   * SPINNER_DELAY_MS 才显示，慢速真机照样有反馈。
   */
  @Trace spinnerOn: boolean = false;
  /** 该照片的显示宽高（vp 无关，仅用于算缩放比）。 */
  @Trace photoW: number = 1;
  @Trace photoH: number = 1;

  constructor(w: number = 1, h: number = 1) {
    this.photoW = w;
    this.photoH = h;
  }
}

// ---- Zoom transform state ----
/**
 * 缩放 / 位移状态。
 *
 * 为什么要单独抽一个 `@ObservedV2` 对象：如果把 scale/offset 写成
 * ZoomableImage 自己的 `@Local`，每个捏合事件都会重跑它的 build()，于是
 * `GestureGroup(...)` 连同 3 个手势每帧重建、每帧重新绑定到节点上（ArkUI 会把
 * 识别器整套换掉）。这里把逐帧变化的值交给叶子组件 ZoomLayer 订阅，手势树就
 * 只在「缩放是否越过 1x」时重建一次。
 */
@ObservedV2
class ZoomState {
  @Trace scale: number = 1.0;
  @Trace x: number = 0;
  @Trace y: number = 0;
}

/** 只负责把 transform 画出来的叶子组件：每帧重建的只有这一个 Image。 */
@ComponentV2
struct ZoomLayer {
  @Param pixelMap: image.PixelMap | null = null;
  @Param zoom: ZoomState = new ZoomState();

  build() {
    if (this.pixelMap !== null) {
      Image(this.pixelMap)
        .draggable(false)
        .objectFit(ImageFit.Contain)
        .width('100%').height('100%')
        .scale({ x: this.zoom.scale, y: this.zoom.scale })
        .translate({ x: this.zoom.x, y: this.zoom.y })
    }
  }
}

// ---- ZoomableImage ----
@ComponentV2
struct ZoomableImage {
  @Param pixelMap: image.PixelMap | null = null;
  @Param photoW: number = 1;
  @Param photoH: number = 1;
  @Param pageKey: number = 0;
  @Event onZoomChange: (zoomed: boolean) => void = () => {};
  @Event onGestureStart: () => void = () => {};
  @Event onGestureEnd: () => void = () => {};
  /** 捏合真正的开始/结束（含取消）：页面据此关闭背景模糊。 */
  @Event onPinchState: (active: boolean) => void = () => {};
  /** 缩放/位移。逐帧变化，但刻意不在本组件的 build 里读（见 ZoomState 注释）。 */
  private zoom: ZoomState = new ZoomState();
  /**
   * 手势结束时汇报当前变换（scale + 平移，单位 vp，相对照片居中位置）。
   * 返回转场要靠它把「放大后的画面」当成收回动画的起点，否则放大状态一按返回
   * 画面会先跳回等比显示，再缩回缩略图。
   */
  @Event onTransform: (scale: number, offX: number, offY: number) => void = () => {};
  /** 是否已放大到 1x 以上：只用于切换 PanGesture 的触发距离。 */
  @Local zoomed: boolean = false;
  private lastScale: number = 1.0;
  private lastOffX: number = 0;
  private lastOffY: number = 0;
  private compW: number = 0;
  private compH: number = 0;
  private imgW: number = 1;
  private imgH: number = 1;
  private pinching: boolean = false;
  /** Normalized zoom center (0-1) within the image, saved at pinch start */
  private zoomCenterX: number = 0.5;
  private zoomCenterY: number = 0.5;
  private panEndAt: number = 0;
  private readonly PAN_DBLTAP_DEBOUNCE_MS: number = 200;
  /** Accumulated pan offset saved when pinch is active, to prevent double-counting */
  private accumPanOffX: number = 0;
  private accumPanOffY: number = 0;
  private panActive: boolean = false;
  private perf: PinchPerf = new PinchPerf();

  @Monitor('pageKey')
  onPageChange(): void {
    this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.reset(); });
    this.updateImgCache();
  }

  @Monitor('photoW')
  onPhotoWChange(): void {
    this.updateImgCache();
  }

  aboutToAppear(): void {
    this.updateImgCache();
  }

  private updateImgCache(): void {
    const s = Math.min(this.compW > 0 ? this.compW / this.photoW : 1,
      this.compH > 0 ? this.compH / this.photoH : 1);
    this.imgW = this.photoW * s;
    this.imgH = this.photoH * s;
  }

  /** 让 PanGesture 的触发距离跟随缩放状态；只在 1x 边界翻转时重建一次手势树。 */
  private syncZoomed(): void {
    const z = this.zoom.scale > 1.0;
    if (this.zoomed !== z) { this.zoomed = z; }
  }

  /** 汇报一次当前变换（只在手势/动画结束时调用，不在逐帧热路径上）。 */
  private reportTransform(): void {
    this.onTransform(this.zoom.scale, this.zoom.x, this.zoom.y);
  }

  private reset(): void {
    this.zoom.scale = 1.0;
    this.zoom.x = 0;
    this.zoom.y = 0;
    this.lastScale = 1.0;
    this.lastOffX = 0;
    this.lastOffY = 0;
    this.pinching = false;
    this.zoomCenterX = 0.5;
    this.zoomCenterY = 0.5;
    this.panActive = false;
    this.accumPanOffX = 0;
    this.accumPanOffY = 0;
    this.syncZoomed();
  }

  private applyTransform(scale: number, panOffX: number, panOffY: number): void {
    const ns = Math.max(1.0, Math.min(5.0, this.lastScale * scale));
    this.zoom.scale = ns;
    // Zoom compensation: keep the zoomCenter point fixed on screen
    // Formula: offX = (lastOffX + panOffX) + (zoomCenterX - 0.5) * imgW * lastScale * (1 - scale)
    this.zoom.x = (this.lastOffX + panOffX) +
      (this.zoomCenterX - 0.5) * this.imgW * (1 - scale) * this.lastScale;
    this.zoom.y = (this.lastOffY + panOffY) +
      (this.zoomCenterY - 0.5) * this.imgH * (1 - scale) * this.lastScale;
    this.clampAndCheckEdge();
    this.syncZoomed();
  }

  private clampAndCheckEdge(): void {
    const iw = this.imgW * this.zoom.scale;
    const ih = this.imgH * this.zoom.scale;
    const mx = iw > this.compW ? (iw - this.compW) / 2 : 0;
    const my = ih > this.compH ? (ih - this.compH) / 2 : 0;
    if (iw > this.compW) {
      this.zoom.x = Math.max(-mx, Math.min(mx, this.zoom.x));
    } else {
      this.zoom.x = 0;
    }
    if (ih > this.compH) {
      this.zoom.y = Math.max(-my, Math.min(my, this.zoom.y));
    } else {
      this.zoom.y = 0;
    }
  }

  private onPinchStart(e: GestureEvent): void {
    if (!e) return;
    this.onGestureStart();
    this.onPinchState(true);
    this.perf.begin();
    this.pinching = true;
    this.lastScale = this.zoom.scale;
    this.lastOffX = this.zoom.x;
    this.lastOffY = this.zoom.y;
    const iw = this.imgW * this.lastScale;
    const ih = this.imgH * this.lastScale;
    const il = (this.compW - iw) / 2 + this.lastOffX;
    const it = (this.compH - ih) / 2 + this.lastOffY;
    this.zoomCenterX = iw > 0 ? Math.max(0, Math.min(1, (e.pinchCenterX - il) / iw)) : 0.5;
    this.zoomCenterY = ih > 0 ? Math.max(0, Math.min(1, (e.pinchCenterY - it) / ih)) : 0.5;
  }

  private onPinchUpdate(e: GestureEvent): void {
    if (!e) return;
    const t0 = Date.now();
    // Compute new scale
    const ns = Math.max(1.0, Math.min(5.0, this.lastScale * e.scale));
    this.zoom.scale = ns;
    // Compute offset directly from pinchCenter (screen-space absolute position)
    // This follows the official HarmonyOS example pattern:
    //   pointX = (compW - newDisplayW) / 2 + newDisplayW * centerX
    //   offX = pinchCenterX - pointX
    // where centerX is the normalized pinch position within the image.
    const newW = this.imgW * ns;
    const newH = this.imgH * ns;
    const pointX = (this.compW - newW) / 2 + newW * this.zoomCenterX;
    const pointY = (this.compH - newH) / 2 + newH * this.zoomCenterY;
    this.zoom.x = e.pinchCenterX - pointX;
    this.zoom.y = e.pinchCenterY - pointY;
    this.clampAndCheckEdge();
    this.syncZoomed();
    this.perf.update(Date.now() - t0);
  }

  private onPinchEnd(_e: GestureEvent): void {
    if (!this.pinching) return;
    this.pinching = false;
    this.onPinchState(false);
    this.logPinchPerf();
    if (this.zoom.scale < 1.05) {
      this.onZoomChange(false);
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.reset(); });
      this.reportTransform();
      this.onGestureEnd();
      return;
    }
    this.lastScale = this.zoom.scale;
    this.lastOffX = this.zoom.x;
    this.lastOffY = this.zoom.y;
    this.onZoomChange(true);
    this.reportTransform();
    this.onGestureEnd();
  }

  /**
   * 捏合被系统取消（来电、三指、手势冲突）时也要收尾。
   * 少了这一步，页面会永远停在「捏合中」：标题栏没有模糊。
   */
  private onPinchCancel(): void {
    if (!this.pinching) return;
    this.pinching = false;
    this.onPinchState(false);
    this.logPinchPerf();
    this.lastScale = this.zoom.scale;
    this.lastOffX = this.zoom.x;
    this.lastOffY = this.zoom.y;
    this.onZoomChange(this.zoom.scale > 1.0);
    this.reportTransform();
    this.onGestureEnd();
  }

  private logPinchPerf(): void {
    const summary = this.perf.end();
    if (summary) {
      hilog.info(DOMAIN, 'ViewerPerf', 'pinch %{public}s', summary);
    }
  }

  private onPanStart(_e: GestureEvent): void {
    this.panActive = true;
    this.accumPanOffX = 0;
    this.accumPanOffY = 0;
    if (this.pinching) return;
    this.onGestureStart();
    this.lastOffX = this.zoom.x;
    this.lastOffY = this.zoom.y;
  }

  private onPanUpdate(e: GestureEvent): void {
    if (!e || this.zoom.scale <= 1.0) return;
    if (this.pinching) {
      // While pinch is active, PanGesture keeps accumulating offset for the tracked finger.
      // Save this offset so we can subtract it when the pinch ends,
      // preventing a jump from accumulated finger movement during pinch.
      if (this.panActive) {
        this.accumPanOffX = e.offsetX;
        this.accumPanOffY = e.offsetY;
      }
      return;
    }
    // Subtract offset that accumulated during pinch; only apply NEW finger movement.
    const effectiveOffX = e.offsetX - this.accumPanOffX;
    const effectiveOffY = e.offsetY - this.accumPanOffY;
    // Compensate for the scaled local coordinate system:
    // .scale() shrinks the component's local coordinate space, so GestureEvent.offsetX
    // reports a smaller value. Multiply by scale to restore the screen-space delta.
    this.applyTransform(1, effectiveOffX * this.zoom.scale, effectiveOffY * this.zoom.scale);
  }

  private onPanEnd(_e: GestureEvent): void {
    this.panActive = false;
    if (this.pinching) return;
    this.lastOffX = this.zoom.x;
    this.lastOffY = this.zoom.y;
    this.panEndAt = Date.now();
    this.reportTransform();
    this.onGestureEnd();
  }

  private onPanCancel(): void {
    this.panActive = false;
    if (this.pinching) return;
    this.lastOffX = this.zoom.x;
    this.lastOffY = this.zoom.y;
    this.reportTransform();
    this.onGestureEnd();
  }

  private onDblTap(e: GestureEvent): void {
    // Debounce: ignore double-tap shortly after panning to avoid conflicting with rapid successive drags
    if (Date.now() - this.panEndAt < this.PAN_DBLTAP_DEBOUNCE_MS) {
      return;
    }
    if (this.zoom.scale > 1.0) {
      this.onZoomChange(false);
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.reset(); });
      return;
    }
    const fl = e?.fingerList;
    const tx = (fl && fl.length > 0) ? fl[0].localX : this.compW / 2;
    const ty = (fl && fl.length > 0) ? fl[0].localY : this.compH / 2;
    const iw = this.imgW;
    const ih = this.imgH;
    const il = (this.compW - iw) / 2;
    const it = (this.compH - ih) / 2;
    this.zoomCenterX = iw > 0 ? (tx - il) / iw : 0.5;
    this.zoomCenterY = ih > 0 ? (ty - it) / ih : 0.5;
    this.lastScale = 1.0;
    this.lastOffX = 0;
    this.lastOffY = 0;
    this.onZoomChange(true);
    this.getUIContext().animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.applyTransform(2.5, 0, 0);
      this.lastScale = this.zoom.scale;
      this.lastOffX = this.zoom.x;
      this.lastOffY = this.zoom.y;
      this.reportTransform();
    });
    this.onGestureEnd();
  }

  build() {
    Stack() {
      ZoomLayer({ pixelMap: this.pixelMap, zoom: this.zoom })
    }
    .width('100%').height('100%')
    .gesture(
      GestureGroup(GestureMode.Parallel,
        PinchGesture({ fingers: 2, distance: 1 })
          .onActionStart((e: GestureEvent) => { this.onPinchStart(e); })
          .onActionUpdate((e: GestureEvent) => { this.onPinchUpdate(e); })
          .onActionEnd((e: GestureEvent) => { this.onPinchEnd(e); })
          .onActionCancel(() => { this.onPinchCancel(); }),
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: this.zoomed ? 3 : 80 })
          .onActionStart((e: GestureEvent) => { this.onPanStart(e); })
          .onActionUpdate((e: GestureEvent) => { this.onPanUpdate(e); })
          .onActionEnd((e: GestureEvent) => { this.onPanEnd(e); })
          .onActionCancel(() => { this.onPanCancel(); }),
        TapGesture({ count: 2 })
          .onAction((e: GestureEvent) => { this.onDblTap(e); })
      )
    )
    .onAreaChange((_o: Area, n: Area) => {
      this.compW = n.width as number;
      this.compH = n.height as number;
      this.updateImgCache();
    })
  }
}

// ---- MainImageView (top-level @ComponentV2 for Repeat+virtualScroll recycling) ----
@ComponentV2
struct MainImageView {
  @Param photo: PhotoEntry | null = null;
  @Param pageKey: number = 0;
  /**
   * 该照片的渲染状态（全尺寸位图 / 加载中）。
   * 这些字段只能在本组件里读；页面读它们会让整页跟着每次解码重建。
   */
  @Param state: PhotoRenderState | null = null;
  /** 缩略图缓存：普通 Map，不可观测，靠 thumbnailVersion 建立订阅。 */
  @Param thumbMap: Map<number, image.PixelMap> = new Map<number, image.PixelMap>();
  @Param svc: CameraService = CameraService.getInstance();
  @Event onZoomChange: (zoomed: boolean) => void = () => {};
  @Event onGestureStart: () => void = () => {};
  @Event onGestureEnd: () => void = () => {};
  @Event onPinchState: (active: boolean) => void = () => {};
  @Event onOverlayToggle: () => void = () => {};
  /** 手势结束时的变换快照，转给页面做返回转场起点。 */
  @Event onTransform: (scale: number, offX: number, offY: number) => void = () => {};

  /**
   * 当前应显示的位图：全尺寸优先，否则用缩略图。
   *
   * `thumbnailPixelMapMap` 是普通 Map，不参与自动追踪；这里读一下
   * `thumbnailVersion`（每 4 张缩略图递增一次）建立订阅，占位图才会在解码
   * 完成后被替换。这个读只让本组件订阅，不会波及页面。
   */
  private bitmapFor(handle: number): image.PixelMap | null {
    const st = this.state;
    if (st !== null && st.fullPm !== null) { return st.fullPm; }
    if (this.svc.thumbnailVersion < 0) { return null; }
    return this.thumbMap.get(handle) ?? null;
  }

  private hasFullRes(): boolean {
    return this.state !== null && this.state.fullPm !== null;
  }

  private scanText(): string {
    if (this.svc.scanTotal <= 0) { return ''; }
    return `更新中 ${this.svc.scanProgress}/${this.svc.scanTotal}`;
  }

  build() {
    Stack() {
      if (this.photo !== null && this.state !== null) {
        if (this.bitmapFor(this.photo.handle) !== null) {
          ZoomableImage({
            pixelMap: this.bitmapFor(this.photo.handle),
            photoW: this.state.photoW,
            photoH: this.state.photoH,
            pageKey: this.pageKey,
            onZoomChange: this.onZoomChange,
            onGestureStart: this.onGestureStart,
            onGestureEnd: this.onGestureEnd,
            onPinchState: this.onPinchState,
            onTransform: this.onTransform
          })
        } else {
          Column() {
            Text(this.photo.filename)
              .fontSize(FontSize.Body).fontColor($r('app.color.viewer_text_secondary'))
              .maxLines(2).textAlign(TextAlign.Center)
            if (this.svc.scanning) {
              Text(this.svc.lastDecodedHandle >= 0 ? '正在解码缩略图…' : '等待扫描…')
                .fontSize(FontSize.Caption).fontColor($r('app.color.viewer_text_tertiary')).margin({ top: 8 })
            }
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.viewer_placeholder_bg'))
          .onClick(() => { this.onOverlayToggle(); })
        }
      }

      if (this.state !== null && this.state.spinnerOn) {
        Column() {
          LoadingProgress()
            .color($r('app.color.text_on_dark'))
            .width(48).height(48)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.viewer_scrim'))
        .hitTestBehavior(HitTestMode.None)
      }

      // Scanning banner — shown when scanning and no full-res loaded yet
      if (this.svc.scanning && !this.hasFullRes() && this.svc.scanTotal > 0) {
        Text(this.scanText())
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.viewer_text_on_dark_80'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 4, bottom: 4 })
          .backgroundColor($r('app.color.viewer_banner_bg'))
          .position({ bottom: 0 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%').height('100%')
    .onClick(() => { this.onOverlayToggle(); })
  }
}

// ---- Constants (from SwiperSyncTestPage) ----
const MAX_S = 1.3;
const MIN_S = 1.0;
const ITEM_SPACE = 2;
const CENTER_OFFSET = 14;
const SNAP_DURATION = 150;
const INERTIA_THRESHOLD = 3000;
const INERTIA_FACTOR = 150;
const INERTIA_DURATION = 5000;

// Preload queue item
interface PreloadTask {
  handle: number;
  priority: number;
}

function buildDisplayIndices(total: number): number[] {
  const arr: number[] = [];
  for (let i = 0; i < total; i++) { arr.push(i); }
  return arr;
}

// ---- Formatting helpers ----
function formatCaptureDate(entry: PhotoEntry): string {
  const raw = entry.captureDate;
  if (!raw || raw.length < 14) return '';
  // PTP format: YYYYMMDDThhmmss
  const y = raw.substring(0, 4);
  const mo = raw.substring(4, 6);
  const d = raw.substring(6, 8);
  const h = raw.substring(9, 11);
  const mi = raw.substring(11, 13);
  const s = raw.substring(13, 15);
  return `${y}年${mo}月${d}日 ${h}:${mi}:${s}`;
}

function formatFileSize(bytes: number): string {
  if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${bytes} B`;
}

function formatResolution(w?: number, h?: number): string {
  if (w && h && w > 0 && h > 0) return `${w}×${h}`;
  return '';
}

// ---- ThumbCellView (separate @ComponentV2 for proper Repeat+virtualScroll recycling) ----
@ComponentV2
struct ThumbCellView {
  @Param realIdx: number = -1;
  @Param pixelMap: image.PixelMap | null = null;
  @Param s: number = 1.0;
  @Param ox: number = 0;
  @Param borderWeight: number = 0;
  @Event onCellClick: () => void = () => {};

  build() {
    Column() {
      if (this.realIdx >= 0 && this.pixelMap !== null) {
        Image(this.pixelMap)
          .draggable(false)
          .objectFit(ImageFit.Cover)
          .width('100%').height('100%')
          .borderRadius(Radius.Thumb)
          .border({ width: this.borderWeight * 2, color: $r('app.color.viewer_accent'), radius: Radius.Thumb })
      } else if (this.realIdx >= 0) {
        Column()
          .width('100%').height('100%')
          .borderRadius(Radius.Thumb)
          .backgroundColor($r('app.color.viewer_placeholder_image'))
          .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').aspectRatio(1)
    .borderRadius(Radius.Thumb)
    .backgroundColor(this.realIdx < 0 ? Color.Transparent : $r('app.color.viewer_placeholder_thumb'))
    .justifyContent(FlexAlign.Center)
    .offset({ x: this.ox })
    .scale({ x: this.s, y: this.s })
    .animation({ duration: 150, curve: Curve.Linear })
    .onClick(() => {
      if (this.realIdx >= 0) { this.onCellClick(); }
    })
  }
}

// ---- PhotoViewerScreen @Builder export (NavDestination) ----
@Builder
export function PhotoViewerScreenBuilder() {
  PhotoViewerScreen();
}

@ComponentV2
export struct PhotoViewerScreen {
  // Navigation
  private pageInfos: NavPathStack = new NavPathStack();
  private pageId: number = -1;

  // ---- 一镜到底转场 ----
  /** 被点缩略图的屏幕矩形（px），也是返回动画的兜底终点。 */
  private cardItemInfo: RectInfoInPx = new RectInfoInPx();
  /**
   * 转场位移状态。刻意用普通字段 + `@ObservedV2` 对象：页面 `build()` 不读
   * `left/top/width/height`，逐帧变化的只有叶子组件 `PhotoMorphLayer`，
   * 转场期间不会重建整页（标题栏 + 两个 Swiper + Repeat）。
   */
  private morph: PhotoMorphState = new PhotoMorphState();
  /** 转场期间共享层显示的照片（push 用缩略图；pop 用当前已解码的位图）。 */
  private morphPm: image.PixelMap | null = null;
  /** 返回动画的终点（当前照片在画廊里的矩形），由 handleBack / startPopRect 计算。 */
  private popTargetRect: MorphRect | null = null;
  /** 请求画廊把列表滚到某张照片（目标格子不在可视区时），由 MainScreen 提供。 */
  private requestGalleryScroll: ((handle: number) => void) | undefined = undefined;
  /**
   * 目标矩形的重试：目标格子可能还没被列表渲染出来（虚拟化）或在屏幕外，
   * `handleBack` 先请求画廊滚过去，这里等它一两帧再开始收回。
   */
  private popRetryId: number = -1;
  private popRetryLeft: number = 0;
  private popProxyRef: NavigationTransitionProxy | null = null;
  private popScrollRequested: boolean = false;
  private popScrollSettled: number = 0;
  /** 主图区域不透明度：转场期间由共享层代替，结束时一次性给回。 */
  @Local photoAlpha: number = 0;
  /** 标题栏 / 缩略图条不透明度：照片到位后才淡入。 */
  @Local chromeAlpha: number = 0;
  private chromeTimerId: number = -1;
  /** 当前照片的缩放快照（手势结束时更新），用于「放大状态下返回」的起点矩形。 */
  private curZoomScale: number = 1;
  private curZoomX: number = 0;
  private curZoomY: number = 0;
  private positionLookup: ((handle: number) => string) | undefined = undefined;
  private posCache: Record<string, string> = {};
  /**
   * 矩形插值用帧回调驱动，**不要**改成 animateTo：
   * 共享照片层是转场开始那一刻才创建的新节点，而 `animateTo` 只对「已经渲染过」
   * 的属性做插值——新节点会直接以终值出现（实测 `appear` 里就是终点矩形），
   * 整个一镜到底会变成硬切。帧回调逐帧写状态则与节点生命周期无关。
   */
  private morphSync: displaySync.DisplaySync | null = null;
  private morphFrom: MorphRect = new MorphRect();
  private morphTo: MorphRect = new MorphRect();
  private morphCurve: ICurve = MORPH_CURVE;
  private morphStartMs: number = -1;
  private morphDurationMs: number = 0;
  private morphDone: (() => void) | null = null;

  @Local svc: CameraService = CameraService.getInstance();
  @Local mainIdx: number = 0;
  @Local thumbIdx: number = 0;
  private mainCtrl: SwiperController = new SwiperController();
  private thumbCtrl: SwiperController = new SwiperController();

  private _fromMain: boolean = false;
  private _isDragging: boolean = false;
  private _lastMainFrac: number = 0;
  @Local _swiperWidth: number = 360;
  @Local _thumbItemW: number = 60;
  @Local _inertiaAnim: boolean = false;
  @Local _overlayVisible: boolean = true;

  @Local _realTotal: number = 0;
  @Local _displayCount: number = 9;
  @Local _half: number = 4;
  @Local _displayTotal: number = 0;
  @Local displayIndices: number[] = [];
  @Local scaleArr: number[] = [];
  @Local offsetArr: number[] = [];
  /** 捏合进行中：禁用主 Swiper 的滑动，避免两指同时被识别成翻页。 */
  @Local pinchActive: boolean = false;
  /**
   * 有内容位移（捏合 / 翻页 / 惯性）时关掉标题栏与缩略图条的实时背景模糊。
   * `backgroundBlurStyle` 会对背后正在移动的图片每帧重算一遍模糊，是预览器
   * 缩放卡顿的主要渲染成本；静止时恢复模糊，静态观感不变。
   */
  @Local chromeMotion: boolean = false;
  /** 一次捏合期间主 Swiper 触发的滚动回调次数（只用于性能日志）。 */
  private pinchScrollEvents: number = 0;

  // ---- Full-resolution loading state ----
  /**
   * 已解码的全尺寸位图。刻意用普通 Map：后台预加载每解完一张都会写这里，
   * 若做成 `@Local Map` 就会把整页重建一次（捏合/拖动中撞上就是一次掉帧）。
   * 界面靠 `renderStates` 里那张照片自己的状态刷新。
   */
  private fullResMap: Map<number, image.PixelMap> = new Map();
  /** 每张照片的渲染状态，更新只影响对应的 MainImageView。 */
  private renderStates: Map<number, PhotoRenderState> = new Map();
  private loadingHandle: number = -1;
  private spinnerTimerId: number = -1;
  @Local isZoomed: boolean = false;
  private stableTimerId: number = -1;
  private preloadWindow: number = 3;
  private preloadedHandles: Set<number> = new Set();

  // ---- Interaction-aware serial preload queue ----
  private preloadQueue: PreloadTask[] = [];
  private preloadActive: boolean = false;
  private loadingPaused: boolean = false;
  private pauseTimerId: number = -1;
  private readonly RESUME_COOLDOWN_MS: number = 300;
  private lastInteractionTs: number = 0;

  // Filtered photo list (from gallery's filter)
  @Local photoList: PhotoEntry[] = [];
  // Stable cached copy of photos for Repeat data source (avoids reference changes)
  @Local mainPhotos: PhotoEntry[] = [];

  private getPhotos(): PhotoEntry[] {
    return this.mainPhotos;
  }

  // ---- Scanning guards and auto-recovery ----

  /**
   * 扫描结束时恢复全尺寸加载。
   * 缩略图到达不再需要额外通知：MainImageView 自己订阅了 `thumbnailVersion`。
   */
  @Monitor('svc.scanning')
  onScanningChange(mon: IMonitor): void {
    const before = mon.value()?.before as boolean;
    const now = mon.value()?.now as boolean;
    if (before === true && now === false) {
      this.svc.getLog().add('[PhotoViewer] 扫描完成，自动恢复加载');
      setTimeout(() => { this.scheduleFullResLoad(); }, 100);
    }
  }

  aboutToAppear(): void {
    // 预览器自己有一套「当前优先、前后各 3 张」的加载队列；后台的邻近预加载
    // 若同时跑，会在串行的 USB 管道上插队，把正在看的这张拖慢。
    this.svc.suspendNeighborPreload();
    // The viewer is always dark: force light status/navigation bar icons.
    WindowUtils.applyViewerSystemBars();
  }

  aboutToDisappear(): void {
    this.cancelStableTimer();
    this.cancelChromeTimer();
    this.stopRectAnimation();
    this.cancelPopRetry();
    if (this.spinnerTimerId >= 0) {
      clearTimeout(this.spinnerTimerId);
      this.spinnerTimerId = -1;
    }
    // 停掉预览器自己的解码队列，把后台预加载交还给服务层（回到画廊后下一次
    // 打开照片才不会又从零开始下载）。
    this.loadingPaused = true;
    this.svc.resumeNeighborPreload();
    // Restore system bars to match the app theme.
    WindowUtils.applyThemeSystemBars(
      WindowUtils.isDarkMode(this.getUIContext().getHostContext()));
  }

  /**
   * Initialize photo list from NavDestination params (called from onReady).
   */
  private initFromParams(handle: number, handles: number[] | undefined, startIndex: number | undefined): void {
    if (handles && handles.length > 0) {
      const photoByHandle = new Map<number, PhotoEntry>();
      for (const p of this.svc.photos) {
        photoByHandle.set(p.handle, p);
      }
      this.photoList = [];
      for (const h of handles) {
        const p = photoByHandle.get(h);
        if (p) this.photoList.push(p);
      }
      // When handles from gallery, their order is already the gallery's visual order.
      // Do NOT reverse — the gallery already decides the ordering.
      this.mainPhotos = this.photoList;
    } else {
      // No handles: load all from service and reverse for newest-first
      this.mainPhotos = [...this.svc.photos].reverse();
    }

    this.rebuildDisplayArrays();
    // 预先建好每张照片的渲染状态（不在 build 里创建观察对象）
    this.renderStates.clear();
    this.fullResMap.clear();
    for (const p of this.mainPhotos) {
      this.stateFor(p.handle);
    }
    let initialIndex = 0;
    if (startIndex !== undefined && startIndex >= 0 && startIndex < this.mainPhotos.length) {
      initialIndex = startIndex;
    } else if (handle !== undefined && this.getPhotos().length > 0) {
      for (let i = 0; i < this.getPhotos().length; i++) {
        if (this.getPhotos()[i].handle === handle) {
          initialIndex = i;
          break;
        }
      }
    }
    this.mainIdx = initialIndex;
    this.thumbIdx = initialIndex;
    this.updateScales(initialIndex);
    // Start loading full-res for initial photo after a short delay
    setTimeout(() => { this.scheduleFullResLoad(); }, 200);
  }

  /** 取（或懒建）某张照片的渲染状态。 */
  private stateFor(handle: number): PhotoRenderState {
    let st = this.renderStates.get(handle);
    if (st === undefined) {
      const sz = this.svc.orientedDisplaySizes.get(handle);
      let w = 1;
      let h = 1;
      if (sz !== undefined && sz.w > 0 && sz.h > 0) {
        w = sz.w;
        h = sz.h;
      } else {
        const p = this.photoByHandle(handle);
        if (p !== null) {
          w = p.imagePixWidth ?? 1;
          h = p.imagePixHeight ?? 1;
        }
      }
      st = new PhotoRenderState(w, h);
      this.renderStates.set(handle, st);
    }
    return st;
  }

  private photoByHandle(handle: number): PhotoEntry | null {
    for (const p of this.mainPhotos) {
      if (p.handle === handle) { return p; }
    }
    return null;
  }

  /**
   * 把已缓存的全尺寸位图挂到该照片的渲染状态上（幂等）。
   * 预加载刻意不碰渲染状态，只写普通 Map，等用户翻到这张时再补上。
   */
  private presentCached(handle: number): void {
    const pm = this.fullResMap.get(handle);
    if (pm === undefined) { return; }
    const st = this.stateFor(handle);
    if (st.fullPm !== pm) {
      st.fullPm = pm;
    }
  }

  private rebuildDisplayArrays(): void {
    const photos = this.getPhotos();
    const realTotal = photos.length > 0 ? photos.length : 0;
    if (realTotal === 0) {
      this._realTotal = 0;
      this._displayTotal = 0;
      this.displayIndices = [];
      this.scaleArr = [];
      this.offsetArr = [];
      return;
    }
    const displayCount = Math.min(9, realTotal);
    const half = Math.floor(displayCount / 2);
    const displayTotal = realTotal + half * 2;

    this._realTotal = realTotal;
    this._displayCount = displayCount;
    this._half = half;
    this._displayTotal = displayTotal;
    this.displayIndices = buildDisplayIndices(displayTotal);
    this.scaleArr = new Array<number>(displayTotal).fill(MIN_S);
    this.offsetArr = new Array<number>(displayTotal).fill(0);
    if (displayTotal > half) {
      this.scaleArr[half] = MAX_S;
      for (let i = 0; i < displayTotal; i++) {
        if (!this.isPlaceholder(i) && i !== half) {
          this.offsetArr[i] = i > half ? CENTER_OFFSET : -CENTER_OFFSET;
        }
      }
    }
  }

  private isPlaceholder(displayIdx: number): boolean {
    return displayIdx < this._half || displayIdx >= this._half + this._realTotal;
  }

  private toReal(displayIdx: number): number {
    return displayIdx - this._half;
  }

  private updateScales(realFrac: number): void {
    const half = this._half;
    const dt = this._displayTotal;
    const centerIdx = Math.round(realFrac + half);
    // 性能优化：仅遍历可见窗口内的 item，避免 O(n) 全量遍历
    const window = this._displayCount + 2; // 可见区域 + 余量
    const start = Math.max(0, centerIdx - window);
    const end = Math.min(dt - 1, centerIdx + window);
    for (let i = start; i <= end; i++) {
      let s = MIN_S;
      let o = CENTER_OFFSET;
      if (this.isPlaceholder(i)) {
        s = 0;
        o = 0;
      } else if (i === centerIdx) {
        s = MAX_S;
        o = 0;
      } else {
        o = i > centerIdx ? CENTER_OFFSET : -CENTER_OFFSET;
      }
      // 只在值真的变化时写：`@Local` 数组每次赋值都会通知订阅者。拖动不足半格时
      // 这些值本来就是不变的，逐帧全写会让窗口内 11 个缩略图单元格反复重算并
      // 重启自身的 150ms 动画 —— 翻页时「有点卡」的一条隐性成本。
      if (this.scaleArr[i] !== s) { this.scaleArr[i] = s; }
      if (this.offsetArr[i] !== o) { this.offsetArr[i] = o; }
    }
  }

  /** 只在状态真的翻转时写 `@Local`，避免逐帧重建页面。 */
  private setChromeMotion(on: boolean): void {
    if (this.chromeMotion !== on) { this.chromeMotion = on; }
  }

  /**
   * 捏合开始 / 结束（含取消）。
   *
   * 捏合期间同时做两件事：
   * 1. 关掉标题栏与缩略图条的实时背景模糊 —— 背后图片每帧在动，模糊也要每帧
   *    重算，是缩放卡顿的主要渲染成本；
   * 2. 让主 Swiper 不再滑动，两指手势完全归 ZoomableImage 处理，避免两指拖动
   *    被 Swiper 同时识别成翻页（那样每帧还会额外触发一次缩略图条联动）。
   */
  private setPinchActive(active: boolean): void {
    if (this.pinchActive !== active) { this.pinchActive = active; }
    if (active) {
      this.pinchScrollEvents = 0;
      this.setChromeMotion(true);
    } else {
      this.setChromeMotion(this._isDragging || this._inertiaAnim);
      this.svc.getLog().add(
        `PERF viewer pinch: swiperScrolls=${this.pinchScrollEvents}`);
    }
  }

  // ========== Main -> Thumb ==========

  private onMainGestureSwipe(index: number, extraInfo: SwiperAnimationEvent): void {
    if (!this._isDragging && Math.abs(extraInfo.currentOffset) > 0.5) {
      this._fromMain = true;
      this._isDragging = true;
      this._inertiaAnim = false;
      this._lastMainFrac = this.mainIdx;
      this.thumbCtrl.startFakeDrag();
      this.setChromeMotion(true);
    }
    if (!this._isDragging) return;
    const mainFrac = index - extraInfo.currentOffset / this._swiperWidth;
    const delta = mainFrac - this._lastMainFrac;
    this._lastMainFrac = mainFrac;
    this.thumbCtrl.fakeDragBy(-delta * (this._thumbItemW + ITEM_SPACE));
    this.updateScales(mainFrac);
  }

  private onMainContentDidScroll(_sel: number, index: number, position: number): void {
    // 捏合期间这条回调本该完全不触发（主 Swiper 已 disableSwipe）。记个数，
    // 方便从日志确认「两指手势有没有被 Swiper 抢走」。
    if (this.pinchActive) { this.pinchScrollEvents++; }
    const mainFrac = index - position;
    this.updateScales(mainFrac);
    if (!this._isDragging) return;
    if (index !== this.mainIdx) return;
    if (Math.abs(position) < 0.005) return;
    const delta = mainFrac - this._lastMainFrac;
    this._lastMainFrac = mainFrac;
    this.thumbCtrl.fakeDragBy(-delta * (this._thumbItemW + ITEM_SPACE));
  }

  private onMainAnimationEnd(index: number): void {
    hilog.info(DOMAIN, TAG, `onMainAnimationEnd idx=${index} mainIdx=${this.mainIdx}`);
    if (this._isDragging) {
      this.thumbCtrl.stopFakeDrag();
      this._isDragging = false;
    }
    this._fromMain = false;
    this._inertiaAnim = false;
    this.setChromeMotion(false);
    this.mainIdx = index;
    this.thumbIdx = index;
    this.thumbCtrl.changeIndex(index, false);
    this.updateScales(index);
    this.svc.setDetailIndex(index, this.getPhotos());
    this.scheduleFullResLoad();
  }

  private onMainChange(idx: number): void {
    hilog.info(DOMAIN, TAG, `onMainChange idx=${idx} mainIdx=${this.mainIdx} total=${this.mainPhotos.length}`);
    this.mainIdx = idx;
    // 换了一张照片：缩放快照失效（ZoomableImage 切页时会自己复位）
    this.curZoomScale = 1;
    this.curZoomX = 0;
    this.curZoomY = 0;
    if (this._fromMain && !this._inertiaAnim) {
      this._fromMain = false;
      if (this._isDragging) {
        this.thumbCtrl.stopFakeDrag();
        this._isDragging = false;
      }
      this.thumbIdx = idx;
      this.thumbCtrl.changeIndex(idx, false);
      this.updateScales(idx);
    }
    // Skip full-res download during inertial scrolling — only show what's already cached
    if (!this._inertiaAnim) {
      this.svc.setDetailIndex(idx, this.getPhotos());
      this.scheduleFullResLoad();
    }
  }

  // ========== Thumb -> Main ==========

  private onThumbGestureSwipe(index: number, extraInfo: SwiperAnimationEvent): void {
    if (this._fromMain || this._inertiaAnim) return;
    const centerReal = index - extraInfo.currentOffset / (this._thumbItemW + ITEM_SPACE);
    const clamped = Math.max(0, Math.min(Math.round(centerReal), this._realTotal - 1));
    if (clamped !== this.mainIdx) { this.mainIdx = clamped; }
    this.updateScales(centerReal);
    this.setChromeMotion(true);
  }

  private onThumbAnimationStart(_index: number, targetIndex: number): void {
    if (this._fromMain || this._inertiaAnim) return;
    const realTarget = Math.max(0, Math.min(targetIndex, this._realTotal - 1));
    this.mainCtrl.changeIndex(realTarget, true);
  }

  private onThumbAnimationEnd(index: number): void {
    if (this._fromMain || this._inertiaAnim) return;
    const realIdx = Math.max(0, Math.min(index, this._realTotal - 1));
    this.mainIdx = realIdx;
    this.thumbIdx = index;
    this.updateScales(realIdx);
    this.setChromeMotion(false);
  }

  private onThumbChange(idx: number): void {
    this.thumbIdx = idx;
    if (this._fromMain || this._inertiaAnim) return;
    const centerIdx = idx + this._half;
    if (this.isPlaceholder(centerIdx)) return;
    const realIdx = Math.max(0, Math.min(this.toReal(centerIdx), this._realTotal - 1));
    this.mainIdx = realIdx;
    this.updateScales(realIdx);
  }

  private onThumbClick(realIdx: number): void {
    if (realIdx === this.mainIdx) return;
    this._fromMain = true;
    this.thumbCtrl.changeIndex(realIdx, true);
    this.mainCtrl.changeIndex(realIdx, true);
  }

  // ========== Full-resolution loading ==========

  /**
   * Start or restart the 100ms stabilization timer.
   * When the timer fires, begin downloading the full-resolution photo.
   */
  private scheduleFullResLoad(): void {
    // Scanning guard: no full-res loading until scan completes
    if (this.svc.scanning) {
      return;
    }

    // Cancel any pending timer
    this.cancelStableTimer();

    // During inertial scrolling of the thumbnail strip, don't start any downloads.
    // Already-cached full-res photos will still display; un-cached ones fall back to thumbnail.
    if (this._inertiaAnim) {
      return;
    }

    const handle = this.currentHandle();
    if (handle < 0) return;

    // If already loaded, just ensure preload window is populated
    if (this.fullResMap.has(handle)) {
      this.presentCached(handle);
      this.preloadNeighbors();
      return;
    }
    // Already loading
    if (this.loadingHandle === handle) return;

    this.stableTimerId = setTimeout(() => {
      this.stableTimerId = -1;
      this.loadFullRes(handle);
    }, 100);
  }

  private cancelStableTimer(): void {
    if (this.stableTimerId >= 0) {
      clearTimeout(this.stableTimerId);
      this.stableTimerId = -1;
    }
  }

  private currentHandle(): number {
    const photos = this.getPhotos();
    if (this.mainIdx >= 0 && this.mainIdx < photos.length) {
      return photos[this.mainIdx].handle;
    }
    return -1;
  }

  private async loadFullRes(handle: number): Promise<void> {
    // Scanning guard: no full-res loading until scan completes
    if (this.svc.scanning) return;

    // Guard: already loaded or another load in progress
    if (this.fullResMap.has(handle) || this.loadingHandle >= 0) return;

    this.loadingHandle = handle;
    const startState = this.stateFor(handle);
    startState.loading = true;
    startState.spinnerOn = false;
    if (this.spinnerTimerId >= 0) { clearTimeout(this.spinnerTimerId); }
    this.spinnerTimerId = setTimeout(() => {
      this.spinnerTimerId = -1;
      if (this.loadingHandle === handle && this.stateFor(handle).loading) {
        this.stateFor(handle).spinnerOn = true;
      }
    }, SPINNER_DELAY_MS);
    try {
      const result = await this.svc.loadFullPhoto(handle);
      if (result !== null) {
        const pixelMap = result.pixelMap;
        this.fullResMap.set(handle, pixelMap);
        const st = this.stateFor(handle);
        st.photoW = result.displayW;
        st.photoH = result.displayH;
        st.fullPm = pixelMap;
        // Only trigger preloads if this photo is still the current one
        if (handle === this.currentHandle()) {
          this.preloadNeighbors();
          // Resume queue processing (may have been paused waiting for current)
          if (!this.loadingPaused && !this.preloadActive) {
            this.processPreloadQueue();
          }
        }
      }
    } catch (_e) {
      // Silently fail — thumbnail stays visible
    } finally {
      if (this.loadingHandle === handle) {
        this.loadingHandle = -1;
        const st = this.stateFor(handle);
        st.loading = false;
        st.spinnerOn = false;
        // If queue was waiting for current load to finish, resume now
        if (!this.loadingPaused && this.preloadQueue.length > 0 && !this.preloadActive) {
          setTimeout(() => { this.processPreloadQueue(); }, 50);
        }
      }
    }
  }

  /**
   * Enqueue adjacent photos for serial preloading, ordered by distance from current.
   * Does NOT fire concurrent loads — processPreloadQueue() drains one at a time.
   */
  private preloadNeighbors(): void {
    // Scanning guard
    if (this.svc.scanning) return;

    // Don't rebuild preload queue during inertial scrolling
    if (this._inertiaAnim) {
      return;
    }

    const photos = this.getPhotos();
    const center = this.mainIdx;
    const window = this.preloadWindow;

    // Evict far-away full-res images (> 2× window)
    this.evictDistantFullRes(center);

    // Build priority queue: closer photos = lower priority number = loaded first
    const newQueue: PreloadTask[] = [];
    for (let i = center - window; i <= center + window; i++) {
      if (i === center || i < 0 || i >= photos.length) continue;
      const h = photos[i].handle;
      if (!this.fullResMap.has(h) && !this.preloadedHandles.has(h)) {
        const dist = Math.abs(i - center);
        newQueue.push({ handle: h, priority: dist });
        this.preloadedHandles.add(h);
      }
    }
    // Sort by priority (closer first), then replace existing queue
    newQueue.sort((a, b) => a.priority - b.priority);

    // Merge with existing queue: keep items not yet loaded, prepend new items
    const existing = this.preloadQueue.filter(
      q => !this.fullResMap.has(q.handle) && this.isInPreloadWindow(q.handle)
    );
    // Merge: existing items keep their position, new items inserted by priority
    const merged = newQueue.concat(existing);
    merged.sort((a, b) => a.priority - b.priority);
    // Deduplicate by handle
    const seen = new Set<number>();
    this.preloadQueue = merged.filter(q => {
      if (seen.has(q.handle)) return false;
      seen.add(q.handle);
      return true;
    });

    // Start draining the queue if not already running
    if (!this.preloadActive && !this.loadingPaused) {
      this.processPreloadQueue();
    }
  }

  /**
   * Drain the preload queue one item at a time, yielding to the UI between each.
   * Pauses automatically when loadingPaused is set (during user gestures).
   */
  private async processPreloadQueue(): Promise<void> {
    // Scanning guard
    if (this.svc.scanning) return;

    if (this.preloadActive) return;
    this.preloadActive = true;

    while (this.preloadQueue.length > 0) {
      // Check pause flag — if paused or in inertial scroll, stop and schedule resume
      if (this.loadingPaused || this._inertiaAnim) {
        this.preloadActive = false;
        return;
      }

      // Check if current photo needs loading (higher priority)
      const curHandle = this.currentHandle();
      if (curHandle >= 0 && !this.fullResMap.has(curHandle) && this.loadingHandle < 0) {
        // Current photo not loaded yet — pause preload and load it first
        this.preloadActive = false;
        this.loadFullRes(curHandle);
        return;
      }

      const task = this.preloadQueue.shift();
      if (!task) break;

      // Skip if already loaded or no longer in window
      if (this.fullResMap.has(task.handle) || !this.isInPreloadWindow(task.handle)) {
        this.preloadedHandles.delete(task.handle);
        continue;
      }

      // Skip if current photo is loading (don't compete with it)
      if (this.loadingHandle >= 0) {
        // Put it back and wait
        this.preloadQueue.unshift(task);
        this.preloadActive = false;
        // Retry after current load finishes
        setTimeout(() => {
          if (!this.loadingPaused) this.processPreloadQueue();
        }, 200);
        return;
      }

      try {
        const result = await this.svc.loadFullPhoto(task.handle);
        if (result !== null) {
          // 只写普通 Map：预加载邻近照片不该重建任何界面。
          this.fullResMap.set(task.handle, result.pixelMap);
          if (task.handle === this.currentHandle()) {
            this.presentCached(task.handle);
          }
        }
      } catch (_e) {
        // Silent
      }

      // Yield to the UI thread before next preload
      await new Promise<void>(r => setTimeout(r, 0));
    }

    this.preloadActive = false;
  }

  /** Check if a handle is still within the current preload window. */
  private isInPreloadWindow(handle: number): boolean {
    const photos = this.getPhotos();
    const center = this.mainIdx;
    const window = this.preloadWindow;
    for (let i = center - window; i <= center + window; i++) {
      if (i < 0 || i >= photos.length) continue;
      if (photos[i].handle === handle) return true;
    }
    return false;
  }

  /** Pause all preloading (called on gesture start). */
  private pausePreloading(): void {
    this.loadingPaused = true;
    this.lastInteractionTs = Date.now();
    if (this.pauseTimerId >= 0) {
      clearTimeout(this.pauseTimerId);
      this.pauseTimerId = -1;
    }
  }

  /** Schedule resume of preloading after interaction cooldown. */
  private scheduleResumePreloading(): void {
    this.lastInteractionTs = Date.now();
    if (this.pauseTimerId >= 0) {
      clearTimeout(this.pauseTimerId);
    }
    this.pauseTimerId = setTimeout(() => {
      this.pauseTimerId = -1;
      this.loadingPaused = false;
      // Resume preloading if queue has items
      if (this.preloadQueue.length > 0 && !this.preloadActive) {
        this.processPreloadQueue();
      }
    }, this.RESUME_COOLDOWN_MS);
  }

  /**
   * Evict full-res pixelMaps for photos far from the current index.
   * Keeps memory footprint manageable.
   */
  private evictDistantFullRes(center: number): void {
    const threshold = this.preloadWindow * 2 + 1;
    const photos = this.getPhotos();
    const toEvict: number[] = [];
    this.fullResMap.forEach((_v: image.PixelMap, handle: number) => {
      // Find the index of this handle
      let idx = -1;
      for (let i = 0; i < photos.length; i++) {
        if (photos[i].handle === handle) { idx = i; break; }
      }
      if (idx < 0 || Math.abs(idx - center) > threshold) {
        toEvict.push(handle);
      }
    });
    const releasing: image.PixelMap[] = [];
    for (const h of toEvict) {
      const pm = this.fullResMap.get(h);
      this.fullResMap.delete(h);
      this.preloadedHandles.delete(h);
      const st = this.renderStates.get(h);
      if (st !== undefined && st.fullPm === pm) { st.fullPm = null; }
      if (pm !== undefined) { releasing.push(pm); }
    }
    if (releasing.length > 0) {
      // 释放大位图会占用 UI 线程，挪到当前任务之后再放，
      // 避免正好压在一次捏合或翻页的中间。
      setTimeout(() => {
        for (const pm of releasing) {
          try { pm.release(); } catch (_e) { /* ignore */ }
        }
      }, 0);
    }
  }

  // ========== Title helpers ==========

  private currentPhoto(): PhotoEntry | null {
    const photos = this.getPhotos();
    if (this.mainIdx >= 0 && this.mainIdx < photos.length) {
      return photos[this.mainIdx];
    }
    return null;
  }

  private getMainTitle(): string {
    const p = this.currentPhoto();
    if (!p) return '走走拍拍';
    return formatCaptureDate(p) || p.filename;
  }

  private getSubTitle(): string {
    const p = this.currentPhoto();
    if (!p) return '';
    const parts: string[] = [];
    if (p.filename) parts.push(p.filename);
    if (p.size > 0) parts.push(formatFileSize(p.size));
    const res = formatResolution(p.imagePixWidth, p.imagePixHeight);
    if (res) parts.push(res);
    return parts.join('  ·  ');
  }

  @Builder
  TitleBar() {
    Row() {
      // Back button
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(IconSize.Nav)
          .fontColor([$r('app.color.text_on_dark')])
      }
      .width(36).height(36)
      .backgroundColor($r('app.color.viewer_glass_button'))
      .onClick(() => { this.handleBack(); })

      // Title block
      Column() {
        Text(this.getMainTitle())
          .fontSize(FontSize.CardTitle).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_on_dark'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.getSubTitle())
          .fontSize(FontSize.Caption).fontColor($r('app.color.viewer_text_on_dark_70'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })

      // Current index indicator
      Text(`${this.mainIdx + 1}/${this._realTotal}`)
        .fontSize(FontSize.Caption).fontColor($r('app.color.viewer_text_on_dark_70'))
        .margin({ right: 4 })
    }
    .width('100%')
    // The navigation content area already sits below the status bar,
    // so do not add the status-bar inset again here.
    .padding({ left: 12, right: 12, top: 12, bottom: 8 })
    .backgroundColor(this.chromeBg())
    .backgroundBlurStyle(this.chromeBlur(), { colorMode: ThemeColorMode.DARK })
    .opacity(this.chromeAlpha)
  }

  // ========== 一镜到底转场 ==========

  // ---- 矩形插值（帧回调驱动）----

  private static lerp(a: number, b: number, p: number): number {
    return a + (b - a) * p;
  }

  private stopRectAnimation(): void {
    if (this.morphSync !== null) {
      try {
        this.morphSync.off('frame');
        this.morphSync.stop();
      } catch (_e) { /* ignore */ }
      this.morphSync = null;
    }
    this.morphStartMs = -1;
    this.morphDone = null;
  }

  private onMorphFrame(info: displaySync.IntervalInfo): void {
    const nowMs = info.timestamp / 1000000;
    if (this.morphStartMs < 0) {
      // 第一帧只作为计时起点，画面保持起始矩形，避免起步就跳一格
      this.morphStartMs = nowMs;
      return;
    }
    const raw = this.morphDurationMs > 0 ? (nowMs - this.morphStartMs) / this.morphDurationMs : 1;
    const t = Math.max(0, Math.min(1, raw));
    const p = this.morphCurve.interpolate(t);
    this.morph.left = PhotoViewerScreen.lerp(this.morphFrom.left, this.morphTo.left, p);
    this.morph.top = PhotoViewerScreen.lerp(this.morphFrom.top, this.morphTo.top, p);
    this.morph.width = PhotoViewerScreen.lerp(this.morphFrom.width, this.morphTo.width, p);
    this.morph.height = PhotoViewerScreen.lerp(this.morphFrom.height, this.morphTo.height, p);
    if (t >= 1) {
      const done = this.morphDone;
      this.stopRectAnimation();
      if (done !== null) { done(); }
    }
  }

  /**
   * 从 `from` 插值到 `to`，结束后回调。取不到帧回调时直接落到终点，保证不卡住。
   */
  private startRectAnimation(from: MorphRect, to: MorphRect, duration: number,
    curve: ICurve, onDone: () => void): void {
    this.stopRectAnimation();
    this.morphFrom = from;
    this.morphTo = to;
    this.morphCurve = curve;
    this.morphDurationMs = duration;
    this.morphDone = onDone;
    this.morph.apply(from);
    let sync: displaySync.DisplaySync | null = null;
    try {
      sync = displaySync.create();
      sync.setExpectedFrameRateRange({ expected: 60, min: 30, max: 60 });
      sync.on('frame', (info: displaySync.IntervalInfo) => { this.onMorphFrame(info); });
    } catch (_e) {
      sync = null;
    }
    if (sync === null) {
      this.morph.apply(to);
      this.stopRectAnimation();
      onDone();
      return;
    }
    this.morphSync = sync;
    try {
      sync.start();
    } catch (_e) {
      this.morph.apply(to);
      this.stopRectAnimation();
      onDone();
    }
  }

  /** 转场矩形的一行日志文本（只用于排查，保持简短）。 */
  private morphRectText(r: MorphRect | null): string {
    if (r === null) {
      return 'none';
    }
    return `${r.left.toFixed(1)},${r.top.toFixed(1)} ${r.width.toFixed(1)}x${r.height.toFixed(1)}`;
  }

  private currentMorphRect(): MorphRect {
    return new MorphRect(this.morph.left, this.morph.top, this.morph.width, this.morph.height);
  }

  private cancelChromeTimer(): void {
    if (this.chromeTimerId >= 0) {
      clearTimeout(this.chromeTimerId);
      this.chromeTimerId = -1;
    }
  }

  /** 当前照片的显示宽高比（按已解码原图 / 缩略图的定向尺寸）。 */
  private currentAspect(): number {
    const h = this.currentHandle();
    if (h < 0) {
      return 1;
    }
    const st = this.stateFor(h);
    return MorphGeometry.aspectOf(st.photoW, st.photoH);
  }

  /**
   * 当前照片的中间层是否在场（已经在显示缩略图或原图）。
   * 分享元素动画只对「已显示的画面」有意义；纯占位时不假装有照片。
   */
  private currentPixelMap(): image.PixelMap | null {
    const h = this.currentHandle();
    if (h < 0) {
      return null;
    }
    const st = this.renderStates.get(h);
    if (st !== undefined && st.fullPm !== null) {
      return st.fullPm;
    }
    return this.svc.thumbnailPixelMapMap.get(h) ?? null;
  }

  /**
   * 当前屏幕显示的照片矩形（vp）。未放大时就是 `Contain` 矩形；
   * 放大/拖动过则按缩放快照换算，保证「放大后返回」也从当前画面收缩。
   */
  private currentDisplayRect(): MorphRect {
    const base = MorphGeometry.containRect(this.currentAspect());
    const s = this.curZoomScale;
    if (s <= 1.001) {
      return base;
    }
    const w = base.width * s;
    const h = base.height * s;
    const cx = base.left + base.width / 2 + this.curZoomX;
    const cy = base.top + base.height / 2 + this.curZoomY;
    return new MorphRect(cx - w / 2, cy - h / 2, w, h);
  }

  /**
   * 展开：缩略图矩形 → 照片在预览器里的显示矩形。
   * 照片落位的同时揭开主图与标题栏，共享层随即撤场。
   */
  private playPush(proxy: NavigationTransitionProxy | null): void {
    if (!this.morph.visible) {
      // 没有起点矩形（异常路径）：不做假动画，直接给内容
      this.photoAlpha = 1;
      this.chromeAlpha = 1;
      if (proxy) { proxy.finishTransition(); }
      return;
    }
    const ui = this.getUIContext();
    const end: MorphRect = MorphGeometry.containRect(this.currentAspect());
    this.startRectAnimation(this.currentMorphRect(), end, PUSH_MS, MORPH_CURVE, () => {
      // 与共享层同一帧换手：矩形比例已等于照片比例，Cover/Contain 完全重合
      this.morph.visible = false;
      this.photoAlpha = 1;
      if (proxy) { proxy.finishTransition(); }
    });
    ui.animateTo({ duration: BACKDROP_IN_MS, curve: Curve.EaseOut }, () => {
      this.morph.backdrop = 1;
    });
    this.cancelChromeTimer();
    this.chromeTimerId = setTimeout(() => {
      this.chromeTimerId = -1;
      this.getUIContext().animateTo({ duration: CHROME_IN_MS, curve: Curve.EaseOut }, () => {
        this.chromeAlpha = 1;
      });
    }, CHROME_IN_DELAY_MS);
  }

  /** 收回：显示矩形 → 当前照片缩略图的矩形，背景同时透出画廊。 */
  private playPop(proxy: NavigationTransitionProxy | null): void {
    if (!this.morph.visible) {
      if (proxy) { proxy.finishTransition(); }
      return;
    }
    const ui = this.getUIContext();
    ui.animateTo({ duration: CHROME_OUT_MS, curve: Curve.EaseOut }, () => {
      this.chromeAlpha = 0;
    });
    this.popProxyRef = proxy;
    this.popRetryLeft = POP_TARGET_RETRIES;
    this.startPopRect();
  }

  private cancelPopRetry(): void {
    if (this.popRetryId >= 0) {
      clearTimeout(this.popRetryId);
      this.popRetryId = -1;
    }
    this.popRetryLeft = 0;
    this.popProxyRef = null;
  }

  /**
   * 目标格子至少有一半在窗口内，收回动画才收得进眼睛看得见的地方。
   * 列表有 `cachedCount`，目标格子可能已经渲染但落在屏幕外——这种也要滚。
   */
  private isPopRectUsable(r: RectInfoInPx): boolean {
    if (!(r.width > 0) || !(r.height > 0)) {
      return false;
    }
    const windowVp = WindowUtils.windowHeightPx > 0 ? px2vp(WindowUtils.windowHeightPx) : 0;
    if (windowVp <= 0) {
      return true;
    }
    const visible = Math.min(px2vp(r.bottom), windowVp) - Math.max(px2vp(r.top), 0);
    return visible >= px2vp(r.height) * 0.5;
  }

  /**
   * 查某张照片在画廊里的实时矩形。拿不到、或不在可视区时返回 null，
   * 并（一次 pop 只请求一次）让画廊先滚到那一行。
   */
  private popRectFor(handle: number): MorphRect | null {
    if (handle < 0) {
      return null;
    }
    let rectStr: string = '';
    if (this.positionLookup) {
      try { rectStr = this.positionLookup(handle); } catch (_e) { rectStr = ''; }
    }
    let px: RectInfoInPx | null = null;
    if (rectStr) {
      try { px = JSON.parse(rectStr) as RectInfoInPx; } catch (_e) { px = null; }
    }
    if (px !== null && this.isPopRectUsable(px)) {
      return MorphGeometry.fromPx(px);
    }
    if (!this.popScrollRequested && this.requestGalleryScroll) {
      this.popScrollRequested = true;
      this.svc.getLog().add('pop: 目标格子不在可视区，请求画廊滚动 handle=' + handle);
      try { this.requestGalleryScroll(handle); } catch (_e) { /* ignore */ }
    }
    return null;
  }

  /**
   * 收回动画的起点已摆好，等目标矩形就绪后开始。
   *
   * 目标格子可能因为列表虚拟化还没渲染、或渲染在屏幕外而暂时查不到：`handleBack`
   * 已经请求画廊滚过去，这里按帧重试，拿到就立刻开始收回；超时仍拿不到才退回
   * push 时缓存的位置。标题栏淡出与背景透出不等这里，所以用户看不到停顿。
   */
  private startPopRect(): void {
    const handle = this.currentHandle();
    if (this.popTargetRect === null) {
      this.popTargetRect = this.popRectFor(handle);
    }
    if (this.popTargetRect === null && this.popRetryLeft > 0) {
      this.popRetryLeft--;
      this.popRetryId = setTimeout(() => {
        this.popRetryId = -1;
        this.startPopRect();
      }, POP_TARGET_RETRY_MS);
      return;
    }
    let target: MorphRect | null = this.popTargetRect;
    if (this.popScrollRequested && this.popScrollSettled < POP_SCROLL_SETTLE_FRAMES) {
      // 目标已经拿到，但列表刚被滚动过：多等一帧让新布局上屏，再开始透出+收回
      this.popScrollSettled++;
      this.popRetryId = setTimeout(() => {
        this.popRetryId = -1;
        this.startPopRect();
      }, POP_TARGET_RETRY_MS);
      return;
    }
    if (target === null) {
      // 兜底：push 时缓存的位置 > 最初点的那张
      const cachedStr = this.posCache[String(handle)] ?? '';
      if (cachedStr) {
        try {
          const cachedRect = MorphGeometry.fromPx(JSON.parse(cachedStr) as RectInfoInPx);
          if (MorphGeometry.isValid(cachedRect)) { target = cachedRect; }
        } catch (_e) { /* ignore */ }
      }
      if (target === null) {
        const fallback = MorphGeometry.fromPx(this.cardItemInfo);
        target = MorphGeometry.isValid(fallback) ? fallback : null;
      }
      this.svc.getLog().add('pop: 目标矩形兜底 ' + this.morphRectText(target));
    }
    const proxy = this.popProxyRef;
    this.cancelPopRetry();
    if (target === null) {
      this.morph.visible = false;
      if (proxy) { proxy.finishTransition(); }
      return;
    }
    this.svc.getLog().add('pop: 收回目标 ' + this.morphRectText(target));
    // 背景透出与收回动画一起开始：目标格子可能要等画廊滚动（上面会重试几帧），
    // 先滚好再透出，用户就不会看到「网格跳一下」。
    this.getUIContext().animateTo({ duration: BACKDROP_OUT_MS, curve: Curve.EaseOut }, () => {
      this.morph.backdrop = 0;
    });
    this.startRectAnimation(this.currentMorphRect(), target, POP_MS, MORPH_CURVE, () => {
      this.morph.visible = false;
      if (proxy) { proxy.finishTransition(); }
    });
  }

  /**
   * 共享元素式返回。标题栏返回键与系统返回键都走这里。
   *
   * 先把共享层摆到「当前画面」的位置再 pop：这样 pop 真正开始时页面上没有
   * 任何一帧是空的，标题栏与缩略图条随后淡出、照片收回缩略图。
   */
  private handleBack(): void {
    this.cancelPopRetry();
    this.popScrollRequested = false;
    this.popScrollSettled = 0;
    const curHandle = this.currentHandle();
    // 实时矩形优先；不在可视区（或还没被列表渲染）时，popRectFor 会让画廊滚过去，
    // 真正的等待与重试在 startPopRect 里，不阻塞返回动作。
    this.popTargetRect = this.popRectFor(curHandle);

    const pm = this.currentPixelMap();
    const displayRect = this.currentDisplayRect();
    this.svc.getLog().add('pop: handle=' + curHandle + ' pm=' + (pm !== null) +
      ' rect=' + this.morphRectText(displayRect) + ' -> ' +
      (this.popTargetRect !== null ? this.morphRectText(this.popTargetRect) : 'pending'));
    if (pm !== null) {
      this.morphPm = pm;
      this.morph.apply(displayRect);
      this.morph.visible = true;
      this.photoAlpha = 0;
    }
    this.pageInfos.pop();
  }

  // ========== Builders ==========

  /**
   * 标题栏 / 缩略图条的底色与模糊。
   *
   * 静止时用真材质观感（半透明黑 + COMPONENT_THICK 模糊）；一旦内容开始位移
   * （捏合、拖动、翻页、惯性），模糊会对背后每帧变化的图片重算一次，是预览器
   * 缩放卡顿的主要渲染成本，此时退化为稍深的半透明纯色，观感差别只在运动瞬间。
   */
  private chromeBg(): ResourceColor {
    return this.chromeMotion ? $r('app.color.viewer_chrome_motion') : $r('app.color.viewer_chrome');
  }

  private chromeBlur(): BlurStyle {
    return this.chromeMotion ? BlurStyle.NONE : BlurStyle.COMPONENT_THICK;
  }

  private getThumbPixelMap(realIdx: number): image.PixelMap | null {
    const photos = this.getPhotos();
    if (realIdx >= 0 && realIdx < photos.length) {
      const handle = photos[realIdx].handle;
      if (this.svc.thumbnailPixelMapMap.has(handle)) {
        return this.svc.thumbnailPixelMapMap.get(handle)!;
      }
    }
    return null;
  }

  @Builder
  buildMainImage(ri: RepeatItem<PhotoEntry>) {
    MainImageView({
      photo: ri.item,
      pageKey: ri.index,
      state: this.stateFor(ri.item.handle),
      thumbMap: this.svc.thumbnailPixelMapMap,
      svc: this.svc,
      onZoomChange: (zoomed: boolean) => { this.isZoomed = zoomed; },
      onGestureStart: () => {
        this.pausePreloading();
        this.setChromeMotion(true);
      },
      onGestureEnd: () => {
        this.scheduleResumePreloading();
        this.setChromeMotion(this._isDragging || this._inertiaAnim || this.pinchActive);
      },
      onPinchState: (active: boolean) => { this.setPinchActive(active); },
      onOverlayToggle: () => { this._overlayVisible = !this._overlayVisible; },
      onTransform: (s: number, x: number, y: number) => {
        this.curZoomScale = s;
        this.curZoomX = x;
        this.curZoomY = y;
      }
    })
  }

  @Builder
  ThumbCell(ri: RepeatItem<number>) {
    ThumbCellView({
      realIdx: this.isPlaceholder(ri.item) ? -1 : this.toReal(ri.item),
      pixelMap: this.isPlaceholder(ri.item) ? null : this.getThumbPixelMap(this.toReal(ri.item)),
      s: this.scaleArr[ri.item] ?? MIN_S,
      ox: this.offsetArr[ri.item] ?? 0,
      borderWeight: this.scaleArr[ri.item] >= MAX_S ? 1 : 0,
      onCellClick: (): void => {
        if (!this.isPlaceholder(ri.item)) { this.onThumbClick(this.toReal(ri.item)); }
      }
    })
  }

  /** 状态栏高度（vp），全屏布局下预览器自己避让。 */
  private topInsetVp(): number {
    const px = WindowUtils.topAvoidAreaHeightPx;
    return px > 0 ? px2vp(px) : 0;
  }

  /** 底部导航条高度（vp）。 */
  private bottomInsetVp(): number {
    const px = WindowUtils.navigationIndicatorHeightPx;
    return px > 0 ? px2vp(px) : 0;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 转场背板：从画廊颜色压到纯黑（pop 时反向透出画廊）。
        // 独立叶子组件，opacity 逐帧变化不会牵连本页 build()。
        MorphBackdrop({ alpha: this.morph.backdrop })

        // ===== Regular content (visible after the shared photo lands) =====
        Column() {
          // ===== Custom Title Bar =====
          if (this._overlayVisible) {
            this.TitleBar()
          }

          // ===== Main + Thumb Swipers =====
          Stack() {
            // ===== Main Swiper =====
            Swiper(this.mainCtrl) {
              Repeat<PhotoEntry>(this.mainPhotos)
                .each((ri: RepeatItem<PhotoEntry>) => {
                  Column() {
                    this.buildMainImage(ri);
                  }
                  .width('100%').height('100%')
                })
                .key((_photo: PhotoEntry, idx: number) => idx.toString())
                .virtualScroll({ totalCount: this.mainPhotos.length })
            }
            .index(this.mainIdx)
            .onAreaChange((_o: Area, n: Area) => {
              const w = n.width as number;
              if (w > 0) { this._swiperWidth = w; }
            })
            .disableSwipe(this.isZoomed)
            .onGestureSwipe((i: number, e: SwiperAnimationEvent) => { this.onMainGestureSwipe(i, e); })
            .onContentDidScroll((s: number, i: number, p: number) => { this.onMainContentDidScroll(s, i, p); })
            .onAnimationEnd((i: number) => { this.onMainAnimationEnd(i); })
            .onChange((i: number) => { this.onMainChange(i); })
            .cachedCount(6).loop(false).indicator(false)
            .curve(this._inertiaAnim ? Curve.Friction : Curve.Linear)
            .duration(this._inertiaAnim ? INERTIA_DURATION : SNAP_DURATION)
            .width('100%').height('100%')
            // 转场期间由共享照片层代表这张照片，落地后一次性交还
            .opacity(this.photoAlpha)

            // ===== Thumb Swiper =====
            Column() {
              Blank()
              Row() {
                Swiper(this.thumbCtrl) {
                  Repeat<number>(this.displayIndices)
                    .each((ri: RepeatItem<number>) => {
                      this.ThumbCell(ri)
                    })
                    .key((idx: number) => idx.toString())
                    .virtualScroll({ totalCount: this._displayTotal })
                }
                .cachedCount(6)
                .index(this.thumbIdx)
                .displayCount(this._displayCount)
                .indicator(false).itemSpace(ITEM_SPACE)
                .width('100%').height(this._thumbItemW).clip(false)
                .disableSwipe(false).loop(false)
                .curve(this._inertiaAnim ? Curve.Friction : Curve.Linear)
                .duration(this._inertiaAnim ? INERTIA_DURATION : SNAP_DURATION)
                .onGestureSwipe((i: number, e: SwiperAnimationEvent) => { this.onThumbGestureSwipe(i, e); })
                .onAnimationStart((i: number, t: number) => { this.onThumbAnimationStart(i, t); })
                .onAnimationEnd((i: number) => { this.onThumbAnimationEnd(i); })
                .onChange((i: number) => { this.onThumbChange(i); })
                .onAreaChange((_o: Area, n: Area) => {
                  const sw = n.width as number;
                  if (sw > 0) {
                    this._thumbItemW = (sw - (this._displayCount - 1) * ITEM_SPACE) / this._displayCount;
                  }
                })
                .parallelGesture(
                  PanGesture()
                    .onActionUpdate((e: GestureEvent) => {
                      const vx = e.velocityX || 0;
                      if (Math.abs(vx) >= INERTIA_THRESHOLD && !this._inertiaAnim) {
                        this._inertiaAnim = true;
                      }
                    })
                    .onActionEnd((e: GestureEvent) => {
                      const vx = e.velocityX || 0;
                      if (Math.abs(vx) < INERTIA_THRESHOLD) {
                        this._inertiaAnim = false;
                        return;
                      }
                      const jump = Math.max(1, Math.round(Math.abs(vx) / INERTIA_FACTOR));
                      const step = vx > 0 ? -jump : jump;
                      const target = Math.max(0, Math.min(this.mainIdx + step, this._realTotal - 1));
                      if (target !== this.mainIdx) {
                        const dt = this._displayTotal;
                        for (let i = 0; i < dt; i++) {
                          this.scaleArr[i] = this.isPlaceholder(i) ? 0 : MIN_S;
                          this.offsetArr[i] = 0;
                        }
                        this._fromMain = true;
                        this.thumbCtrl.changeIndex(target, true);
                        this.mainCtrl.changeIndex(target, true);
                      } else {
                        this._inertiaAnim = false;
                      }
                    })
                )
              }
              .width('100%')
              // Reserved area for the gesture bar is already excluded from
              // the page, so the extra inset would be double-counted.
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(this.chromeBg())
              .backgroundBlurStyle(this.chromeBlur(), { colorMode: ThemeColorMode.DARK })
              .opacity(this.chromeAlpha)
            }
            .width('100%').height('100%')
            .hitTestBehavior(HitTestMode.Transparent)
            .visibility(this._overlayVisible ? Visibility.Visible : Visibility.Hidden)
            .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
          }
          .width('100%').height('100%')
          // 这里不能再铺纯黑：转场期间整页要透出下层画廊，
          // 黑底由最底层的 MorphBackdrop 统一提供（它自己会渐入到纯黑）。
          .layoutWeight(1)
        }
        .width('100%').height('100%')
        // 窗口是全屏布局，预览器自己要避让状态栏与导航条
        .padding({ top: this.topInsetVp(), bottom: this.bottomInsetVp() })

        // ===== 共享照片层（转场期间唯一可见的照片，最后绘制在最上层）=====
        if (this.morph.visible) {
          PhotoMorphLayer({ pixelMap: this.morphPm, state: this.morph })
        }
      }
      .width('100%').height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM])
    }
    .hideTitleBar(true)
    // 转场期间必须透明：下层画廊要靠它透出来；黑底由 MorphBackdrop 负责
    .backgroundColor(Color.Transparent)
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
      this.pageId = this.pageInfos.getAllPathName().length - 1;

      // Read navigation params
      const param = context.pathInfo?.param as Record<string, Object>;
      const handle = param['handle'] as number;
      const handles = param['handles'] as number[] | undefined;
      const startIndex = param['startIndex'] as number | undefined;

      // Read card position info for shared element animation
      const cardItemInfoStr = param['cardItemInfo'] as string;
      if (cardItemInfoStr) {
        try {
          this.cardItemInfo = JSON.parse(cardItemInfoStr) as RectInfoInPx;
        } catch (_e) {}
      }

      // Position lookup callback + cached positions (from push time)
      this.positionLookup = param['positionLookup'] as ((handle: number) => string) | undefined;
      // 目标格子不在可视区时，请画廊先把列表滚到那一行（官方图库也是先对齐网格）
      this.requestGalleryScroll = param['requestGalleryScroll'] as
        ((handle: number) => void) | undefined;
      const posCacheStr = param['posCache'] as string | undefined;
      if (posCacheStr) {
        try { this.posCache = JSON.parse(posCacheStr) as Record<string, string>; } catch (_e) {}
      }

      // Initialize photo list and starting index
      this.initFromParams(handle, handles, startIndex);

      // 共享照片层的第一帧（在首次渲染之前设置，避免闪一下）：
      // 起点 = 被点缩略图在画廊里的屏幕矩形，内容 = 那张缩略图。
      const startRect: MorphRect = MorphGeometry.fromPx(this.cardItemInfo);
      const startPm = this.svc.thumbnailPixelMapMap.get(handle);
      if (startPm !== undefined && MorphGeometry.isValid(startRect)) {
        this.morphPm = startPm;
        this.morph.apply(startRect);
        this.morph.visible = true;
        this.photoAlpha = 0;
        this.chromeAlpha = 0;
      } else {
        // 没有缩略图 / 没有位置：退化成「直接出现」，不做假动画
        this.morph.visible = false;
        this.photoAlpha = 1;
        this.chromeAlpha = 1;
      }
      this.svc.getLog().add('push morph ' + this.morphRectText(startRect) + ' pm=' +
        (startPm !== undefined));

      // Register custom transition animation callback
      CustomTransition.getInstance().registerNavParam(this.pageId,
        (isPush: boolean, isExit: boolean, transitionProxy: NavigationTransitionProxy) => {
          if (isPush) {
            this.playPush(transitionProxy);
          } else {
            this.playPop(transitionProxy);
          }
        }, 500);
    })
    .onBackPressed(() => {
      this.handleBack();
      return true;
    })
    .onDisAppear(() => {
      CustomTransition.getInstance().unRegisterNavParam(this.pageId);
    })
  }
}
