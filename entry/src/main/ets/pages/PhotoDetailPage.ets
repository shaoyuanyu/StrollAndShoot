import { router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry, DownloadProgress } from '../model/PhotoEntry';

// ---- ZoomableImage: isolated component so gesture @State changes don't
//      rebuild the parent Swiper/overlay ----
// Pinch / pan formula follows:
//   offset' = (lastOffset + panOff) + (0.5 - center) * size * (1 - scale) * lastScale
// where center is INVERTED (1 - normalized position) per HarmonyOS convention.
@Component
struct ZoomableImage {
  pixelMap: image.PixelMap | null = null;
  photoW: number = 1;
  photoH: number = 1;
  @Prop @Watch('onPageChange') pageKey: number = 0;
  onZoomChange: (zoomed: boolean) => void = () => {};
  onEdgeChange: (atEdge: boolean) => void = () => {};
  onGestureStart: () => void = () => {};
  @State scaleVal: number = 1.0;
  @State offX: number = 0;
  @State offY: number = 0;
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

  onPageChange(): void {
    animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.reset(); });
  }

  aboutToAppear(): void { this.updateImgCache(); }

  private updateImgCache(): void {
    const s = Math.min(this.compW > 0 ? this.compW / this.photoW : 1,
      this.compH > 0 ? this.compH / this.photoH : 1);
    this.imgW = this.photoW * s;
    this.imgH = this.photoH * s;
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

  // Unified transform: called by both pan and pinch.
  // offset' = (lastOffset + panOff) + (0.5 - center) * size * (1 - scale) * lastScale
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

  // ---- Pinch ----
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

  // ---- Pan ----
  private onPanStart(_e: GestureEvent): void {
    if (this.pinching) return;
    this.onGestureStart();
    this.lastOffX = this.offX;
    this.lastOffY = this.offY;
  }

  private onPanUpdate(e: GestureEvent): void {
    if (!e || this.scaleVal <= 1.0 || this.pinching) return;
    this.applyTransform(1, e.offsetX, e.offsetY);
  }

  private onPanEnd(_e: GestureEvent): void {
    if (this.pinching) return;
    this.lastOffX = this.offX;
    this.lastOffY = this.offY;
    if (this.scaleVal > 1.0) {
      const iw = this.imgW * this.scaleVal;
      if (iw > this.compW) {
        const mx = (iw - this.compW) / 2;
        const atEdge = this.offX >= mx - 1 || this.offX <= -mx + 1;
        this.onEdgeChange(atEdge);
      }
    }
  }

  // ---- Double-tap ----
  private onDblTap(e: GestureEvent): void {
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
          PanGesture({
            fingers: 1,
            direction: PanDirection.All,
            distance: this.scaleVal > 1.0 ? 3 : 80
          })
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

// ---- PhotoDetailPage ----
@Entry
@Component
struct PhotoDetailPage {
  @State currentIndex: number = 0;
  @State showOverlay: boolean = true;
  @State fullPixelMap: image.PixelMap | null = null;
  @State loading: boolean = false;
  @State loadedHandle: number = 0;
  @State isZoomed: boolean = false;
  @State allowEdgeSwipe: boolean = true;
  @State isDownloaded: boolean = false;
  @State downloading: boolean = false;
  private photos: PhotoEntry[] = [];
  private service: CameraService = CameraService.getInstance();
  private loadVersion: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      const p = params['photos'] as PhotoEntry[];
      if (p) this.photos = p;
      const idx = params['initialIndex'] as number;
      if (idx !== undefined) this.currentIndex = idx;
    }
    this.loadFullForCurrent();
    this.checkDownloaded();
  }

  private checkDownloaded(): void {
    this.isDownloaded = this.service.isPhotoDownloaded(this.currentPhoto().handle);
  }

  private async downloadCurrent(): Promise<void> {
    if (this.downloading || this.isDownloaded) return;
    this.downloading = true;

    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await this.service.downloadPhotos(
        [this.currentPhoto().handle],
        (_progress: DownloadProgress) => { /* single photo, progress handled by service */ },
        ctx
      );
      this.isDownloaded = this.service.isPhotoDownloaded(this.currentPhoto().handle);
    } catch (_e) {
      // download failed, keep button enabled
    }
    this.downloading = false;
  }

  private currentPhoto(): PhotoEntry {
    return this.photos[this.currentIndex];
  }

  private async loadFullForCurrent(): Promise<void> {
    const photo = this.currentPhoto();
    if (!photo || photo.handle === this.loadedHandle) return;

    this.fullPixelMap = null;
    this.isZoomed = false;
    this.allowEdgeSwipe = true;
    this.loading = true;
    this.loadedHandle = 0;
    this.loadVersion++;
    const ver = this.loadVersion;

    const pixelMap = await this.service.loadFullPhoto(photo.handle);
    if (ver !== this.loadVersion) return;

    if (pixelMap) {
      this.fullPixelMap = pixelMap;
      this.loadedHandle = photo.handle;
      this.service.setDetailIndex(this.currentIndex, this.photos.length);
    }
    this.loading = false;
  }

  private formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }

  private formatDate(dateStr: string): string {
    if (!dateStr || dateStr.length < 8) return dateStr;
    return `${dateStr.substring(0, 4)}-${dateStr.substring(4, 6)}-${dateStr.substring(6, 8)}`;
  }

  build() {
    Stack() {
      Swiper() {
        ForEach(this.photos, (photo: PhotoEntry) => {
          Stack() {
            if (this.fullPixelMap && photo.handle === this.loadedHandle) {
              ZoomableImage({
                pixelMap: this.fullPixelMap,
                photoW: photo.imagePixWidth || 1,
                photoH: photo.imagePixHeight || 1,
                pageKey: this.currentIndex,
                onZoomChange: (zoomed: boolean) => {
                  this.isZoomed = zoomed;
                },
                onEdgeChange: (atEdge: boolean) => {
                  this.allowEdgeSwipe = atEdge;
                },
                onGestureStart: () => {
                  this.service.cancelPreload();
                }
              })
            } else if (this.service.thumbnailPixelMapMap.has(photo.handle)) {
              ZoomableImage({
                pixelMap: this.service.thumbnailPixelMapMap.get(photo.handle)!,
                photoW: photo.imagePixWidth || 1,
                photoH: photo.imagePixHeight || 1,
                pageKey: this.currentIndex,
                onZoomChange: (zoomed: boolean) => {
                  this.isZoomed = zoomed;
                },
                onEdgeChange: (atEdge: boolean) => {
                  this.allowEdgeSwipe = atEdge;
                },
                onGestureStart: () => {
                  this.service.cancelPreload();
                }
              })
            } else {
              Column() {
                Text('📷').fontSize(56)
                Text(photo.filename)
                  .fontSize(14)
                  .fontColor($r('app.color.text_on_dark'))
                  .margin({ top: 12 })
              }
              .width('100%').height('100%')
              .justifyContent(FlexAlign.Center)
            }

            if (this.loading && photo.handle === this.currentPhoto().handle) {
              LoadingProgress()
                .width(32).height(32)
                .color($r('app.color.text_on_dark'))
                .position({ x: '50%', y: '50%' })
                .markAnchor({ x: '50%', y: '50%' })
            }
          }
          .width('100%').height('100%')
          .clip(false)
          .onClick(() => { this.showOverlay = !this.showOverlay; })
        })
      }
      .index(this.currentIndex)
      .indicator(false)
      .loop(false)
      .disableSwipe(this.isZoomed && !this.allowEdgeSwipe)
      .onChange((idx: number) => {
        this.currentIndex = idx;
        this.loadFullForCurrent();
        this.checkDownloaded();
      })
      .width('100%').height('100%')

      if (this.showOverlay) {
        Row() {
          Button() {
            Image($r('sys.symbol.chevron_left'))
              .width(24).height(24)
              .fillColor($r('app.color.text_on_dark'))
          }
          .backgroundColor(Color.Transparent)
          .onClick(() => { router.back(); })

          Blank()

          Text(`${this.currentIndex + 1}/${this.photos.length}`)
            .fontSize(14)
            .fontColor($r('app.color.text_on_dark'))

          Blank()

          Image($r('sys.symbol.chevron_left'))
            .width(24).height(24)
            .fillColor(Color.Transparent)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 48 })
        .backgroundColor('rgba(0,0,0,0.45)')
        .position({ x: 0, y: 0 })

        Column() {
          Text(this.currentPhoto().filename)
            .fontSize(13).fontColor($r('app.color.text_on_dark'))
            .alignSelf(ItemAlign.Start).margin({ bottom: 4 })

          Row({ space: 16 }) {
            if (this.currentPhoto().captureDate) {
              Text(this.formatDate(this.currentPhoto().captureDate!))
                .fontSize(11).fontColor($r('app.color.text_secondary'))
            }
            Text(this.formatSize(this.currentPhoto().size))
              .fontSize(11).fontColor($r('app.color.text_secondary'))
            if (this.currentPhoto().imagePixWidth && this.currentPhoto().imagePixHeight) {
              Text(`${this.currentPhoto().imagePixWidth}x${this.currentPhoto().imagePixHeight}`)
                .fontSize(11).fontColor($r('app.color.text_secondary'))
            }
            Blank()
            if (this.isDownloaded) {
              Text('已下载')
                .fontSize(12).fontColor('#4CAF50')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor('rgba(76,175,80,0.15)')
                .borderRadius(12)
            } else if (this.downloading) {
              Text('下载中…')
                .fontSize(12).fontColor($r('app.color.text_secondary'))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor('rgba(255,255,255,0.12)')
                .borderRadius(12)
            } else {
              Text('下载')
                .fontSize(12).fontColor($r('app.color.text_on_dark'))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor($r('app.color.primary'))
                .borderRadius(12)
                .onClick(() => { this.downloadCurrent(); })
            }
          }
          .alignSelf(ItemAlign.Start).width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
        .backgroundColor('rgba(0,0,0,0.6)')
        .position({ x: 0, y: '100%' })
        .markAnchor({ x: 0, y: '100%' })
      }
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.detail_bg'))
  }
}
