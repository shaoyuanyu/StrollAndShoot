import geoLocationManager from '@ohos.geoLocationManager';
import { PageHeader } from '../components/PageHeader';
import { GpsRecorder } from '../services/GpsRecorder';
import type { GpsRecord } from '../model/PhotoEntry';

@Builder
export function GpsDayDetailPageBuilder() {
  GpsDayDetailPage();
}

@ComponentV2
export struct GpsDayDetailPage {
  private pageInfos: NavPathStack = new NavPathStack();
  @Local gps: GpsRecorder = GpsRecorder.getInstance();
  @Local addresses: Map<string, string> = new Map();
  @Local day: string = '';
  /** 逆地理编码是否正在跑，避免新记录到达时叠起第二个循环。 */
  private geocoding: boolean = false;
  /** 跑循环期间又有新记录到达：结束后再补一轮，否则新记录的地址会一直空着。 */
  private geocodeAgain: boolean = false;

  private initFromParams(param: Record<string, Object> | undefined): void {
    if (param) {
      const day = param['day'] as string;
      if (day) {
        this.day = day;
      }
    }
    this.loadAddresses();
  }

  /** 记录有变化（正在记录时每来一条）就补拉还没解析过的坐标。 */
  @Monitor('gps.recordsVersion')
  onRecordsChanged(): void {
    this.loadAddresses();
  }

  /**
   * 当天记录。参数直接传 gps.recordsVersion，让 Repeat / if 的表达式
   * 在构建期就读到这个 @Trace，新位置点到达时才会重新求值。
   */
  private recordsFor(version: number): GpsRecord[] {
    if (version < 0) return [];
    return this.gps.getDayRecords(this.day);
  }

  /** 地址只跟坐标有关，所以按坐标做缓存键，记录增删后不会错位。 */
  private coordKey(lat: number, lon: number): string {
    return `${lat.toFixed(5)},${lon.toFixed(5)}`;
  }

  /** Fetch reverse geocoding for all records (network required). */
  private async loadAddresses(): Promise<void> {
    if (this.geocoding) {
      this.geocodeAgain = true;
      return;
    }
    if (this.day === '') return;
    if (!canIUse('SystemCapability.Location.Location.Geocoder')) return;

    let geocoderAvailable = false;
    try {
      // @SuppressWarnings syscap
      geocoderAvailable = geoLocationManager.isGeocoderAvailable();
    } catch (_e) {
      return;
    }
    if (!geocoderAvailable) return;

    this.geocoding = true;
    try {
      do {
        this.geocodeAgain = false;
        const targets = this.recordsFor(this.gps.recordsVersion);
        for (let i = 0; i < targets.length; i++) {
          const r = targets[i];
          const key = this.coordKey(r.latitude, r.longitude);
          if (this.addresses.has(key)) continue;

          const addr = await this.reverseGeocode(r.latitude, r.longitude);
          if (addr) {
            this.addresses.set(key, addr);
          }
        }
      } while (this.geocodeAgain);
    } finally {
      this.geocoding = false;
    }
  }

  /** 逆地理编码，返回拼好的中文地址；失败返回 null。 */
  private async reverseGeocode(lat: number, lon: number): Promise<string | null> {
    const req: geoLocationManager.ReverseGeoCodeRequest = {
      latitude: lat,
      longitude: lon,
      maxItems: 1
    };
    try {
      // @SuppressWarnings syscap
      const list = await geoLocationManager.getAddressesFromLocation(req);
      if (!list || list.length === 0) return null;
      return this.formatAddress(list[0]);
    } catch (_e) {
      return null;
    }
  }

  /**
   * 拼地址。行政层级里同一段会重复出现（「上海市 上海市 上海市 黄浦区」、
   * 「广东省 东莞市 东莞市 松山湖」），这里去重后再拼，避免一行里念三遍。
   */
  private formatAddress(addr: geoLocationManager.GeoAddress): string {
    const parts: string[] = [];
    const push = (v: string | undefined): void => {
      const s = (v ?? '').trim();
      if (s !== '' && !parts.includes(s)) {
        parts.push(s);
      }
    };
    push(addr.administrativeArea);
    push(addr.subAdministrativeArea);
    push(addr.locality);
    push(addr.subLocality);
    push(addr.roadName);
    push(addr.premises);
    if (parts.length === 0) {
      const place = (addr.placeName ?? '').trim();
      return place;
    }
    return parts.join(' ');
  }

  formatTime(ts: number): string {
    const d = new Date(ts);
    const h = String(d.getHours()).padStart(2, '0');
    const m = String(d.getMinutes()).padStart(2, '0');
    const s = String(d.getSeconds()).padStart(2, '0');
    return `${h}:${m}:${s}`;
  }

  build() {
    NavDestination() {
      Column() {
        PageHeader({
          title: this.day,
          subtitle: `${this.recordsFor(this.gps.recordsVersion).length} 条记录`,
          onBack: () => { this.pageInfos.pop(); }
        })

        if (this.recordsFor(this.gps.recordsVersion).length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.location_north_up_right_fill'))
              .fontSize(44)
              .fontColor([$r('app.color.text_tertiary')])
            Text('当天无记录')
              .fontSize(15).fontColor($r('app.color.text_secondary'))
          }
          .width('100%').layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            Repeat<GpsRecord>(this.recordsFor(this.gps.recordsVersion))
              .each((ri: RepeatItem<GpsRecord>) => {
                ListItem() {
                  Column({ space: 4 }) {
                    Row() {
                      Text(this.formatTime(ri.item.timestamp))
                        .fontSize(16).fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))

                      Blank()

                      if (ri.item.altitude !== 0) {
                        Text(`海拔 ${ri.item.altitude.toFixed(0)}m`)
                          .fontSize(11).fontColor($r('app.color.text_tertiary'))
                      }
                    }
                    .width('100%')

                    Text(`${ri.item.latitude.toFixed(6)}, ${ri.item.longitude.toFixed(6)}`)
                      .fontSize(12).fontColor($r('app.color.text_secondary'))
                      .alignSelf(ItemAlign.Start)

                    if (this.addresses.has(this.coordKey(ri.item.latitude, ri.item.longitude))) {
                      Text(this.addresses.get(this.coordKey(ri.item.latitude, ri.item.longitude))!.trim())
                        .fontSize(11).fontColor($r('app.color.text_tertiary'))
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .alignSelf(ItemAlign.Start)
                    }
                  }
                  .width('100%').padding(16)
                  .alignItems(HorizontalAlign.Start)
                  .backgroundColor($r('app.color.bg_surface'))
                  .borderRadius(24)
                }
                .margin({ bottom: 8 })
              })
              .key((r: GpsRecord) => `${r.timestamp}_${r.latitude}_${r.longitude}`)
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
      this.initFromParams(context.pathInfo?.param as Record<string, Object> | undefined);
    })
  }
}
