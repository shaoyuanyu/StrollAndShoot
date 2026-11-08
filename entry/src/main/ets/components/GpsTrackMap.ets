import { MapComponent, map, mapCommon } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { GpsTrack, type GpsDayTrack, type GpsTrackBounds } from '../utils/GpsTrack';
import { GpsTrackSketch } from './GpsTrackSketch';
import { formatDistanceCompact, formatDurationCompact } from '../utils/GpsFormat';
import { WindowUtils } from '../utils/WindowUtils';
import type { GpsRecord } from '../model/PhotoEntry';
import { MapCapability } from '../utils/MapCapability';
import { L10n } from '../utils/L10n';
import { FontSize, IconSize, Radius } from '../utils/UiTokens';

/** 预览图上的折线最多保留多少个点；缩略图只有 190vp 高，再多也看不出来。 */
const PREVIEW_MAX_POINTS = 1200;
/** 地图初始化超时。超时后切到示意图，地图服务不可用时页面不会一直空着。 */
const MAP_INIT_TIMEOUT_MS = 10000;

const EMPTY_BOUNDS: GpsTrackBounds = { minLat: 0, maxLat: 0, minLon: 0, maxLon: 0 };

/**
 * 「定位记录」日期卡片里的轨迹地图预览。
 *
 * 性能与交互上的取舍：
 * - 只有展开的卡片才会创建这个组件，收起后 MapComponent 随之销毁；
 * - 预览图禁用所有手势（列表还要滚动），点击整张图进入全屏；
 * - 折线抽稀到 1200 点，并按天缓存转换后的 GCJ02 坐标；
 * - 地图初始化失败/超时降级为 GpsTrackSketch，按钮和全屏入口仍然可用。
 */
@ComponentV2
export struct GpsTrackMap {
  @Param track: GpsDayTrack | null = null;
  @Event onOpen: () => void = () => {};

  @Local mapReady: boolean = false;
  /** 内部兜底状态（未签名 / 不支持 / 超时 / 失败），只用于分支判断，不直接显示。 */
  @Local mapError: string = '';

  private mapOptions: mapCommon.MapOptions = {
    position: { target: { latitude: 22.87938, longitude: 113.87971 }, zoom: 14 }
  };
  private mapCallback: AsyncCallback<map.MapComponentController> =
    (err: BusinessError, controller: map.MapComponentController): void => {
      this.handleMapReady(err, controller);
    };
  private controller?: map.MapComponentController;
  /** WGS84→GCJ02 结果按坐标缓存：新定位只新增 1 个点，不能每 11 秒重转 1200 个。 */
  private gcjCache: Map<string, mapCommon.LatLng> = new Map();
  private mapLoaded: boolean = false;
  private fitPending: boolean = true;
  private drawing: boolean = false;
  private drawAgain: boolean = false;
  private timeoutId: number = -1;

  aboutToAppear(): void {
    this.applyMapOptions();
    if (!MapCapability.isSignedPackage()) {
      // 模拟器的 unsigned HAP 没有 Map Kit Profile 能力，瓦片会 403
      this.mapError = '未签名调试包';
      return;
    }
    if (!canIUse('SystemCapability.Map.Core')) {
      this.mapError = '本机不支持地图服务';
      return;
    }
    this.timeoutId = setTimeout(() => {
      if (!this.mapReady && this.mapError === '') {
        this.mapError = '地图加载超时';
      }
    }, MAP_INIT_TIMEOUT_MS);
  }

  aboutToDisappear(): void {
    this.cancelInitTimeout();
  }

  private cancelInitTimeout(): void {
    if (this.timeoutId >= 0) {
      clearTimeout(this.timeoutId);
      this.timeoutId = -1;
    }
  }

  private applyMapOptions(): void {
    const track = this.track;
    let lat = 22.87938;
    let lon = 113.87971;
    let zoom = 14;
    if (track !== null && track.count > 0) {
      lat = (track.bounds.minLat + track.bounds.maxLat) / 2;
      lon = (track.bounds.minLon + track.bounds.maxLon) / 2;
      zoom = 15;
    }
    // Map Kit 的 target 必须是 GCJ02；WGS84 在国内会偏几百米。
    let target: mapCommon.LatLng = { latitude: lat, longitude: lon };
    try {
      target = map.convertCoordinateSync(
        mapCommon.CoordinateType.WGS84,
        mapCommon.CoordinateType.GCJ02,
        target
      );
    } catch (_e) {
      // 地图能力不可用时保留原始坐标，组件本身会走 Canvas 兜底
    }
    this.mapOptions = {
      position: { target: target, zoom: zoom },
      mapType: mapCommon.MapType.STANDARD,
      rotateGesturesEnabled: false,
      scrollGesturesEnabled: false,
      zoomGesturesEnabled: false,
      tiltGesturesEnabled: false,
      zoomControlsEnabled: false,
      myLocationControlsEnabled: false,
      compassControlsEnabled: false,
      scaleControlsEnabled: false
    };
  }

  @Monitor('track')
  onTrackChanged(): void {
    // 预览图跟着最新轨迹重新框一次；全屏页则只在用户点「回到全程」时框
    this.fitPending = true;
    this.drawTrack();
  }

  private isDark(): boolean {
    return WindowUtils.isDarkMode(this.getUIContext().getHostContext());
  }

  private handleMapReady(err: BusinessError, controller: map.MapComponentController): void {
    this.cancelInitTimeout();
    if (err) {
      this.mapError = `地图加载失败 (${err.code})`;
      this.mapReady = false;
      return;
    }

    this.controller = controller;
    this.mapReady = true;
    // 相机控制不依赖瓦片加载完成；mapLoad 可能早于本回调，先置 true 再做 fit
    this.mapLoaded = true;
    try {
      controller.setAllGesturesEnabled(false);
      controller.setZoomControlsEnabled(false);
      controller.setMyLocationControlsEnabled(false);
      controller.setCompassControlsEnabled(false);
      controller.setScaleControlsEnabled(false);
      controller.setDayNightMode(
        this.isDark() ? mapCommon.DayNightMode.NIGHT : mapCommon.DayNightMode.DAY
      );
      controller.setLogoAlignment(mapCommon.LogoAlignment.BOTTOM_START);
      controller.setLogoPadding({ left: this.getUIContext().vp2px(8), bottom: this.getUIContext().vp2px(8) });
      controller.setLogoScale(0.8);
      controller.setPadding({
        left: this.getUIContext().vp2px(4), right: this.getUIContext().vp2px(4), top: this.getUIContext().vp2px(4), bottom: this.getUIContext().vp2px(4)
      });
    } catch (_e) {
      // 这些是视觉修饰，失败不影响轨迹绘制
    }

    controller.on('mapLoad', () => {
      this.mapLoaded = true;
      this.fitPending = true;
      this.drawTrack();
    });
    this.drawTrack();
  }

  private trackColor(): number {
    return this.isDark() ? 0xFF4C91FF : 0xFF0A59F7;
  }

  /** WGS84 → GCJ02。坐标级缓存：新增一个定位只多转一个点。 */
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

  private gcjFor(track: GpsDayTrack): mapCommon.LatLng[] {
    const sampled = GpsTrack.sample(track.points, PREVIEW_MAX_POINTS);
    const out: mapCommon.LatLng[] = [];
    for (let i = 0; i < sampled.length; i++) {
      out.push(this.gcjOf(sampled[i]));
    }
    return out;
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

  private fit(points: mapCommon.LatLng[]): void {
    const controller = this.controller;
    if (controller === undefined || points.length === 0 || !this.mapLoaded) return;
    if (points.length === 1) {
      controller.moveCamera(map.newLatLng(points[0], 16));
      return;
    }
    controller.moveCamera(map.newLatLngBounds(this.boundsOf(points), this.getUIContext().vp2px(24)));
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
    if (track.count === 0) return;

    const points = this.gcjFor(track);
    if (points.length === 0) return;

    try {
      await controller.addPolyline({
        points: points,
        color: this.trackColor(),
        width: this.getUIContext().vp2px(4),
        jointType: mapCommon.JointType.ROUND,
        startCap: mapCommon.CapStyle.ROUND,
        endCap: mapCommon.CapStyle.ROUND,
        zIndex: 2
      });
      await controller.addMarker({
        position: points[0],
        icon: $r('app.media.gps_start'),
        anchorU: 0.5,
        anchorV: 0.5,
        clickable: false,
        zIndex: 3
      });
      if (points.length > 1) {
        await controller.addMarker({
          position: points[points.length - 1],
          icon: $r('app.media.gps_end'),
          anchorU: 0.5,
          anchorV: 0.5,
          clickable: false,
          zIndex: 3
        });
      }
    } catch (_e) {
      // 单次绘制失败不隐藏地图，下一次记录更新还会重试
      return;
    }

    if (this.fitPending) {
      this.fit(points);
      this.fitPending = false;
    }
  }

  private statsText(): string {
    const track = this.track;
    if (track === null || track.count === 0) return '';
    // 与全屏面板的统计顺序保持一致：距离 → 时长 → 记录数。
    const parts: string[] = [];
    if (track.distanceMeters > 0) {
      parts.push(formatDistanceCompact(track.distanceMeters));
    }
    if (track.durationMs > 0) {
      parts.push(formatDurationCompact(track.durationMs));
    }
    parts.push(L10n.plural('record_count', track.count, track.count));
    return parts.join(' · ');
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 只有地图不可用/未签名时才画 Canvas；签名包上地图会把它完全盖住，
      // 继续绘制只会白白消耗 CPU/GPU（尤其记录每 11 秒更新一次时）。
      if (this.mapError !== '') {
        GpsTrackSketch({
          sketchPoints: this.track !== null ? this.track.sketchPoints : [],
          bounds: this.track !== null ? this.track.bounds : EMPTY_BOUNDS,
          caption: $r('app.string.gps_map_unavailable')
        })
      }

      if (this.track !== null && this.track.count > 0 && this.mapError === '' &&
        canIUse('SystemCapability.Map.Core')) {
        MapComponent({
          mapOptions: this.mapOptions,
          mapCallback: this.mapCallback
        })
          .width('100%')
          .height('100%')
      }

      if (this.track !== null && this.track.count > 0 && this.mapError === '' && !this.mapReady) {
        Stack({ alignContent: Alignment.Center }) {
          Row({ space: 6 }) {
            LoadingProgress().width(16).height(16)
            Text($r('app.string.gps_map_loading')).fontSize(FontSize.Micro).fontColor($r('app.color.text_secondary'))
          }
          .padding({ left: 10, right: 12, top: 6, bottom: 6 })
          .backgroundColor($r('app.color.glass_bg'))
          .borderRadius(Radius.Chip)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.track !== null && this.track.count > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.location_north_up_right_fill'))
              .fontSize(IconSize.Small)
              .fontColor([$r('app.color.text_secondary')])
            Text(this.statsText())
              .fontSize(FontSize.Micro)
              .fontColor($r('app.color.text_secondary'))
          }
          .padding({ left: 9, right: 10, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.glass_bg'))
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
          .borderRadius(Radius.Chip)
          .margin({ left: 10, top: 10 })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)

        Stack({ alignContent: Alignment.BottomEnd }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
              .fontSize(IconSize.Small)
              .fontColor([$r('app.color.text_primary')])
            Text($r('app.string.gps_fullscreen'))
              .fontSize(FontSize.Micro)
              .fontColor($r('app.color.text_primary'))
          }
          .padding({ left: 8, right: 10, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.glass_bg'))
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
          .borderRadius(Radius.Chip)
          .margin({ right: 10, bottom: 10 })
          .onClick(() => { this.onOpen(); })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.track !== null && this.track.count > 0) {
        // 透明按钮盖在整张图上。Canvas 是独立绘制层，用它自己的 onClick
        // 在部分版本上收不到事件；放在最上层的按钮能稳定拿到点击（也覆盖两个芯片，
        // 点哪里都进全屏）。
        Button()
          .width('100%')
          .height('100%')
          // 1/255 黑：肉眼不可见，但给空按钮一个非零背景，保证命中测试
          .backgroundColor(0x01000000)
          .onClick(() => { this.onOpen(); })
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}
