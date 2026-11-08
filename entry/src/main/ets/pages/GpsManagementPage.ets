import { uiMaterial } from '@kit.ArkUI';
import { GpsTrackMap } from '../components/GpsTrackMap';
import { GpsRecorder } from '../services/GpsRecorder';
import { GpsTrackCache } from '../services/GpsTrackCache';
import { WindowUtils } from '../utils/WindowUtils';
import { TITLE_BAR_HEIGHT, titleBarInsetVp } from '../utils/TitleBarMetrics';
import { type GpsDayTrack } from '../utils/GpsTrack';
import type { GpsDailyGroup } from '../model/PhotoEntry';

@Builder
export function GpsManagementPageBuilder() {
  GpsManagementPage();
}

/**
 * 一天的记录卡片。
 *
 * 拆成独立 @ComponentV2 的原因：Repeat 命中相同 key 时不会重跑 each，
 * 卡片内部直接读 gps.recordsVersion / @Consumer expandedDays，才能在
 * 记录增加、展开状态变化时独立刷新，而不是靠每次都换 key（那会把地图
 * 组件整个重建，展开中的地图会闪）。
 */
@ComponentV2
struct GpsDayCard {
  @Param day: string = '';
  @Event onToggle: () => void = () => {};
  @Event onSelectToggle: () => void = () => {};
  @Event onOpen: () => void = () => {};

  private gps: GpsRecorder = GpsRecorder.getInstance();
  private trackCache: GpsTrackCache = GpsTrackCache.getInstance();
  @Consumer() expandedDays: string[] = [];
  @Consumer() selectMode: boolean = false;
  @Consumer() selectedDays: string[] = [];

  private expanded(): boolean {
    return this.expandedDays.includes(this.day);
  }

  private selected(): boolean {
    return this.selectedDays.includes(this.day);
  }

  private group(): GpsDailyGroup | null {
    // 读 recordsVersion 建立 V2 依赖；getGroupForDay 内部有按天的聚合缓存
    return this.gps.getGroupForDay(this.day);
  }

  private isMock(): boolean {
    const g = this.group();
    return g !== null && g.mock === true;
  }

  private countText(): string {
    const g = this.group();
    return g !== null ? `${g.count} 条定位记录` : '0 条定位记录';
  }

  private hm(ts: number): string {
    const d = new Date(ts);
    return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  }

  private timeRange(): string {
    const g = this.group();
    if (g === null) return '';
    return `${this.hm(g.first)} – ${this.hm(g.last)}`;
  }

  /** 只有展开且不在多选态时才聚合当天轨迹；收起/多选不遍历记录。 */
  private track(): GpsDayTrack | null {
    if (!this.expanded() || this.selectMode) return null;
    if (this.gps.recordsVersion < 0) return null;
    const records = this.gps.getDayRecords(this.day);
    return this.trackCache.getDayTrack(this.day, records);
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(this.day)
              .fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            if (this.isMock()) {
              // 不再做胶囊徽章；一个轻量文字标识即可
              Text('模拟')
                .fontSize(10)
                .fontColor($r('app.color.primary'))
            }
          }
          .alignItems(VerticalAlign.Center)

          Text(`${this.countText()} · ${this.timeRange()}`)
            .fontSize(11).fontColor($r('app.color.text_tertiary'))
            .alignSelf(ItemAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.selectMode) {
          Stack() {
            Circle()
              .width(22).height(22)
              .fill(this.selected() ? $r('app.color.primary') : Color.Transparent)
              .stroke(this.selected() ? $r('app.color.primary') : $r('app.color.text_tertiary'))
              .strokeWidth(1.5)
            if (this.selected()) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(12)
                .fontColor([$r('app.color.text_on_primary')])
            }
          }
          .width(22).height(22)
        } else {
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(16)
            .fontColor([$r('app.color.text_tertiary')])
            .rotate({ angle: this.expanded() ? 180 : 0 })
        }
      }
      .width('100%')
      .padding(16)
      .onClick(() => {
        if (this.selectMode) {
          this.onSelectToggle();
        } else {
          this.onToggle();
        }
      })

      if (this.expanded() && !this.selectMode) {
        Column() {
          GpsTrackMap({
            track: this.track(),
            onOpen: () => { this.onOpen(); }
          })
        }
        .width('100%')
        .height(190)
        .padding({ left: 12, right: 12, bottom: 12 })
        .borderRadius(18)
        .clip(true)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(24)
    .border({
      width: this.selectMode && this.selected() ? 1.5 : 0,
      color: $r('app.color.primary')
    })
    .clip(true)
  }
}

@ComponentV2
export struct GpsManagementPage {
  private pageInfos: NavPathStack = new NavPathStack();
  @Local gps: GpsRecorder = GpsRecorder.getInstance();
  /** 展开的日期（手风琴，只保留一个）。@Provider 让每张卡片独立订阅。 */
  @Provider() expandedDays: string[] = [];
  /** 多选态：日期卡只做选择，不展开地图。 */
  @Provider() selectMode: boolean = false;
  @Provider() selectedDays: string[] = [];
  private defaultExpansionApplied: boolean = false;
  private trackCache: GpsTrackCache = GpsTrackCache.getInstance();
  /** 标题栏玻璃控件材质。只有放在 NavDestination.title 里才能拿到真材质。 */
  private readonly titleMaterial: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      interactive: true
    });
  /** 多选底部操作栏；挂进标题栏浮层，才能拿到内容区没有的真材质。 */
  private readonly floatMaterial: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      interactive: true
    });

  aboutToAppear(): void {
    this.applyDefaultExpansion();
  }

  @Monitor('gps.recordsVersion')
  onRecordsChanged(): void {
    // 页面打开时还没有记录（例如刚清空过），等第一批数据到了再展开第一条
    if (!this.defaultExpansionApplied) {
      this.applyDefaultExpansion();
    }
    if (this.selectMode) {
      const groups = this.groupsFor(this.gps.recordsVersion);
      if (groups.length === 0) {
        this.selectMode = false;
        this.selectedDays = [];
      } else {
        const valid = this.selectedDays.filter((day: string) =>
          groups.some((g: GpsDailyGroup): boolean => g.day === day));
        if (valid.length !== this.selectedDays.length) {
          this.selectedDays = valid;
        }
      }
    }
  }

  private navIndicatorVp(): number {
    const px = WindowUtils.navigationIndicatorHeightPx;
    return px > 0 ? this.getUIContext().px2vp(px) : 0;
  }

  /** 多选操作栏离屏幕顶部的 vp 位置；与底部页签/手势条保持同样的 12vp 间距。 */
  private selectionBarTopVp(): number {
    const heightPx = WindowUtils.windowHeightPx;
    if (heightPx <= 0) return 0;
    const heightVp = this.getUIContext().px2vp(heightPx);
    return Math.max(0, heightVp - this.navIndicatorVp() - 56 - 12);
  }

  private applyDefaultExpansion(): void {
    if (this.defaultExpansionApplied) return;
    const groups = this.gps.getDailyStats();
    if (groups.length === 0) return;
    this.expandedDays = [groups[0].day];
    this.defaultExpansionApplied = true;
  }

  /**
   * 取按天分组。参数直接传 gps.recordsVersion，是为了在构建期把这个 @Trace
   * 读到 Repeat / if 自己的表达式上 —— records 是普通数组，只在方法内部读
   * 版本号时，外层节点不一定会跟着重算。
   */
  private groupsFor(version: number): GpsDailyGroup[] {
    if (version < 0) return [];
    return this.gps.getDailyStats();
  }

  private headerActionText(): string {
    if (this.selectMode) return '取消';
    return this.groupsFor(this.gps.recordsVersion).length > 0 ? '选择' : '';
  }

  private onHeaderAction(): void {
    if (this.selectMode) {
      this.exitSelectMode();
    } else {
      this.selectMode = true;
      this.selectedDays = [];
      this.expandedDays = [];
    }
  }

  private exitSelectMode(): void {
    this.selectMode = false;
    this.selectedDays = [];
    const groups = this.groupsFor(this.gps.recordsVersion);
    this.expandedDays = groups.length > 0 ? [groups[0].day] : [];
  }

  private toggleDay(day: string): void {
    // 手风琴：同时只保留一个展开的地图。一天一张 MapComponent 太重，
    // 多个日期同时展开会把列表变成多张地图实例，滚动也容易掉帧。
    const next: string[] = this.expandedDays.includes(day) ? [] : [day];
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.expandedDays = next;
    });
  }

  private toggleSelected(day: string): void {
    const next = this.selectedDays.slice();
    const idx = next.indexOf(day);
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(day);
    }
    this.selectedDays = next;
  }

  private toggleSelectAll(): void {
    const groups = this.groupsFor(this.gps.recordsVersion);
    if (this.selectedDays.length === groups.length) {
      this.selectedDays = [];
    } else {
      this.selectedDays = groups.map((g: GpsDailyGroup): string => g.day);
    }
  }

  private openViewer(day: string): void {
    const param: Record<string, Object> = {};
    param['day'] = day;
    this.pageInfos.pushPath({
      name: 'GpsTrackViewerPage',
      param: param
    });
  }

  private deleteSelected(): void {
    const days = this.selectedDays.slice();
    if (days.length === 0) return;

    const groups = this.groupsFor(this.gps.recordsVersion);
    const mockDays = days.filter((day: string): boolean => this.gps.isMockDay(day));
    const realDays = days.filter((day: string): boolean => !this.gps.isMockDay(day));
    let total = 0;
    for (const g of groups) {
      if (realDays.includes(g.day)) total += g.count;
    }

    let title = '删除定位记录';
    let message = `删除选中的 ${realDays.length} 天，共 ${total} 条定位记录？`;
    if (realDays.length === 0) {
      title = '清除模拟轨迹';
      message = `清除 ${mockDays.length} 天的模拟轨迹？真实定位记录不受影响。`;
    } else if (mockDays.length > 0) {
      message = `删除 ${realDays.length} 天的 ${total} 条定位记录，并清除 ${mockDays.length} 天的模拟轨迹？`;
    }
    const actionLabel = realDays.length === 0 ? '清除' : '删除';

    this.getUIContext().showAlertDialog({
      title: title,
      message: message,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: actionLabel,
        fontColor: $r('app.color.button_danger'),
        action: () => {
          for (const day of days) {
            this.gps.deleteDay(day);
            this.trackCache.invalidate(day);
          }
          this.selectedDays = [];
          this.selectMode = false;
          const remaining = this.groupsFor(this.gps.recordsVersion);
          this.expandedDays = remaining.length > 0 ? [remaining[0].day] : [];
        }
      }
    });
  }

  /**
   * 多选底部操作栏。自身不设背景，材质由 ManagementTitleBar 的浮岛层提供；
   * 直接放在内容区里 systemMaterial 不生效。
   */
  @Builder
  SelectBottomBar() {
    Row({ space: 8 }) {
      Text(`已选 ${this.selectedDays.length} 天`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)

      Button(this.selectedDays.length === this.groupsFor(this.gps.recordsVersion).length
        ? '取消全选' : '全选')
        .fontSize(14)
        .height(36)
        .fontColor($r('app.color.primary'))
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.toggleSelectAll(); })

      Button('删除')
        .fontSize(14)
        .height(36)
        .padding({ left: 18, right: 18 })
        .fontColor($r('app.color.text_on_primary'))
        .backgroundColor($r('app.color.button_danger'))
        .borderRadius(18)
        .enabled(this.selectedDays.length > 0)
        .opacity(this.selectedDays.length > 0 ? 1 : 0.35)
        .onClick(() => { this.deleteSelected(); })
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 10 })
    .borderRadius(28)
    .systemMaterial(this.floatMaterial)
  }

  /**
   * 二级页标题栏。必须走 NavDestination.title：沉浸光感只在标题栏里生效，
   * 放在内容区的 Button 即使设了 systemMaterial 也拿不到材质。
   */
  @Builder
  ManagementTitleBar() {
    Stack({ alignContent: Alignment.Top }) {
      // 标题栏下面是会滚动的日期卡，纯文字标题需要一层从页面底色到透明的
      // 渐隐，避免卡片滑到标题文字后面糊成一片；玻璃控件本身由材质负责模糊。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.nav_bg'), 0],
            [$r('app.color.nav_bg'), 0.3],
            [$r('app.color.nav_bg_mid'), 0.7],
            [$r('app.color.bg_page_fade'), 1]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      Column() {
        Blank().height(Math.max(0, titleBarInsetVp() - TITLE_BAR_HEIGHT))
        Row({ space: 8 }) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(20)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40).height(40)
          .backgroundColor(Color.Transparent)
          .borderRadius(20)
          .systemMaterial(this.titleMaterial)
          .onClick(() => { this.pageInfos.pop(); })

          Column({ space: 1 }) {
            Text('定位记录')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
            Text(`共 ${this.gps.displayRecordCount()} 条定位记录`)
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (this.headerActionText().length > 0) {
            Button(this.headerActionText())
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .height(36)
              .padding({ left: 16, right: 16 })
              .backgroundColor(Color.Transparent)
              .borderRadius(18)
              .systemMaterial(this.titleMaterial)
              .onClick(() => { this.onHeaderAction(); })
          }
        }
        .width('100%')
        .height(TITLE_BAR_HEIGHT)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height('100%')

      if (this.selectMode && WindowUtils.windowHeightPx > 0) {
        Column() {
          this.SelectBottomBar()
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
        .position({ x: 0, y: this.selectionBarTopVp() })
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    NavDestination() {
      Column() {
        if (this.groupsFor(this.gps.recordsVersion).length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.location_north_up_right_fill'))
              .fontSize(44)
              .fontColor([$r('app.color.text_tertiary')])
            Text('还没有定位记录')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
            Text('在设置页打开「定位记录」后，应用会按设定的频率记录定位')
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
                    day: ri.item.day,
                    onToggle: () => { this.toggleDay(ri.item.day); },
                    onSelectToggle: () => { this.toggleSelected(ri.item.day); },
                    onOpen: () => { this.openViewer(ri.item.day); }
                  })
                }
                .margin({ bottom: 8 })
              })
              // key 只用 day：当天的心跳点每分钟都在变，若把 count/first/last
              // 编进 key，每次定位都会重建整张卡片（以及展开中的地图）。
              .key((group: GpsDailyGroup) => group.day)
          }
          .width('100%').layoutWeight(1)
          .padding({
            left: 16,
            right: 16,
            top: 8,
            // 多选操作栏悬浮在列表上方，给最后一张卡片留出同样的高度。
            bottom: this.selectMode ? 84 + this.navIndicatorVp() : 16 + this.navIndicatorVp()
          })
          .contentStartOffset(titleBarInsetVp())
          .scrollBar(BarState.Off)
        }
      }
      .width('100%').height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideBackButton(true)
    .title({ builder: this.ManagementTitleBar, height: titleBarInsetVp() }, {
      barStyle: BarStyle.STACK
    })
    .backgroundColor($r('app.color.bg_page'))
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}
