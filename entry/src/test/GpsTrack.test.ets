import { describe, it, expect } from '@ohos/hypium';
import { GpsTrack } from '../main/ets/utils/GpsTrack';
import { GpsTrackCache } from '../main/ets/services/GpsTrackCache';
import type { GpsRecord } from '../main/ets/model/PhotoEntry';

const BASE = 1793970000000;
const LAT = 31.2304;
const LON = 121.4737;

function fix(ts: number, lat: number = LAT, lon: number = LON, alt: number = 10): GpsRecord {
  const r: GpsRecord = {
    timestamp: ts,
    latitude: lat,
    longitude: lon,
    altitude: alt
  };
  return r;
}

export default function gpsTrackTest() {
  describe('GpsTrack', () => {
    it('原地不动每 10 分钟补一条心跳，不会无限合并', 0, () => {
      const records: GpsRecord[] = [];
      for (let i = 0; i <= 20; i++) {
        GpsTrack.append(records, fix(BASE + i * 31000));
      }
      expect(records.length).assertEqual(2);
      expect(records[0].timestamp).assertEqual(BASE + 19 * 31000);
      expect(records[0].runStart).assertEqual(BASE);
      expect(records[1].timestamp).assertEqual(BASE + 20 * 31000);
      expect(records[1].runStart).assertEqual(BASE + 20 * 31000);
    });

    it('移动超过 5 米就新增一条', 0, () => {
      const records: GpsRecord[] = [];
      GpsTrack.append(records, fix(BASE));
      const merged = GpsTrack.append(records, fix(BASE + 31000, LAT + 0.001));
      expect(merged).assertEqual(false);
      expect(records.length).assertEqual(2);
      expect(records[1].latitude).assertEqual(LAT + 0.001);
    });

    it('5 米内合并、超过 5 米新增', 0, () => {
      const records: GpsRecord[] = [];
      GpsTrack.append(records, fix(BASE));
      // 约 4.45 米，仍在 5 米内，合并
      const near = GpsTrack.append(records, fix(BASE + 11000, LAT + 0.00004));
      expect(near).assertEqual(true);
      expect(records.length).assertEqual(1);
      // 相对锚点约 5.57 米，超过 5 米，新增
      const far = GpsTrack.append(records, fix(BASE + 22000, LAT + 0.00005));
      expect(far).assertEqual(false);
      expect(records.length).assertEqual(2);
    });

    it('10 分钟内的原地抖动仍合并', 0, () => {
      const records: GpsRecord[] = [];
      GpsTrack.append(records, fix(BASE));
      const merged = GpsTrack.append(records, fix(BASE + 31000, LAT + 0.00001));
      expect(merged).assertEqual(true);
      expect(records.length).assertEqual(1);
      expect(records[0].timestamp).assertEqual(BASE + 31000);
    });

    it('compact 把旧版每 31 秒的重复点整理成心跳点', 0, () => {
      const raw: GpsRecord[] = [];
      for (let i = 0; i <= 232; i++) {
        raw.push(fix(BASE + i * 31000));
      }
      const out = GpsTrack.compact(raw);
      expect(out.length).assertEqual(12);
      expect(out[0].runStart).assertEqual(BASE);
      expect(out[0].timestamp).assertEqual(BASE + 19 * 31000);
      expect(out[1].runStart).assertEqual(BASE + 20 * 31000);
      const again = GpsTrack.compact(out);
      expect(again.length).assertEqual(out.length);
    });

    it('compact 不合并真正移动过的点', 0, () => {
      const raw: GpsRecord[] = [
        fix(BASE),
        fix(BASE + 31000, LAT + 0.001),
        fix(BASE + 62000, LAT + 0.002)
      ];
      const out = GpsTrack.compact(raw);
      expect(out.length).assertEqual(3);
    });

    it('跳点判断按速度而不是距离', 0, () => {
      const shanghai = fix(BASE);
      expect(GpsTrack.isImplausibleJump(shanghai, fix(BASE + 31000, 22.8787, 113.8798))).assertEqual(true);
      expect(GpsTrack.isImplausibleJump(shanghai, fix(BASE + 31000, LAT + 0.01))).assertEqual(false);
      expect(GpsTrack.isImplausibleJump(
        shanghai, fix(BASE + 11 * 60 * 1000, 22.8787, 113.8798)
      )).assertEqual(false);
    });

    it('runStart 非法时回落到 timestamp', 0, () => {
      const r = fix(BASE + 1000);
      r.runStart = BASE + 5000;
      expect(GpsTrack.runStartOf(r)).assertEqual(BASE + 1000);
    });

    it('buildDayTrack 聚合距离、时长、边界与首条时间', 0, () => {
      const dayStart = new Date(2026, 10, 6, 0, 0, 0).getTime();
      const records: GpsRecord[] = [
        fix(dayStart + 3600000, 22.8787, 113.8800, 45),
        fix(dayStart + 3611000, 22.8787, 113.8801, 46),
        fix(dayStart + 3622000, 22.8788, 113.8802, 47)
      ];
      records[0].runStart = dayStart + 3500000;

      const track = GpsTrack.buildDayTrack('2026-11-06', records);
      expect(track.count).assertEqual(3);
      expect(track.first).assertEqual(dayStart + 3500000);
      expect(track.last).assertEqual(dayStart + 3622000);
      expect(track.durationMs).assertEqual(122000);
      expect(track.distanceMeters > 10 && track.distanceMeters < 40).assertTrue();
      expect(track.bounds.minLat).assertEqual(22.8787);
      expect(track.bounds.maxLat).assertEqual(22.8788);
      expect(track.bounds.minLon).assertEqual(113.8800);
      expect(track.bounds.maxLon).assertEqual(113.8802);
    });

    it('跨午夜的 runStart 在当天轨迹里裁到 0 点', 0, () => {
      const dayStart = new Date(2026, 10, 6, 0, 0, 0).getTime();
      const r = fix(dayStart + 60000);
      r.runStart = dayStart - 300000;
      const track = GpsTrack.buildDayTrack('2026-11-06', [r]);
      expect(track.first).assertEqual(dayStart);
      expect(track.durationMs).assertEqual(60000);
    });

    it('sample 保留首尾点且不超过上限', 0, () => {
      const points: GpsRecord[] = [];
      for (let i = 0; i < 1000; i++) {
        points.push(fix(BASE + i * 1000, LAT + i * 0.00001));
      }
      const sampled = GpsTrack.sample(points, 160);
      expect(sampled.length).assertEqual(160);
      expect(sampled[0] === points[0]).assertTrue();
      expect(sampled[sampled.length - 1] === points[999]).assertTrue();

      const short = GpsTrack.sample(points.slice(0, 20), 160);
      expect(short.length).assertEqual(20);
    });

    it('fingerprint 对末点变化敏感、对海拔不敏感', 0, () => {
      const records: GpsRecord[] = [
        fix(BASE),
        fix(BASE + 11000, LAT + 0.001)
      ];
      const fp = GpsTrack.fingerprint(records);
      expect(GpsTrack.fingerprint(records)).assertEqual(fp);

      const altitudeOnly = records.slice();
      altitudeOnly[1] = fix(BASE + 11000, LAT + 0.001, LON, 99);
      expect(GpsTrack.fingerprint(altitudeOnly)).assertEqual(fp);

      const moved = records.slice();
      moved[1] = fix(BASE + 12000, LAT + 0.001);
      expect(GpsTrack.fingerprint(moved) === fp).assertFalse();
    });

    it('GpsTrackCache 命中同指纹、失效后重建', 0, () => {
      const cache = GpsTrackCache.getInstance();
      cache.clear();
      const records: GpsRecord[] = [
        fix(BASE),
        fix(BASE + 11000, LAT + 0.001)
      ];
      const first = cache.getDayTrack('2026-11-06', records);
      const again = cache.getDayTrack('2026-11-06', records);
      expect(first === again).assertTrue();

      const changed = records.slice();
      changed.push(fix(BASE + 22000, LAT + 0.002));
      const rebuilt = cache.getDayTrack('2026-11-06', changed);
      expect(first === rebuilt).assertFalse();
      expect(rebuilt.count).assertEqual(3);

      cache.invalidate('2026-11-06');
      const afterInvalidate = cache.getDayTrack('2026-11-06', changed);
      expect(rebuilt === afterInvalidate).assertFalse();
      cache.clear();
    });
  });
}
