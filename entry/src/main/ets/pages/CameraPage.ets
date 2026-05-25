import { ConnectionStatusBar } from '../components/ConnectionStatusBar';
import { CameraService } from '../services/CameraService';

@ComponentV2
export struct CameraPage {
  @Local svc: CameraService = CameraService.getInstance();
  @Event onScan: () => void = () => {};
  @Event onDisconnect: () => void = () => {};

  build() {
    Column() {
      ConnectionStatusBar({
        connected: this.svc.connected, cameraName: this.svc.cameraName,
        photoCount: this.svc.photoCount, statusText: this.svc.statusText,
        compact: false, scanProgress: this.svc.scanProgress, scanTotal: this.svc.scanTotal
      }).margin({ top: 12, bottom: 12 })

      Row() {
        Button(this.svc.scanning ? '扫描中...' : (this.svc.connected ? '重新扫描' : '搜索相机'))
          .onClick(() => { this.onScan(); })
          .enabled(!this.svc.scanning).fontSize(14).width('45%')

        if (this.svc.connected) {
          Button('断开连接')
            .onClick(() => { this.onDisconnect(); })
            .fontSize(14).width('45%')
            .backgroundColor($r('app.color.button_danger'))
            .margin({ left: '5%' })
        }
      }
      .width('100%').margin({ bottom: 12 })

      if (this.svc.connected) {
        Text('设备信息')
          .fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .alignSelf(ItemAlign.Start).margin({ top: 8, bottom: 8 })

        Column() {
          Row() {
            Text('型号').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.svc.cameraName).fontSize(14).fontColor($r('app.color.text_primary'))
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
