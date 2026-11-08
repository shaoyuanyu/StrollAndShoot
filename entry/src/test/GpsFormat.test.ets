import { describe, it, expect } from '@ohos/hypium';
import {
  formatAltitude, formatClock, formatCoordinate, formatDistance,
  formatDistanceCompact, formatDuration, formatDurationCompact
} from '../main/ets/utils/GpsFormat';
import { L10n } from '../main/ets/utils/L10n';

/**
 * Local Test 不加载 HAP 的资源索引，这里用一份最小的中文资源表代替，
 * 让 GpsFormat 的单位文案仍然可断言。正式运行时由 EntryAbility 注入
 * 真正的 resourceManager。
 */
const TEST_VALUES: Record<string, string> = {
  'gps_zero_meters': '0 米',
  'gps_distance_meters': '%1$d 米',
  'gps_distance_kilometers': '%1$s 公里',
  'gps_zero_distance_compact': '0m',
  'gps_distance_compact_meters': '%1$dm',
  'gps_distance_compact_kilometers': '%1$skm',
  'gps_zero_minutes': '0 分钟',
  'gps_duration_minutes': '%1$d 分钟',
  'gps_duration_hours': '%1$d 小时',
  'gps_duration_hours_minutes': '%1$d 小时 %2$d 分',
  'gps_zero_duration_compact': '0分',
  'gps_duration_compact_minutes': '%1$d分',
  'gps_duration_compact_hours': '%1$d时',
  'gps_duration_compact_hours_minutes': '%1$d时%2$d分',
  'gps_altitude': '海拔 %1$dm'
};

function testString(name: string, args: Array<string | number>): string {
  let text = TEST_VALUES[name] ?? name;
  for (let i = 0; i < args.length; i++) {
    const value = String(args[i]);
    text = text.replace(`%${i + 1}$s`, value).replace(`%${i + 1}$d`, value);
  }
  return text;
}

export default function gpsFormatTest() {
  L10n.setResolvers(testString, (name: string, _count: number,
    args: Array<string | number>): string => testString(name, args));

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
