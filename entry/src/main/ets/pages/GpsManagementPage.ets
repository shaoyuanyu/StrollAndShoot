import { GpsRecorder } from '../services/GpsRecorder';
import type { GpsDailyGroup } from '../model/PhotoEntry';
import { PageHeader } from '../components/PageHeader';

@Builder
export function GpsManagementPageBuilder() {
  GpsManagementPage();
}

@ComponentV2
export struct GpsManagementPage {
  private pageInfos: NavPathStack = new NavPathStack();
  private gpsRecorder: GpsRecorder = GpsRecorder.getInstance();
  @Local dailyGroups: GpsDailyGroup[] = [];
  @Local totalCount: number = 0;

  aboutToAppear(): void {
    this.refresh();
    this.gpsRecorder.onChange = () => { this.refresh(); };
  }

  refresh(): void {
    this.dailyGroups = this.gpsRecorder.getDailyStats();
    this.totalCount = this.gpsRecorder.recordCount();
  }

  deleteDay(day: string, count: number): void {
    this.getUIContext().showAlertDialog({
      title: '删除记录',
      message: `删除 ${day} 的 ${count} 条GPS记录？`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.button_danger'),
        action: () => {
          this.gpsRecorder.deleteDay(day);
          this.refresh();
        }
      }
    });
  }

  build() {
    NavDestination() {
      Column() {
        // Header
        PageHeader({
          title: '定位记录',
          subtitle: `共 ${this.totalCount} 条`,
          onBack: () => { this.pageInfos.pop(); }
        })

      if (this.dailyGroups.length === 0) {
        Column() {
          Text('暂无GPS记录')
            .fontSize(14).fontColor($r('app.color.text_secondary'))
            .margin({ top: 80 })
        }
        .width('100%').layoutWeight(1)
      } else {
        List() {
          Repeat<GpsDailyGroup>(this.dailyGroups)
            .each((ri: RepeatItem<GpsDailyGroup>) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(ri.item.day)
                      .fontSize(15).fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                    Text(`${ri.item.count} 条记录`)
                      .fontSize(12).fontColor($r('app.color.text_secondary'))
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)

                  Blank()

                  Button('删除')
                    .fontSize(12).height(30)
                    .fontColor($r('app.color.button_danger'))
                    .backgroundColor($r('app.color.primary_soft'))
                    .onClick(() => { this.deleteDay(ri.item.day, ri.item.count); })
                }
                .width('100%').padding(16)
                .backgroundColor($r('app.color.bg_surface'))
                .borderRadius(16)
                .border({ width: 1, color: $r('app.color.card_border') })
                .onClick(() => {
                  const param: Record<string, Object> = {};
                  param['day'] = ri.item.day;
                  this.pageInfos.pushPath({
                    name: 'GpsDayDetailPage',
                    param: param
                  });
                })
              }
              .margin({ bottom: 8 })
            })
            .key((group: GpsDailyGroup) => group.day)
        }
        .width('100%').layoutWeight(1)
        .padding({ left: 16, right: 16, top: 8 })
        .scrollBar(BarState.Off)
      }
      }
      .width('100%').height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}
