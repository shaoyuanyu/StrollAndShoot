import { router } from '@kit.ArkUI';
import { GpsRecorder } from '../services/GpsRecorder';
import type { GpsDailyGroup } from '../model/PhotoEntry';

@Entry
@Component
struct GpsManagementPage {
  private gpsRecorder: GpsRecorder = GpsRecorder.getInstance();
  @State dailyGroups: GpsDailyGroup[] = [];
  @State totalCount: number = 0;

  aboutToAppear(): void {
    this.refresh();
    this.gpsRecorder.onChange = () => { this.refresh(); };
  }

  refresh(): void {
    this.dailyGroups = this.gpsRecorder.getDailyStats();
    this.totalCount = this.gpsRecorder.recordCount();
  }

  deleteDay(day: string, count: number): void {
    AlertDialog.show({
      title: '删除记录',
      message: `删除 ${day} 的 ${count} 条GPS记录？`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E84026',
        action: () => {
          this.gpsRecorder.deleteDay(day);
          this.refresh();
        }
      }
    });
  }

  build() {
    Column() {
      // Header
      Row() {
        Button({ type: ButtonType.Circle }) {
          Text('←').fontSize(18)
        }
        .width(36).height(36)
        .backgroundColor($r('app.color.bg_surface'))
        .onClick(() => { router.back(); })

        Text('GPS记录管理')
          .fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 10 })

        Blank()

        Text(`共 ${this.totalCount} 条`)
          .fontSize(13).fontColor($r('app.color.text_secondary'))
      }
      .width('100%').padding({ left: 12, right: 12, top: 12, bottom: 8 })

      if (this.dailyGroups.length === 0) {
        Column() {
          Text('暂无GPS记录')
            .fontSize(14).fontColor($r('app.color.text_secondary'))
            .margin({ top: 80 })
        }
        .width('100%').layoutWeight(1)
      } else {
        List() {
          ForEach(this.dailyGroups, (group: GpsDailyGroup) => {
            ListItem() {
              Row() {
                Column() {
                  Text(group.day)
                    .fontSize(15).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text(`${group.count} 条记录`)
                    .fontSize(12).fontColor($r('app.color.text_secondary'))
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)

                Blank()

                Button('删除')
                  .fontSize(12).height(30)
                  .fontColor('#E84026')
                  .backgroundColor($r('app.color.bg_page'))
                  .onClick(() => { this.deleteDay(group.day, group.count); })
              }
              .width('100%').padding(14)
              .onClick(() => {
                router.pushUrl({
                  url: 'pages/GpsDayDetailPage',
                  params: { day: group.day }
                });
              })
            }
          }, (group: GpsDailyGroup) => group.day)
        }
        .width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
