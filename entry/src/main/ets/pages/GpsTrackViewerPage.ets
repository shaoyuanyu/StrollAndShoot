import { MapComponent, map, mapCommon } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { GpsRecorder } from '../services/GpsRecorder';
import { GpsTrackCache } from '../services/GpsTrackCache';
import { GpsGeocoder } from '../services/GpsGeocoder';
import { GpsTrackSketch } from '../components/GpsTrackSketch';
import { GpsTrack, type GpsDayTrack } from '../utils/GpsTrack';
import {
  formatAltitude, formatClock, formatCoordinate, formatDistance, formatDuration, formatHm
} from '../utils/GpsFormat';
import { WindowUtils } from '../utils/WindowUtils';
import { TITLE_BAR_HEIGHT, titleBarInsetVp } from '../utils/TitleBarMetrics';
import { FontSize, IconSize, Radius, pillRadius } from '../utils/UiTokens';
import { MapCapability } from '../utils/MapCapability';
import { L10n } from '../utils/L10n';
import { formatDayKey } from '../utils/DateTimeText';
import type { GpsRecord } from '../model/PhotoEntry';

@Builder
export function GpsTrackViewerPageBuilder() {
  GpsTrackViewerPage();
}

/** 全屏折线最多保留的顶点数。一天的 11 秒记录约 7 千点，4000 点足够细腻。 */
const FULLSCREEN_MAX_POINTS = 4000;
const MAP_INIT_TIMEOUT_MS = 10000;

/**
 * 单条定位明细。
 *
 * 选中态通过 @Consumer 读取页面上的 @Provider selectedIndex：Repeat 命中
 * 相同 key 不会重跑 each，不能只靠父组件把 selected 作为 @Param 传进来。
 * 地址按坐标缓存，这里读一次 cachedText 就建立了对 GpsGeocoder.version 的依赖。
 */
interface GpsTrackGroup {
  startIndex: number;
  endIndex: number;
  first: number;
  last: number;
  count: number;
  latitude: number;
  longitude: number;
  distanceMeters: number;
  stationary: boolean;
}

/** 相邻采样超过 30 分钟视为新行程；GPS 心跳一般 10 分钟一个，不会误切。 */
const TRIP_GAP_MS: number = 30 * 60 * 1000;
/** 行程内累计位移小于 120 米视为停留。 */
const STAY_DISTANCE_METERS: number = 120;

interface GpsTimelineItem {
  kind: string;
  group: GpsTrackGroup;
  pointIndex: number;
}

@ComponentV2
struct GpsPointRow {
  @Param index: number = 0;
  @Param record: GpsRecord = { timestamp: 0, latitude: 0, longitude: 0, altitude: 0 };
  @Param isFirst: boolean = false;
  @Param isLast: boolean = false;
  @Param precise: boolean = false;
  @Event onSelect: () => void = () => {};
  @Consumer() selectedIndex: number = -1;

  private geocoder: GpsGeocoder = GpsGeocoder.getInstance();

  private selected(): boolean {
    return this.selectedIndex === this.index;
  }

  private timeText(): string {
    return this.precise
      ? formatClock(this.record.timestamp)
      : formatHm(this.record.timestamp);
  }

  private address(): string {
    return this.geocoder.cachedText(this.record.latitude, this.record.longitude);
  }

  build() {
    Column() {
      if (this.selected()) {
        Column() {
          Column({ space: 4 }) {
            Row({ space: 6 }) {
              Text(this.timeText())
                .fontSize(FontSize.CardTitle)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.primary'))
              if (this.isFirst || this.isLast) {
                Text(this.isFirst
                  ? $r('app.string.gps_start_point') : $r('app.string.gps_end_point'))
                  .fontSize(FontSize.Micro)
                  .fontColor($r('app.color.text_tertiary'))
              }
              Blank()
              if (this.record.altitude !== 0) {
                Text(formatAltitude(this.record.altitude))
                  .fontSize(FontSize.Micro)
                  .fontColor($r('app.color.text_tertiary'))
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text(formatCoordinate(this.record.latitude, this.record.longitude))
              .fontSize(FontSize.Micro)
              .fontColor($r('app.color.text_tertiary'))
              .alignSelf(ItemAlign.Start)

            if (this.address() !== '') {
              Text(this.address())
                .fontSize(FontSize.Caption)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .alignSelf(ItemAlign.Start)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 8, right: 8, top: 14, bottom: 14 })
          .backgroundColor($r('app.color.primary_soft'))
          .borderRadius(Radius.Inner)
          .onClick(() => { this.onSelect(); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      } else {
        Row({ space: 12 }) {
          Row({ space: 6 }) {
            Text(this.timeText())
              .fontSize(FontSize.Body)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            if (this.isFirst || this.isLast) {
              Text(this.isFirst
                  ? $r('app.string.gps_start_point') : $r('app.string.gps_end_point'))
                .fontSize(FontSize.Micro)
                .fontColor($r('app.color.text_tertiary'))
            }
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 20, right: 20, top: 14, bottom: 14 })
        .onClick(() => { this.onSelect(); })

        if (!this.isLast) {
          Divider()
            .color($r('app.color.divider'))
            .margin({ left: 20, right: 20 })
        }
      }
    }
    .width('100%')
  }
}

@ComponentV2
struct GpsGroupHeader {
  @Param groupStart: number = 0;
  @Param first: number = 0;
  @Param last: number = 0;
  @Param count: number = 0;
  @Param latitude: number = 0;
  @Param longitude: number = 0;
  @Param distanceMeters: number = 0;
  @Param stationary: boolean = true;
  @Event onToggle: () => void = () => {};
  @Consumer() expandedGroupStarts: number[] = [];

  private geocoder: GpsGeocoder = GpsGeocoder.getInstance();

  private expanded(): boolean {
    return this.expandedGroupStarts.includes(this.groupStart);
  }

  private icon(): Resource {
    return this.stationary
      ? $r('sys.symbol.location_north_up_right_fill')
      : $r('sys.symbol.figure_walk');
  }

  private title(): string {
    const address = this.geocoder.cachedText(this.latitude, this.longitude);
    return address !== '' ? address : formatCoordinate(this.latitude, this.longitude);
  }

  private subtitle(): string {
    const range = `${formatHm(this.first)} – ${formatHm(this.last)}`;
    const records = L10n.plural('record_count', this.count, this.count);
    if (this.stationary) {
      if (this.count <= 1) return L10n.tr('gps_group_stationary', range, records);
      return L10n.tr('gps_group_stationary_duration',
        range, formatDuration(this.last - this.first), records);
    }
    return L10n.tr('gps_group_moving',
      range, formatDistance(this.distanceMeters), records);
  }

  build() {
    Column() {
      Row({ space: 10 }) {
      SymbolGlyph(this.icon())
        .fontSize(IconSize.Body)
        .fontColor([$r('app.color.primary')])

      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(this.title())
            .fontSize(FontSize.CardTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.stationary
            ? $r('app.string.gps_stationary') : $r('app.string.gps_moving'))
            .fontSize(FontSize.Micro)
            .fontColor($r('app.color.primary'))
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.subtitle())
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .alignSelf(ItemAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(IconSize.Body)
        .fontColor([$r('app.color.text_tertiary')])
        .rotate({ angle: this.expanded() ? 180 : 0 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 8, right: 8, top: 13, bottom: 12 })
      .backgroundColor($r('app.color.bg_surface'))
      .border({ width: 0.5, color: $r('app.color.card_border') })
      .borderRadius(Radius.Inner)
      .onClick(() => { this.onToggle(); })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 6, bottom: 4 })
  }
}

/**
 * 全屏轨迹查看。
 *
 * 上半部分是可交互地图，下半部分是系统 bindSheet 明细面板；列表按地点分组、
 * 虚拟化，地址只为可视分组标题和选中点按需解析。地图加载失败/超时降级为
 * Canvas 轨迹示意图（既有特殊降级），明细列表仍然完整可用。
 */
@ComponentV2
export struct GpsTrackViewerPage {
  private pageInfos: NavPathStack = new NavPathStack();
  @Local gps: GpsRecorder = GpsRecorder.getInstance();
  @Local day: string = '';
  @Local track: GpsDayTrack | null = null;
  @Local mapReady: boolean = false;
  /** 内部兜底状态（未签名 / 不支持 / 超时 / 失败），只用于分支判断，不直接显示。 */
  @Local mapError: string = '';
  /** 系统半模态的高度（vp）；拖动时由 onHeightDidChange 更新地图避让。 */
  @Local sheetHeightVp: number = 380;
  /** 系统半模态是否展开。真正的拖拽、圆角、毛玻璃和吸附都交给 bindSheet。 */
  @Local showSheet: boolean = false;
  /** 轨迹滑杆的当前位置（点索引）。 */
  @Local sliderValue: number = 0;
  /** 选中点索引。@Provider 让虚拟列表里的行各自订阅，不依赖 each 重跑。 */
  @Provider() selectedIndex: number = -1;
  /** 已展开的轨迹分组（按 group.startIndex 记）。 */
  @Provider() expandedGroupStarts: number[] = [];

  private trackCache: GpsTrackCache = GpsTrackCache.getInstance();
  private geocoder: GpsGeocoder = GpsGeocoder.getInstance();
  private listScroller: Scroller = new Scroller();
  private readonly titleMaterial: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      interactive: true
    });
  /**
   * 明细面板材质。bindSheet 不受应用级开关影响，必须显式设置 systemMaterial；
   * 设置后 backgroundColor / blurStyle 会失效，所以不再同时设这两个属性。
   */
  private readonly sheetMaterial: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THICK
    });

  private mapOptions: mapCommon.MapOptions = {
    position: { target: { latitude: 22.87938, longitude: 113.87971 }, zoom: 14 }
  };
  private mapCallback: AsyncCallback<map.MapComponentController> =
    (err: BusinessError, controller: map.MapComponentController): void => {
      this.handleMapReady(err, controller);
    };
  private controller?: map.MapComponentController;
  /** WGS84→GCJ02 结果按坐标缓存，新增定位只转换新坐标。 */
  private gcjCache: Map<string, mapCommon.LatLng> = new Map();
  private mapLoaded: boolean = false;
  private fitPending: boolean = true;
  private drawing: boolean = false;
  private drawAgain: boolean = false;
  private timeoutId: number = -1;
  private startMarkerId: string = '';
  private endMarkerId: string = '';
  private selectedMarker?: map.Marker;
  private selectionToken: number = 0;
  private prefetching: boolean = false;
  private prefetchAgain: boolean = false;
  private prefetchStart: number = 0;
  private prefetchEnd: number = 0;
  private groupsCacheFingerprint: string = '';
  private groupsCache: GpsTrackGroup[] = [];
  private timelineCacheFingerprint: string = '';
  private timelineCacheExpanded: string = '';
  private timelineCacheItems: GpsTimelineItem[] = [];
  private groupDefaultsApplied: boolean = false;
  /** 当前 List 可视范围（扁平时间线索引），用来避免点已可见的行还强制居中滚动。 */
  private visibleStart: number = 0;
  private visibleEnd: number = 8;

  aboutToDisappear(): void {
    this.cancelInitTimeout();
  }

  private cancelInitTimeout(): void {
    if (this.timeoutId >= 0) {
      clearTimeout(this.timeoutId);
      this.timeoutId = -1;
    }
  }

  private startInitTimeout(): void {
    this.cancelInitTimeout();
    this.timeoutId = setTimeout(() => {
      if (!this.mapReady && this.mapError === '') {
        this.mapError = '地图加载超时';
      }
    }, MAP_INIT_TIMEOUT_MS);
  }

  /** 只有签名包、且是超时/加载失败时给重试；未签名/无地图能力重试没有意义。 */
  private canRetryMap(): boolean {
    return MapCapability.isSignedPackage() &&
      canIUse('SystemCapability.Map.Core') &&
      (this.mapError === '地图加载超时' || this.mapError.startsWith('地图加载失败'));
  }

  private retryMap(): void {
    if (!this.canRetryMap()) return;
    this.controller = undefined;
    this.mapReady = false;
    this.mapLoaded = false;
    this.fitPending = true;
    this.mapError = '';
    this.gcjCache.clear();
    this.startInitTimeout();
  }

  /** 系统半模态参数：三档高度、拖动条、系统材质、允许操作地图。 */
  private sheetOptions(): SheetOptions {
    return {
      height: 380,
      detents: [380, 600, 780],
      detentSelection: 380,
      preferType: SheetType.BOTTOM,
      showClose: false,
      dragBar: true,
      maskColor: Color.Transparent,
      enableOutsideInteractive: true,
      systemMaterial: this.sheetMaterial,
      onHeightDidChange: (height: number) => {
        // 系统回调给的是 px（模拟器上 380vp 的档位实测返回 1330），
        // 这里必须换算成 vp，否则地图 padding 和示意图的 bottomInset 会大 3 倍多。
        const heightVp = this.getUIContext().px2vp(height);
        if (heightVp > 0) {
          this.sheetHeightVp = heightVp;
          this.applySheetMapPadding();
        }
      },
      onWillDismiss: (action: DismissSheetAction) => {
        // 明细面板是页面主体：下拉到最低档不关闭；但系统侧滑/三键返回
        // 必须真正退出页面，否则 shouldDismiss 空实现会把返回手势吞掉。
        if (action.reason === DismissReason.PRESS_BACK ||
          action.reason === DismissReason.SLIDE) {
          this.showSheet = false;
          this.pageInfos.pop();
        }
      }
    };
  }

  /** 面板高度变化时同步地图的 padding 和 logo 位置。 */
  private applySheetMapPadding(): void {
    const c = this.controller;
    if (c === undefined) return;
    try {
      c.setPadding({
        left: this.getUIContext().vp2px(12),
        right: this.getUIContext().vp2px(12),
        top: this.getUIContext().vp2px(titleBarInsetVp() + 12),
        bottom: this.getUIContext().vp2px(this.sheetHeightVp + 16)
      });
      c.setLogoPadding({
        left: this.getUIContext().vp2px(10),
        bottom: this.getUIContext().vp2px(this.sheetHeightVp + 10)
      });
    } catch (_e) {
      // 地图已销毁时忽略
    }
  }

  private bottomSafeVp(): number {
    const px = WindowUtils.navigationIndicatorHeightPx;
    return px > 0 ? this.getUIContext().px2vp(px) : 0;
  }

  private isDark(): boolean {
    return WindowUtils.isDarkMode(this.getUIContext().getHostContext());
  }

  private applyMapOptions(track: GpsDayTrack): void {
    const lat = (track.bounds.minLat + track.bounds.maxLat) / 2;
    const lon = (track.bounds.minLon + track.bounds.maxLon) / 2;
    // Map Kit 的 target 必须是 GCJ02；直接用 WGS84 会在国内偏几百米。
    // 这里只是初始中心，真正的适配由 tryFit() 用转换后的点完成。
    let target: mapCommon.LatLng = { latitude: lat, longitude: lon };
    try {
      target = map.convertCoordinateSync(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        target
      );
    } catch (_e) {
      // 地图能力不可用时仍走 Canvas 兜底，保留原始坐标即可
    }
    this.mapOptions = {
      position: { target: target, zoom: 15 },
      mapType: mapCommon.MapType.STANDARD,
      rotateGesturesEnabled: true,
      scrollGesturesEnabled: true,
      zoomGesturesEnabled: true,
      tiltGesturesEnabled: true,
      zoomControlsEnabled: false,
      myLocationControlsEnabled: false,
      compassControlsEnabled: false,
      scaleControlsEnabled: false
    };
  }

  /**
   * 按行程分组：相邻采样间隔超过 30 分钟才开新组；行程内累计位移
   * 小于 120 米判为「停留」，否则判为「移动」。
   */
  private trackGroups(): GpsTrackGroup[] {
    const track = this.track;
    if (track === null || track.count === 0) return [];
    if (this.groupsCacheFingerprint === track.fingerprint) return this.groupsCache;

    const out: GpsTrackGroup[] = [];
    let current: GpsTrackGroup | null = null;
    for (let i = 0; i < track.count; i++) {
      const r = track.points[i];
      if (current === null) {
        current = {
          startIndex: i, endIndex: i,
          // 当天第一组用 runStart 并裁到 0 点，和面板顶部的「时长」保持一致；
          // 后续组从本组第一个采样点算，避免上一轮静止的起点跨过行程间隔。
          first: i === 0
            ? Math.max(GpsTrack.runStartOf(r), GpsTrack.startOfDay(r.timestamp))
            : r.timestamp,
          last: r.timestamp,
          count: 1, latitude: r.latitude, longitude: r.longitude,
          distanceMeters: 0, stationary: true
        };
        continue;
      }

      const previous = track.points[i - 1];
      const gap = r.timestamp - previous.timestamp;
      if (gap > TRIP_GAP_MS) {
        current.stationary = current.distanceMeters < STAY_DISTANCE_METERS;
        out.push(current);
        current = {
          startIndex: i, endIndex: i, first: r.timestamp, last: r.timestamp,
          count: 1, latitude: r.latitude, longitude: r.longitude,
          distanceMeters: 0, stationary: true
        };
        continue;
      }

      current.distanceMeters += GpsTrack.distanceMeters(
        previous.latitude, previous.longitude, r.latitude, r.longitude
      );
      current.endIndex = i;
      current.last = r.timestamp;
      current.count++;
    }
    if (current !== null) {
      current.stationary = current.distanceMeters < STAY_DISTANCE_METERS;
      out.push(current);
    }
    this.groupsCacheFingerprint = track.fingerprint;
    this.groupsCache = out;
    return out;
  }

  private groupForPoint(index: number): GpsTrackGroup | null {
    const groups = this.trackGroups();
    for (const g of groups) {
      if (index >= g.startIndex && index <= g.endIndex) return g;
    }
    return null;
  }

  private groupExpanded(startIndex: number): boolean {
    return this.expandedGroupStarts.includes(startIndex);
  }

  private toggleGroup(startIndex: number): void {
    const next = this.expandedGroupStarts.slice();
    const idx = next.indexOf(startIndex);
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(startIndex);
    }
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
      this.expandedGroupStarts = next;
    });
  }

  private applyGroupDefaults(next: GpsDayTrack): void {
    // 只在这个页面首次拿到轨迹时决定默认展开；后续 GPS 心跳不能把用户手动展开的分组收回去。
    if (this.groupDefaultsApplied) return;
    this.groupDefaultsApplied = true;
    const groups = this.trackGroups();
    // 小轨迹直接展开采样；长轨迹先给“地点分组”的总览，点分组再展开。
    this.expandedGroupStarts = next.count <= 30
      ? groups.map((g: GpsTrackGroup): number => g.startIndex)
      : [];
  }

  private timelineItems(): GpsTimelineItem[] {
    const track = this.track;
    if (track === null || track.count === 0) {
      this.timelineCacheFingerprint = '';
      this.timelineCacheExpanded = '';
      this.timelineCacheItems = [];
      return this.timelineCacheItems;
    }
    // 长轨迹展开一个含几千个点的分组时，每次滚动/选中都重建 GpsTimelineItem
    // 数组很浪费；按「轨迹指纹 + 展开分组」做一层轻量缓存。
    const expandedKey = this.expandedGroupStarts.join(',');
    if (this.timelineCacheFingerprint === track.fingerprint &&
      this.timelineCacheExpanded === expandedKey) {
      return this.timelineCacheItems;
    }
    const out: GpsTimelineItem[] = [];
    for (const g of this.trackGroups()) {
      out.push({ kind: 'group', group: g, pointIndex: -1 });
      if (this.groupExpanded(g.startIndex)) {
        for (let i = g.startIndex; i <= g.endIndex; i++) {
          out.push({ kind: 'point', group: g, pointIndex: i });
        }
      }
    }
    this.timelineCacheFingerprint = track.fingerprint;
    this.timelineCacheExpanded = expandedKey;
    this.timelineCacheItems = out;
    return out;
  }

  private flatIndexForPoint(pointIndex: number): number {
    const items = this.timelineItems();
    for (let i = 0; i < items.length; i++) {
      if (items[i].kind === 'point' && items[i].pointIndex === pointIndex) return i;
    }
    return -1;
  }

  private prefetchGroupAnchors(items: GpsTimelineItem[], start: number, end: number): void {
    if (!this.geocoder.isAvailable()) return;
    for (let i = start; i <= end && i < items.length; i++) {
      if (items[i].kind !== 'group') continue;
      const g = items[i].group;
      if (this.geocoder.cachedText(g.latitude, g.longitude) !== '') continue;
      this.geocoder.resolve(g.latitude, g.longitude).catch((_e: Error) => {});
    }
  }

  private loadTrack(): void {
    if (this.day === '') return;
    const records = this.gps.getDayRecords(this.day);
    const next = this.trackCache.getDayTrack(this.day, records);
    const previous = this.track;
    this.track = next;
    if (next.count > 0) {
      // 页面可能在当天还没有记录时就打开了（冷启动/刚清空），等第一批记录
      // 到了要自动把明细面板展开，不能只依赖 onReady 那一次判断。
      this.showSheet = true;
      this.applyGroupDefaults(next);
    }

    // 首次进入，或当天记录被删光后重新出现：都要重新准备地图/相机/超时
    if (previous === null || previous.count === 0) {
      if (next.count > 0) {
        this.applyMapOptions(next);
        this.mapError = '';
        this.mapReady = false;
        this.mapLoaded = false;
        this.fitPending = true;
        if (!MapCapability.isSignedPackage()) {
          // unsigned HAP（模拟器）没有地图 Profile 能力，直接走示意图
          this.mapError = '未签名调试包';
        } else if (canIUse('SystemCapability.Map.Core')) {
          this.startInitTimeout();
        } else {
          this.mapError = '本机不支持地图服务';
        }
        this.prefetchAround(0, 6);
        this.prefetchGroupAnchors(this.timelineItems(), 0, 6);
      }
      return;
    }

    if (previous.fingerprint === next.fingerprint) return;

    if (next.count === 0) {
      // 当天的记录被删光：地图节点会随 count===0 卸载，旧 controller 引用作废
      this.showSheet = false;
      this.controller = undefined;
      this.mapReady = false;
      this.mapLoaded = false;
      this.mapError = '';
      this.gcjCache.clear();
      this.selectedMarker = undefined;
      this.selectedIndex = -1;
      this.sliderValue = 0;
      this.expandedGroupStarts = [];
      this.groupsCacheFingerprint = '';
      this.groupsCache = [];
      this.groupDefaultsApplied = false;
      return;
    }

    if (this.selectedIndex >= next.count) {
      this.clearSelection();
    }
    this.drawTrack();
    if (this.fitPending) {
      this.tryFit();
    }
  }

  @Monitor('gps.recordsVersion')
  onRecordsChanged(): void {
    if (this.day === '') return;
    this.loadTrack();
  }

  private clearSelection(): void {
    this.selectedIndex = -1;
    this.sliderValue = 0;
    this.selectionToken++;
    if (this.selectedMarker !== undefined) {
      try {
        this.selectedMarker.setVisible(false);
      } catch (_e) {
        // 地图可能已经被 clear() 清掉，忽略即可
      }
    }
  }

  private selectIndex(index: number): void {
    const track = this.track;
    if (track === null || index < 0 || index >= track.count) return;
    this.selectedIndex = index;
    this.sliderValue = index;
    const record = track.points[index];
    const group = this.groupForPoint(index);
    if (group !== null && !this.groupExpanded(group.startIndex)) {
      this.expandedGroupStarts = this.expandedGroupStarts.concat([group.startIndex]);
    }
    const flatIndex = this.flatIndexForPoint(index);
    if (flatIndex >= 0 && (flatIndex < this.visibleStart || flatIndex > this.visibleEnd)) {
      this.listScroller.scrollToIndex(flatIndex, true, ScrollAlign.CENTER);
    }
    this.prefetchAround(index - 2, index + 2);

    if (this.controller !== undefined) {
      this.showSelectedMarker(record);
      this.controller.animateCamera(map.newLatLng(this.gcjOf(record), 17), 260);
    }
  }

  private onScrub(value: number, mode: SliderChangeMode): void {
    this.sliderValue = value;
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.selectIndex(Math.round(value));
    }
  }

  private prefetchAround(start: number, end: number): void {
    const track = this.track;
    if (track === null || track.count === 0) return;
    if (!this.geocoder.isAvailable()) return;
    this.prefetchStart = Math.max(0, start - 1);
    this.prefetchEnd = Math.min(track.count - 1, end + 3);
    if (this.prefetching) {
      this.prefetchAgain = true;
      return;
    }
    this.runPrefetch();
  }

  private async runPrefetch(): Promise<void> {
    this.prefetching = true;
    try {
      do {
        this.prefetchAgain = false;
        const track = this.track;
        if (track === null) break;
        for (let i = this.prefetchStart; i <= this.prefetchEnd && i < track.count; i++) {
          const r = track.points[i];
          if (this.geocoder.cachedText(r.latitude, r.longitude) !== '') continue;
          await this.geocoder.resolve(r.latitude, r.longitude);
        }
      } while (this.prefetchAgain);
    } finally {
      this.prefetching = false;
    }
  }

  private handleMapReady(err: BusinessError, controller: map.MapComponentController): void {
    this.cancelInitTimeout();
    if (err) {
      this.mapError = `地图加载失败 (${err.code})`;
      this.mapReady = false;
      return;
    }
    if (this.mapError !== '') return;

    this.controller = controller;
    this.mapReady = true;
    // 同上：初始化回调即可移动相机，不要等 mapLoad（它可能已经过去了）
    this.mapLoaded = true;
    try {
      controller.setAllGesturesEnabled(true);
      controller.setZoomControlsEnabled(false);
      controller.setMyLocationControlsEnabled(false);
      controller.setCompassControlsEnabled(false);
      controller.setScaleControlsEnabled(false);
      controller.setDayNightMode(
        this.isDark() ? mapCommon.DayNightMode.NIGHT : mapCommon.DayNightMode.DAY
      );
      controller.setLogoAlignment(mapCommon.LogoAlignment.BOTTOM_START);
      controller.setLogoScale(0.9);
      this.applySheetMapPadding();
    } catch (_e) {
      // 视觉修饰失败不影响主流程
    }

    const events = controller.getEventManager();
    events.on('mapLoad', () => {
      this.mapLoaded = true;
      this.drawTrack();
      this.tryFit();
    });
    events.on('markerClick', (marker: map.Marker) => {
      this.onMarkerClick(marker);
    });
    this.drawTrack();
    this.tryFit();
  }

  private onMarkerClick(marker: map.Marker): void {
    const track = this.track;
    if (track === null || track.count === 0) return;
    const id = marker.getId();
    if (id === this.startMarkerId) {
      this.selectIndex(0);
    } else if (id === this.endMarkerId) {
      this.selectIndex(track.count - 1);
    }
  }

  private trackColor(): number {
    return this.isDark() ? 0xFF4C91FF : 0xFF0A59F7;
  }

  private casingColor(): number {
    return this.isDark() ? 0xCC000000 : 0xCCFFFFFF;
  }

  /** WGS84 → GCJ02。折线只抽稀到 4000 点，坐标级缓存让记录更新时只转新点。 */
  private gcjFor(track: GpsDayTrack): mapCommon.LatLng[] {
    const sampled = GpsTrack.sample(track.points, FULLSCREEN_MAX_POINTS);
    const out: mapCommon.LatLng[] = [];
    for (let i = 0; i < sampled.length; i++) {
      out.push(this.gcjOf(sampled[i]));
    }
    return out;
  }

  private gcjOf(record: GpsRecord): mapCommon.LatLng {
    const key = `${record.latitude.toFixed(6)},${record.longitude.toFixed(6)}`;
    const hit = this.gcjCache.get(key);
    if (hit !== undefined) return hit;

    const raw: mapCommon.LatLng = { latitude: record.latitude, longitude: record.longitude };
    let converted: mapCommon.LatLng = raw;
    try {
      converted = map.convertCoordinateSync(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        raw
      );
    } catch (_e) {
      converted = raw;
    }
    this.gcjCache.set(key, converted);
    return converted;
  }

  private boundsOf(points: mapCommon.LatLng[]): mapCommon.LatLngBounds {
    let minLat = points[0].latitude;
    let maxLat = points[0].latitude;
    let minLon = points[0].longitude;
    let maxLon = points[0].longitude;
    for (let i = 1; i < points.length; i++) {
      const p = points[i];
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return {
      southwest: { latitude: minLat, longitude: minLon },
      northeast: { latitude: maxLat, longitude: maxLon }
    };
  }

  /** 适配全程时把标题栏和底部面板算进去，轨迹不会有一半压在面板下面。 */
  private mapFitPadding(): mapCommon.Padding {
    return {
      left: this.getUIContext().vp2px(24),
      right: this.getUIContext().vp2px(24),
      top: this.getUIContext().vp2px(titleBarInsetVp() + 24),
      bottom: this.getUIContext().vp2px(this.sheetHeightVp + 24)
    };
  }

  private tryFit(): void {
    const controller = this.controller;
    const track = this.track;
    if (controller === undefined || track === null || track.count === 0) return;
    if (!this.mapLoaded || !this.fitPending) return;

    const points = this.gcjFor(track);
    if (points.length === 0) return;
    if (points.length === 1) {
      controller.moveCamera(map.newLatLng(points[0], 16));
    } else {
      controller.moveCamera(map.newLatLngBounds(this.boundsOf(points), this.mapFitPadding()));
    }
    this.fitPending = false;
  }

  private fitTrack(): void {
    this.clearSelection();
    this.fitPending = true;
    this.tryFit();
  }

  private drawTrack(): void {
    if (this.controller === undefined) return;
    if (this.drawing) {
      this.drawAgain = true;
      return;
    }
    this.drawing = true;
    this.doDraw().finally(() => {
      this.drawing = false;
      if (this.drawAgain) {
        this.drawAgain = false;
        this.drawTrack();
      }
    });
  }

  private async doDraw(): Promise<void> {
    const controller = this.controller;
    const track = this.track;
    if (controller === undefined || track === null) return;

    controller.clear();
    // 让还在路上的选中点 marker 失效，避免 clear 之后又插进来一个旧点
    this.selectionToken++;
    this.selectedMarker = undefined;
    this.startMarkerId = '';
    this.endMarkerId = '';
    if (track.count === 0) return;

    const points = this.gcjFor(track);
    if (points.length === 0) return;

    try {
      await controller.addPolyline({
        points: points,
        color: this.casingColor(),
        width: this.getUIContext().vp2px(7),
        jointType: mapCommon.JointType.ROUND,
        startCap: mapCommon.CapStyle.ROUND,
        endCap: mapCommon.CapStyle.ROUND,
        zIndex: 1
      });
      await controller.addPolyline({
        points: points,
        color: this.trackColor(),
        width: this.getUIContext().vp2px(4),
        jointType: mapCommon.JointType.ROUND,
        startCap: mapCommon.CapStyle.ROUND,
        endCap: mapCommon.CapStyle.ROUND,
        zIndex: 2
      });

      const start = await controller.addMarker({
        position: points[0],
        icon: $r('app.media.gps_start'),
        anchorU: 0.5,
        anchorV: 0.5,
        clickable: true,
        zIndex: 4
      });
      this.startMarkerId = start.getId();

      if (points.length > 1) {
        const end = await controller.addMarker({
          position: points[points.length - 1],
          icon: $r('app.media.gps_end'),
          anchorU: 0.5,
          anchorV: 0.5,
          clickable: true,
          zIndex: 4
        });
        this.endMarkerId = end.getId();
      }

      if (this.selectedIndex >= 0 && this.selectedIndex < track.count) {
        await this.addSelectedMarker(track.points[this.selectedIndex]);
      }
    } catch (_e) {
      // 单次绘制失败保留地图，下一次记录更新会重试
    }
  }

  private async addSelectedMarker(record: GpsRecord): Promise<void> {
    const controller = this.controller;
    if (controller === undefined) return;
    const token = this.selectionToken;
    try {
      const marker = await controller.addMarker({
        position: this.gcjOf(record),
        icon: $r('app.media.gps_selected'),
        anchorU: 0.5,
        anchorV: 0.5,
        clickable: true,
        zIndex: 5
      });
      if (token !== this.selectionToken) {
        marker.remove();
        return;
      }
      this.selectedMarker = marker;
    } catch (_e) {
      // 地图已被销毁/切换页面时 addMarker 可能失败，选中态由页面状态兜底
    }
  }

  private showSelectedMarker(record: GpsRecord): void {
    const controller = this.controller;
    if (controller === undefined) return;
    if (this.selectedMarker !== undefined) {
      try {
        this.selectedMarker.setPosition(this.gcjOf(record));
        this.selectedMarker.setVisible(true);
        return;
      } catch (_e) {
        // clear() 之后旧 marker 已失效，走下面重新创建
        this.selectedMarker = undefined;
      }
    }
    this.addSelectedMarker(record).catch((_e: Error) => {});
  }

  private pointCount(): number {
    return this.track !== null ? this.track.count : 0;
  }

  private isMockTrack(): boolean {
    const track = this.track;
    return track !== null && track.count > 0 && track.points[0].mock === true;
  }

  private titleDayLabel(): ResourceStr {
    const today = GpsRecorder.dayKeyFor(Date.now());
    if (this.day === today) return $r('app.string.date_today');
    const yesterday = GpsRecorder.dayKeyFor(Date.now() - 86400000);
    if (this.day === yesterday) return $r('app.string.date_yesterday');
    return this.dayLabel();
  }

  /** 跨年的旧记录带年份，当年只显示月日（格式交给系统区域）。 */
  private dayLabel(): string {
    return formatDayKey(this.day);
  }

  private distanceText(): string {
    const meters = this.track !== null ? this.track.distanceMeters : 0;
    return meters < 5 ? L10n.tr('gps_not_moved') : formatDistance(meters);
  }

  private sheetSubtitle(): ResourceStr {
    if (this.selectedIndex >= 0) {
      return $r('app.string.gps_sheet_position', this.selectedIndex + 1, this.pointCount());
    }
    const track = this.track;
    if (track === null || track.count === 0) return '';
    // 与统计行的「时长」用同一个起点：首条记录可能是跨午夜静止心跳，
    // 此时 track.first 已经被裁到当天 0 点，不能再用 points[0].timestamp。
    return $r('app.string.gps_sheet_day_range',
      this.dayLabel(), formatHm(track.first), formatHm(track.last));
  }

  private recordAt(index: number): GpsRecord {
    const track = this.track;
    if (track !== null && index >= 0 && index < track.count) return track.points[index];
    return { timestamp: 0, latitude: 0, longitude: 0, altitude: 0 };
  }

  private confirmDeleteDay(): void {
    if (this.day === '') return;
    if (this.isMockTrack()) {
      this.getUIContext().showAlertDialog({
        title: $r('app.string.gps_clear_mock_day_title'),
        message: $r('app.string.gps_clear_mock_day_message'),
        autoCancel: true,
        primaryButton: { value: $r('app.string.common_cancel'), action: () => {} },
        secondaryButton: {
          value: $r('app.string.common_clear'),
          fontColor: $r('app.color.button_danger'),
          action: () => {
            this.gps.clearMockTrack();
            this.trackCache.invalidate(this.day);
            this.pageInfos.pop();
          }
        }
      });
      return;
    }

    this.getUIContext().showAlertDialog({
      title: $r('app.string.gps_delete_day_title'),
      message: $r('app.string.gps_delete_day_message', this.dayLabel(),
        L10n.plural('record_count', this.pointCount(), this.pointCount())),
      autoCancel: true,
      primaryButton: { value: $r('app.string.common_cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.common_delete'),
        fontColor: $r('app.color.button_danger'),
        action: () => {
          this.gps.deleteDay(this.day);
          this.trackCache.invalidate(this.day);
          this.pageInfos.pop();
        }
      }
    });
  }

  private selectedRecord(): GpsRecord | null {
    const track = this.track;
    if (track === null) return null;
    if (this.selectedIndex < 0 || this.selectedIndex >= track.count) return null;
    return track.points[this.selectedIndex];
  }

  @Builder
  ViewerTitleBar() {
    Column() {
      Blank().height(Math.max(0, titleBarInsetVp() - TITLE_BAR_HEIGHT))
      Row({ space: 10 }) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(IconSize.Nav)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40).height(40)
        .backgroundColor(Color.Transparent)
        .systemMaterial(this.titleMaterial)
        .onClick(() => { this.pageInfos.pop(); })

        // 标题也做成标题栏里的玻璃控件，直接吃 ImmersiveMaterial，
        // 不再用整条白色大胶囊 + backgroundBlurStyle。
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Text(this.titleDayLabel())
            .fontSize(FontSize.CardTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
        }
        .height(40)
        .padding({ left: 16, right: 16 })
        .backgroundColor(Color.Transparent)
        .borderRadius(pillRadius(40))
        .systemMaterial(this.titleMaterial)

        Blank()

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(IconSize.Nav)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40).height(40)
        .backgroundColor(Color.Transparent)
        .systemMaterial(this.titleMaterial)
        .bindMenu([
          {
            value: $r('app.string.gps_delete_day_menu'),
            action: () => { this.confirmDeleteDay(); }
          }
        ])
      }
      .width('100%')
      .height(TITLE_BAR_HEIGHT)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SheetContent() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text($r('app.string.gps_track_details'))
              .fontSize(FontSize.Title)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            if (this.isMockTrack()) {
              Text($r('app.string.gps_mock_track'))
                .fontSize(FontSize.Micro)
                .fontColor($r('app.color.primary'))
            }
          }
          .alignItems(VerticalAlign.Center)

          Text(this.sheetSubtitle())
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.selectedIndex >= 0) {
          Button($r('app.string.gps_back_to_full'))
            .fontSize(FontSize.Caption)
            .height(30)
            .fontColor($r('app.color.primary'))
            .backgroundColor($r('app.color.primary_soft'))
            .borderRadius(pillRadius(30))
            .padding({ left: 12, right: 12 })
            .onClick(() => { this.fitTrack(); })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 2, bottom: 8 })

      Row() {
        Column({ space: 4 }) {
          Text(this.distanceText())
            .fontSize(FontSize.CardTitle).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.figure_walk'))
              .fontSize(IconSize.Small).fontColor([$r('app.color.primary')])
            Text($r('app.string.gps_distance')).fontSize(FontSize.Micro).fontColor($r('app.color.text_tertiary'))
          }
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)

        Divider().vertical(true).height(26).color($r('app.color.divider'))

        Column({ space: 4 }) {
          Text(formatDuration(this.track !== null ? this.track.durationMs : 0))
            .fontSize(FontSize.CardTitle).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(IconSize.Small).fontColor([$r('app.color.primary')])
            Text($r('app.string.gps_duration')).fontSize(FontSize.Micro).fontColor($r('app.color.text_tertiary'))
          }
        }
        // 时长可能到「13 小时 12 分」，比距离/条数长；给中间列更多权重，
        // 避免 16fp 的值在三分之一栏里折成两行。
        .layoutWeight(1.4).alignItems(HorizontalAlign.Start)
        .padding({ left: 16 })

        Divider().vertical(true).height(26).color($r('app.color.divider'))

        Column({ space: 4 }) {
          Text(`${this.pointCount()}`)
            .fontSize(FontSize.CardTitle).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.location_north_up_right_fill'))
              .fontSize(IconSize.Small).fontColor([$r('app.color.primary')])
            Text($r('app.string.gps_records_label')).fontSize(FontSize.Micro).fontColor($r('app.color.text_tertiary'))
          }
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
        .padding({ left: 16 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 6 })

      Row() {
        Slider({
          value: this.sliderValue,
          min: 0,
          max: Math.max(0, this.pointCount() - 1),
          step: 1
        })
          .width('100%')
          .selectedColor($r('app.color.primary'))
          .trackColor($r('app.color.divider'))
          .blockColor($r('app.color.primary'))
          .trackThickness(3)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.onScrub(value, mode);
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 10 })

      Divider()
        .color($r('app.color.divider'))
        .margin({ left: 20, right: 20 })

      List({ scroller: this.listScroller }) {
        Repeat<GpsTimelineItem>(this.timelineItems())
          .each((ri: RepeatItem<GpsTimelineItem>) => {
            ListItem() {
              if (ri.item.kind === 'group') {
                GpsGroupHeader({
                  groupStart: ri.item.group.startIndex,
                  first: ri.item.group.first,
                  last: ri.item.group.last,
                  count: ri.item.group.count,
                  latitude: ri.item.group.latitude,
                  longitude: ri.item.group.longitude,
                  distanceMeters: ri.item.group.distanceMeters,
                  stationary: ri.item.group.stationary,
                  onToggle: () => { this.toggleGroup(ri.item.group.startIndex); }
                })
              } else {
                GpsPointRow({
                  index: ri.item.pointIndex,
                  record: this.recordAt(ri.item.pointIndex),
                  isFirst: ri.item.pointIndex === 0,
                  isLast: ri.item.pointIndex === this.pointCount() - 1,
                  precise: !ri.item.group.stationary,
                  onSelect: () => { this.selectIndex(ri.item.pointIndex); }
                })
              }
            }
          })
          .key((item: GpsTimelineItem) =>
            item.kind === 'group' ? `g${item.group.startIndex}` : `p${item.pointIndex}`)
          .virtualScroll()
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ bottom: this.bottomSafeVp() + 8 })
      .scrollBar(BarState.Off)
      .onScrollIndex((start: number, end: number) => {
        this.visibleStart = start;
        this.visibleEnd = end;
        // 未选中的行只显示时间、不显示地址，滚一遍列表不需要把每行地址都查出来；
        // 只有分组标题需要地址，选中行由 selectIndex() 单独预取。
        this.prefetchGroupAnchors(this.timelineItems(), start, end);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.track === null) {
          Column({ space: 8 }) {
            LoadingProgress().width(28).height(28)
            Text($r('app.string.gps_loading_track'))
              .fontSize(FontSize.Caption).fontColor($r('app.color.text_secondary'))
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.track.count === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.location_north_up_right_fill'))
              .fontSize(IconSize.Empty)
              .fontColor([$r('app.color.text_tertiary')])
            Text($r('app.string.gps_no_records_day'))
              .fontSize(FontSize.Body).fontColor($r('app.color.text_secondary'))
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Stack({ alignContent: Alignment.TopStart }) {
            // 地图可用时不要保留 Canvas 兜底层：MapComponent 会完全盖住它，
            // 但选中点/记录变化仍会触发重绘，属于纯浪费。
            if (this.mapError !== '') {
              GpsTrackSketch({
                sketchPoints: this.track.sketchPoints,
                bounds: this.track.bounds,
                selected: this.selectedRecord(),
                caption: $r('app.string.gps_map_unavailable'),
                captionBottom: this.sheetHeightVp + 10,
                topInset: titleBarInsetVp() + 8,
                bottomInset: this.sheetHeightVp + 8
              })

              if (this.canRetryMap()) {
                Row() {
                  Button($r('app.string.gps_retry_map'))
                    .fontSize(FontSize.Caption)
                    .height(30)
                    .padding({ left: 12, right: 12 })
                    .fontColor($r('app.color.text_primary'))
                    .backgroundColor($r('app.color.glass_bg'))
                    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
                    .borderRadius(pillRadius(30))
                    .onClick(() => { this.retryMap(); })
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.End)
                .alignItems(VerticalAlign.Top)
                .padding({ top: titleBarInsetVp() + 8, right: 16 })
                .hitTestBehavior(HitTestMode.Transparent)
              }
            }

            if (this.mapError === '' && canIUse('SystemCapability.Map.Core')) {
              MapComponent({
                mapOptions: this.mapOptions,
                mapCallback: this.mapCallback
              })
                .width('100%')
                .height('100%')
            }

            if (this.mapError === '' && !this.mapReady) {
              Stack({ alignContent: Alignment.Center }) {
                Row({ space: 6 }) {
                  LoadingProgress().width(16).height(16)
                  Text($r('app.string.gps_map_loading')).fontSize(FontSize.Micro).fontColor($r('app.color.text_secondary'))
                }
                .padding({ left: 10, right: 12, top: 6, bottom: 6 })
                .backgroundColor($r('app.color.glass_bg'))
                .borderRadius(Radius.Chip)
              }
              .width('100%').height('100%')
              .hitTestBehavior(HitTestMode.None)
            }
          }
          .width('100%')
          .height('100%')

        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      .bindSheet($$this.showSheet, this.SheetContent, this.sheetOptions())
    }
    .hideBackButton(true)
    .title({ builder: this.ViewerTitleBar, height: titleBarInsetVp() }, {
      barStyle: BarStyle.STACK
    })
    .backgroundColor($r('app.color.bg_page'))
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
      const param = context.pathInfo?.param as Record<string, Object> | undefined;
      if (param) {
        const day = param['day'] as string;
        if (day) {
          this.day = day;
          this.loadTrack();
          this.showSheet = this.track !== null && this.track.count > 0;
        }
      }
    })
  }
}
