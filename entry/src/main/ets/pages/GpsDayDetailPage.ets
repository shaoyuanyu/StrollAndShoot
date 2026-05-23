import { router } from '@kit.ArkUI';
import { geoLocationManager } from '@kit.LocationKit';
import { GpsRecorder } from '../services/GpsRecorder';
import type { GpsRecord } from '../model/PhotoEntry';

@Entry
@ComponentV2
struct GpsDayDetailPage {
  private gpsRecorder: GpsRecorder = GpsRecorder.getInstance();
  @Local records: GpsRecord[] = [];
  @Local addresses: Map<number, string> = new Map();
  private day: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    if (params && typeof params.day === 'string') {
      this.day = params.day as string;
      this.records = this.gpsRecorder.getDayRecords(this.day);
    }
    this.loadAddresses();
  }

  /** Fetch reverse geocoding for all records (network required). */
  private async loadAddresses(): Promise<void> {
    if (!geoLocationManager.isGeocoderAvailable()) return;

    const addressCache = new Map<string, string>();

    for (let i = 0; i < this.records.length; i++) {
      const r = this.records[i];
      const cacheKey = `${r.latitude.toFixed(5)},${r.longitude.toFixed(5)}`;
      const cached = addressCache.get(cacheKey);
      if (cached !== undefined) {
        this.addresses.set(i, cached);
        continue;
      }

      try {
        const addr = await this.reverseGeocode(r.latitude, r.longitude);
        if (addr) {
          addressCache.set(cacheKey, addr);
          this.addresses.set(i, addr);
        }
      } catch (_e) {
        // skip on error
      }
    }
  }

  /** Wrap callback-based getAddressesFromLocation in a Promise. */
  private reverseGeocode(lat: number, lon: number): Promise<string | null> {
    return new Promise((resolve: (value: string | null) => void) => {
      const req: geoLocationManager.ReverseGeoCodeRequest = {
        latitude: lat,
        longitude: lon,
        maxItems: 1
      };
      geoLocationManager.getAddressesFromLocation(req, (err, data) => {
        if (err || !data || data.length === 0) {
          resolve(null);
          return;
        }
        const addr = data[0];
        const parts: string[] = [];
        if (addr.administrativeArea) parts.push(addr.administrativeArea);
        if (addr.subAdministrativeArea) parts.push(addr.subAdministrativeArea);
        if (addr.locality) parts.push(addr.locality);
        if (addr.subLocality) parts.push(addr.subLocality);
        if (addr.roadName) parts.push(addr.roadName);
        if (addr.premises) parts.push(addr.premises);
        resolve(parts.length > 0 ? parts.join(' ') : (addr.placeName || null));
      });
    });
  }

  formatTime(ts: number): string {
    const d = new Date(ts);
    const h = String(d.getHours()).padStart(2, '0');
    const m = String(d.getMinutes()).padStart(2, '0');
    const s = String(d.getSeconds()).padStart(2, '0');
    return `${h}:${m}:${s}`;
  }

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Circle }) {
          Text('←').fontSize(18)
        }
        .width(36).height(36)
        .backgroundColor($r('app.color.bg_surface'))
        .onClick(() => { router.back(); })

        Text(this.day)
          .fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 10 })

        Blank()

        Text(`${this.records.length} 条`)
          .fontSize(13).fontColor($r('app.color.text_secondary'))
      }
      .width('100%').padding({ left: 12, right: 12, top: 12, bottom: 8 })

      if (this.records.length === 0) {
        Column() {
          Text('当天无记录')
            .fontSize(14).fontColor($r('app.color.text_secondary'))
            .margin({ top: 80 })
        }
        .width('100%').layoutWeight(1)
      } else {
        List() {
          Repeat<GpsRecord>(this.records)
            .each((ri: RepeatItem<GpsRecord>) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(`#${ri.index + 1}`)
                      .fontSize(12).fontColor($r('app.color.text_secondary'))
                      .width(36)

                    Column() {
                      Text(this.formatTime(ri.item.timestamp))
                        .fontSize(15).fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                      Text(`${ri.item.latitude.toFixed(6)}, ${ri.item.longitude.toFixed(6)}`)
                        .fontSize(12).fontColor($r('app.color.text_secondary'))
                        .margin({ top: 2 })
                    }
                    .alignItems(HorizontalAlign.Start)

                    Blank()

                    if (ri.item.altitude !== 0) {
                      Text(`${ri.item.altitude.toFixed(0)}m`)
                        .fontSize(12).fontColor($r('app.color.text_secondary'))
                    }
                  }
                  .width('100%')

                  if (this.addresses.has(ri.index)) {
                    Text(this.addresses.get(ri.index)!.trim())
                      .fontSize(11).fontColor($r('app.color.text_secondary'))
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 4 })
                  }
                }
                .width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
                .alignItems(HorizontalAlign.Start)
              }
            })
            .key((_r: GpsRecord, idx: number) => `${idx}`)
        }
        .width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
