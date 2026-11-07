import { GpsTrack, type GpsDayTrack } from '../utils/GpsTrack';
import type { GpsRecord } from '../model/PhotoEntry';

/** 最多缓存多少天。一天最多约 7 千个点（11 秒一条），32 天足够翻看。 */
const MAX_CACHED_DAYS = 32;

/**
 * 按天轨迹的内存缓存。
 *
 * 页面滚动/重渲染时不应该反复遍历记录、算距离、抽稀；`GpsTrack.fingerprint`
 * 命中时直接复用同一个对象，地图组件拿到同一个引用也就不会白白重画。
 * 删除某天或清空记录后要调用 invalidate/clear，避免拿到已删除的数据。
 */
export class GpsTrackCache {
  private static instance: GpsTrackCache | undefined;
  private tracks: Map<string, GpsDayTrack> = new Map();

  static getInstance(): GpsTrackCache {
    if (!GpsTrackCache.instance) {
      GpsTrackCache.instance = new GpsTrackCache();
    }
    return GpsTrackCache.instance;
  }

  private constructor() {}

  getDayTrack(day: string, records: GpsRecord[]): GpsDayTrack {
    const fp = GpsTrack.fingerprint(records);
    const hit = this.tracks.get(day);
    if (hit !== undefined && hit.fingerprint === fp) {
      // LRU：命中后挪到末尾
      this.tracks.delete(day);
      this.tracks.set(day, hit);
      return hit;
    }

    const track = GpsTrack.buildDayTrack(day, records, fp);
    this.tracks.delete(day);
    this.tracks.set(day, track);
    while (this.tracks.size > MAX_CACHED_DAYS) {
      const oldest = this.tracks.keys().next();
      if (oldest.done === true) break;
      this.tracks.delete(oldest.value);
    }
    return track;
  }

  invalidate(day: string): void {
    this.tracks.delete(day);
  }

  clear(): void {
    this.tracks.clear();
  }
}
