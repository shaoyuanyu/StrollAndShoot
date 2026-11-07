import { describe, it, expect } from '@ohos/hypium';
import { GpsMockTrack } from '../main/ets/utils/GpsMockTrack';
import { GpsTrack } from '../main/ets/utils/GpsTrack';
import type { GpsRecord } from '../main/ets/model/PhotoEntry';

const ORIGIN_LAT = 31.2304;
const ORIGIN_LON = 121.4737;

function origin(): GpsRecord {
  const r: GpsRecord = {
    timestamp: 0,
    latitude: ORIGIN_LAT,
    longitude: ORIGIN_LON,
    altitude: 10
  };
  return r;
}

export default function gpsMockTrackTest() {
  describe('GpsMockTrack', () => {
    it('相机图案点数、时间和 mock 标记', 0, () => {
      const now = new Date(2026, 10, 7, 12, 0, 0).getTime();
      const records = GpsMockTrack.buildCameraTrack(origin(), now);
      expect(records.length > 24).assertTrue();
      expect(records[records.length - 1].timestamp).assertEqual(now);
      expect(records[0].timestamp).assertEqual(now - 4 * 60 * 1000);

      for (let i = 0; i < records.length; i++) {
        expect(records[i].mock).assertTrue();
        expect(records[i].runStart).assertEqual(records[i].timestamp);
        if (i > 0) {
          expect(records[i].timestamp >= records[i - 1].timestamp).assertTrue();
        }
      }
    });

    it('图案宽约 300 米、高约 210 米', 0, () => {
      const now = new Date(2026, 10, 7, 12, 0, 0).getTime();
      const records = GpsMockTrack.buildCameraTrack(origin(), now);
      let minLat = records[0].latitude;
      let maxLat = records[0].latitude;
      let minLon = records[0].longitude;
      let maxLon = records[0].longitude;
      for (let i = 1; i < records.length; i++) {
        const r = records[i];
        if (r.latitude < minLat) minLat = r.latitude;
        if (r.latitude > maxLat) maxLat = r.latitude;
        if (r.longitude < minLon) minLon = r.longitude;
        if (r.longitude > maxLon) maxLon = r.longitude;
      }
      const midLat = (minLat + maxLat) / 2;
      const width = GpsTrack.distanceMeters(midLat, minLon, midLat, maxLon);
      const height = GpsTrack.distanceMeters(minLat, minLon, maxLat, minLon);
      expect(width > 280 && width < 320).assertTrue();
      expect(height > 195 && height < 225).assertTrue();
    });

    it('图案从当前位置附近开始，且能聚合成当天轨迹', 0, () => {
      const now = new Date(2026, 10, 7, 12, 0, 0).getTime();
      const records = GpsMockTrack.buildCameraTrack(origin(), now);
      const startDistance = GpsTrack.distanceMeters(
        ORIGIN_LAT, ORIGIN_LON, records[0].latitude, records[0].longitude
      );
      expect(startDistance < 300).assertTrue();

      const track = GpsTrack.buildDayTrack('2026-11-07', records);
      expect(track.count).assertEqual(records.length);
      expect(track.distanceMeters > 100).assertTrue();
      expect(track.first).assertEqual(records[0].timestamp);
      expect(track.last).assertEqual(now);
    });

    it('刚过零点时所有点仍落在当天', 0, () => {
      const dayStart = new Date(2026, 10, 7, 0, 0, 0).getTime();
      const now = dayStart + 60000;
      const records = GpsMockTrack.buildCameraTrack(origin(), now);
      for (let i = 0; i < records.length; i++) {
        expect(records[i].timestamp >= dayStart).assertTrue();
        expect(records[i].timestamp <= now).assertTrue();
      }
    });
  });
}
