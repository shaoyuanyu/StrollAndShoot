/**
 * GPS 页面的纯格式化函数。
 *
 * 距离、时长与海拔的单位文案来自 string.json，通过 L10n 按当前区域解析；
 * 这里只保留数值换算与进位规则，方便在 Local Test 里验证（测试会注入
 * 一份测试用资源解析器）。
 */

import { L10n } from './L10n';

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

/** HH:mm:ss */
export function formatClock(ts: number): string {
  const d = new Date(ts);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

/** HH:mm，用于轨迹时间线和分组标题；秒对当天概览没有意义。 */
export function formatHm(ts: number): string {
  const d = new Date(ts);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** 完整距离：`820 米` / `3.20 公里`。 */
export function formatDistance(meters: number): string {
  if (!Number.isFinite(meters) || meters <= 0) return L10n.tr('gps_zero_meters');
  if (meters < 1000) return L10n.tr('gps_distance_meters', Math.round(meters));
  if (meters < 10000) return L10n.tr('gps_distance_kilometers', (meters / 1000).toFixed(2));
  return L10n.tr('gps_distance_kilometers', (meters / 1000).toFixed(1));
}

/** 紧凑距离，用于空间有限的玻璃胶囊。 */
export function formatDistanceCompact(meters: number): string {
  if (!Number.isFinite(meters) || meters <= 0) return L10n.tr('gps_zero_distance_compact');
  if (meters < 1000) return L10n.tr('gps_distance_compact_meters', Math.round(meters));
  if (meters < 10000) return L10n.tr('gps_distance_compact_kilometers', (meters / 1000).toFixed(1));
  return L10n.tr('gps_distance_compact_kilometers', (meters / 1000).toFixed(0));
}

/** 完整时长：`12 分钟` / `1 小时 12 分`。 */
export function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return L10n.tr('gps_zero_minutes');
  const totalMinutes = Math.round(ms / 60000);
  if (totalMinutes < 60) return L10n.tr('gps_duration_minutes', Math.max(1, totalMinutes));
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (minutes === 0) return L10n.tr('gps_duration_hours', hours);
  return L10n.tr('gps_duration_hours_minutes', hours, minutes);
}

/** 紧凑时长：`12分` / `1时12分`。用单字单位，避免和距离的 m 混淆。 */
export function formatDurationCompact(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return L10n.tr('gps_zero_duration_compact');
  const totalMinutes = Math.round(ms / 60000);
  if (totalMinutes < 60) return L10n.tr('gps_duration_compact_minutes', Math.max(1, totalMinutes));
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return minutes === 0
    ? L10n.tr('gps_duration_compact_hours', hours)
    : L10n.tr('gps_duration_compact_hours_minutes', hours, minutes);
}

/** `22.878700, 113.880000` */
export function formatCoordinate(lat: number, lon: number): string {
  return `${lat.toFixed(6)}, ${lon.toFixed(6)}`;
}

/** `海拔 45m`；海拔缺失时返回空串，调用方用 if 隐藏。 */
export function formatAltitude(altitude: number): string {
  if (!Number.isFinite(altitude) || altitude === 0) return '';
  return L10n.tr('gps_altitude', Math.round(altitude));
}
