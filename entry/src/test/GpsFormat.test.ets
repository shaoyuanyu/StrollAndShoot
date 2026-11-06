import { describe, it, expect } from '@ohos/hypium';
import {
  formatAltitude, formatClock, formatCoordinate, formatDistance,
  formatDistanceCompact, formatDuration, formatDurationCompact
} from '../main/ets/utils/GpsFormat';

export default function gpsFormatTest() {
  describe('GpsFormat', () => {
    it('距离：米与公里', 0, () => {
      expect(formatDistance(0)).assertEqual('0 米');
      expect(formatDistance(820)).assertEqual('820 米');
      expect(formatDistance(3200)).assertEqual('3.20 公里');
      expect(formatDistance(12345)).assertEqual('12.3 公里');
    });

    it('紧凑距离', 0, () => {
      expect(formatDistanceCompact(0)).assertEqual('0m');
      expect(formatDistanceCompact(820)).assertEqual('820m');
      expect(formatDistanceCompact(3200)).assertEqual('3.2km');
      expect(formatDistanceCompact(12345)).assertEqual('12km');
    });

    it('时长：分钟与小时', 0, () => {
      expect(formatDuration(0)).assertEqual('0 分钟');
      expect(formatDuration(12 * 60000)).assertEqual('12 分钟');
      expect(formatDuration(60 * 60000)).assertEqual('1 小时');
      expect(formatDuration(72 * 60000)).assertEqual('1 小时 12 分');
      expect(formatDurationCompact(12 * 60000)).assertEqual('12分');
      expect(formatDurationCompact(72 * 60000)).assertEqual('1时12分');
    });

    it('时间与坐标格式化', 0, () => {
      const ts = new Date(2026, 10, 6, 22, 48, 23).getTime();
      expect(formatClock(ts)).assertEqual('22:48:23');
      expect(formatCoordinate(22.8787, 113.88)).assertEqual('22.878700, 113.880000');
    });

    it('海拔 0 视为缺失', 0, () => {
      expect(formatAltitude(0)).assertEqual('');
      expect(formatAltitude(45.4)).assertEqual('海拔 45m');
    });
  });
}
