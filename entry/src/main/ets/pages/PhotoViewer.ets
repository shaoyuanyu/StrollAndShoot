import { image } from '@kit.ImageKit';
import { curves, uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { displaySync } from '@kit.ArkGraphics2D';
import { AbilityConstant, common, Configuration, EnvironmentCallback } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { CameraService } from '../services/CameraService';
import { GpsRecorder } from '../services/GpsRecorder';
import { GpsTrack, type GpsDayTrack } from '../utils/GpsTrack';
import { GpsTrackMap } from '../components/GpsTrackMap';
import { FavoritesStore } from '../model/FavoritesStore';
import { PtpPriority } from './PtpHost';
import type { DownloadProgress, GpsRecord, PhotoEntry } from '../model/PhotoEntry';
import { CustomTransition } from '../CustomTransition/CustomNavigationUtils';
import {
  MorphGeometry,
  MorphRect,
  MorphBackdrop,
  PhotoMorphLayer,
  PhotoMorphState,
  VIEWER_TITLE_BAR_HEIGHT
} from '../CustomTransition/PhotoMorph';
import { RectInfoInPx } from '../utils/ComponentAttrUtils';
import { WindowUtils } from '../utils/WindowUtils';
import { ControlHeight, FontSize, IconSize, Radius } from '../utils/UiTokens';
import { formatCaptureTime } from '../utils/DateTimeText';
import { GlassEffect } from '../utils/GlassEffect';

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

  /** 结束采样并返回帧摘要；不要求有 update() 调用（转场用）。 */
  endFramesOnly(): string {
    if (this.sync !== null) {
      try { this.sync.stop(); } catch (_e) { /* ignore */ }
    }
    if (this.frames === 0) { return ''; }
    const ms = Math.max(1, Date.now() - this.startMs);
    const fps = this.frames * 1000 / ms;
    return `frames=${this.frames}, fps=${fps.toFixed(0)}, ` +
      `lateFrames=${this.lateFrames}, gapMax=${this.maxFrameGapMs.toFixed(0)}ms`;
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
const SPINNER_DELAY_MS = 300;
/** 翻页停稳多久才启动全图下载；快速连滑时避免给中间页白下。 */
const FULLRES_STABLE_MS = 260;
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
/** 手动显示/隐藏标题栏与缩略图条的淡入淡出时长。 */
const CHROME_FADE_MS = 180;
/** 底部操作栏高度（vp）。与 Tabs 悬浮页签的默认高度一致。 */
const ACTION_BAR_HEIGHT = ControlHeight.Bar;
/** 操作栏浮层总高：多留 8vp 给悬浮胶囊的阴影，避免被 Tabs 边界裁掉。 */
const ACTION_BAR_OVERLAY_HEIGHT = ACTION_BAR_HEIGHT + 8;
/** 上滑打开详情面板的最小竖直位移（vp）。 */
const DETAILS_SWIPE_UP_VP = 40;

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
class PreviewHolder {
  pm: image.PixelMap | null = null;
}

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
    // GestureEvent.offsetX/offsetY 是「相对手指按下位置」的屏幕空间位移（vp），
    // 不会被 .scale() 缩小。`applyTransform` / `clampAndCheckEdge` 里的
    // zoom.x/zoom.y 同样是屏幕空间（捏合路径用 pinchCenterX 直接算），
    // 所以这里**不能再乘 scale**：以前乘上去导致 5 倍缩放时手指划 100vp、
    // 照片走 500vp（ISSUE-015-B）。
    this.applyTransform(1, effectiveOffX, effectiveOffY);
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
              Text(this.svc.lastDecodedHandle >= 0
                ? $r('app.string.viewer_decoding') : $r('app.string.viewer_waiting_scan'))
                .fontSize(FontSize.Caption).fontColor($r('app.color.viewer_text_tertiary')).margin({ top: 8 })
            }
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.viewer_placeholder_bg'))
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

      // 扫描期间只给缩略图、不下载原图（USB 要留给缩略图传输）。这里明确告知用户，
      // 否则「一直不出原图」会被当成卡死或加载失败。
      if (this.svc.scanning && !this.hasFullRes() && this.svc.scanTotal > 0) {
        Column({ space: 2 }) {
          Text($r('app.string.viewer_scanning_thumb_only',
            this.svc.scanProgress, this.svc.scanTotal))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.viewer_text_on_dark_80'))
            .textAlign(TextAlign.Center)
            .width('100%')
          Text($r('app.string.viewer_scanning_thumb_note'))
            .fontSize(FontSize.Micro)
            .fontColor($r('app.color.viewer_text_on_dark_70'))
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .padding({ top: 6, bottom: 6, left: 16, right: 16 })
        .backgroundColor($r('app.color.viewer_banner_bg'))
        .position({ bottom: 0 })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%').height('100%')
  }
}

// ---- Constants (from SwiperSyncTestPage) ----
const MAX_S = 1.3;
const MIN_S = 1.0;
const ITEM_SPACE = 2;
const CENTER_OFFSET = 14;
const SNAP_DURATION = 150;
/** 缩略图条落位动画的安全超时：万一没收到 onAnimationEnd，也要恢复全量图加载。 */
const THUMB_SETTLE_GUARD_MS = 1600;

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
  const y = parseInt(raw.substring(0, 4), 10);
  const mo = parseInt(raw.substring(4, 6), 10);
  const d = parseInt(raw.substring(6, 8), 10);
  const h = parseInt(raw.substring(9, 11), 10);
  const mi = parseInt(raw.substring(11, 13), 10);
  const s = parseInt(raw.substring(13, 15), 10);
  if (!Number.isFinite(y) || !Number.isFinite(mo) || !Number.isFinite(d) ||
    !Number.isFinite(h) || !Number.isFinite(mi) || !Number.isFinite(s)) return '';
  return formatCaptureTime(y, mo, d, h, mi, s);
}

function formatFileSize(bytes: number): string {
  if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${bytes} B`;
}

// ---- ThumbCellView (separate @ComponentV2 for proper Repeat+virtualScroll recycling) ----
@ComponentV2
struct ThumbCellView {
  @Param realIdx: number = -1;
  @Param pixelMap: image.PixelMap | null = null;
  @Param s: number = 1.0;
  @Param ox: number = 0;
  @Param borderWeight: number = 0;
  /** 是否是缩略图条的中心项：其余项压暗，把注意力留给当前这张。 */
  @Param emphasized: boolean = false;
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
    // 非中心项压暗（占位项本来就透明，不受影响）
    .opacity(this.emphasized ? 1 : 0.68)
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
  /**
   * 转场期间不发起原图下载与解码。
   *
   * USB 是串行管道，6MP 的下载 + 解码会和共享层动画抢主线程：真机实测转场
   * 帧率只有 33–48fps、gapMax 89ms，观感就是「几乎没有动画 + 一顿」。
   * 新页面默认是转场中，落地后再放行（另有兜底定时器，回调没来也不会一直卡着）。
   */
  private transitionActive: boolean = true;
  /** 标题栏 / 缩略图条不透明度：照片到位后才淡入。 */
  @Local chromeAlpha: number = 0;
  /**
   * 用户手动显示/隐藏控件的不透明度（0~1）。
   * 必须用数字而不是布尔：`animateTo` 不会对布尔值做插值，直接用布尔会让
   * 控件「啪」地消失。`_overlayVisible` 只负责逻辑状态。
   */
  @Local overlayAlpha: number = 1;
  /**
   * 控件是否还挂在渲染树上。
   * 淡出结束后才置 false：用 `Visibility.Hidden` 而不是 `opacity(0)` 收尾，
   * 因为隐藏节点会连同**子节点**一起退出命中测试——只把父容器设成
   * `hitTestBehavior(None)` 并不会阻止子按钮继续响应，隐藏后仍会误触。
   */
  @Local chromeVisible: boolean = true;
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
  /** 矩形动画的兜底定时器（onFinish 没来时的保险）。 */
  private morphTimerId: number = -1;
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
  /**
   * 保存到系统相册：正在保存的照片 handle（-1 表示空闲）。
   * 只影响保存按钮自己的图标，不参与整页状态。
   */
  @Local savingHandle: number = -1;
  /**
   * 当前相机已保存到系统相册的照片键。
   * 用数组而不是普通 Set：需要参与 V2 追踪，保存成功后按钮才会从下载图标换成对勾。
   */
  @Local savedKeys: string[] = [];
  /** 本地收藏（PersistenceV2，键与下载记录同源）。 */
  @Local favStore: FavoritesStore = FavoritesStore.getInstance();
  /** 详情面板是否显示。上滑照片或点标题栏右侧的 info 钮打开。 */
  @Local detailsOpen: boolean = false;
  /** 当前照片匹配到的 GPS 点与单点轨迹（详情面板里的地图）。 */
  @Local photoGps: GpsRecord | null = null;
  @Local photoTrack: GpsDayTrack | null = null;
  /** 正在把当前原图编码成分享文件。 */
  @Local shareBusy: boolean = false;
  /** 上滑手势采样：按下点与当前最大上移量（相对照片区域）。 */
  private swipeDownX: number = 0;
  private swipeDownY: number = 0;
  private swipeUpDy: number = 0;
  private swipeActive: boolean = false;
  /** 这一笔触摸里出现过多指（捏合）：抬手时不要再当成单击/上滑。 */
  private multiTouchSeen: boolean = false;
  /** MainScreen 传入：保存成功后同步画廊的已下载绿点。 */
  private notifyDownloadSaved: (() => void) | undefined = undefined;
  /** 显隐动画序号：淡出回调晚到时不误把刚唤出的控件收掉。 */
  private overlayFadeSeq: number = 0;
  /** 页面销毁守卫：保存是异步的，回调晚到时不再碰 UI。 */
  private destroyed: boolean = false;
  /**
   * 当前是否为深色模式。只用于 `backgroundBlurStyle` 的 colorMode 与系统栏图标：
   * 颜色资源本身由资源限定词自动切换，不需要在 build() 里逐项判断。
   *
   * **必须是 `@Local`**：用户可能停留在预览器里切换系统深/浅色。系统环境回调
   * 更新它后，页面需要重建一次，缩略图条的 `backgroundBlurStyle` 与颜色资源才会
   * 按新主题重新取值；写成普通字段时缩略图条会停在旧主题（其他组件的资源会由
   * 资源系统自动刷新，唯独这里的 `chromeBg()` + blur colorMode 不会）。
   */
  @Local isDark: boolean = false;
  /** 系统环境变化监听；预览器常驻期间可能跨一次深/浅色切换，退出时必须注销。 */
  private appCtx: common.ApplicationContext | null = null;
  private envCallbackId: number = -1;

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
  /** 最近一次翻页方向：+1 下一张，-1 上一张；预加载优先同方向。 */
  private swipeDir: number = 1;

  // ---- Interaction-aware serial preload queue ----
  private preloadQueue: PreloadTask[] = [];
  private preloadActive: boolean = false;
  private loadingPaused: boolean = false;
  /** 当前进行中的手势数（捏合与拖动可以并行，所以用计数而不是布尔）。 */
  private gestureDepth: number = 0;
  /** USB 正忙时被挡下的全尺寸加载请求，等当前下载结束时补投。 */
  private pendingFullResHandle: number = -1;
  /** 缩略图条落位动画的安全超时句柄。 */
  private thumbSettleGuardId: number = -1;
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
    // 深浅色跟随应用主题：系统栏内容色与页面背板保持一致（浅色深字、深色白字）。
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.isDark = WindowUtils.isDarkMode(hostCtx);
    WindowUtils.applyThemeSystemBars(this.isDark);
    // 预览器可能停留很久，期间系统深/浅色会变化。`chromeBg()` 返回的 ResourceColor
    // 与 `backgroundBlurStyle` 的 colorMode 不会自动跟随，必须由状态变化触发重建。
    // 注意：官方文档说明，即使应用显式设置了深浅色，系统主题变化仍会触发这个回调，
    // 所以这里用应用当前的有效配置（WindowUtils.isDarkMode）而不是 config.colorMode。
    const envCb: EnvironmentCallback = {
      onMemoryLevel: (_level: AbilityConstant.MemoryLevel): void => {
      },
      onConfigurationUpdated: (_config: Configuration): void => {
        if (this.destroyed) {
          return;
        }
        const dark = WindowUtils.isDarkMode(hostCtx);
        if (dark === this.isDark) {
          return;
        }
        this.isDark = dark;
        WindowUtils.applyThemeSystemBars(dark);
      }
    };
    try {
      if (hostCtx) {
        this.appCtx = hostCtx.getApplicationContext();
        this.envCallbackId = this.appCtx.on('environment', envCb);
      }
    } catch (_e) {
      // 拿不到 ApplicationContext 时至少保留 aboutToAppear 的初值
    }
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.cancelStableTimer();
    this.cancelChromeTimer();
    this.stopRectAnimation();
    this.cancelPopRetry();
    this.endThumbSettle();
    this.pendingFullResHandle = -1;
    if (this.spinnerTimerId >= 0) {
      clearTimeout(this.spinnerTimerId);
      this.spinnerTimerId = -1;
    }
    // 停掉预览器自己的解码队列，把后台预加载交还给服务层（回到画廊后下一次
    // 打开照片才不会又从零开始下载）。
    this.loadingPaused = true;
    this.svc.resumeNeighborPreload();
    // 注销系统环境监听，避免预览器退出后仍持有页面与上下文。
    if (this.appCtx !== null && this.envCallbackId >= 0) {
      this.appCtx.off('environment', this.envCallbackId).catch((_e: Error) => {
        // best effort
      });
      this.appCtx = null;
      this.envCallbackId = -1;
    }
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
    // 先挂上「加载中」状态：转场期间整页被共享照片层盖住，转圈不可见；
    // 落地那一刻照片一揭开就能立刻看到，而不是等防抖 + 显示延迟再出现。
    // 真正的下载由 finishTransitionGate() 在转场结束时立即发起。
    const initialHandle = this.currentHandle();
    if (initialHandle >= 0 && !this.fullResMap.has(initialHandle)) {
      this.pendingFullResHandle = initialHandle;
      this.markDeferredLoading(initialHandle);
      // 用户要求：一镜到底转场期间就开始取原图，不再等共享层落地。
      // 共享层始终显示缩略图，全尺寸解码完成只会更新底下被 photoAlpha 盖住的内容层；
      // 转场可能因此多一些 CPU/IO，但照片落位时往往已经就绪。
      this.loadFullRes(initialHandle, true);
    }
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

  // ========== 控件显隐（点击照片切换） ==========

  /**
   * 显示/隐藏标题栏与缩略图条。只由单击照片触发，**不做自动隐藏**。
   *
   * 隐藏 = 先淡出 180ms，再置 `Visibility.Hidden`。节点**始终保留布局位置**，
   * 所以照片区域尺寸不变、图片不会跳；隐藏后连同子按钮一起退出命中测试。
   */
  private setOverlayVisible(visible: boolean): void {
    if (this.destroyed || this._overlayVisible === visible) {
      return;
    }
    this._overlayVisible = visible;
    const seq = ++this.overlayFadeSeq;
    if (visible) {
      // 先挂上节点（此时透明度还是 0），下一帧再淡入
      this.chromeVisible = true;
      this.getUIContext().animateTo({ duration: CHROME_FADE_MS, curve: Curve.EaseOut }, () => {
        this.overlayAlpha = 1;
      });
    } else {
      this.getUIContext().animateTo({
        duration: CHROME_FADE_MS,
        curve: Curve.EaseOut,
        onFinish: () => {
          // 淡出期间又被唤出时不收节点，否则会闪一下
          if (seq === this.overlayFadeSeq && !this._overlayVisible && !this.destroyed) {
            this.chromeVisible = false;
          }
        }
      }, () => {
        this.overlayAlpha = 0;
      });
    }
  }

  private toggleOverlay(): void {
    this.setOverlayVisible(!this._overlayVisible);
  }

  /**
   * 照片区域的被动触摸采样：上滑打开详情面板。
   *
   * 用 `onTouch` 而不是再加一个 PanGesture：照片/缩略图/Swiper 已经有自己的
   * 手势链，多一个方向相同的手势会和它们抢识别；`onTouch` 只是旁观，不消费事件。
   */
  private onViewerTouch(event: TouchEvent): void {
    const t = event.touches.length > 0
      ? event.touches[0]
      : (event.changedTouches.length > 0 ? event.changedTouches[0] : null);
    if (event.type === TouchType.Down) {
      if (t === null) { return; }
      if (event.touches.length > 1) {
        // 第二根手指按下：这是捏合，不是单击/上滑
        this.multiTouchSeen = true;
        this.swipeActive = false;
        return;
      }
      this.swipeDownX = t.x;
      this.swipeDownY = t.y;
      this.swipeUpDy = 0;
      this.swipeActive = true;
      this.multiTouchSeen = false;
      return;
    }
    if (event.type === TouchType.Move) {
      if (event.touches.length > 1) {
        this.multiTouchSeen = true;
        this.swipeActive = false;
        return;
      }
      if (!this.swipeActive || t === null) { return; }
      this.swipeUpDy = Math.min(this.swipeUpDy, t.y - this.swipeDownY);
      return;
    }
    if (event.type === TouchType.Cancel) {
      // 手势被系统取消（来电、三指、与捏合冲突）时只复位，不能当成单击，
      // 否则一次被取消的触摸也会把标题栏/缩略图条收起来。
      this.swipeActive = false;
      return;
    }
    if (event.type === TouchType.Up) {
      if (this.multiTouchSeen) {
        // 捏合结束的那次抬手不能触发控件显隐/详情
        this.multiTouchSeen = false;
        this.swipeActive = false;
        return;
      }
      const dx = t !== null ? t.x - this.swipeDownX : 0;
      const dy = t !== null ? t.y - this.swipeDownY : 0;
      if (this.swipeActive) {
        if (Math.abs(dx) < 8 && Math.abs(dy) < 8) {
          // 单击照片：显示 / 隐藏标题栏与缩略图条
          this.toggleOverlay();
        } else if (!this.isZoomed && this.swipeUpDy <= -DETAILS_SWIPE_UP_VP &&
                   Math.abs(dx) < DETAILS_SWIPE_UP_VP * 1.5) {
          // 上滑打开详情面板
          this.openDetails();
        }
      }
      this.swipeActive = false;
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
    if (index !== this.mainIdx) {
      // 快速连滑时上一段动画的 end 可能晚到；不能让它把 mainIdx 拉回旧页。
      hilog.info(DOMAIN, TAG, `ignore stale animationEnd idx=${index} mainIdx=${this.mainIdx}`);
      return;
    }
    if (this._isDragging) {
      this.thumbCtrl.stopFakeDrag();
      this._isDragging = false;
    }
    this._fromMain = false;
    this.setChromeMotion(false);
    this.mainIdx = index;
    this.clearDeferredLoading(this.currentHandle());
    this.thumbIdx = index;
    this.thumbCtrl.changeIndex(index, false);
    this.updateScales(index);
    this.svc.setDetailIndex(index, this.getPhotos());
    this.scheduleFullResLoad();
  }

  private onMainChange(idx: number): void {
    hilog.info(DOMAIN, TAG, `onMainChange idx=${idx} mainIdx=${this.mainIdx} total=${this.mainPhotos.length}`);
    if (idx !== this.mainIdx) {
      this.swipeDir = idx > this.mainIdx ? 1 : -1;
    }
    this.mainIdx = idx;
    this.clearDeferredLoading(this.currentHandle());
    // 换了一张照片：缩放快照失效（ZoomableImage 切页时会自己复位）
    this.curZoomScale = 1;
    this.curZoomX = 0;
    this.curZoomY = 0;
    if (this._fromMain) {
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
    // 拖动过程中必须持续更新中心高亮。以前 `_inertiaAnim` 在手指还没抬起时
    // 就被置位，主图与高亮一起停住，用户会觉得“不跟手”（ISSUE-014-C）。
    if (this._fromMain) return;
    const centerReal = index - extraInfo.currentOffset / (this._thumbItemW + ITEM_SPACE);
    const clamped = Math.max(0, Math.min(Math.round(centerReal), this._realTotal - 1));
    if (clamped !== this.mainIdx) { this.mainIdx = clamped; }
    this.updateScales(centerReal);
    this.setChromeMotion(true);
  }

  private onThumbAnimationStart(_index: number, targetIndex: number): void {
    if (this._fromMain) return;
    const realTarget = Math.max(0, Math.min(targetIndex, this._realTotal - 1));
    this.mainCtrl.changeIndex(realTarget, true);
    // 缩略图条开始落位/惯性动画：只暂停全量图加载，不接管它的动画。
    this.beginThumbSettle();
  }

  /** 缩略图条进入落位动画：暂停全量图加载，动画结束后再补。 */
  private beginThumbSettle(): void {
    this._inertiaAnim = true;
    if (this.thumbSettleGuardId >= 0) { clearTimeout(this.thumbSettleGuardId); }
    this.thumbSettleGuardId = setTimeout(() => {
      this.thumbSettleGuardId = -1;
      this.endThumbSettle();
    }, THUMB_SETTLE_GUARD_MS);
  }

  private endThumbSettle(): void {
    this._inertiaAnim = false;
    if (this.thumbSettleGuardId >= 0) {
      clearTimeout(this.thumbSettleGuardId);
      this.thumbSettleGuardId = -1;
    }
  }

  private onThumbAnimationEnd(index: number): void {
    this.endThumbSettle();
    if (this._fromMain) return;
    const realIdx = Math.max(0, Math.min(index, this._realTotal - 1));
    this.mainIdx = realIdx;
    this.thumbIdx = index;
    this.updateScales(realIdx);
    this.setChromeMotion(false);
    // 动画结束后补投当前页的全尺寸加载（动画期间是被暂停的）
    this.scheduleFullResLoad();
  }

  private onThumbChange(idx: number): void {
    this.thumbIdx = idx;
    if (this._fromMain) return;
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
      if (this.currentHandle() !== handle) {
        return;
      }
      this.loadFullRes(handle);
    }, FULLRES_STABLE_MS);
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

  /** 延迟加载时先给用户反馈：缩略图保留，同时立刻显示转圈。 */
  private markDeferredLoading(handle: number): void {
    if (handle < 0 || this.fullResMap.has(handle)) return;
    const st = this.stateFor(handle);
    st.loading = true;
    st.spinnerOn = true;
  }

  /** 清掉不再需要的延迟状态；正在下载的那张和 except 保留。 */
  private clearDeferredLoading(except: number): void {
    this.renderStates.forEach((st: PhotoRenderState, h: number) => {
      if (h !== except && h !== this.loadingHandle) {
        st.loading = false;
        st.spinnerOn = false;
      }
    });
  }

  /**
   * @param immediate 首次进入预览器时用 true：跳过 300ms 的转圈显示延迟。
   *   普通翻页仍走防抖，避免快速滑动时转圈一闪一闪。
   */
  private async loadFullRes(handle: number, immediate: boolean = false): Promise<void> {
    // Scanning guard: no full-res loading until scan completes
    if (this.svc.scanning) return;
    // 已经加载过 / 就是当前正在加载的那张
    if (this.fullResMap.has(handle)) return;
    if (this.loadingHandle === handle) return;
    if (this.loadingHandle >= 0) {
      // 另一张正在下载：USB 是串行管道、不可取消（PtpHost 的 getObject 会等
      // usbBusy），所以先把「用户真正想看的这张」记下来，等当前下载结束后补投。
      // 以前这里直接 return，请求被静默丢弃，用户停在大号缩略图上（ISSUE-014-A）。
      this.pendingFullResHandle = handle;
      this.clearDeferredLoading(handle);
      this.markDeferredLoading(handle);
      return;
    }

    this.clearDeferredLoading(handle);
    this.loadingHandle = handle;
    const startState = this.stateFor(handle);
    const keepSpinner = startState.spinnerOn || immediate;
    startState.loading = true;
    if (this.spinnerTimerId >= 0) {
      clearTimeout(this.spinnerTimerId);
      this.spinnerTimerId = -1;
    }
    if (keepSpinner) {
      // 首次进入：照片一揭开就转圈，不再等 300ms
      startState.spinnerOn = true;
    } else {
      startState.spinnerOn = false;
      this.spinnerTimerId = setTimeout(() => {
        this.spinnerTimerId = -1;
        if (this.loadingHandle === handle && this.stateFor(handle).loading) {
          this.stateFor(handle).spinnerOn = true;
        }
      }, SPINNER_DELAY_MS);
    }
    const previewHolder = new PreviewHolder();
    try {
      const result = await this.svc.loadFullPhoto(handle, PtpPriority.FOREGROUND,
        (pm: image.PixelMap, w: number, h: number) => {
          if (this.loadingHandle !== handle || this.currentHandle() !== handle) {
            try {
              pm.release();
            } catch (_e) { /* best effort */ }
            return;
          }
          previewHolder.pm = pm;
          const st = this.stateFor(handle);
          st.fullPm = pm;
          st.photoW = w;
          st.photoH = h;
          st.loading = false;
          st.spinnerOn = false;
        });
      if (result !== null) {
        const pixelMap = result.pixelMap;
        this.fullResMap.set(handle, pixelMap);
        const st = this.stateFor(handle);
        st.photoW = result.displayW;
        st.photoH = result.displayH;
        st.fullPm = pixelMap;
        const preview = previewHolder.pm;
        if (preview !== null) {
          try {
            preview.release();
          } catch (_e) { /* best effort */ }
          previewHolder.pm = null;
        }
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
        // 补投被丢弃的请求：优先当前页，其次刚才排队的那张。
        const remembered = this.pendingFullResHandle;
        this.pendingFullResHandle = -1;
        const cur = this.currentHandle();
        let next = -1;
        if (cur >= 0 && cur !== handle && !this.fullResMap.has(cur)) {
          next = cur;
        } else if (remembered >= 0 && remembered !== handle &&
                   !this.fullResMap.has(remembered) && this.isInPreloadWindow(remembered)) {
          next = remembered;
        }
        if (next >= 0) {
          setTimeout(() => { this.loadFullRes(next); }, 0);
          return;
        }
        this.clearDeferredLoading(-1);
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
        const dir = i > center ? 1 : -1;
        // 同方向优先：下一张/上一张先于反方向同距离的图。
        const bias = dir === this.swipeDir ? 1 : 0;
        newQueue.push({ handle: h, priority: dist * 2 - bias });
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
        const result = await this.svc.loadFullPhoto(task.handle, PtpPriority.PRELOAD);
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
      // 捏合/拖动常常超过 300ms；只要手势还在进行就继续保持暂停。
      // 以前这里无条件恢复，于是「捏合到第 0.3 秒」后台预加载又开始了，
      // 每 1–2 秒读 7MB + 解一张 6MP，和捏合渲染抢带宽（ISSUE-015-A）。
      if (this.gestureDepth > 0) {
        this.scheduleResumePreloading();
        return;
      }
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

  private getMainTitle(): ResourceStr {
    const p = this.currentPhoto();
    if (!p) return $r('app.string.viewer_title_fallback');
    return formatCaptureDate(p) || p.filename;
  }



  // ========== 保存到系统相册 ==========

  /** 某张照片是否已经保存到系统相册（键与画廊绿点同源）。 */
  private isSaved(photo: PhotoEntry): boolean {
    const key = this.svc.makeDownloadKey(photo.filename, photo.size);
    for (const k of this.savedKeys) {
      if (k === key) { return true; }
    }
    return false;
  }

  private currentPhotoSaved(): boolean {
    const p = this.currentPhoto();
    return p !== null && this.isSaved(p);
  }

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2600 });
    } catch (_e) {
      // 页面正在退出时 toast 不可用，不影响保存本身
    }
  }

  /**
   * 把当前照片下载并保存到系统相册。
   *
   * 复用画廊的下载管线（USB 读取 → 写沙箱 → 按拍摄时间写入 GPS → 系统相册确认框 →
   * 下载记录），所以保存后回到画廊会立刻显示已下载绿点。
   */
  private async saveCurrentPhoto(): Promise<void> {
    if (this.savingHandle >= 0) { return; }
    const photo = this.currentPhoto();
    if (photo === null) { return; }
    if (this.svc.scanning) {
      this.toast($r('app.string.viewer_save_scanning'));
      return;
    }
    if (this.isSaved(photo)) {
      this.toast($r('app.string.viewer_already_saved'));
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!ctx) {
      this.toast($r('app.string.viewer_save_failed'));
      return;
    }

    this.savingHandle = photo.handle;
    // 预览器自己的邻近预加载和这次下载抢同一条 USB 管道：先清空队列并暂停，
    // 保存结束后再恢复（否则用户会看到保存按钮转很久）。
    this.cancelStableTimer();
    this.preloadQueue = [];
    this.pausePreloading();
    this.svc.getLog().add(`[PhotoViewer] 保存到相册: ${photo.filename} (${photo.size} B)`);
    try {
      await this.svc.downloadPhotos([photo.handle],
        (_progress: DownloadProgress) => { /* 顶栏用按钮转圈表达进度，不需要逐张回调 */ },
        ctx);
      if (this.destroyed) { return; }
      // 以「下载记录里真的有这条」为准：用户在系统相册确认框点取消时，
      // downloadPhotos 也会以 complete 结束，但记录不会写入。
      this.savedKeys = this.svc.getDownloadedKeys();
      if (this.isSaved(photo)) {
        this.toast($r('app.string.viewer_saved_to_album'));
        if (this.notifyDownloadSaved !== undefined) {
          try { this.notifyDownloadSaved(); } catch (_e) { /* ignore */ }
        }
      } else {
        this.toast($r('app.string.viewer_save_cancelled'));
      }
    } catch (err) {
      this.svc.getLog().add(`[PhotoViewer] 保存失败: ${JSON.stringify(err)}`);
      if (!this.destroyed) {
        this.toast($r('app.string.viewer_save_failed'));
      }
    } finally {
      if (!this.destroyed) {
        this.savingHandle = -1;
        this.scheduleResumePreloading();
      }
    }
  }

  /**
   * 顶部标题栏。
   *
   * 挂在 NavDestination 的 `.title()` 里（见 build），这是通用组件唯一能拿到
   * 系统沉浸光感材质的两个区域之一（另一个是横向 Tabs 的底部 TabBar）。
   * 标题栏本身不铺材质：只给两颗圆形按钮设置 `systemMaterial`，把材质面积
   * 控制在局部；整条背板用压色渐变保证文字在亮照片上也能读。
   *
   * 这里只放「拍摄时间 + 序号」：文件名 / 大小 / 分辨率等放上滑详情面板，
   * 否则一行副标题放不下，只能被省略号吃掉。
   */
  // ========== 收藏 / 分享 ==========

  private currentPhotoFavorite(): boolean {
    const p = this.currentPhoto();
    if (p === null) { return false; }
    return this.favStore.isFavorite(this.svc.makeDownloadKey(p.filename, p.size));
  }

  private toggleFavorite(): void {
    const p = this.currentPhoto();
    if (p === null) { return; }
    const key = this.svc.makeDownloadKey(p.filename, p.size);
    const nowFavorite = this.favStore.toggle(key);
    this.toast(nowFavorite
      ? $r('app.string.viewer_favorite_added')
      : $r('app.string.viewer_favorite_removed'));
    this.svc.getLog().add(`[PhotoViewer] 收藏${nowFavorite ? '' : '取消'}: ${p.filename}`);
  }

  /** 上一次分享临时文件的路径：下次分享前删掉，避免 cache 目录越积越多。 */
  private lastSharePath: string = '';

  /**
   * 分享：单击直接分享**原图**；长按分享按钮直接分享**压缩图**。
   * 两者都不弹选择框。原图取相机原始压缩字节，不重新编码；
   * 压缩图把当前已解码 PixelMap 重编码为高质量 JPEG。
   */
  private shareCurrentPhoto(): void {
    this.doShareCurrent(true);
  }


  private async doShareCurrent(original: boolean): Promise<void> {
    if (this.shareBusy) { return; }
    const p = this.currentPhoto();
    if (p === null) { return; }
    if (original && this.svc.scanning) {
      this.toast($r('app.string.viewer_share_scanning'));
      return;
    }
    const st = this.renderStates.get(p.handle);
    const pm = st !== undefined ? st.fullPm : null;
    if (!original && pm === null) {
      this.toast($r('app.string.viewer_share_no_image'));
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!ctx) { return; }

    this.shareBusy = true;
    this.toast($r('app.string.viewer_share_preparing'));
    const pausePreload = original;
    if (pausePreload) {
      // 取原图要走 USB：和保存一样先让预览器自己的预加载队列让路
      this.cancelStableTimer();
      this.preloadQueue = [];
      this.pausePreloading();
    }
    try {
      let buf: ArrayBuffer;
      let ext = 'jpg';
      let kind = '压缩图';
      if (original) {
        const bytes = await this.svc.getOriginalBytes(p.handle, PtpPriority.FOREGROUND);
        if (bytes === null) {
          this.toast($r('app.string.viewer_share_original_failed'));
          return;
        }
        buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
        const dot = p.filename.lastIndexOf('.');
        if (dot >= 0 && dot < p.filename.length - 1) {
          ext = p.filename.substring(dot + 1).toLowerCase();
        }
        kind = `原图 ${(bytes.length / 1048576).toFixed(1)}MB`;
      } else {
        const packer = image.createImagePacker();
        buf = await packer.packToData(pm!, { format: 'image/jpeg', quality: 92 });
      }

      if (this.lastSharePath !== '') {
        try { await fileIo.unlink(this.lastSharePath); } catch (_e) { /* best effort */ }
      }
      const path = `${ctx.cacheDir}/share_${p.handle}_${Date.now()}.${ext}`;
      const f = await fileIo.open(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.write(f.fd, buf);
      await fileIo.close(f);
      this.lastSharePath = path;

      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.IMAGE,
        uri: fileUri.getUriFromPath(path),
        title: p.filename
      });
      const controller = new systemShare.ShareController(shareData);
      await controller.show(ctx, {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
      this.svc.getLog().add(`[PhotoViewer] 分享(${kind}): ${p.filename}`);
    } catch (err) {
      this.svc.getLog().add(`[PhotoViewer] 分享失败: ${JSON.stringify(err)}`);
      if (!this.destroyed) {
        this.toast($r('app.string.viewer_share_failed'));
      }
    } finally {
      if (!this.destroyed) {
        this.shareBusy = false;
        if (pausePreload) {
          this.scheduleResumePreloading();
        }
      }
    }
  }

  @Builder
  TitleBar() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 顶部压色：浅色为页面底色、深色为黑 65% → 透明。不用材质是为了避免
      // 整条大面积材质，也避免和下面照片区域「一层玻璃压一层玻璃」。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.viewer_scrim_top'), 0.0],
            [$r('app.color.viewer_scrim_clear'), 1.0]
          ]
        })

      Row() {
        // 返回：40vp 圆形玻璃钮，与主界面标题栏的玻璃胶囊同一尺寸
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(IconSize.Nav)
            .fontColor([$r('app.color.viewer_chrome_text')])
        }
        .width(ControlHeight.Pill)
        .height(ControlHeight.Pill)
        // 兜底底色：调试开关关掉材质时仍是一个圆形玻璃钮，而不是一个孤零零的图标
        .backgroundColor($r('app.color.viewer_glass_button'))
        .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true,
          // 材质底色跟随主题：浅色给白底、深色给黑底，避免胶囊与页面背板撞色
          materialColor: $r('app.color.viewer_material_tint')
        })))
        .onClick(() => { this.handleBack(); })

        // 拍摄时间 + 序号。文件名、大小、分辨率都移到详情面板。
        Column({ space: 1 }) {
          Text(this.getMainTitle())
            .fontSize(FontSize.CardTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.viewer_chrome_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(`${this.mainIdx + 1} / ${this._realTotal}`)
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.viewer_chrome_text_secondary'))
            .maxLines(1)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .margin({ left: 12 })

        // 详情：也提供按钮入口，上滑手势不是所有用户都会发现
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(IconSize.Nav)
            .fontColor([$r('app.color.viewer_chrome_text')])
        }
        .width(ControlHeight.Pill)
        .height(ControlHeight.Pill)
        .backgroundColor($r('app.color.viewer_glass_button'))
        .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true,
          // 材质底色跟随主题：浅色给白底、深色给黑底，避免胶囊与页面背板撞色
          materialColor: $r('app.color.viewer_material_tint')
        })))
        .onClick(() => { this.openDetails(); })
      }
      .width('100%')
      .height(VIEWER_TITLE_BAR_HEIGHT)
      // 与 MorphGeometry 的标题栏高度保持一致：图片显示区域必须和实际布局同源，
      // 否则一镜到底的落点会比真实照片高几 vp（改高度要同步 PhotoMorph 常量）。
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .opacity(this.chromeAlpha * this.overlayAlpha)
    // 控件收起后连按钮一起退出命中测试（Visibility.Hidden 会作用于整棵子树）
    .visibility(this.chromeVisible ? Visibility.Visible : Visibility.Hidden)
  }

  // ========== 底部操作栏（下载 / 收藏 / 分享） ==========

  /**
   * 底部操作栏。
   *
   * 用 Tabs 的底部悬浮页签来承载：这是通用按钮在内容区拿到系统沉浸光感材质的
   * 唯一官方方式（`barFloatingStyle.systemMaterial`）。Tabs 只负责提供材质背板，
   * 真实内容仍然由上面的照片区域承担，所以这里放一个空 TabContent。
   */
  @Builder
  ActionBar() {
    Row() {
      // 下载 / 已保存
      Column({ space: 2 }) {
        Stack() {
          if (this.savingHandle >= 0) {
            LoadingProgress()
              .width(IconSize.Large)
              .height(IconSize.Large)
              .color($r('app.color.viewer_chrome_text'))
          } else {
            SymbolGlyph(this.currentPhotoSaved()
              ? $r('sys.symbol.checkmark_circle_fill')
              : $r('sys.symbol.arrow_down_to_line'))
              .fontSize(IconSize.Large)
              .fontColor([this.currentPhotoSaved()
                ? $r('app.color.status_connected')
                : $r('app.color.viewer_chrome_text')])
          }
        }
        .width(IconSize.Large).height(IconSize.Large)

        Text(this.currentPhotoSaved()
          ? $r('app.string.viewer_action_saved')
          : $r('app.string.viewer_action_download'))
          .fontSize(FontSize.Micro)
          .fontColor($r('app.color.viewer_chrome_text_secondary'))
          .maxLines(1)
      }
      .width('33.33%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.saveCurrentPhoto(); })

      // 收藏 / 已收藏
      Column({ space: 2 }) {
        SymbolGlyph(this.currentPhotoFavorite()
          ? $r('sys.symbol.bookmark_fill')
          : $r('sys.symbol.bookmark'))
          .fontSize(IconSize.Large)
          .fontColor([this.currentPhotoFavorite()
            ? $r('app.color.viewer_accent')
            : $r('app.color.viewer_chrome_text')])
          .width(IconSize.Large).height(IconSize.Large)

        Text(this.currentPhotoFavorite()
          ? $r('app.string.viewer_action_favorited')
          : $r('app.string.viewer_action_favorite'))
          .fontSize(FontSize.Micro)
          .fontColor($r('app.color.viewer_chrome_text_secondary'))
          .maxLines(1)
      }
      .width('33.33%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.toggleFavorite(); })

      // 分享
      Column({ space: 2 }) {
        Stack() {
          if (this.shareBusy) {
            LoadingProgress()
              .width(IconSize.Large)
              .height(IconSize.Large)
              .color($r('app.color.viewer_chrome_text'))
          } else {
            SymbolGlyph($r('sys.symbol.share'))
              .fontSize(IconSize.Large)
              .fontColor([$r('app.color.viewer_chrome_text')])
          }
        }
        .width(IconSize.Large).height(IconSize.Large)

        Text($r('app.string.viewer_action_share'))
          .fontSize(FontSize.Micro)
          .fontColor($r('app.color.viewer_chrome_text_secondary'))
          .maxLines(1)
      }
      .width('33.33%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.shareCurrentPhoto(); })
      // 长按直接走「压缩图」，不弹任何选择框；单击是原图
      .gesture(LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => { this.doShareCurrent(false); }))
    }
    .width('100%')
    .height('100%')
  }

  // ========== 上滑详情面板 ==========

  private openDetails(): void {
    const p = this.currentPhoto();
    if (p === null) { return; }
    const gps = p.captureDate ? GpsRecorder.getInstance().findClosest(p.captureDate) : null;
    this.photoGps = gps;
    if (gps !== null && p.captureDate && p.captureDate.length >= 8) {
      const day = `${p.captureDate.substring(0, 4)}-${p.captureDate.substring(4, 6)}-${p.captureDate.substring(6, 8)}`;
      // 用单点轨迹复用 GpsTrackMap 的地图/标记/降级能力
      this.photoTrack = GpsTrack.buildDayTrack(day, [gps]);
    } else {
      this.photoTrack = null;
    }
    this.detailsOpen = true;
  }

  private detailFormatText(): string {
    const p = this.currentPhoto();
    if (p === null) { return ''; }
    const ext = p.filename.substring(p.filename.lastIndexOf('.') + 1).toUpperCase();
    return ext !== '' ? ext : '';
  }

  private detailResolutionText(): string {
    const p = this.currentPhoto();
    if (p === null) { return ''; }
    const st = this.renderStates.get(p.handle);
    const w = st !== undefined && st.photoW > 1 ? Math.round(st.photoW) : (p.imagePixWidth ?? 0);
    const h = st !== undefined && st.photoH > 1 ? Math.round(st.photoH) : (p.imagePixHeight ?? 0);
    if (w > 0 && h > 0) { return `${w} × ${h}`; }
    return '';
  }

  private detailLocationText(): ResourceStr {
    const gps = this.photoGps;
    if (gps === null) { return $r('app.string.viewer_detail_no_location'); }
    return `${gps.latitude.toFixed(5)}, ${gps.longitude.toFixed(5)}`;
  }

  /** 当前照片是否匹配到了 GPS 点（决定「位置」行是否可点进当天轨迹）。 */
  private currentPhotoHasGps(): boolean {
    return this.photoGps !== null;
  }

  /** 打开当前照片当天在「定位记录」里的轨迹页（地图定位的落点）。 */
  private openPhotoDayTrack(): void {
    const p = this.currentPhoto();
    if (p === null || !p.captureDate || p.captureDate.length < 8) { return; }
    if (!this.currentPhotoHasGps()) { return; }
    const day = `${p.captureDate.substring(0, 4)}-${p.captureDate.substring(4, 6)}-${p.captureDate.substring(6, 8)}`;
    this.detailsOpen = false;
    const stack = this.pageInfos;
    // 等半模态收起再 push，避免新页面和面板动画叠在一起
    setTimeout(() => {
      const param: Record<string, Object> = {};
      param['day'] = day;
      stack.pushPath({ name: 'GpsTrackViewerPage', param: param });
    }, 250);
  }

  @Builder
  DetailRow(label: ResourceStr, value: ResourceStr) {
    Row({ space: 16 }) {
      Text(label)
        .fontSize(FontSize.Body)
        .fontColor($r('app.color.text_secondary'))
        .width(88)
        .flexShrink(0)
      Text(value)
        .fontSize(FontSize.Body)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 12, bottom: 12 })
  }

  /**
   * 详情面板参数。
   *
   * bindSheet 不跟随应用级材质开关，必须显式给 `systemMaterial`；调试关闭材质时
   * 不能把材质设成 `Material.empty`（面板会变全透明），要换回不透明底色。
   */
  private detailsSheetOptions(): SheetOptions {
    const opts: SheetOptions = {
      height: SheetSize.MEDIUM,
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      preferType: SheetType.BOTTOM,
      dragBar: true,
      showClose: false
    };
    if (GlassEffect.isEnabled()) {
      opts.systemMaterial = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THICK
      });
    } else {
      opts.backgroundColor = $r('app.color.bg_surface');
    }
    return opts;
  }

  @Builder
  DetailsSheet() {
    Column() {
      Text($r('app.string.viewer_details_title'))
        .fontSize(FontSize.PageTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: 8 })

      Scroll() {
        Column() {
          this.DetailRow($r('app.string.viewer_detail_filename'), this.getCurrentFilename())
          Divider().color($r('app.color.divider'))
          this.DetailRow($r('app.string.viewer_detail_capture'), this.getMainTitle())
          Divider().color($r('app.color.divider'))
          this.DetailRow($r('app.string.viewer_detail_resolution'), this.detailResolutionText())
          Divider().color($r('app.color.divider'))
          this.DetailRow($r('app.string.viewer_detail_size'), this.getCurrentSizeText())
          Divider().color($r('app.color.divider'))
          this.DetailRow($r('app.string.viewer_detail_format'), this.detailFormatText())
          Divider().color($r('app.color.divider'))
          this.DetailRow($r('app.string.viewer_detail_camera'), this.getCameraText())
          Divider().color($r('app.color.divider'))
          if (this.photoTrack !== null) {
            Column({ space: 8 }) {
              Row({ space: 16 }) {
                Text($r('app.string.viewer_detail_location'))
                  .fontSize(FontSize.Body)
                  .fontColor($r('app.color.text_secondary'))
                  .width(88)
                  .flexShrink(0)
                Text(this.detailLocationText())
                  .fontSize(FontSize.Body)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: 12 })

              Column() {
                GpsTrackMap({
                  track: this.photoTrack,
                  showStats: false,
                  onOpen: () => { this.openPhotoDayTrack(); }
                })
              }
              .width('100%')
              .height(160)
              .borderRadius(Radius.Inner)
              .clip(true)

              Row({ space: 4 }) {
                Text($r('app.string.viewer_detail_open_track'))
                  .fontSize(FontSize.Caption)
                  .fontColor($r('app.color.primary'))
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(IconSize.Small)
                  .fontColor([$r('app.color.primary')])
              }
              .width('100%')
              .justifyContent(FlexAlign.End)
              .padding({ bottom: 12 })
              .onClick(() => { this.openPhotoDayTrack(); })
            }
            .width('100%')
          } else {
            this.DetailRow($r('app.string.viewer_detail_location'), this.detailLocationText())
          }
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 8, bottom: 24 })
    // 调试关闭材质时面板容器本身可能仍是半透明；给内容层补一块不透明底，
    // 保证「文件名/位置」这些文字不会直接浮在照片上。开启材质时保持透明。
    .backgroundColor(GlassEffect.isEnabled() ? Color.Transparent : $r('app.color.bg_surface'))
    // 兜底底色是铺满的，给顶部两角圆回来，跟系统半模态的圆角一致
    .borderRadius(GlassEffect.isEnabled() ? 0 : { topLeft: Radius.Card, topRight: Radius.Card })
  }

  private getCurrentFilename(): string {
    const p = this.currentPhoto();
    return p !== null ? p.filename : '';
  }

  private getCurrentSizeText(): string {
    const p = this.currentPhoto();
    return p !== null && p.size > 0 ? formatFileSize(p.size) : '';
  }

  private getCameraText(): string {
    return this.svc.cameraName !== '' ? this.svc.cameraName : this.svc.cameraIdentity;
  }

  // ========== 一镜到底转场 ==========

  // ---- 转场帧采样 ----
  /** 转场期间与捏合同一套 displaySync 采样，用来量化“掉帧”而不是只凭观感。 */
  private morphPerf: PinchPerf = new PinchPerf();
  private morphPerfLabel: string = '';

  // ---- 矩形插值（帧回调驱动）----

  private static lerp(a: number, b: number, p: number): number {
    return a + (b - a) * p;
  }

  private stopRectAnimation(): void {
    if (this.morphPerfLabel !== '') {
      const summary = this.morphPerf.endFramesOnly();
      if (summary !== '') {
        hilog.info(DOMAIN, 'ViewerPerf', 'transition %{public}s %{public}s',
          this.morphPerfLabel, summary);
      }
      this.morphPerfLabel = '';
    }
    if (this.morphTimerId >= 0) {
      clearTimeout(this.morphTimerId);
      this.morphTimerId = -1;
    }
    this.morphDone = null;
  }

  /**
   * 从 `from` 插值到 `to`，结束后回调。
   *
   * 2026-11-09 真机：以前用 `displaySync` 每帧回调里改 4 个 @Trace 字段，
   * 等于每帧跑一次 JS build + 属性 diff，push 只有 47fps、pop 掉到 21fps
   * （`gapMax=134ms`）。现在把整段矩形变化交给 `animateTo` 的原生属性动画：
   * 插值在框架内部完成，不再逐帧回调 JS；`onFinish` 里再交接共享层。
   */
  private startRectAnimation(from: MorphRect, to: MorphRect, duration: number,
    curve: ICurve, onDone: () => void, label: string): void {
    this.stopRectAnimation();
    this.morphPerfLabel = label;
    this.morphPerf.begin();
    this.morph.apply(from);
    this.morphDone = onDone;
    const startedAt = Date.now();
    const ui = this.getUIContext();
    ui.animateTo({
      duration: duration,
      curve: curve,
      onFinish: () => {
        hilog.info(DOMAIN, 'ViewerPerf', 'transition %{public}s native %{public}dms',
          label, Date.now() - startedAt);
        const done = this.morphDone;
        this.stopRectAnimation();
        if (done !== null) { done(); }
      }
    }, () => {
      this.morph.apply(to);
    });
    // 兜底：onFinish 没来（例如转场被打断）也不能让共享层一直挂着
    this.morphTimerId = setTimeout(() => {
      this.morphTimerId = -1;
      const done = this.morphDone;
      this.stopRectAnimation();
      if (done !== null) { done(); }
    }, duration + 200);
  }

  /** 转场矩形的一行日志文本（只用于排查，保持简短）。 */
  private morphRectText(r: MorphRect | null): string {
    if (r === null) {
      return 'none';
    }
    return `${r.left.toFixed(1)},${r.top.toFixed(1)} ${r.width.toFixed(1)}x${r.height.toFixed(1)}`;
  }

  /**
   * 换共享层的位图，并把它的原始尺寸交给 PhotoMorphState。
   *
   * 位图原始尺寸是内层 `Image` 的固定布局尺寸；比例必须与位图一致，
   * 否则每帧的等比换算会多裁一块（见 PhotoMorph 头注释的推导）。
   */
  private setMorphBitmap(pm: image.PixelMap): void {
    this.morphPm = pm;
  }

  /** 转场结束（或兜底超时）后放行原图加载。 */
  private finishTransitionGate(): void {
    if (!this.transitionActive) {
      return;
    }
    this.transitionActive = false;
    const handle = this.currentHandle();
    if (handle < 0) {
      return;
    }
    // 原图在转场期间就已经开始取（initFromParams）。
    // 如果已经取到，这里直接交还位图；否则保留转圈状态，等下载/解码完成。
    if (this.fullResMap.has(handle)) {
      this.presentCached(handle);
      this.preloadNeighbors();
      return;
    }
    if (this.loadingHandle !== handle) {
      this.loadFullRes(handle, true);
    }
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
    const base = MorphGeometry.containRect(this.currentAspect(), this.bottomChromeHeight());
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
      this.finishTransitionGate();
      return;
    }
    const ui = this.getUIContext();
    const end: MorphRect = MorphGeometry.containRect(this.currentAspect(), this.bottomChromeHeight());
    this.startRectAnimation(this.currentMorphRect(), end, PUSH_MS, MORPH_CURVE, () => {
      // 与共享层同一帧换手：矩形比例已等于照片比例，Cover/Contain 完全重合
      this.morph.visible = false;
      this.photoAlpha = 1;
      if (proxy) { proxy.finishTransition(); }
      this.finishTransitionGate();
    }, 'push');
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
    }, 'pop');
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
      this.setMorphBitmap(pm);
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
    if (!GlassEffect.isEnabled()) {
      // 关闭磨砂时用较深的纯色保证文字对比度（模拟器调试用）
      return $r('app.color.viewer_chrome_motion');
    }
    return this.chromeMotion ? $r('app.color.viewer_chrome_motion') : $r('app.color.viewer_chrome');
  }

  private chromeBlur(): BlurStyle {
    if (!GlassEffect.isEnabled()) {
      return BlurStyle.NONE;
    }
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
        this.gestureDepth++;
        // 手指一落下就取消「停稳后下载」的定时器，避免滑动过程中给中间页白下一次 6MB。
        this.cancelStableTimer();
        this.pausePreloading();
        this.setChromeMotion(true);
      },
      onGestureEnd: () => {
        if (this.gestureDepth > 0) { this.gestureDepth--; }
        this.scheduleResumePreloading();
        this.setChromeMotion(this._isDragging || this._inertiaAnim || this.pinchActive);
      },
      onPinchState: (active: boolean) => { this.setPinchActive(active); },
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
      emphasized: this.scaleArr[ri.item] >= MAX_S,
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

  /** 缩略图条总高度（vp）：Swiper 高度 + 上下各 8vp 内边距。 */
  private thumbStripHeight(): number {
    return this._thumbItemW + 16;
  }

  /**
   * 预览器底部控件占用的总高度（vp）。
   *
   * 从图片区域底边往上：缩略图条（item + 16）+ 8vp 间距 + 操作栏 56vp。
   * `_thumbItemW` 是布局后才知道的，但它的值完全由窗口宽度、列数（最多 9）
   * 与 2vp 的 ITEM_SPACE 决定，所以这里直接按公式算，保证图片区域、
   * 一镜到底终点和实际布局三者同源。
   */
  private bottomChromeHeight(): number {
    const count = this._displayCount > 0 ? this._displayCount : 9;
    const widthVp = WindowUtils.windowWidthPx > 0 ? px2vp(WindowUtils.windowWidthPx) : 360;
    const itemW = (widthVp - 32 - (count - 1) * ITEM_SPACE) / count;
    return itemW + 16 + 8 + ControlHeight.Bar;
  }

  /** 底部导航条高度（vp）。 */
  private bottomInsetVp(): number {
    const px = WindowUtils.navigationIndicatorHeightPx;
    return px > 0 ? px2vp(px) : 0;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 转场背板：从画廊颜色压到页面底色（深色为纯黑；pop 时反向透出画廊）。
        // 独立叶子组件，opacity 逐帧变化不会牵连本页 build()。
        MorphBackdrop({ alpha: this.morph.backdrop })

        // ===== Regular content (visible after the shared photo lands) =====
        Column() {
          // 标题栏已移到 NavDestination 的 .title()（见 build 尾部）：
          // 只有标题栏 / 底部 TabBar 两个区域能拿到系统沉浸光感材质。
          // 这里保留同高的顶部留白，图片区域与 PhotoMorph 的几何保持同一口径。

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
            // 单击切控件 / 上滑开详情：挂在 Swiper 上，缩略图条与底部操作栏是它的兄弟节点，
            // 点在它们上面的触摸不会冒泡到这里。
            .onTouch((event: TouchEvent) => { this.onViewerTouch(event); })
            .onGestureSwipe((i: number, e: SwiperAnimationEvent) => { this.onMainGestureSwipe(i, e); })
            .onContentDidScroll((s: number, i: number, p: number) => { this.onMainContentDidScroll(s, i, p); })
            .onAnimationEnd((i: number) => { this.onMainAnimationEnd(i); })
            .onChange((i: number) => { this.onMainChange(i); })
            .cachedCount(6).loop(false).indicator(false)
            .curve(Curve.Linear)
            .duration(SNAP_DURATION)
            .width('100%').height('100%')
            // 底部让出缩略图条 + 操作栏：照片在剩余可见区域里居中，整体上移。
            // 与 MorphGeometry.containRect(..., bottomChromeHeight()) 同一口径。
            .padding({ bottom: this.bottomChromeHeight() })
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
                .curve(Curve.Linear)
                .duration(SNAP_DURATION)
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
              }
              .width('100%')
              // Reserved area for the gesture bar is already excluded from
              // the page, so the extra inset would be double-counted.
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(this.chromeBg())
              .backgroundBlurStyle(this.chromeBlur(), {
                colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
              })
              .opacity(this.chromeAlpha)
            }
            .width('100%').height('100%')
            // 缩略图条常驻：不再跟随单击照片显隐，只跟随转场淡入
            .hitTestBehavior(HitTestMode.Transparent)
          }
          .width('100%').height('100%')
          // 这里不能再铺不透明底色：转场期间整页要透出下层画廊，
          // 页面背板由最底层的 MorphBackdrop 统一提供（它自己会渐入到页面底色）。
          .layoutWeight(1)
        }
        .width('100%').height('100%')
        // 窗口是全屏布局，预览器自己要避让状态栏、标题栏与导航条。
        // 顶部 = 状态栏 + 标题栏，和 PhotoMorph.imageAreaTop() 同一口径。
        .padding({
          top: this.topInsetVp() + VIEWER_TITLE_BAR_HEIGHT,
          bottom: this.bottomInsetVp()
        })

        // ===== 底部操作栏（浮层） =====
        // 用一个高度只有操作栏的 Tabs 提供系统材质背板；TabContent 是空的，
        // 照片区域仍然由上面的 Column 承担，手势不受影响。
        Column() {
          Tabs({ barPosition: BarPosition.End }) {
            TabContent() {
            }
            .tabBar(this.ActionBar())
          }
          .width('100%')
          .height(ACTION_BAR_OVERLAY_HEIGHT)
          .scrollable(false)
          // 调试关闭材质时给一层页面色底，否则操作栏图标没有承托
          .backgroundColor(GlassEffect.isEnabled() ? Color.Transparent : $r('app.color.viewer_chrome'))
          // 官方悬浮页签：barOverlap + barPosition End + 横向 Tabs 三个条件同时满足，
          // barFloatingStyle.systemMaterial 才会生效。
          .barOverlap(true)
          .barFloatingStyle({
            barBottomMargin: 0,
            maskColor: Color.Transparent,
            systemMaterial: GlassEffect.material(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.REGULAR,
              interactive: true,
              materialColor: $r('app.color.viewer_material_tint')
            }))
          })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.End)
        // 操作栏在缩略图条上方：底部让出导航条 + 缩略图条高度 + 8vp 间距
        .padding({ bottom: this.bottomInsetVp() + this.thumbStripHeight() + 8 })
        // 与标题栏一起跟随单击淡出；缩略图条保持常驻
        .opacity(this.chromeAlpha * this.overlayAlpha)
        .visibility(this.chromeVisible ? Visibility.Visible : Visibility.Hidden)
        // 自身不响应，只让操作栏里的按钮接收点击；其余区域的触摸照常落到照片上
        .hitTestBehavior(HitTestMode.Transparent)

        // ===== 共享照片层（转场期间唯一可见的照片，最后绘制在最上层）=====
        if (this.morph.visible) {
          PhotoMorphLayer({ pixelMap: this.morphPm, state: this.morph })
        }
      }
      .width('100%').height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM])
      // 上滑详情面板：半模态自带材质，和标题栏 / 底部操作栏同一套沉浸光感。
      .bindSheet($$this.detailsOpen, this.DetailsSheet(), this.detailsSheetOptions())
    }
    .title({ builder: this.TitleBar, height: this.topInsetVp() + VIEWER_TITLE_BAR_HEIGHT }, {
      barStyle: BarStyle.STACK,
      // 背板不给材质（只给两颗按钮），避免整条大面积材质压住照片
      systemMaterial: uiMaterial.Material.empty
    })
    .hideBackButton(true)
    // 转场期间必须透明：下层画廊要靠它透出来；页面背板由 MorphBackdrop 负责
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
      // 在预览器里保存照片后，请 MainScreen 刷新已下载集合（画廊绿点）
      this.notifyDownloadSaved = param['onDownloadSaved'] as (() => void) | undefined;
      const posCacheStr = param['posCache'] as string | undefined;
      if (posCacheStr) {
        try { this.posCache = JSON.parse(posCacheStr) as Record<string, string>; } catch (_e) {}
      }

      // 保存按钮的初始状态与画廊绿点同源
      this.savedKeys = this.svc.getDownloadedKeys();

      // Initialize photo list and starting index
      this.initFromParams(handle, handles, startIndex);

      // 共享照片层的第一帧（在首次渲染之前设置，避免闪一下）：
      // 起点 = 被点缩略图在画廊里的屏幕矩形，内容 = 那张缩略图。
      const startRect: MorphRect = MorphGeometry.fromPx(this.cardItemInfo);
      const startPm = this.svc.thumbnailPixelMapMap.get(handle);
      if (startPm !== undefined && MorphGeometry.isValid(startRect)) {
        this.setMorphBitmap(startPm);
        this.morph.apply(startRect);
        this.morph.visible = true;
        this.photoAlpha = 0;
        this.chromeAlpha = 0;
      } else {
        // 没有缩略图 / 没有位置：退化成「直接出现」，不做假动画。
        // 背板必须一次性置为不透明，否则页面背景会透出下层画廊。
        this.morph.visible = false;
        this.morph.backdrop = 1;
        this.photoAlpha = 1;
        this.chromeAlpha = 1;
      }
      this.svc.getLog().add('push morph ' + this.morphRectText(startRect) + ' pm=' +
        (startPm !== undefined));
      // 兜底放行：转场回调没来（比如被系统直接跳过）时，不能让原图一直不加载
      setTimeout(() => { this.finishTransitionGate(); }, 900);

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
