import { CameraService } from '../services/CameraService';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';

@ComponentV2
export struct CameraPage {
  @Local svc: CameraService = CameraService.getInstance();
  @Param scroller: Scroller = new Scroller();
  @Event onScan: (quickMode: boolean) => void = (_q: boolean) => {};
  @Event onDisconnect: () => void = () => {};

  private statusColor(): Resource {
    if (this.svc.connected) return $r('app.color.status_connected');
    if (this.svc.scanning) return $r('app.color.primary');
    return $r('app.color.status_disconnected');
  }

  @Builder
  StatusCard() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Row()
          .width(8).height(8).borderRadius(4)
          .backgroundColor(this.statusColor())
        Text(this.svc.connected ? '已连接' : (this.svc.statusText || '未连接相机'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.svc.connected && this.svc.photoCount > 0) {
          Text(`${this.svc.photoCount} 张`)
            .fontSize(13)
            .fontColor($r('app.color.primary'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.primary_soft'))
            .borderRadius(12)
        }
      }
      .width('100%')

      if (this.svc.connected) {
        Column({ space: 4 }) {
          Text(this.svc.cameraName)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.svc.cameraIdentity)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      if (this.svc.scanTotal > 0) {
        Column({ space: 6 }) {
          Progress({
            value: this.svc.scanProgress,
            total: this.svc.scanTotal,
            type: ProgressType.Linear
          })
            .width('100%').height(3)
            .color($r('app.color.primary'))
            .backgroundColor($r('app.color.divider'))
          Row() {
            Text(this.svc.scanPhaseText || '正在扫描')
              .fontSize(11).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(`${this.svc.scanProgress}/${this.svc.scanTotal}`)
              .fontSize(11).fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
        }
        .width('100%')
      }

      if (this.svc.scanStatsText) {
        Text(this.svc.scanStatsText)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(16)
    .border({ width: 1, color: $r('app.color.card_border') })
  }

  @Builder
  Actions() {
    if (!this.svc.connected) {
      Column({ space: 12 }) {
        Button('搜索相机')
          .width('100%').height(44)
          .fontSize(16)
          .fontColor($r('app.color.text_on_primary'))
          .backgroundColor($r('app.color.primary'))
          .enabled(!this.svc.scanning)
          .onClick(() => { this.onScan(true); })
        Text('请用 USB 数据线连接相机，并在相机上选择 PTP 传输模式')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('100%')
    } else {
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Button('快速扫描')
            .layoutWeight(1).height(48)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_on_primary'))
            .backgroundColor($r('app.color.primary'))
            .enabled(!this.svc.scanning)
            .opacity(this.svc.scanning ? 0.4 : 1)
            .onClick(() => { this.onScan(true); })
          Button('全量扫描')
            .layoutWeight(1).height(48)
            .fontSize(15)
            .fontColor($r('app.color.primary'))
            .backgroundColor($r('app.color.primary_soft'))
            .border({ width: 1, color: $r('app.color.primary') })
            .enabled(!this.svc.scanning)
            .opacity(this.svc.scanning ? 0.4 : 1)
            .onClick(() => { this.onScan(false); })
        }
        .width('100%')

        Button('断开连接')
          .width('100%').height(44)
          .fontSize(15)
          .fontColor($r('app.color.button_danger'))
          .backgroundColor($r('app.color.bg_surface'))
          .border({ width: 1, color: $r('app.color.button_danger') })
          .onClick(() => { this.onDisconnect(); })
      }
      .width('100%')
    }
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 12 }) {
        if (this.svc.connected || this.svc.scanning || this.svc.scanTotal > 0) {
          this.StatusCard()
        }
        this.Actions()

        if (this.svc.connected) {
          Text('设备信息')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ top: 4, left: 4 })

          Column() {
            CameraInfoRow({ label: '品牌', value: this.svc.deviceManufacturer || '未知' })
            CameraInfoRow({ label: '型号', value: this.svc.cameraName || '未知' })
            CameraInfoRow({ label: '序列号', value: this.svc.deviceSerialNumber || '无' })
            CameraInfoRow({ label: '固件版本', value: this.svc.deviceVersion || '未知' })
            CameraInfoRow({ label: 'USB 识别码', value: this.svc.usbVidPid || '未知' })
            CameraInfoRow({ label: 'USB 序列号', value: this.svc.usbSerialNumber || '无' })
            CameraInfoRow({ label: '缓存标识', value: this.svc.cameraIdentity || '无' })
            CameraInfoRow({ label: '照片数量', value: `${this.svc.photoCount}` })
            CameraInfoRow({ label: '连接方式', value: 'USB PTP', last: true })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.bg_surface'))
          .borderRadius(16)
          .border({ width: 1, color: $r('app.color.card_border') })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 96 })
    }
    .width('100%').height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    // 标题栏浮在内容之上，首屏内容按其高度内缩；滚动时从标题栏下方穿过
    .contentStartOffset(titleBarTotalVp())
  }
}

/** 设备信息行（独立组件，@Param 变化时会刷新）。 */
@ComponentV2
struct CameraInfoRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param last: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .flexShrink(0)
      Text(this.value)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 16 })
    }
    .width('100%')
    .height(48)
    .border(this.last ? { width: 0 } : { width: { bottom: 0.5 }, color: $r('app.color.divider') })
  }
}
