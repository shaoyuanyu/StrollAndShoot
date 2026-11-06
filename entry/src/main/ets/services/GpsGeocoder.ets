import geoLocationManager from '@ohos.geoLocationManager';

/** 最多缓存多少个坐标的地址。一天几百个点，400 条足够覆盖最近浏览。 */
const MAX_CACHED_ADDRESSES = 400;

/**
 * 按坐标查询中文地址，带内存缓存与并发去重。
 *
 * 全屏轨迹页只给「当前选中的点」和列表可视区域按需查询，而不是一进页面
 * 就为几百上千个点发请求；同一坐标只查一次，滚动回来直接命中缓存。
 * `version` 是给 V2 用的变更计数：地址是普通 Map，不发信号行不会刷新。
 */
@ObservedV2
export class GpsGeocoder {
  /** 地址缓存变化计数。列表行读 cachedText() 时顺带建立依赖。 */
  @Trace version: number = 0;

  private static instance: GpsGeocoder | undefined;
  private cache: Map<string, string> = new Map();
  private pending: Map<string, Promise<string | null>> = new Map();
  private available: boolean | null = null;

  static getInstance(): GpsGeocoder {
    if (!GpsGeocoder.instance) {
      GpsGeocoder.instance = new GpsGeocoder();
    }
    return GpsGeocoder.instance;
  }

  private constructor() {}

  private key(lat: number, lon: number): string {
    return `${lat.toFixed(5)},${lon.toFixed(5)}`;
  }

  /** 已缓存的地址；没有时返回空串。读 version 是为了让列表行订阅缓存变化。 */
  cachedText(lat: number, lon: number): string {
    if (this.version < 0) return '';
    const text = this.cache.get(this.key(lat, lon));
    return text !== undefined ? text : '';
  }

  /** 查询地址。失败、无网络、逆地理编码不可用时返回 null，不抛异常。 */
  async resolve(lat: number, lon: number): Promise<string | null> {
    const key = this.key(lat, lon);
    const hit = this.cache.get(key);
    if (hit !== undefined) return hit;

    const running = this.pending.get(key);
    if (running !== undefined) return running;

    const task = this.lookup(lat, lon, key);
    this.pending.set(key, task);
    try {
      return await task;
    } finally {
      this.pending.delete(key);
    }
  }

  private async lookup(lat: number, lon: number, key: string): Promise<string | null> {
    if (!this.isAvailable()) return null;

    const req: geoLocationManager.ReverseGeoCodeRequest = {
      latitude: lat,
      longitude: lon,
      maxItems: 1
    };
    try {
      // @SuppressWarnings syscap
      const list = await geoLocationManager.getAddressesFromLocation(req);
      if (!list || list.length === 0) return null;
      const text = this.formatAddress(list[0]);
      if (text === '') return null;

      this.cache.set(key, text);
      while (this.cache.size > MAX_CACHED_ADDRESSES) {
        const oldest = this.cache.keys().next();
        if (oldest.done === true) break;
        this.cache.delete(oldest.value);
      }
      this.version++;
      return text;
    } catch (_e) {
      return null;
    }
  }

  isAvailable(): boolean {
    if (this.available !== null) return this.available;
    if (!canIUse('SystemCapability.Location.Location.Geocoder')) {
      this.available = false;
      return false;
    }
    try {
      // @SuppressWarnings syscap
      this.available = geoLocationManager.isGeocoderAvailable();
    } catch (_e) {
      this.available = false;
    }
    return this.available === true;
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
      return (addr.placeName ?? '').trim();
    }
    return parts.join(' ');
  }
}
