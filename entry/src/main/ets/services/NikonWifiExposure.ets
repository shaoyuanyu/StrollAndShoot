/**
 * Nikon Wi-Fi 曝光参数：属性码、格式化和 DevicePropDesc 解析。
 *
 * 属性码来自 SnapBridge 2.14.3 反编译的 `GetFnumberAction` /
 * `GetShutterSpeedAction` / `GetIsoAction` / `GetExposureCompensationAction`：
 * - 光圈 `0x5007`，UINT16，值 = f 值 × 100（f/2.8 → 280）；
 * - 快门 `0xD100`，UINT32，高 16 位分子、低 16 位分母（1/250 → 0x0001_00FA）；
 * - ISO `0xD0B4`（新机型，UINT32），旧属性 `0x500F`（UINT16）；
 * - 曝光补偿 `0x5010`，INT16，单位 1/1000 EV（+1/3 EV → 333）。
 *
 * 相机返回的可用值通过 `0x1014 GetDevicePropDesc` 读取；失败时用本文件的
 * 标准 1/3 档列表兜底。PTP 属性数据一律小端。
 */

export const EXPOSURE_OP_GET_DEVICE_PROP_DESC = 0x1014;
export const EXPOSURE_OP_SET_DEVICE_PROP_VALUE = 0x1016;

export const EXPOSURE_PROP_APERTURE = 0x5007;
export const EXPOSURE_PROP_SHUTTER = 0xD100;
export const EXPOSURE_PROP_ISO = 0xD0B4;
export const EXPOSURE_PROP_ISO_FALLBACK = 0x500F;
export const EXPOSURE_PROP_EV = 0x5010;

export const EXPOSURE_PARAM_APERTURE = 'aperture';
export const EXPOSURE_PARAM_SHUTTER = 'shutter';
export const EXPOSURE_PARAM_ISO = 'iso';
export const EXPOSURE_PARAM_EV = 'ev';

export interface ExposureOption {
  value: number;
  label: string;
}

export function u16le(data: Uint8Array, offset: number): number {
  if (offset + 2 > data.length) return 0;
  return data[offset] | (data[offset + 1] << 8);
}

export function u32le(data: Uint8Array, offset: number): number {
  if (offset + 4 > data.length) return 0;
  return (data[offset] | (data[offset + 1] << 8)
    | (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
}

export function signed16(raw: number): number {
  const v = raw & 0xFFFF;
  return v >= 0x8000 ? v - 0x10000 : v;
}

export function u16leBytes(value: number): Uint8Array {
  return new Uint8Array([value & 0xFF, (value >> 8) & 0xFF]);
}

export function u32leBytes(value: number): Uint8Array {
  return new Uint8Array([
    value & 0xFF,
    (value >>> 8) & 0xFF,
    (value >>> 16) & 0xFF,
    (value >>> 24) & 0xFF
  ]);
}

export function shutterRaw(numerator: number, denominator: number): number {
  return (((numerator & 0xFFFF) << 16) | (denominator & 0xFFFF)) >>> 0;
}

export function shutterNumerator(raw: number): number {
  return (raw >>> 16) & 0xFFFF;
}

export function shutterDenominator(raw: number): number {
  return raw & 0xFFFF;
}

/** f/2.8、f/10、f/0.95；未知值返回 `--`。 */
export function formatAperture(raw: number): string {
  if (raw <= 0) return '--';
  const value = raw / 100;
  if (Math.abs(value - Math.round(value)) < 0.001) {
    return `f/${Math.round(value)}`;
  }
  if (raw % 10 !== 0) return `f/${value.toFixed(2)}`;
  return `f/${value.toFixed(1)}`;
}

/**
 * 快门显示：1/250、2"、2.5"；Bulb / X / Time 用尼康的 65535 哨兵值。
 */
export function formatShutter(numerator: number, denominator: number): string {
  if (numerator === 65535 && denominator === 65535) return 'Bulb';
  if (numerator === 65535 && denominator === 65534) return 'X';
  if (numerator === 65535 && denominator === 65533) return 'Time';
  if (numerator <= 0 || denominator <= 0) return '--';
  if (denominator === 1) return `${numerator}"`;
  if (numerator === 1) return `1/${denominator}`;
  const seconds = numerator / denominator;
  if (seconds >= 1) return `${seconds.toFixed(1)}"`;
  const reciprocal = 1 / seconds;
  if (Math.abs(reciprocal - Math.round(reciprocal)) < 0.05) {
    return `1/${Math.round(reciprocal)}`;
  }
  return `1/${reciprocal.toFixed(1)}`;
}

export function formatIso(raw: number): string {
  if (raw <= 0) return '--';
  return `${raw}`;
}

/** 曝光补偿：raw 是 1/1000 EV，显示 +0.3 / -0.3 / +0.0。 */
export function formatEv(raw: number): string {
  const value = raw / 1000;
  const sign = value > 0 ? '+' : '';
  return `${sign}${value.toFixed(1)}`;
}

function makeOption(param: string, value: number): ExposureOption {
  return { value: value, label: exposureLabel(param, value) };
}

export function exposureLabel(param: string, value: number): string {
  if (param === EXPOSURE_PARAM_APERTURE) return formatAperture(value);
  if (param === EXPOSURE_PARAM_SHUTTER) {
    return formatShutter(shutterNumerator(value), shutterDenominator(value));
  }
  if (param === EXPOSURE_PARAM_ISO) return formatIso(value);
  if (param === EXPOSURE_PARAM_EV) return formatEv(value);
  return '--';
}

/**
 * 解析 `0x1014 GetDevicePropDesc` 的枚举 / 范围，转成 UI 选项。
 *
 * 不盲信描述里的 dataType：尼康不同固件对同一属性的数据类型上报会漂移
 * （实测 ISO 描述按 4B 读会得到 6553632）。这里按属性尝试 2B / 4B 两种
 * 布局，只接受数值范围合理、项数足够的候选；都不合理就返回空，让调用方
 * 使用标准 1/3 档兜底列表。
 */
export function parseDescriptorOptions(data: Uint8Array, param: string): ExposureOption[] {
  const sizes: number[] = param === EXPOSURE_PARAM_SHUTTER || param === EXPOSURE_PARAM_ISO
    ? [4, 2] : [2, 4];
  let best: ExposureOption[] = [];
  for (const size of sizes) {
    const options = parseDescriptorWithSize(data, param, size);
    if (isPlausible(param, options)) return options;
    if (options.length > best.length) best = options;
  }
  return [];
}

function parseDescriptorWithSize(data: Uint8Array, param: string, size: number): ExposureOption[] {
  if (size <= 0 || data.length < 6) return [];
  const formOffset = 5 + size * 2;
  if (formOffset >= data.length) return [];
  const form = data[formOffset];
  let offset = formOffset + 1;
  const values: number[] = [];
  // PTP FormFlag：1 = Range（min/max/step），2 = Enumeration（count + values）。
  // 之前把这两个分支写反了，光圈枚举被当成 range，才出现 f/0.22 这种值。
  if (form === 2) {
    if (offset + 2 > data.length) return [];
    const count = u16le(data, offset);
    offset += 2;
    const limit = Math.min(count, 256);
    for (let i = 0; i < limit && offset + size <= data.length; i++) {
      values.push(readValueWithSize(data, offset, size, param === EXPOSURE_PARAM_EV));
      offset += size;
    }
  } else if (form === 1) {
    if (offset + size * 3 > data.length) return [];
    const min = readValueWithSize(data, offset, size, param === EXPOSURE_PARAM_EV);
    const max = readValueWithSize(data, offset + size, size, param === EXPOSURE_PARAM_EV);
    const step = readValueWithSize(data, offset + size * 2, size, param === EXPOSURE_PARAM_EV);
    if (step > 0 && max >= min) {
      const count = Math.floor((max - min) / step) + 1;
      const limit = Math.min(count, 256);
      for (let i = 0; i < limit; i++) {
        values.push(min + i * step);
      }
    }
  }
  const options: ExposureOption[] = [];
  const seen = new Set<number>();
  for (const value of values) {
    if (seen.has(value)) continue;
    seen.add(value);
    options.push(makeOption(param, value));
  }
  return options;
}

function readValueWithSize(data: Uint8Array, offset: number, size: number,
                           signed: boolean): number {
  if (offset + size > data.length) return 0;
  let raw = 0;
  for (let i = 0; i < size; i++) {
    raw |= data[offset + i] << (8 * i);
  }
  if (size === 4) {
    return signed ? raw | 0 : raw >>> 0;
  }
  if (signed) {
    const signBit = 1 << (size * 8 - 1);
    return (raw & signBit) !== 0 ? raw - (1 << (size * 8)) : raw;
  }
  return raw;
}

function isPlausible(param: string, options: ExposureOption[]): boolean {
  if (options.length < 2) return false;
  for (const opt of options) {
    if (param === EXPOSURE_PARAM_APERTURE) {
      if (opt.value < 50 || opt.value > 20000) return false;
    } else if (param === EXPOSURE_PARAM_ISO) {
      if (opt.value < 25 || opt.value > 204800) return false;
    } else if (param === EXPOSURE_PARAM_EV) {
      if (opt.value < -5000 || opt.value > 5000) return false;
    } else if (param === EXPOSURE_PARAM_SHUTTER) {
      const num = shutterNumerator(opt.value);
      const den = shutterDenominator(opt.value);
      if (num <= 0 || den <= 0 || num > 100000 || den > 100000) return false;
    }
  }
  return true;
}

function shutterOption(numerator: number, denominator: number): ExposureOption {
  return makeOption(EXPOSURE_PARAM_SHUTTER, shutterRaw(numerator, denominator));
}

function isoOption(value: number): ExposureOption {
  return makeOption(EXPOSURE_PARAM_ISO, value);
}

function evOption(milli: number): ExposureOption {
  return makeOption(EXPOSURE_PARAM_EV, milli);
}

/** 相机没给 DevicePropDesc 时的兜底列表；顺序从大到小/快到慢，符合相机菜单习惯。 */
export function staticOptions(param: string): ExposureOption[] {
  const options: ExposureOption[] = [];
  if (param === EXPOSURE_PARAM_APERTURE) {
    const values: number[] = [95, 100, 110, 120, 140, 160, 180, 200, 220, 250,
      280, 320, 350, 400, 450, 500, 560, 630, 710, 800, 900, 1000, 1100,
      1300, 1400, 1600, 1800, 2000, 2200, 2500, 2900, 3200, 3600, 4000,
      4500, 5100, 5700, 6400];
    for (const value of values) options.push(makeOption(param, value));
    return options;
  }
  if (param === EXPOSURE_PARAM_SHUTTER) {
    const values: number[] = [
      shutterRaw(1, 8000), shutterRaw(1, 6400), shutterRaw(1, 5000),
      shutterRaw(1, 4000), shutterRaw(1, 3200), shutterRaw(1, 2500),
      shutterRaw(1, 2000), shutterRaw(1, 1600), shutterRaw(1, 1250),
      shutterRaw(1, 1000), shutterRaw(1, 800), shutterRaw(1, 640),
      shutterRaw(1, 500), shutterRaw(1, 400), shutterRaw(1, 320),
      shutterRaw(1, 250), shutterRaw(1, 200), shutterRaw(1, 160),
      shutterRaw(1, 125), shutterRaw(1, 100), shutterRaw(1, 80),
      shutterRaw(1, 60), shutterRaw(1, 50), shutterRaw(1, 40),
      shutterRaw(1, 30), shutterRaw(1, 25), shutterRaw(1, 20),
      shutterRaw(1, 15), shutterRaw(10, 130), shutterRaw(1, 10),
      shutterRaw(1, 8), shutterRaw(1, 6), shutterRaw(1, 5),
      shutterRaw(1, 4), shutterRaw(10, 32), shutterRaw(10, 25),
      shutterRaw(1, 2), shutterRaw(10, 16), shutterRaw(10, 13),
      shutterRaw(1, 1), shutterRaw(13, 10), shutterRaw(16, 10),
      shutterRaw(2, 1), shutterRaw(25, 10), shutterRaw(32, 10),
      shutterRaw(4, 1), shutterRaw(5, 1), shutterRaw(6, 1),
      shutterRaw(8, 1), shutterRaw(10, 1), shutterRaw(13, 1),
      shutterRaw(15, 1), shutterRaw(20, 1), shutterRaw(25, 1),
      shutterRaw(30, 1)
    ];
    for (const value of values) options.push(makeOption(param, value));
    return options;
  }
  if (param === EXPOSURE_PARAM_ISO) {
    const values: number[] = [50, 64, 72, 80, 100, 125, 140, 160, 200, 250,
      280, 320, 400, 500, 560, 640, 800, 1000, 1100, 1250, 1600, 2000,
      2200, 2500, 3200, 4000, 4500, 5000, 6400, 8000, 9000, 10000, 12800,
      16000, 18000, 20000, 25600, 32000, 36000, 40000, 51200, 64000,
      72000, 80000, 102400, 128000, 204800];
    for (const value of values) options.push(isoOption(value));
    return options;
  }
  if (param === EXPOSURE_PARAM_EV) {
    for (let i = -15; i <= 15; i++) {
      options.push(evOption(Math.trunc(i * 1000 / 3)));
    }
    return options;
  }
  return options;
}
