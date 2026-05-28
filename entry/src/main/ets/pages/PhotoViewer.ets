import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry } from '../model/PhotoEntry';
import { CustomTransition } from '../CustomTransition/CustomNavigationUtils';
import { AnimationProperties } from '../CustomTransition/AnimationProperties';
import { getMyNode, MyNodeController } from '../NodeContainer/CustomComponent';
import { ComponentAttrUtils, RectInfoInPx } from '../utils/ComponentAttrUtils';

const TAG = 'PhotoViewer';
const DOMAIN = 0x0001;

// ---- ZoomableImage ----
@ComponentV2
struct ZoomableImage {
  @Param pixelMap: image.PixelMap | null = null;
  @Param photoW: number = 1;
  @Param photoH: number = 1;
  @Param pageKey: number = 0;
  @Event onZoomChange: (zoomed: boolean) => void = () => {};
  @Event onEdgeChange: (atEdge: boolean) => void = () => {};
  @Event onGestureStart: () => void = () => {};
  @Event onGestureEnd: () => void = () => {};
  @Local scaleVal: number = 1.0;
  @Local offX: number = 0;
  @Local offY: number = 0;
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

  @Monitor('pageKey')
  onPageChange(): void {
    animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.reset(); });
    this.updateImgCache();
  }

  @Monitor('photoW')
  onPhotoWChange(): void {
    this.updateImgCache();
  }

  aboutToAppear(): void {
    this.initContainerDims();
    this.updateImgCache();
  }

  private initContainerDims(): void {
    try {
      const d = display.getDefaultDisplaySync();
      if (d) {
        this.compW = d.width;
        this.compH = d.height;
        hilog.info(0x0001, 'ZoomClamp', 'display=%{public}dx%{public}d', d.width, d.height);
      }
    } catch (_e) { /* fallback to onAreaChange */ }
  }

  private updateImgCache(): void {
    const s = Math.min(this.compW > 0 ? this.compW / this.photoW : 1,
      this.compH > 0 ? this.compH / this.photoH : 1);
    this.imgW = this.photoW * s;
    this.imgH = this.photoH * s;
    hilog.info(0x0001, 'ZoomClamp', 'cache photo=%{public}dx%{public}d comp=%{public}dx%{public}d img=%{public}dx%{public}d s=%{public}f',
      this.photoW, this.photoH, this.compW, this.compH, this.imgW, this.imgH, s);
  }

  private reset(): void {
    this.scaleVal = 1.0;
    this.offX = 0;
    this.offY = 0;
    this.lastScale = 1.0;
    this.lastOffX = 0;
    this.lastOffY = 0;
    this.pinching = false;
    this.zoomCenterX = 0.5;
    this.zoomCenterY = 0.5;
    this.panActive = false;
    this.accumPanOffX = 0;
    this.accumPanOffY = 0;
  }

  private applyTransform(scale: number, panOffX: number, panOffY: number): void {
    const ns = Math.max(1.0, Math.min(5.0, this.lastScale * scale));
    this.scaleVal = ns;
    // Zoom compensation: keep the zoomCenter point fixed on screen
    // Formula: offX = (lastOffX + panOffX) + (zoomCenterX - 0.5) * imgW * lastScale * (1 - scale)
    this.offX = (this.lastOffX + panOffX) +
      (this.zoomCenterX - 0.5) * this.imgW * (1 - scale) * this.lastScale;
    this.offY = (this.lastOffY + panOffY) +
      (this.zoomCenterY - 0.5) * this.imgH * (1 - scale) * this.lastScale;
    this.clampAndCheckEdge();
  }

  private clampAndCheckEdge(): void {
    const iw = this.imgW * this.scaleVal;
    const ih = this.imgH * this.scaleVal;
    const mx = iw > this.compW ? (iw - this.compW) / 2 : 0;
    const my = ih > this.compH ? (ih - this.compH) / 2 : 0;
    if (iw > this.compW) {
      this.offX = Math.max(-mx, Math.min(mx, this.offX));
    } else {
      this.offX = 0;
    }
    if (ih > this.compH) {
      this.offY = Math.max(-my, Math.min(my, this.offY));
    } else {
      this.offY = 0;
    }
    hilog.info(0x0001, 'ZoomClamp', 'clamp scale=%{public}f iw=%{public}d ih=%{public}d mx=%{public}d my=%{public}d off=%{public}d,%{public}d',
      this.scaleVal, iw, ih, mx, my, this.offX, this.offY);
  }

  private onPinchStart(e: GestureEvent): void {
    if (!e) return;
    this.onGestureStart();
    this.pinching = true;
    this.lastScale = this.scaleVal;
    this.lastOffX = this.offX;
    this.lastOffY = this.offY;
    const iw = this.imgW * this.lastScale;
    const ih = this.imgH * this.lastScale;
    const il = (this.compW - iw) / 2 + this.lastOffX;
    const it = (this.compH - ih) / 2 + this.lastOffY;
    this.zoomCenterX = iw > 0 ? Math.max(0, Math.min(1, (e.pinchCenterX - il) / iw)) : 0.5;
    this.zoomCenterY = ih > 0 ? Math.max(0, Math.min(1, (e.pinchCenterY - it) / ih)) : 0.5;
  }

  private onPinchUpdate(e: GestureEvent): void {
    if (!e) return;
    // Compute new scale
    const ns = Math.max(1.0, Math.min(5.0, this.lastScale * e.scale));
    this.scaleVal = ns;
    // Compute offset directly from pinchCenter (screen-space absolute position)
    // This follows the official HarmonyOS example pattern:
    //   pointX = (compW - newDisplayW) / 2 + newDisplayW * centerX
    //   offX = pinchCenterX - pointX
    // where centerX is the normalized pinch position within the image.
    const newW = this.imgW * ns;
    const newH = this.imgH * ns;
    const pointX = (this.compW - newW) / 2 + newW * this.zoomCenterX;
    const pointY = (this.compH - newH) / 2 + newH * this.zoomCenterY;
    this.offX = e.pinchCenterX - pointX;
    this.offY = e.pinchCenterY - pointY;
    this.clampAndCheckEdge();
  }

  private onPinchEnd(_e: GestureEvent): void {
    if (!this.pinching) return;
    this.pinching = false;
    if (this.scaleVal < 1.05) {
      this.onZoomChange(false);
      this.onEdgeChange(false);
      animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.reset(); });
      this.onGestureEnd();
      return;
    }
    this.lastScale = this.scaleVal;
    this.lastOffX = this.offX;
    this.lastOffY = this.offY;
    this.onZoomChange(true);
    this.onGestureEnd();
  }

  private onPanStart(_e: GestureEvent): void {
    this.panActive = true;
    this.accumPanOffX = 0;
    this.accumPanOffY = 0;
    if (this.pinching) return;
    this.onGestureStart();
    this.lastOffX = this.offX;
    this.lastOffY = this.offY;
  }

  private onPanUpdate(e: GestureEvent): void {
    if (!e || this.scaleVal <= 1.0) return;
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
    // reports a smaller value. Multiply by scaleVal to restore the screen-space delta.
    this.applyTransform(1, effectiveOffX * this.scaleVal, effectiveOffY * this.scaleVal);
  }

  private onPanEnd(_e: GestureEvent): void {
    this.panActive = false;
    if (this.pinching) return;
    this.lastOffX = this.offX;
    this.lastOffY = this.offY;
    this.panEndAt = Date.now();
    if (this.scaleVal > 1.0) {
      const iw = this.imgW * this.scaleVal;
      if (iw > this.compW) {
        const mx = (iw - this.compW) / 2;
        const atEdge = this.offX >= mx - 1 || this.offX <= -mx + 1;
        this.onEdgeChange(atEdge);
      }
    }
    this.onGestureEnd();
  }

  private onDblTap(e: GestureEvent): void {
    // Debounce: ignore double-tap shortly after panning to avoid conflicting with rapid successive drags
    if (Date.now() - this.panEndAt < this.PAN_DBLTAP_DEBOUNCE_MS) {
      return;
    }
    if (this.scaleVal > 1.0) {
      this.onZoomChange(false);
      this.onEdgeChange(false);
      animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.reset(); });
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
    animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.applyTransform(2.5, 0, 0);
      this.lastScale = this.scaleVal;
      this.lastOffX = this.offX;
      this.lastOffY = this.offY;
    });
    this.onGestureEnd();
  }

  build() {
    if (this.pixelMap !== null) {
      Image(this.pixelMap)
        .draggable(false)
        .objectFit(ImageFit.Contain)
        .width('100%').height('100%')
        .scale({ x: this.scaleVal, y: this.scaleVal })
        .translate({ x: this.offX, y: this.offY })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PinchGesture({ fingers: 2, distance: 1 })
              .onActionStart((e: GestureEvent) => { this.onPinchStart(e); })
              .onActionUpdate((e: GestureEvent) => { this.onPinchUpdate(e); })
              .onActionEnd((e: GestureEvent) => { this.onPinchEnd(e); }),
            PanGesture({ fingers: 1, direction: PanDirection.All, distance: this.scaleVal > 1.0 ? 3 : 80 })
              .onActionStart((e: GestureEvent) => { this.onPanStart(e); })
              .onActionUpdate((e: GestureEvent) => { this.onPanUpdate(e); })
              .onActionEnd((e: GestureEvent) => { this.onPanEnd(e); }),
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
}

// ---- MainImageView (top-level @ComponentV2 for Repeat+virtualScroll recycling) ----
@ComponentV2
struct MainImageView {
  @Param pixelMap: image.PixelMap | null = null;
  @Param photoW: number = 1;
  @Param photoH: number = 1;
  @Param pageKey: number = 0;
  @Param isLoading: boolean = false;
  @Param hasThumb: boolean = false;
  @Param filename: string = '';
  @Event onZoomChange: (zoomed: boolean) => void = () => {};
  @Event onGestureStart: () => void = () => {};
  @Event onGestureEnd: () => void = () => {};
  @Event onOverlayToggle: () => void = () => {};

  build() {
    Stack() {
      if (this.hasThumb) {
        ZoomableImage({
          pixelMap: this.pixelMap,
          photoW: this.photoW,
          photoH: this.photoH,
          pageKey: this.pageKey,
          onZoomChange: this.onZoomChange,
          onGestureStart: this.onGestureStart,
          onGestureEnd: this.onGestureEnd
        })
      } else {
        Column() {
          Text(this.filename)
            .fontSize(14).fontColor('#aaa')
            .maxLines(2).textAlign(TextAlign.Center)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#222')
        .onClick(() => { this.onOverlayToggle(); })
      }

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .color(Color.White)
            .width(48).height(48)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.3)')
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
          .borderRadius(4)
          .border({ width: this.borderWeight * 2, color: '#2196F3', radius: 4 })
      } else if (this.realIdx >= 0) {
        Column()
          .width('100%').height('100%')
          .borderRadius(4)
          .backgroundColor('#444')
          .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').aspectRatio(1)
    .borderRadius(4)
    .backgroundColor(this.realIdx < 0 ? Color.Transparent : '#333')
    .justifyContent(FlexAlign.Center)
    .offset({ x: this.ox })
    .scale({ x: this.s, y: this.s })
    .animation({ duration: 200, curve: Curve.Linear })
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

  // Shared element transition
  private cardItemInfo: RectInfoInPx = new RectInfoInPx();
  @Local animationProperties: AnimationProperties | null = null;
  @Local myNodeController: MyNodeController | undefined = undefined;
  private prePageDoFinishTransition: () => void = () => {};
  private shouldDoDefaultTransition: boolean = false;
  private positionLookup: ((handle: number) => string) | undefined = undefined;
  private posCache: Record<string, string> = {};

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
  @Local thumbFrac: number = 0;

  // ---- Full-resolution loading state ----
  @Local fullResMap: Map<number, image.PixelMap> = new Map();
  @Local loadingHandle: number = -1;
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

  aboutToAppear(): void {
    // Initialize animation properties (params will be read in onReady)
    this.animationProperties = new AnimationProperties(this.getUIContext());
    // Pick up the BuilderNode shared from MainScreen/GalleryPage
    this.myNodeController = getMyNode();
  }

  aboutToDisappear(): void {
    this.cancelStableTimer();
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
    this.thumbFrac = realFrac;
    const half = this._half;
    const dt = this._displayTotal;
    const centerFrac = realFrac + half;
    const centerIdx = Math.round(centerFrac);
    for (let i = 0; i < dt; i++) {
      if (this.isPlaceholder(i)) {
        this.scaleArr[i] = 0;
        this.offsetArr[i] = 0;
      } else {
        const d = i - centerIdx;
        if (d === 0) {
          this.scaleArr[i] = MAX_S;
          this.offsetArr[i] = 0;
        } else {
          this.scaleArr[i] = MIN_S;
          this.offsetArr[i] = d > 0 ? CENTER_OFFSET : -CENTER_OFFSET;
        }
      }
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
    }
    if (!this._isDragging) return;
    const mainFrac = index - extraInfo.currentOffset / this._swiperWidth;
    const delta = mainFrac - this._lastMainFrac;
    this._lastMainFrac = mainFrac;
    this.thumbCtrl.fakeDragBy(-delta * (this._thumbItemW + ITEM_SPACE));
    this.updateScales(mainFrac);
  }

  private onMainContentDidScroll(_sel: number, index: number, position: number): void {
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
    this.mainIdx = index;
    this.thumbIdx = index;
    this.thumbCtrl.changeIndex(index, false);
    this.updateScales(index);
    this.scheduleFullResLoad();
  }

  private onMainChange(idx: number): void {
    hilog.info(DOMAIN, TAG, `onMainChange idx=${idx} mainIdx=${this.mainIdx} total=${this.mainPhotos.length}`);
    this.mainIdx = idx;
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
    // Guard: already loaded or another load in progress
    if (this.fullResMap.has(handle) || this.loadingHandle >= 0) return;

    this.loadingHandle = handle;
    try {
      const result = await this.svc.loadFullPhoto(handle);
      if (result !== null) {
        const pixelMap = result.pixelMap;
        this.fullResMap.set(handle, pixelMap);
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
          this.fullResMap.set(task.handle, result.pixelMap);
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
    for (const h of toEvict) {
      const pm = this.fullResMap.get(h);
      if (pm) { pm.release(); }
      this.fullResMap.delete(h);
      this.preloadedHandles.delete(h);
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
          .fontSize(22)
          .fontColor([Color.White])
      }
      .width(36).height(36)
      .backgroundColor('rgba(255,255,255,0.15)')
      .onClick(() => { this.pageInfos.pop(); })

      // Title block
      Column() {
        Text(this.getMainTitle())
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor(Color.White)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.getSubTitle())
          .fontSize(11).fontColor('#bbb')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })

      // Current index indicator
      Text(`${this.mainIdx + 1}/${this._realTotal}`)
        .fontSize(12).fontColor('#888')
        .margin({ right: 4 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 8 })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  }

  // ========== Builders ==========

  private getDisplayPixelMap(entry: PhotoEntry): image.PixelMap | null {
    // Prefer full-resolution if loaded
    if (this.fullResMap.has(entry.handle)) {
      return this.fullResMap.get(entry.handle)!;
    }
    // Fall back to thumbnail
    return this.getThumbPixelMap(this.mainIdx);
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

  private orientedW(ri: RepeatItem<PhotoEntry>): number {
    const s = this.svc.orientedDisplaySizes.get(ri.item.handle);
    return s ? s.w : (ri.item.imagePixWidth ?? 1);
  }

  private orientedH(ri: RepeatItem<PhotoEntry>): number {
    const s = this.svc.orientedDisplaySizes.get(ri.item.handle);
    return s ? s.h : (ri.item.imagePixHeight ?? 1);
  }

  @Builder
  buildMainImage(ri: RepeatItem<PhotoEntry>) {
    MainImageView({
      pixelMap: this.fullResMap.has(ri.item.handle)
        ? this.fullResMap.get(ri.item.handle)! : this.getThumbPixelMap(ri.index),
      photoW: this.orientedW(ri),
      photoH: this.orientedH(ri),
      pageKey: ri.index,
      isLoading: this.loadingHandle === ri.item.handle,
      hasThumb: this.svc.thumbnailPixelMapMap.has(ri.item.handle),
      filename: ri.item.filename,
      onZoomChange: (zoomed: boolean) => { this.isZoomed = zoomed; },
      onGestureStart: () => { this.pausePreloading(); },
      onGestureEnd: () => { this.scheduleResumePreloading(); },
      onOverlayToggle: () => { this._overlayVisible = !this._overlayVisible; }
    })
  }

  @Builder
  ThumbCell(ri: RepeatItem<number>) {
    ThumbCellView({
      realIdx: this.isPlaceholder(ri.item) ? -1 : this.toReal(ri.item),
      pixelMap: this.isPlaceholder(ri.item) ? null : this.getThumbPixelMap(this.toReal(ri.item)),
      s: this.scaleArr[ri.item] ?? MIN_S,
      ox: this.offsetArr[ri.item] ?? 0,
      borderWeight: this.isPlaceholder(ri.item) ? 0 :
        Math.max(0, 1 - Math.abs(this.toReal(ri.item) - this.thumbFrac)),
      onCellClick: (): void => {
        if (!this.isPlaceholder(ri.item)) { this.onThumbClick(this.toReal(ri.item)); }
      }
    })
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // Shared element in positioned inner Stack so translateY aligns
        // with window coordinates (see FAQ: expandSafeArea doesn't change
        // layout origin).
        Stack({ alignContent: Alignment.TopStart }) {
          if (this.myNodeController && this.animationProperties && !this.animationProperties.showDetailContent) {
            NodeContainer(this.myNodeController)
              .width('100%')
              .height('100%')
          }
        }
        .position({ y: this.animationProperties?.positionValue ?? 0 })

        // ===== Regular content (visible after transition completes) =====
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
                  .onAreaChange((_o: Area, n: Area) => {
                    const w = n.width as number;
                    if (w > 0) { this._swiperWidth = w; }
                  })
                })
                .key((_photo: PhotoEntry, idx: number) => idx.toString())
                .virtualScroll({ totalCount: this.mainPhotos.length })
            }
            .index(this.mainIdx)
            .disableSwipe(this.isZoomed)
            .onGestureSwipe((i: number, e: SwiperAnimationEvent) => { this.onMainGestureSwipe(i, e); })
            .onContentDidScroll((s: number, i: number, p: number) => { this.onMainContentDidScroll(s, i, p); })
            .onAnimationEnd((i: number) => { this.onMainAnimationEnd(i); })
            .onChange((i: number) => { this.onMainChange(i); })
            .cachedCount(2).loop(false).indicator(false)
            .curve(this._inertiaAnim ? Curve.Friction : Curve.Linear)
            .duration(this._inertiaAnim ? INERTIA_DURATION : SNAP_DURATION)
            .width('100%').height('100%')

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
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
            }
            .width('100%').height('100%')
            .hitTestBehavior(HitTestMode.Transparent)
            .visibility(this._overlayVisible ? Visibility.Visible : Visibility.Hidden)
            .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
          }
          .width('100%').height('100%')
          .backgroundColor(Color.Black)
          .layoutWeight(1)
        }
        .width('100%').height('100%')
        .opacity(this.animationProperties?.showDetailContent ? 1.0 : 0.0)
        .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
      }
      // Animation transforms applied to the outer Stack:
      .scale({ x: this.animationProperties?.scaleValue ?? 1, y: this.animationProperties?.scaleValue ?? 1 })
      .translate({ x: this.animationProperties?.translateX ?? 0, y: this.animationProperties?.translateY ?? 0 })
      .width(this.animationProperties?.clipWidth ?? '100%')
      .height(this.animationProperties?.clipHeight ?? '100%')
      .borderRadius(this.animationProperties?.radius ?? 0)
      .clip(true)
      .expandSafeArea([SafeAreaType.SYSTEM])
    }
    .hideTitleBar(true)
    .backgroundColor(this.animationProperties?.navDestinationBgColor ?? Color.Black)
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

      // Back-transition callback
      this.prePageDoFinishTransition = param['doDefaultTransition'] as () => void;
      if (!this.prePageDoFinishTransition) {
        this.prePageDoFinishTransition = () => {};
      }

      // Position lookup callback + cached positions (from push time)
      this.positionLookup = param['positionLookup'] as ((handle: number) => string) | undefined;
      const posCacheStr = param['posCache'] as string | undefined;
      if (posCacheStr) {
        try { this.posCache = JSON.parse(posCacheStr) as Record<string, string>; } catch (_e) {}
      }

      // Initialize photo list and starting index
      this.initFromParams(handle, handles, startIndex);

      // Set initial animation state to thumbnail position (BEFORE first render).
      // This ensures the first frame shows the shared element at the correct starting
      // position, then animateTo smoothly expands it to full screen.
      if (this.animationProperties) {
        this.animationProperties.setInitialState(this.cardItemInfo, 0);
        this.svc.getLog().add('setInitialState called, cardInfo=' + JSON.stringify(this.cardItemInfo));
      } else {
        this.svc.getLog().add('setInitialState SKIP: animationProperties is null');
      }

      // Register custom transition animation callback
      CustomTransition.getInstance().registerNavParam(this.pageId,
        (isPush: boolean, isExit: boolean, transitionProxy: NavigationTransitionProxy) => {
          this.animationProperties?.doAnimation(
            this.cardItemInfo, isPush, isExit, transitionProxy, 0,
            this.prePageDoFinishTransition, this.myNodeController);
        }, 500);
    })
    .onBackPressed(() => {
      const curHandle = this.currentHandle();
      if (curHandle >= 0) {
        // 1. Update the shared element (BuilderNode) with the CURRENT photo's
        //    thumbnail (not the originally-clicked one).
        if (this.myNodeController) {
          const pm = this.svc.thumbnailPixelMapMap.get(curHandle);
          if (pm) {
            this.myNodeController.setPixelMap(this.getUIContext(), pm);
            this.svc.getLog().add('pop: updated BuilderNode pixelMap for handle=' + curHandle);
          }
        }

        // 2. Look up the current thumbnail's grid position for the return animation.
        //    Priority: positionLookup (live) > posCache (cached at push time) > original cardItemInfo
        let rectStr: string = '';
        if (this.positionLookup) {
          try { rectStr = this.positionLookup(curHandle); } catch (_e) {}
        }
        if (!rectStr) {
          rectStr = this.posCache[String(curHandle)] ?? '';
          if (rectStr) {
            this.svc.getLog().add('pop: used posCache for handle=' + curHandle);
          }
        }
        if (rectStr) {
          try {
            this.cardItemInfo = JSON.parse(rectStr) as RectInfoInPx;
            this.svc.getLog().add('pop: updated cardItemInfo for handle=' + curHandle);
          } catch (_e) {}
        } else {
          this.svc.getLog().add('pop: no position found for handle=' + curHandle + ', using original');
        }
      }
      this.pageInfos.pop();
      return true;
    })
    .onDisAppear(() => {
      CustomTransition.getInstance().unRegisterNavParam(this.pageId);
    })
  }
}
