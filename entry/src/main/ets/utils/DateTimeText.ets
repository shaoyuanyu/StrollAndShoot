/**
 * 日期时间显示。
 *
 * 日期格式（月份名称、年月日顺序、24/12 小时制）交给系统 Intl 按当前区域
 * 输出，避免在 string.json 里维护 12 个月的名称；「今天 / 昨天」这类相对
 * 文案仍走资源。
 */

/** 2025-11-06 → 本地化日期；跨年时带年份。 */
export function formatDayKey(day: string): string {
  const parts = day.split('-');
  if (parts.length !== 3) return day;
  const year = parseInt(parts[0], 10);
  const month = parseInt(parts[1], 10);
  const date = parseInt(parts[2], 10);
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(date)) {
    return day;
  }
  const text = formatDateParts(year, month, date, year !== new Date().getFullYear());
  return text !== '' ? text : day;
}

/** 年月日；withYear 为 false 时只显示月日（当年的日期分组标题）。 */
export function formatDateParts(year: number, month: number, day: number, withYear: boolean): string {
  const date = new Date(year, month - 1, day);
  if (Number.isNaN(date.getTime())) return '';
  if (withYear) {
    const formatter = new Intl.DateTimeFormat(undefined, {
      year: 'numeric', month: 'short', day: 'numeric'
    });
    return formatter.format(date);
  }
  const formatter = new Intl.DateTimeFormat(undefined, {
    month: 'short', day: 'numeric'
  });
  return formatter.format(date);
}

/** PTP 的 YYYYMMDDThhmmss 拍成「2025年11月6日 14:03:22」/「Nov 6, 2025, 14:03:22」。 */
export function formatCaptureTime(year: number, month: number, day: number,
  hour: number, minute: number, second: number): string {
  const date = new Date(year, month - 1, day, hour, minute, second);
  if (Number.isNaN(date.getTime())) return '';
  const formatter = new Intl.DateTimeFormat(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false
  });
  return formatter.format(date);
}

/** ISO 时间串 → 本地化日期；解析失败时退回原串前 10 位。 */
export function formatIsoDate(iso: string): string {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso.substring(0, 10);
  const formatter = new Intl.DateTimeFormat(undefined, {
    year: 'numeric', month: '2-digit', day: '2-digit'
  });
  return formatter.format(date);
}
