import type { GpsRecord } from '../model/PhotoEntry';
import { GpsTrack } from './GpsTrack';

/** 相机图案上的一个点，单位米；x 向东，y 向北。 */
interface MockGpsPoint {
  x: number;
  y: number;
}

const METERS_PER_DEG_LAT: number = 111320;
const TRACK_DURATION_MS: number = 4 * 60 * 1000;
const LENS_RADIUS: number = 55;
const LENS_STEPS: number = 16;

/**
 * 调试包的模拟 GPS 轨迹生成器。
 *
 * 以当前位置为原点，生成一个约 300m × 210m 的相机图案（机身 + 取景器 + 镜头 +
 * 快门），时间铺在最近 4 分钟内。点带 `mock: true`，只交给 GpsRecorder 做
 * 当天显示，不写进 gps_records.json，也不参与照片 EXIF 匹配。
 *
 * 单独拆成纯逻辑是为了能在 Local Test 里验证点数、时间范围和包围盒。
 */
export class GpsMockTrack {
  static buildCameraTrack(origin: GpsRecord, now: number): GpsRecord[] {
    const shape = GpsMockTrack.cameraPattern();
    const n = shape.length;
    if (n === 0) return [];

    const dayStart = GpsTrack.startOfDay(now);
    let first = now - TRACK_DURATION_MS;
    const minStart = dayStart + 1000;
    if (first < minStart) first = minStart;
    if (first > now) first = now - 1000;
    const step = n > 1 ? (now - first) / (n - 1) : 0;

    const cosLat = Math.max(0.2, Math.cos(origin.latitude * Math.PI / 180));
    const out: GpsRecord[] = [];
    for (let i = 0; i < n; i++) {
      const p = shape[i];
      const ts = Math.round(first + step * i);
      const record: GpsRecord = {
        timestamp: ts,
        latitude: origin.latitude + p.y / METERS_PER_DEG_LAT,
        longitude: origin.longitude + p.x / (METERS_PER_DEG_LAT * cosLat),
        altitude: origin.altitude,
        runStart: ts,
        mock: true
      };
      out.push(record);
    }
    out.sort((a: GpsRecord, b: GpsRecord) => a.timestamp - b.timestamp);
    return out;
  }

  /**
   * 一笔画相机：从取景器左侧开始 → 顶部取景器 → 机身一圈 → 回取景器左侧 →
   * 镜头一圈 → 快门按钮。机身与镜头之间会有一条连接线，正好当作镜头卡口。
   */
  private static cameraPattern(): MockGpsPoint[] {
    const out: MockGpsPoint[] = [];
    const add = (x: number, y: number): void => {
      out.push({ x: x, y: y });
    };

    // 取景器 + 机身外轮廓
    add(-40, 90);
    add(-30, 120);
    add(30, 120);
    add(40, 90);
    add(150, 90);
    add(150, -90);
    add(-150, -90);
    add(-150, 90);
    add(-40, 90);

    // 镜头：从顶部进入，顺时针一圈后回到顶部
    add(0, LENS_RADIUS);
    for (let i = 1; i <= LENS_STEPS; i++) {
      const a = Math.PI / 2 + (Math.PI * 2 * i) / LENS_STEPS;
      add(Math.cos(a) * LENS_RADIUS, Math.sin(a) * LENS_RADIUS);
    }

    // 快门按钮：从镜头顶部接到机身右上角，再画一个小方块
    add(105, 90);
    add(105, 115);
    add(130, 115);
    add(130, 90);
    add(105, 90);
    return out;
  }
}
