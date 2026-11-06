import type { GpsRecord } from '../model/PhotoEntry';

/** 两次定位相距小于 5 米算「原地不动」。 */
export const SAME_SPOT_METERS = 5;
/** 原地不动时合并记录的最长间隔；到点补一条，保证 EXIF 匹配不断档。 */
export const HEARTBEAT_MS = 10 * 60 * 1000;
/**
 * 判定「跳点」的速度上限（m/s）。1080 km/h 比民航巡航还高，
 * 超过它只可能是定位源切换/漂移，不是人真的移动了。
 */
export const MAX_SPEED_MPS = 300;
/** 只有间隔在这个窗口内才做跳点判断；隔了很久再出现远点可能是真的出远门。 */
export const JUMP_WINDOW_MS = 10 * 60 * 1000;

/**
 * GPS 轨迹的纯逻辑：合并、心跳、旧数据整理、跳点判断。
 *
 * 单独拆出来是为了能在 Local Test 里直接跑，不需要设备与定位服务；
 * GpsRecorder 只负责订阅回调、持久化和 UI 状态。
 */
export class GpsTrack {
  /** 球面距离（米）。 */
  static distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const rad = Math.PI / 180;
    const dLat = (lat2 - lat1) * rad;
    const dLon = (lon2 - lon1) * rad;
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
    return 2 * 6371000 * Math.asin(Math.sqrt(a));
  }

  /**
   * 连续原地记录的起点时间。旧数据没有 runStart，就把它自己当作起点。
   * 值非法或晚于 timestamp 时也回落到 timestamp，避免脏数据把心跳算坏。
   */
  static runStartOf(record: GpsRecord): number {
    const s = record.runStart;
    if (s === undefined || !Number.isFinite(s) || s > record.timestamp) {
      return record.timestamp;
    }
    return s;
  }

  /**
   * 把一条新定位并入记录集，返回是否合并到了最后一条。
   *
   * 合并的判定用「本次连续静止的起点」而不是最后一条记录的时间戳：
   * 如果每次合并都把时间戳往前推，间隔就永远小于 HEARTBEAT_MS，
   * 静止一整天也只会留下最后一个点，之前的照片全部匹配不到 GPS。
   */
  static append(records: GpsRecord[], fix: GpsRecord): boolean {
    const n = records.length;
    const last: GpsRecord | null = n > 0 ? records[n - 1] : null;

    if (last !== null && fix.timestamp > last.timestamp) {
      const runStart = GpsTrack.runStartOf(last);
      const moved = GpsTrack.distanceMeters(
        last.latitude, last.longitude, fix.latitude, fix.longitude
      );
      if (moved < SAME_SPOT_METERS && fix.timestamp - runStart < HEARTBEAT_MS) {
        const merged: GpsRecord = {
          timestamp: fix.timestamp,
          latitude: last.latitude,
          longitude: last.longitude,
          altitude: fix.altitude,
          runStart: runStart
        };
        records[n - 1] = merged;
        return true;
      }
    }

    const added: GpsRecord = {
      timestamp: fix.timestamp,
      latitude: fix.latitude,
      longitude: fix.longitude,
      altitude: fix.altitude,
      runStart: fix.runStart !== undefined ? fix.runStart : fix.timestamp
    };
    records.push(added);
    return false;
  }

  /**
   * 整理历史记录：旧版本每 31 秒写一条，同一位置会堆出大量重复点。
   * 按与新数据相同的规则折叠成「每 10 分钟一个心跳点」，腾出空间也给
   * EXIF 匹配留下足够密的时间锚点。已经整理过的数据再跑一次结果不变。
   */
  static compact(records: GpsRecord[]): GpsRecord[] {
    const out: GpsRecord[] = [];
    for (let i = 0; i < records.length; i++) {
      const r = records[i];
      const start = GpsTrack.runStartOf(r);
      const normalized: GpsRecord = {
        timestamp: r.timestamp,
        latitude: r.latitude,
        longitude: r.longitude,
        altitude: r.altitude,
        runStart: start
      };
      const last: GpsRecord | null = out.length > 0 ? out[out.length - 1] : null;
      if (last !== null && normalized.timestamp > last.timestamp) {
        const lastStart = GpsTrack.runStartOf(last);
        const moved = GpsTrack.distanceMeters(
          last.latitude, last.longitude, normalized.latitude, normalized.longitude
        );
        if (moved < SAME_SPOT_METERS && normalized.timestamp - lastStart < HEARTBEAT_MS) {
          out[out.length - 1] = {
            timestamp: normalized.timestamp,
            latitude: last.latitude,
            longitude: last.longitude,
            altitude: normalized.altitude,
            runStart: lastStart
          };
          continue;
        }
      }
      out.push(normalized);
    }
    return out;
  }

  /**
   * 是否是从上一条定位「瞬移」过来的异常点：定位源切换、丢星后首次定位
   * 都可能把位置一下甩到几十公里外。速度高到不可能是真实移动时丢弃这一次，
   * 但仍把它当作下一次判断的参考点，这样真到了新城市后第二个点能正常入库。
   */
  static isImplausibleJump(prev: GpsRecord | null, next: GpsRecord): boolean {
    if (prev === null) return false;
    const dt = next.timestamp - prev.timestamp;
    if (dt <= 0 || dt > JUMP_WINDOW_MS) return false;
    const distance = GpsTrack.distanceMeters(
      prev.latitude, prev.longitude, next.latitude, next.longitude
    );
    return distance / (dt / 1000) > MAX_SPEED_MPS;
  }
}
