@Component
export struct SelectionActionBar {
  @Prop selectedCount: number = 0;
  @Prop totalVisible: number = 0;
  onCancel: () => void = () => {};
  onDownload: () => void = () => {};
  onSelectAll: () => void = () => {};

  private get allSelected(): boolean {
    return this.totalVisible > 0 && this.selectedCount >= this.totalVisible;
  }

  build() {
    Row() {
      Button(this.allSelected ? '取消全选' : '全选')
        .fontSize(13)
        .backgroundColor($r('app.color.bg_page'))
        .fontColor($r('app.color.primary'))
        .onClick(() => { this.onSelectAll(); })
        .margin({ right: 8 })

      Text(`已选 ${this.selectedCount} 张`)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Button('取消')
        .fontSize(13)
        .backgroundColor($r('app.color.bg_page'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => { this.onCancel(); })
        .margin({ right: 8 })

      Button(`下载 (${this.selectedCount})`)
        .fontSize(13)
        .backgroundColor($r('app.color.primary'))
        .fontColor($r('app.color.text_on_primary'))
        .enabled(this.selectedCount > 0)
        .onClick(() => { this.onDownload(); })
    }
    .width('100%').height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.action_bar_bg'))
  }
}
