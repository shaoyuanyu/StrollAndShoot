import { ConnectionStatusBar } from '../components/ConnectionStatusBar';
import { CameraService } from '../services/CameraService';

@ComponentV2
export struct CameraPage {
  @Local svc: CameraService = CameraService.getInstance();
  @Event onScan: (quickMode: boolean) => void = (_q: boolean) => {};
  @Event onDisconnect: () => void = () => {};

  build() {
    Column() {
      ConnectionStatusBar({
        connected: this.svc.connected, cameraName: this.svc.cameraName,
        photoCount: this.svc.photoCount, statusText: this.svc.statusText,
        compact: false, scanProgress: this.svc.scanProgress, scanTotal: this.svc.scanTotal,
        scanStatsText: this.svc.scanStatsText,
        scanPhaseText: this.svc.scanPhaseText
      }).margin({ top: 12, bottom: 12 })

      if (!this.svc.connected) {
        Button('搜索相机')
          .onClick(() => { this.onScan(true); })
          .fontSize(14).width('80%')
          .enabled(!this.svc.scanning)
      } else {
        Row() {
          Button('快速扫描')
            .onClick(() => { this.onScan(true); })
            .enabled(!this.svc.scanning).fontSize(14).width('45%')

          if (this.svc.scanning) {
            Button('扫描中...')
              .fontSize(14).width('45%')
              .backgroundColor('#888')
          } else {
            Button('全量扫描')
              .onClick(() => { this.onScan(false); })
              .fontSize(14).width('45%')
              .backgroundColor('#E65100')
          }
        }
        .width('100%')
        .margin({ bottom: 8 })

        Row() {
          Button('断开连接')
            .onClick(() => { this.onDisconnect(); })
            .fontSize(14).width('80%')
            .backgroundColor($r('app.color.button_danger'))
        }
        .width('100%')
        .margin({ bottom: 12 })
      }

      if (this.svc.connected) {
        Text('设备信息')
          .fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .alignSelf(ItemAlign.Start).margin({ top: 8, bottom: 8 })

        Column() {
          Row() {
            Text('品牌').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.svc.deviceManufacturer || '未知').fontSize(14).fontColor($r('app.color.text_primary'))
          }.width('100%').padding(12)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          Row() {
            Text('型号').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.svc.cameraName || '未知').fontSize(14).fontColor($r('app.color.text_primary'))
          }.width('100%').padding(12)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          Row() {
            Text('序列号(PTP)').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.svc.deviceSerialNumber || '无').fontSize(14).fontColor($r('app.color.text_primary'))
          }.width('100%').padding(12)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          Row() {
            Text('固件版本').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.svc.deviceVersion || '未知').fontSize(14).fontColor($r('app.color.text_primary'))
          }.width('100%').padding(12)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          Row() {
            Text('USB识别码').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.svc.usbVidPid).fontSize(13).fontColor($r('app.color.text_primary'))
          }.width('100%').padding(12)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          Row() {
            Text('USB序列号').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.svc.usbSerialNumber || '无').fontSize(14).fontColor($r('app.color.text_primary'))
          }.width('100%').padding(12)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          Row() {
            Text('缓存标识').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.svc.cameraIdentity).fontSize(12).fontColor($r('app.color.text_primary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').padding(12)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          Row() {
            Text('照片数量').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(`${this.svc.photoCount}`).fontSize(14).fontColor($r('app.color.text_primary'))
          }.width('100%').padding(12)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          Row() {
            Text('连接方式').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text('USB').fontSize(14).fontColor($r('app.color.text_primary'))
          }.width('100%').padding(12)
        }
        .width('100%')
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(8)
      }
    }
    .width('100%').height('100%').padding({ left: 12, right: 12 })
  }
}
