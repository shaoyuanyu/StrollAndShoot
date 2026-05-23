import type { DownloadProgress } from '../model/PhotoEntry';

@ComponentV2
export struct DownloadProgressBar {
  @Param progress: DownloadProgress = {
    phase: 'idle', currentIndex: 0, totalCount: 0,
    currentFilename: '', currentSizeBytes: 0,
    downloadedCount: 0, totalBytes: 0, downloadedBytes: 0,
    errors: []
  };
  @Event onCancel: () => void = () => {};

  private progressPercent(): number {
    if (this.progress.totalCount === 0) return 0;
    return Math.round((this.progress.downloadedCount / this.progress.totalCount) * 100);
  }

  private formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }

  build() {
    Column() {
      Progress({
        value: this.progressPercent(),
        total: 100,
        type: ProgressType.Linear
      })
        .width('100%').height(4)
        .color($r('app.color.primary'))
        .backgroundColor($r('app.color.divider'))

      Row() {
        Column() {
          Text(
            this.progress.phase === 'complete'
              ? `下载完成 (${this.progress.downloadedCount}/${this.progress.totalCount})`
              : `下载中 ${this.progress.downloadedCount}/${this.progress.totalCount}`
          )
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))

          if (this.progress.phase !== 'complete' && this.progress.currentFilename) {
            Text(`${this.progress.currentFilename} (${this.formatSize(this.progress.currentSizeBytes)})`)
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.progress.phase === 'downloading' || this.progress.phase === 'saving') {
          Button('取消')
            .fontSize(13)
            .backgroundColor($r('app.color.bg_page'))
            .fontColor($r('app.color.button_danger'))
            .onClick(() => { this.onCancel(); })
        } else if (this.progress.phase === 'complete') {
          Button('完成')
            .fontSize(13)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.text_on_primary'))
            .onClick(() => { this.onCancel(); })
        }

        if (this.progress.errors.length > 0) {
          Text(`! ${this.progress.errors.length}`)
            .fontSize(11)
            .fontColor($r('app.color.status_error'))
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    }
    .width('100%')
    .backgroundColor($r('app.color.action_bar_bg'))
  }
}
