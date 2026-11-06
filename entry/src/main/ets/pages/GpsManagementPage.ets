import { PageHeader } from '../components/PageHeader';
import { GpsRecorder } from '../services/GpsRecorder';
import type { GpsDailyGroup } from '../model/PhotoEntry';

@Builder
export function GpsManagementPageBuilder() {
  GpsManagementPage();
}

/**
 * 一天的记录卡片。单独做成 @ComponentV2：@Builder 的值参数不会随数据刷新，
 * 而 @Param 会（与画廊页的 ThumbImage 同理）。
 */
@ComponentV2
struct GpsDayCard {
  @Param group: GpsDailyGroup = { day: '', count: 0, first: 0, last: 0 };
  @Event onOpen: () => void = () => {};
  @Event onDelete: () => void = () => {};

  private hm(ts: number): string {
    const d = new Date(ts);
    return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  }

  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.group.day)
          .fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .alignSelf(ItemAlign.Start)
        Text(`${this.group.count} 条 · ${this.hm(this.group.first)} – ${this.hm(this.group.last)}`)
          .fontSize(11).fontColor($r('app.color.text_tertiary'))
          .alignSelf(ItemAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button('删除')
        .fontSize(12).height(30)
        .fontColor($r('app.color.button_danger'))
        .backgroundColor($r('app.color.primary_soft'))
        .onClick(() => { this.onDelete(); })
    }
    .width('100%').padding(16)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(24)
    .onClick(() => { this.onOpen(); })
  }
}

@ComponentV2
export struct GpsManagementPage {
  private pageInfos: NavPathStack = new NavPathStack();
  @Local gps: GpsRecorder = GpsRecorder.getInstance();

  /**
   * 取按天分组。参数直接传 gps.recordsVersion，是为了在构建期把这个 @Trace
   * 读到 Repeat / if 自己的表达式上 —— records 是普通数组，只在方法内部读
   * 版本号时，外层节点不一定会跟着重算，页面会停在第一次渲染的样子。
   */
  private groupsFor(version: number): GpsDailyGroup[] {
    if (version < 0) return [];
    return this.gps.getDailyStats();
  }

  private openDay(day: string): void {
    const param: Record<string, Object> = {};
    param['day'] = day;
    this.pageInfos.pushPath({
      name: 'GpsDayDetailPage',
      param: param
    });
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
          this.gps.deleteDay(day);
        }
      }
    });
  }

  build() {
    NavDestination() {
      Column() {
        PageHeader({
          title: '定位记录',
          subtitle: `共 ${this.gps.recordCount} 条`,
          onBack: () => { this.pageInfos.pop(); }
        })

        if (this.groupsFor(this.gps.recordsVersion).length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.location_north_up_right_fill'))
              .fontSize(44)
              .fontColor([$r('app.color.text_tertiary')])
            Text('还没有定位记录')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
            Text('在设置页打开「定位记录」后，应用会按设定的频率记录位置点')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
          }
          .width('100%').layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            Repeat<GpsDailyGroup>(this.groupsFor(this.gps.recordsVersion))
              .each((ri: RepeatItem<GpsDailyGroup>) => {
                ListItem() {
                  GpsDayCard({
                    group: ri.item,
                    onOpen: () => { this.openDay(ri.item.day); },
                    onDelete: () => { this.deleteDay(ri.item.day, ri.item.count); }
                  })
                }
                .margin({ bottom: 8 })
              })
              // key 要带上会变的内容：只用 day 的话，当天最后一条时间每次心跳都在变，
              // 命中同一个 key 不会重跑 each，行内容就不会刷新。
              .key((group: GpsDailyGroup) => `${group.day}_${group.count}_${group.first}_${group.last}`)
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
