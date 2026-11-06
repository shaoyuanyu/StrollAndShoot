/**
 * GPS 页面的纯格式化函数。
 *
 * 单独放在这里是为了在 Local Test 里直接验证（不依赖 UI / 定位服务）。
 * 距离和时长都做两种写法：卡片上的玻璃胶囊用紧凑版，底部明细用中文完整版。
 */

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

/** 完整距离：`820 米` / `3.2 公里`。 */
export function formatDistance(meters: number): string {
  if (!Number.isFinite(meters) || meters <= 0) return '0 米';
  if (meters < 1000) return `${Math.round(meters)} 米`;
  if (meters < 10000) return `${(meters / 1000).toFixed(2)} 公里`;
  return `${(meters / 1000).toFixed(1)} 公里`;
}

/** 紧凑距离，用于空间有限的玻璃胶囊。 */
export function formatDistanceCompact(meters: number): string {
  if (!Number.isFinite(meters) || meters <= 0) return '0m';
  if (meters < 1000) return `${Math.round(meters)}m`;
  if (meters < 10000) return `${(meters / 1000).toFixed(1)}km`;
  return `${(meters / 1000).toFixed(0)}km`;
}

/** 完整时长：`12 分钟` / `1 小时 12 分`。 */
export function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return '0 分钟';
  const totalMinutes = Math.round(ms / 60000);
  if (totalMinutes < 60) return `${Math.max(1, totalMinutes)} 分钟`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (minutes === 0) return `${hours} 小时`;
  return `${hours} 小时 ${minutes} 分`;
}

/** 紧凑时长：`12分` / `1时12分`。用单字单位，避免和距离的 m 混淆。 */
export function formatDurationCompact(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return '0分';
  const totalMinutes = Math.round(ms / 60000);
  if (totalMinutes < 60) return `${Math.max(1, totalMinutes)}分`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return minutes === 0 ? `${hours}时` : `${hours}时${minutes}分`;
}

/** `22.878700, 113.880000` */
export function formatCoordinate(lat: number, lon: number): string {
  return `${lat.toFixed(6)}, ${lon.toFixed(6)}`;
}

/** `海拔 45m`；海拔缺失时返回空串，调用方用 if 隐藏。 */
export function formatAltitude(altitude: number): string {
  if (!Number.isFinite(altitude) || altitude === 0) return '';
  return `海拔 ${Math.round(altitude)}m`;
}
