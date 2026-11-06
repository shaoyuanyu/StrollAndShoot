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

/** 一天的轨迹在经纬度方向上的包围盒。 */
export interface GpsTrackBounds {
  minLat: number;
  maxLat: number;
  minLon: number;
  maxLon: number;
}

/**
 * 一天的轨迹快照。页面只读这个对象，不直接遍历 GpsRecorder 的记录。
 *
 * `fingerprint` 用来判断缓存是否还有效；`sketchPoints` 是抽稀过的折线，
 * 供地图不可用时的 Canvas/Shape 示意图使用，避免把上万个点画到 UI 线程。
 */
export interface GpsDayTrack {
  day: string;
  fingerprint: string;
  points: GpsRecord[];
  sketchPoints: GpsRecord[];
  count: number;
  first: number;
  last: number;
  distanceMeters: number;
  durationMs: number;
  bounds: GpsTrackBounds;
}

/**
 * GPS 轨迹的纯逻辑：合并、心跳、旧数据整理、跳点判断、按天聚合。
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

  /** 当天 0 点（本地时区）的时间戳。 */
  static startOfDay(timestamp: number): number {
    const d = new Date(timestamp);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  /**
   * 记录集的轻量指纹。使用首尾时间与坐标，而不是整份 JSON：
   * 新定位到达时最后一条的 timestamp 一定会变，足以让缓存失效；
   * 只改海拔不影响轨迹形状，不需要重画地图。
   */
  static fingerprint(records: GpsRecord[]): string {
    const n = records.length;
    if (n === 0) return '0';
    const first = records[0];
    const last = records[n - 1];
    return `${n}|${first.timestamp}|${first.latitude}|${first.longitude}` +
      `|${last.timestamp}|${last.latitude}|${last.longitude}`;
  }

  /**
   * 把一天的记录聚合成地图/列表要用的快照。
   *
   * 距离按相邻点逐段累加；首条时间取这一轮静止的起点（runStart），并裁剪到
   * 当天 0 点，跨午夜的一轮静止不会让「当天时长」多出前一天。
   * 记录必须已按时间升序排列（GpsRecorder.getDayRecords 保证）。
   */
  static buildDayTrack(day: string, records: GpsRecord[], fp?: string): GpsDayTrack {
    const n = records.length;
    let distance = 0;
    let minLat = 0;
    let maxLat = 0;
    let minLon = 0;
    let maxLon = 0;
    let first = 0;
    let last = 0;

    if (n > 0) {
      const p0 = records[0];
      minLat = p0.latitude;
      maxLat = p0.latitude;
      minLon = p0.longitude;
      maxLon = p0.longitude;
      first = Math.max(GpsTrack.runStartOf(p0), GpsTrack.startOfDay(p0.timestamp));
      last = records[n - 1].timestamp;

      for (let i = 1; i < n; i++) {
        const prev = records[i - 1];
        const cur = records[i];
        distance += GpsTrack.distanceMeters(
          prev.latitude, prev.longitude, cur.latitude, cur.longitude
        );
        if (cur.latitude < minLat) minLat = cur.latitude;
        if (cur.latitude > maxLat) maxLat = cur.latitude;
        if (cur.longitude < minLon) minLon = cur.longitude;
        if (cur.longitude > maxLon) maxLon = cur.longitude;
      }
    }

    const bounds: GpsTrackBounds = {
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon
    };
    return {
      day: day,
      fingerprint: fp !== undefined ? fp : GpsTrack.fingerprint(records),
      points: records,
      sketchPoints: GpsTrack.sample(records, 160),
      count: n,
      first: first,
      last: last,
      distanceMeters: distance,
      durationMs: last > first ? last - first : 0,
      bounds: bounds
    };
  }

  /**
   * 均匀抽稀，保留首尾点。只用于示意图；地图折线用原始点。
   * 均匀采样会略去小转角，但 160 个点铺满一张缩略图已经足够，
   * 而且 O(n) 不会在定位回调的 11 秒节奏里卡住 UI。
   */
  static sample(points: GpsRecord[], maxPoints: number): GpsRecord[] {
    if (maxPoints < 2 || points.length <= maxPoints) return points;
    const out: GpsRecord[] = [];
    const step = (points.length - 1) / (maxPoints - 1);
    for (let i = 0; i < maxPoints; i++) {
      const idx = Math.round(i * step);
      const p = points[idx];
      if (out.length === 0 || out[out.length - 1] !== p) {
        out.push(p);
      }
    }
    return out;
  }
}
