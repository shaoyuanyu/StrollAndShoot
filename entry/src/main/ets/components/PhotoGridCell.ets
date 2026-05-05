import { CameraService } from '../services/CameraService';
import type { PhotoEntry } from '../model/PhotoEntry';

@Component
export struct PhotoGridCell {
  @Prop photo: PhotoEntry = { handle: 0, filename: '', size: 0 };
  @Prop selectMode: boolean = false;
  @Prop selected: boolean = false;
  private service: CameraService = CameraService.getInstance();
  onTap: () => void = () => {};
  onLongPress: () => void = () => {};

  build() {
    Stack() {
      if (this.service.thumbnailPixelMapMap.has(this.photo.handle)) {
        Image(this.service.thumbnailPixelMapMap.get(this.photo.handle)!)
          .objectFit(ImageFit.Cover)
          .width('100%').height('100%')
      } else {
        Column() {
          Text('📷')
            .fontSize(28)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.thumbnail_placeholder'))
      }

      // Bottom label overlay
      Column() {
        Text(this.photo.filename)
          .fontSize(10)
          .fontColor($r('app.color.text_on_dark'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 4, right: 4 })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .backgroundColor('rgba(0,0,0,0.55)')
      .position({ x: 0, y: '100%' })
      .markAnchor({ x: 0, y: '100%' })

      // Selection checkbox (select mode only)
      if (this.selectMode) {
        Checkbox()
          .select(this.selected)
          .width(22).height(22)
          .position({ x: '100%', y: 0 })
          .markAnchor({ x: '100%', y: 0 })
          .margin({ top: 6, right: 6 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%').height('100%')
    .borderRadius(8)
    .clip(true)
    .gesture(
      TapGesture({ count: 1 }).onAction(() => { this.onTap(); })
    )
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => { this.onLongPress(); })
    )
  }
}
