import { ConnectionStatusBar } from '../components/ConnectionStatusBar';

@Component
export struct CameraPage {
  @Prop connected: boolean = false;
  @Prop cameraName: string = '';
  @Prop photoCount: number = 0;
  @Prop statusText: string = '就绪';
  @Prop scanning: boolean = false;
  @Prop scanProgress: number = 0;
  @Prop scanTotal: number = 0;
  onScan: () => void = () => {};
  onDisconnect: () => void = () => {};

  build() {
    Column() {
      ConnectionStatusBar({
        connected: this.connected, cameraName: this.cameraName,
        photoCount: this.photoCount, statusText: this.statusText,
        compact: false, scanProgress: this.scanProgress, scanTotal: this.scanTotal
      }).margin({ top: 12, bottom: 12 })

      Row() {
        Button(this.scanning ? '扫描中...' : (this.connected ? '重新扫描' : '搜索相机'))
          .onClick(() => { this.onScan(); })
          .enabled(!this.scanning).fontSize(14).width('45%')

        if (this.connected) {
          Button('断开连接')
            .onClick(() => { this.onDisconnect(); })
            .fontSize(14).width('45%')
            .backgroundColor($r('app.color.button_danger'))
            .margin({ left: '5%' })
        }
      }
      .width('100%').margin({ bottom: 12 })

      if (this.connected) {
        Text('设备信息')
          .fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .alignSelf(ItemAlign.Start).margin({ top: 8, bottom: 8 })

        Column() {
          Row() {
            Text('型号').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.cameraName).fontSize(14).fontColor($r('app.color.text_primary'))
          }.width('100%').padding(12)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          Row() {
            Text('照片数量').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(`${this.photoCount}`).fontSize(14).fontColor($r('app.color.text_primary'))
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
