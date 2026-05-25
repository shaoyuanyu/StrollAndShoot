import { router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry } from '../model/PhotoEntry';

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
  private pinchCx: number = 0.5;
  private pinchCy: number = 0.5;
  private panEndAt: number = 0;
  private readonly PAN_DBLTAP_DEBOUNCE_MS: number = 200;

  @Monitor('pageKey')
  onPageChange(): void {
    animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.reset(); });
  }

  aboutToAppear(): void { this.updateImgCache(); }

  private updateImgCache(): void {
    const pw = this.photoW > 0 ? this.photoW : (this.compW > 0 ? this.compW : 360);
    const ph = this.photoH > 0 ? this.photoH : (this.compH > 0 ? this.compH : 360);
    const s = Math.min(this.compW > 0 ? this.compW / pw : 1,
      this.compH > 0 ? this.compH / ph : 1);
    this.imgW = pw * s;
    this.imgH = ph * s;
  }

  private reset(): void {
    this.scaleVal = 1.0;
    this.offX = 0;
    this.offY = 0;
    this.lastScale = 1.0;
    this.lastOffX = 0;
    this.lastOffY = 0;
    this.pinching = false;
  }

  private applyTransform(scale: number, panOffX: number, panOffY: number): void {
    const ns = Math.max(1.0, Math.min(5.0, this.lastScale * scale));
    this.scaleVal = ns;
    this.offX = (this.lastOffX + panOffX) +
      (0.5 - this.pinchCx) * this.imgW * (1 - scale) * this.lastScale;
    this.offY = (this.lastOffY + panOffY) +
      (0.5 - this.pinchCy) * this.imgH * (1 - scale) * this.lastScale;
    this.clampAndCheckEdge();
  }

  private clampAndCheckEdge(): void {
    const iw = this.imgW * this.scaleVal;
    const ih = this.imgH * this.scaleVal;
    if (iw > this.compW) {
      const mx = (iw - this.compW) / 2;
      this.offX = Math.max(-mx, Math.min(mx, this.offX));
    } else {
      this.offX = 0;
    }
    if (ih > this.compH) {
      const my = (ih - this.compH) / 2;
      this.offY = Math.max(-my, Math.min(my, this.offY));
    } else {
      this.offY = 0;
    }
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
    const cx = iw > 0 ? Math.max(0, (e.pinchCenterX - il) / iw) : 0.5;
    const cy = ih > 0 ? Math.max(0, (e.pinchCenterY - it) / ih) : 0.5;
    this.pinchCx = 1 - cx;
    this.pinchCy = 1 - cy;
  }

  private onPinchUpdate(e: GestureEvent): void {
    if (!e) return;
    this.applyTransform(e.scale, e.offsetX, e.offsetY);
  }

  private onPinchEnd(_e: GestureEvent): void {
    if (!this.pinching) return;
    this.pinching = false;
    if (this.scaleVal < 1.05) {
      this.onZoomChange(false);
      this.onEdgeChange(false);
      animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.reset(); });
      return;
    }
    this.lastScale = this.scaleVal;
    this.lastOffX = this.offX;
    this.lastOffY = this.offY;
    this.onZoomChange(true);
  }

  private onPanStart(_e: GestureEvent): void {
    if (this.pinching) return;
    this.onGestureStart();
    this.lastOffX = this.offX;
    this.lastOffY = this.offY;
  }

  private onPanUpdate(e: GestureEvent): void {
    if (!e || this.scaleVal <= 1.0 || this.pinching) return;
    // Compensate for the scaled local coordinate system:
    // .scale() shrinks the component's local coordinate space, so GestureEvent.offsetX
    // reports a smaller value. Multiply by scaleVal to restore the screen-space delta.
    this.applyTransform(1, e.offsetX * this.scaleVal, e.offsetY * this.scaleVal);
  }

  private onPanEnd(_e: GestureEvent): void {
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
    const tapCx = iw > 0 ? (tx - il) / iw : 0.5;
    const tapCy = ih > 0 ? (ty - it) / ih : 0.5;
    this.pinchCx = 1 - tapCx;
    this.pinchCy = 1 - tapCy;
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
  }

  build() {
    if (this.pixelMap !== null) {
      Image(this.pixelMap)
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

// ---- Constants (from SwiperSyncTestPage) ----
const MAX_S = 1.3;
const MIN_S = 1.0;
const ITEM_SPACE = 2;
const CENTER_OFFSET = 14;
const SNAP_DURATION = 150;
const INERTIA_THRESHOLD = 3000;
const INERTIA_FACTOR = 150;
const INERTIA_DURATION = 5000;

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
  @Event onCellClick: () => void = () => {};

  build() {
    Column() {
      if (this.realIdx >= 0 && this.pixelMap !== null) {
        Image(this.pixelMap)
          .objectFit(ImageFit.Cover)
          .width('100%').height('100%')
          .borderRadius(4)
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

// ---- PhotoViewer @Entry ----
@Entry
@ComponentV2
struct PhotoViewer {
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

  // ---- Full-resolution loading state ----
  @Local fullResMap: Map<number, image.PixelMap> = new Map();
  @Local loadingHandle: number = -1;
  @Local isZoomed: boolean = false;
  private stableTimerId: number = -1;
  private preloadWindow: number = 3;
  private preloadedHandles: Set<number> = new Set();

  // Filtered photo list (from gallery's filter)
  @Local photoList: PhotoEntry[] = [];

  private getPhotos(): PhotoEntry[] {
    return this.photoList.length > 0 ? this.photoList : this.svc.photos;
  }

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object> | undefined;
    const handle = params ? (params['handle'] as number) : undefined;
    const handles = params ? (params['handles'] as number[] | undefined) : undefined;

    // Build filtered photo list if handles were passed
    if (handles && handles.length > 0) {
      const handleSet = new Set(handles);
      this.photoList = this.svc.photos.filter(p => handleSet.has(p.handle));
    }

    this.rebuildDisplayArrays();
    let initialIndex = 0;
    if (handle !== undefined && this.getPhotos().length > 0) {
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

  aboutToDisappear(): void {
    this.cancelStableTimer();
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
    if (!this._isDragging) return;
    if (index !== this.mainIdx) return;
    if (Math.abs(position) < 0.005) return;
    const mainFrac = index - position;
    const delta = mainFrac - this._lastMainFrac;
    this._lastMainFrac = mainFrac;
    this.thumbCtrl.fakeDragBy(-delta * (this._thumbItemW + ITEM_SPACE));
    this.updateScales(mainFrac);
  }

  private onMainAnimationEnd(index: number): void {
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
    this.scheduleFullResLoad();
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

    const handle = this.currentHandle();
    if (handle < 0) return;
    // Already loaded or loading
    if (this.fullResMap.has(handle) || this.loadingHandle === handle) return;

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
      const pixelMap = await this.svc.loadFullPhoto(handle);
      if (pixelMap !== null) {
        this.fullResMap.set(handle, pixelMap);
        // Trigger preload of adjacent photos
        this.preloadNeighbors();
      }
    } catch (_e) {
      // Silently fail — thumbnail stays visible
    } finally {
      if (this.loadingHandle === handle) {
        this.loadingHandle = -1;
      }
    }
  }

  /**
   * Preload adjacent photos within the sliding window (±preloadWindow).
   * Uses a background queue to avoid blocking the current load.
   */
  private preloadNeighbors(): void {
    const photos = this.getPhotos();
    const center = this.mainIdx;
    const window = this.preloadWindow;
    // Collect handles to preload: nearby, not yet loaded, not already queued
    const toPreload: number[] = [];
    for (let i = center - window; i <= center + window; i++) {
      if (i === center || i < 0 || i >= photos.length) continue;
      const h = photos[i].handle;
      if (!this.fullResMap.has(h) && !this.preloadedHandles.has(h)) {
        toPreload.push(h);
        this.preloadedHandles.add(h);
      }
    }
    // Evict far-away full-res images (> 2× window)
    this.evictDistantFullRes(center);
    // Fire preloads asynchronously
    for (const h of toPreload) {
      this.preloadOne(h);
    }
  }

  private async preloadOne(handle: number): Promise<void> {
    try {
      const pixelMap = await this.svc.loadFullPhoto(handle);
      if (pixelMap !== null) {
        this.fullResMap.set(handle, pixelMap);
      }
    } catch (_e) {
      // Silent
    }
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
      .onClick(() => { router.back(); })

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

  @Builder
  MainImageContent(photo: PhotoEntry, idx: number) {
    Stack() {
      // Zoomable image (pinch/pan/double-tap)
      ZoomableImage({
        pixelMap: this.fullResMap.has(photo.handle)
          ? this.fullResMap.get(photo.handle)! : this.getThumbPixelMap(idx),
        photoW: photo.imagePixWidth ?? 1,
        photoH: photo.imagePixHeight ?? 1,
        pageKey: idx,
        onZoomChange: (zoomed: boolean) => {
          this.isZoomed = zoomed;
        }
      })

      // Loading overlay
      if (this.loadingHandle === photo.handle) {
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
    .onClick(() => { this._overlayVisible = !this._overlayVisible; })
    .onAreaChange((_o: Area, n: Area) => {
      const w = n.width as number;
      if (w > 0) { this._swiperWidth = w; }
    })
  }

  @Builder
  ThumbCell(ri: RepeatItem<number>) {
    ThumbCellView({
      realIdx: this.isPlaceholder(ri.item) ? -1 : this.toReal(ri.item),
      pixelMap: this.isPlaceholder(ri.item) ? null : this.getThumbPixelMap(this.toReal(ri.item)),
      s: this.scaleArr[ri.item] ?? MIN_S,
      ox: this.offsetArr[ri.item] ?? 0,
      onCellClick: (): void => {
        if (!this.isPlaceholder(ri.item)) { this.onThumbClick(this.toReal(ri.item)); }
      }
    })
  }

  build() {
    Column() {
      // ===== Custom Title Bar =====
      if (this._overlayVisible) {
        this.TitleBar()
      }

      // ===== Main + Thumb Swipers =====
      Stack() {
        // ===== Main Swiper =====
        Swiper(this.mainCtrl) {
          Repeat<PhotoEntry>(this.getPhotos())
            .each((ri: RepeatItem<PhotoEntry>) => {
              Stack() {
                if (this.svc.thumbnailPixelMapMap.has(ri.item.handle)) {
                  this.MainImageContent(ri.item, ri.index);
                } else {
                  Column() {
                    Text(ri.item.filename)
                      .fontSize(14).fontColor('#aaa')
                      .maxLines(2).textAlign(TextAlign.Center)
                  }
                  .width('100%').height('100%')
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor('#222')
                  .onClick(() => { this._overlayVisible = !this._overlayVisible; })
                }
              }
              .width('100%').height('100%')
            })
            .key((_photo: PhotoEntry, idx: number) => idx.toString())
            .virtualScroll({ totalCount: this._realTotal })
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
    .backgroundColor(Color.Black)
  }
}
