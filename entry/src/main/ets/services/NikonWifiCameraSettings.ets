/**
 * Nikon Wi-Fi 拍摄设置：白平衡、曝光模式、AF 模式与 AF 区域。
 *
 * 属性码与取值来自 SnapBridge 2.14.3 反编译结果：
 * - 白平衡 `0x5005`（UINT16）；视频白平衡 `0xD23A`（UINT16）。
 * - 曝光模式 `0x500E`（UINT16）：1=M、2=P、3=A、4=S、0x8000=AUTO。
 * - 实时取景 AF 模式 `0xD061`（UINT8）：0=AF-S、1=AF-C、2=AF-F、
 *   3=MF（固定）、4=MF、5=AF-A；SnapBridge 只写 0/1/4/5。
 * - AF 区域 `0xD05D`（UINT16）：0x8010 单点、0x8011 自动区域、
 *   0x8012 3D 跟踪、0x8013/0x8014 动态区域、0x8017 针点、
 *   0x8018/0x8019 宽区域、0x8020/0x8021 自动区域（人物/动物）等。
 *
 * 可用值仍以相机 `0x1014 GetDevicePropDesc` 的枚举为准；描述缺失或
 * 解析不出至少两项时退回本文件的保守列表，不凭空扩展相机能力。
 */

import { L10n } from '../utils/L10n';
import {
  EXPOSURE_PARAM_APERTURE,
  EXPOSURE_PARAM_EV,
  EXPOSURE_PARAM_ISO,
  EXPOSURE_PARAM_SHUTTER
} from './NikonWifiExposure';

export const CAMERA_PROP_WHITE_BALANCE = 0x5005;
export const CAMERA_PROP_MOVIE_WHITE_BALANCE = 0xD23A;
export const CAMERA_PROP_EXPOSURE_PROGRAM = 0x500E;
export const CAMERA_PROP_AF_MODE = 0xD061;
export const CAMERA_PROP_AF_AREA = 0xD05D;

export const PROGRAM_MODE_MANUAL = 1;
export const PROGRAM_MODE_PROGRAM = 2;
export const PROGRAM_MODE_APERTURE = 3;
export const PROGRAM_MODE_SHUTTER = 4;
export const PROGRAM_MODE_AUTO = 0x8000;

export const AF_AREA_SINGLE_POINT = 0x8010;
export const AF_AREA_AUTO_AREA = 0x8011;
export const AF_AREA_TRACKING_3D = 0x8012;
export const AF_AREA_DYNAMIC_M = 0x8013;
export const AF_AREA_DYNAMIC_L = 0x8014;
export const AF_AREA_PIN_POINT = 0x8017;
export const AF_AREA_WIDE_S = 0x8018;
export const AF_AREA_WIDE_L = 0x8019;
export const AF_AREA_WIDE_L_HUMAN = 0x801A;
export const AF_AREA_WIDE_L_ANIMAL = 0x801B;
export const AF_AREA_WIDE_C1 = 0x801E;
export const AF_AREA_WIDE_C2 = 0x801F;
export const AF_AREA_AUTO_HUMAN = 0x8020;
export const AF_AREA_AUTO_ANIMAL = 0x8021;

export interface CameraOption {
  value: number;
  label: string;
}

/** 曝光模式显示：P / A / S / M / AUTO；未读到返回 `--`。 */
export function programModeLabel(mode: number): string {
  if (mode === PROGRAM_MODE_MANUAL) return 'M';
  if (mode === PROGRAM_MODE_PROGRAM) return 'P';
  if (mode === PROGRAM_MODE_APERTURE) return 'A';
  if (mode === PROGRAM_MODE_SHUTTER) return 'S';
  if (mode === PROGRAM_MODE_AUTO) return 'AUTO';
  return '--';
}

/** 日志用名称，比 UI 上的单字母更容易读。 */
export function programModeName(mode: number): string {
  if (mode === PROGRAM_MODE_MANUAL) return 'M（手动）';
  if (mode === PROGRAM_MODE_PROGRAM) return 'P（程序自动）';
  if (mode === PROGRAM_MODE_APERTURE) return 'A（光圈优先）';
  if (mode === PROGRAM_MODE_SHUTTER) return 'S（快门优先）';
  if (mode === PROGRAM_MODE_AUTO) return 'AUTO（全自动）';
  return '未知';
}

/**
 * 当前曝光模式下某个参数是否可调。
 *
 * 这是页面置灰依据，不是拍摄限制的硬编码：相机仍可能在自动 ISO 等
 * 子模式下拒绝写入，失败时由相机回执提示。模式未知时保持全开，
 * 避免读不到属性就把所有控件锁死。
 */
export function exposureParamEnabled(mode: number, param: string): boolean {
  if (param !== EXPOSURE_PARAM_APERTURE && param !== EXPOSURE_PARAM_SHUTTER
    && param !== EXPOSURE_PARAM_ISO && param !== EXPOSURE_PARAM_EV) {
    return false;
  }
  if (mode === PROGRAM_MODE_MANUAL) return true;
  if (mode === PROGRAM_MODE_PROGRAM) {
    return param === EXPOSURE_PARAM_ISO || param === EXPOSURE_PARAM_EV;
  }
  if (mode === PROGRAM_MODE_APERTURE) {
    return param !== EXPOSURE_PARAM_SHUTTER;
  }
  if (mode === PROGRAM_MODE_SHUTTER) {
    return param !== EXPOSURE_PARAM_APERTURE;
  }
  if (mode === PROGRAM_MODE_AUTO) {
    return param === EXPOSURE_PARAM_EV;
  }
  return true;
}

export function whiteBalanceLabelKey(value: number, movie: boolean): string {
  if (value === 2) return 'camera_wifi_remote_wb_auto';
  if (value === 4) return 'camera_wifi_remote_wb_daylight';
  if (value === 5) return 'camera_wifi_remote_wb_fluorescent';
  if (value === 6) return 'camera_wifi_remote_wb_incandescent';
  if (value === 7) return 'camera_wifi_remote_wb_flash';
  if (value === 0x8010) return 'camera_wifi_remote_wb_cloudy';
  if (value === 0x8011) return 'camera_wifi_remote_wb_shade';
  if (value === 0x8012) return 'camera_wifi_remote_wb_color_temp';
  if (value === 0x8013) return 'camera_wifi_remote_wb_preset';
  if (value === 0x8016) return 'camera_wifi_remote_wb_natural';
  if (movie && value === 0x8015) return 'camera_wifi_remote_wb_same_as_still';
  return '';
}

export function whiteBalanceLabel(value: number, movie: boolean): string {
  const key = whiteBalanceLabelKey(value, movie);
  return key === '' ? '--' : L10n.tr(key);
}

function makeOption(value: number, labelKey: string): CameraOption {
  return { value: value, label: L10n.tr(labelKey) };
}

export function whiteBalanceStaticOptions(movie: boolean): CameraOption[] {
  const values: number[] = movie
    ? [0x8015, 2, 0x8016, 4, 0x8010, 0x8011, 5, 6, 0x8012, 0x8013]
    : [2, 0x8016, 4, 0x8010, 0x8011, 5, 6, 7, 0x8012, 0x8013];
  const options: CameraOption[] = [];
  for (const value of values) {
    const key = whiteBalanceLabelKey(value, movie);
    if (key !== '') options.push(makeOption(value, key));
  }
  return options;
}

export function whiteBalanceOptionsFromDescriptor(data: Uint8Array | null,
                                                 movie: boolean): CameraOption[] {
  const values = descriptorValues(data, [2, 1]);
  const options: CameraOption[] = [];
  const seen = new Set<number>();
  for (const value of values) {
    if (seen.has(value)) continue;
    const key = whiteBalanceLabelKey(value, movie);
    if (key === '') continue;
    seen.add(value);
    options.push(makeOption(value, key));
  }
  return options.length >= 2 ? options : whiteBalanceStaticOptions(movie);
}

export function afModeLabelKey(value: number): string {
  if (value === 0) return 'camera_wifi_remote_af_s';
  if (value === 1) return 'camera_wifi_remote_af_c';
  if (value === 2) return 'camera_wifi_remote_af_f';
  if (value === 3) return 'camera_wifi_remote_mf_fixed';
  if (value === 4) return 'camera_wifi_remote_mf';
  if (value === 5) return 'camera_wifi_remote_af_a';
  return '';
}

export function afModeLabel(value: number): string {
  const key = afModeLabelKey(value);
  return key === '' ? '--' : L10n.tr(key);
}

export function afModeStaticOptions(): CameraOption[] {
  const values: number[] = [0, 1, 5, 4];
  const options: CameraOption[] = [];
  for (const value of values) {
    const key = afModeLabelKey(value);
    if (key !== '') options.push(makeOption(value, key));
  }
  return options;
}

export function afModeOptionsFromDescriptor(data: Uint8Array | null): CameraOption[] {
  const values = descriptorValues(data, [1, 2]);
  const options: CameraOption[] = [];
  const seen = new Set<number>();
  for (const value of values) {
    // 3 是「MF（固定）」，只读状态，不作为可写选项。
    if (value === 3 || seen.has(value)) continue;
    const key = afModeLabelKey(value);
    if (key === '') continue;
    seen.add(value);
    options.push(makeOption(value, key));
  }
  return options.length >= 2 ? options : afModeStaticOptions();
}

export function afAreaLabelKey(value: number): string {
  if (value === AF_AREA_SINGLE_POINT) return 'camera_wifi_remote_af_area_single';
  if (value === AF_AREA_AUTO_AREA) return 'camera_wifi_remote_af_area_auto';
  if (value === AF_AREA_TRACKING_3D) return 'camera_wifi_remote_af_area_3d';
  if (value === AF_AREA_DYNAMIC_M) return 'camera_wifi_remote_af_area_dynamic_m';
  if (value === AF_AREA_DYNAMIC_L) return 'camera_wifi_remote_af_area_dynamic_l';
  if (value === AF_AREA_PIN_POINT) return 'camera_wifi_remote_af_area_pin';
  if (value === AF_AREA_WIDE_S) return 'camera_wifi_remote_af_area_wide_s';
  if (value === AF_AREA_WIDE_L) return 'camera_wifi_remote_af_area_wide_l';
  if (value === AF_AREA_WIDE_L_HUMAN) return 'camera_wifi_remote_af_area_wide_l_human';
  if (value === AF_AREA_WIDE_L_ANIMAL) return 'camera_wifi_remote_af_area_wide_l_animal';
  if (value === AF_AREA_WIDE_C1) return 'camera_wifi_remote_af_area_wide_c1';
  if (value === AF_AREA_WIDE_C2) return 'camera_wifi_remote_af_area_wide_c2';
  if (value === AF_AREA_AUTO_HUMAN) return 'camera_wifi_remote_af_area_auto_human';
  if (value === AF_AREA_AUTO_ANIMAL) return 'camera_wifi_remote_af_area_auto_animal';
  return '';
}

export function afAreaLabel(value: number): string {
  const key = afAreaLabelKey(value);
  return key === '' ? '--' : L10n.tr(key);
}

export function afAreaStaticOptions(): CameraOption[] {
  const values: number[] = [
    AF_AREA_SINGLE_POINT, AF_AREA_AUTO_AREA, AF_AREA_TRACKING_3D,
    AF_AREA_DYNAMIC_M, AF_AREA_DYNAMIC_L, AF_AREA_PIN_POINT,
    AF_AREA_WIDE_S, AF_AREA_WIDE_L, AF_AREA_WIDE_L_HUMAN,
    AF_AREA_WIDE_L_ANIMAL, AF_AREA_WIDE_C1, AF_AREA_WIDE_C2,
    AF_AREA_AUTO_HUMAN, AF_AREA_AUTO_ANIMAL
  ];
  const options: CameraOption[] = [];
  for (const value of values) {
    const key = afAreaLabelKey(value);
    if (key !== '') options.push(makeOption(value, key));
  }
  return options;
}

export function afAreaOptionsFromDescriptor(data: Uint8Array | null): CameraOption[] {
  const values = descriptorValues(data, [2, 1]);
  const options: CameraOption[] = [];
  const seen = new Set<number>();
  for (const value of values) {
    if (seen.has(value)) continue;
    const key = afAreaLabelKey(value);
    if (key === '') continue;
    seen.add(value);
    options.push(makeOption(value, key));
  }
  return options.length >= 2 ? options : afAreaStaticOptions();
}

export function isAutoAfArea(value: number): boolean {
  return value === AF_AREA_AUTO_AREA || value === AF_AREA_AUTO_HUMAN
    || value === AF_AREA_AUTO_ANIMAL;
}

/**
 * 点画面移动对焦点只对支持「可移动区域」的模式有意义。
 * 自动区域和 3D 跟踪由相机自己选区，发 ChangeAfArea 会成功但不会移动。
 */
export function afAreaSupportsPoint(value: number): boolean {
  if (value < 0) return true;
  if (value === AF_AREA_AUTO_AREA || value === AF_AREA_TRACKING_3D
    || value === AF_AREA_AUTO_HUMAN || value === AF_AREA_AUTO_ANIMAL) {
    return false;
  }
  return value >= AF_AREA_SINGLE_POINT && value <= AF_AREA_AUTO_ANIMAL;
}

/**
 * 解析 `0x1014 GetDevicePropDesc` 的枚举 / 范围值。
 *
 * 与曝光描述共用同一套 PTP 布局：属性码 2B + 数据类型 2B + GetSet 1B +
 * 默认值 + 当前值 + FormFlag。PTP 的 FormFlag 是 1=Range、2=Enumeration。
 * 这里按调用方给的宽度依次尝试（尼康不同属性可能报 1B/2B 不一致）。
 */
export function parseEnumDescriptor(data: Uint8Array, size: number): number[] {
  if (size <= 0 || data.length < 6) return [];
  const formOffset = 5 + size * 2;
  if (formOffset >= data.length) return [];
  const form = data[formOffset];
  let offset = formOffset + 1;
  const values: number[] = [];
  if (form === 2) {
    if (offset + 2 > data.length) return [];
    const count = data[offset] | (data[offset + 1] << 8);
    offset += 2;
    const limit = Math.min(count, 64);
    for (let i = 0; i < limit && offset + size <= data.length; i++) {
      values.push(readValue(data, offset, size));
      offset += size;
    }
  } else if (form === 1) {
    if (offset + size * 3 > data.length) return [];
    const min = readValue(data, offset, size);
    const max = readValue(data, offset + size, size);
    const step = readValue(data, offset + size * 2, size);
    if (step > 0 && max >= min) {
      const count = Math.min(Math.floor((max - min) / step) + 1, 64);
      for (let i = 0; i < count; i++) values.push(min + i * step);
    }
  }
  const unique: number[] = [];
  const seen = new Set<number>();
  for (const value of values) {
    if (seen.has(value)) continue;
    seen.add(value);
    unique.push(value);
  }
  return unique;
}

function descriptorValues(data: Uint8Array | null, sizes: number[]): number[] {
  if (data === null) return [];
  for (const size of sizes) {
    const values = parseEnumDescriptor(data, size);
    if (values.length >= 2) return values;
  }
  return [];
}

function readValue(data: Uint8Array, offset: number, size: number): number {
  if (offset + size > data.length) return 0;
  let raw = 0;
  for (let i = 0; i < size; i++) {
    raw |= data[offset + i] << (8 * i);
  }
  return raw >>> 0;
}
