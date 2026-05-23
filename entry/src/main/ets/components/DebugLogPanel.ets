/**
 * Reusable debug log panel with copy and clear actions.
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { AppLog, type LogEntry } from '../services/AppLog';

@ComponentV2
export struct DebugLogPanel {
  @Param logText: string = '';
  private appLog: AppLog | null = null;

  // Set the AppLog instance for copy/clear operations
  setLog(log: AppLog): void {
    this.appLog = log;
  }

  build() {
    Column() {
      // Header
      Row() {
        Text('调试日志')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
        Blank()
        Button('清除')
          .onClick(() => {
            if (this.appLog) {
              this.appLog.clear();
            }
          })
          .fontSize(11)
          .height(28)
          .margin({ right: 6 })
        Button('复制')
          .onClick(() => {
            const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);
            pasteboard.getSystemPasteboard().setData(data);
            if (this.appLog) {
              this.appLog.add('日志已复制到剪贴板');
            }
          })
          .fontSize(11)
          .height(28)
      }
      .width('100%')
      .margin({ bottom: 6 })

      // Log content
      Scroll() {
        Text(this.logText)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor('#333333')
          .width('100%')
          .padding(8)
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#F0F0F0')
      .borderRadius(8)
    }
    .width('100%')
    .height('100%')
  }
}
