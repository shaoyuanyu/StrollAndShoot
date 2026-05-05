import { router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry } from '../model/PhotoEntry';

@Entry
@Component
struct PhotoDetailPage {
  @State currentIndex: number = 0;
  @State showOverlay: boolean = true;
  @State fullPixelMap: image.PixelMap | null = null;
  @State loading: boolean = false;
  @State loadedHandle: number = 0;
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
  }

  private currentPhoto(): PhotoEntry {
    return this.photos[this.currentIndex];
  }

  private async loadFullForCurrent(): Promise<void> {
    const photo = this.currentPhoto();
    if (!photo || photo.handle === this.loadedHandle) return;

    // Show thumbnail while loading
    this.fullPixelMap = null;
    this.loading = true;
    this.loadedHandle = 0;
    this.loadVersion++;
    const ver = this.loadVersion;

    const pixelMap = await this.service.loadFullPhoto(photo.handle);
    if (ver !== this.loadVersion) return; // stale

    if (pixelMap) {
      this.fullPixelMap = pixelMap;
      this.loadedHandle = photo.handle;
      // Trigger preload of adjacent photos
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
            // Show full-res if loaded for this handle, else thumbnail
            if (this.fullPixelMap && photo.handle === this.loadedHandle) {
              Image(this.fullPixelMap)
                .objectFit(ImageFit.Contain)
                .width('100%').height('100%')
            } else if (this.service.thumbnailPixelMapMap.has(photo.handle)) {
              Image(this.service.thumbnailPixelMapMap.get(photo.handle)!)
                .objectFit(ImageFit.Contain)
                .width('100%').height('100%')
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

            // Loading indicator
            if (this.loading && photo.handle === this.currentPhoto().handle) {
              LoadingProgress()
                .width(32).height(32)
                .color($r('app.color.text_on_dark'))
                .position({ x: '50%', y: '50%' })
                .markAnchor({ x: '50%', y: '50%' })
            }
          }
          .width('100%').height('100%')
          .onClick(() => { this.showOverlay = !this.showOverlay; })
        })
      }
      .index(this.currentIndex)
      .indicator(false)
      .loop(false)
      .onChange((idx: number) => {
        this.currentIndex = idx;
        this.loadFullForCurrent();
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
          }
          .alignSelf(ItemAlign.Start)
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
