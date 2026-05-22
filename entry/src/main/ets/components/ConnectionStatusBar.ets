@Component
export struct ConnectionStatusBar {
  @Prop connected: boolean = false;
  @Prop cameraName: string = '';
  @Prop photoCount: number = 0;
  @Prop statusText: string = '就绪';
  @Prop compact: boolean = false;
  @Prop scanProgress: number = 0;
  @Prop scanTotal: number = 0;

  build() {
    if (this.compact) {
      Row() {
        Circle({ width: 8, height: 8 })
          .fill(this.connected ? $r('app.color.status_connected') : $r('app.color.status_disconnected'))
        Text(this.connected ? this.cameraName : this.statusText)
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 6 })
        Blank()
        if (this.connected && this.photoCount > 0) {
          Text(`${this.photoCount}`)
            .fontSize(11)
            .fontColor($r('app.color.text_on_primary'))
            .backgroundColor($r('app.color.primary'))
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor($r('app.color.primary_light'))
      .borderRadius(16)
    } else {
      Column() {
        Row() {
          Circle({ width: 12, height: 12 })
            .fill(this.connected ? $r('app.color.status_connected') :
                  (this.statusText.includes('搜索') || this.statusText.includes('扫描') ?
                   $r('app.color.primary') : $r('app.color.status_disconnected')))
          Text(this.statusText)
            .fontSize(16)
            .fontColor(this.connected ? $r('app.color.status_connected') :
                       (this.statusText.includes('搜索') || this.statusText.includes('扫描') ?
                        $r('app.color.primary') : $r('app.color.status_disconnected')))
            .margin({ left: 8 })
        }

        if (this.connected && this.cameraName) {
          Text(`相机型号: ${this.cameraName}`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 8 })
        }

        if (this.connected) {
          Text(`照片数量: ${this.photoCount}`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 4 })
        }

        if (this.scanTotal > 0) {
          Column() {
            Progress({
              value: this.scanProgress,
              total: this.scanTotal,
              type: ProgressType.Linear
            })
              .width('100%')
              .height(4)
              .color($r('app.color.primary'))
              .backgroundColor($r('app.color.thumbnail_placeholder'))
            Text(`${this.scanProgress}/${this.scanTotal}`)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 4 })
          }
          .width('100%')
          .margin({ top: 8 })
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.bg_page'))
      .borderRadius(12)
    }
  }
}
