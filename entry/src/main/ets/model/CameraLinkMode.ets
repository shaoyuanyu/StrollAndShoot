/**
 * 四条链路模式，用户在相机页顶部四选一。
 *
 * 这是 1.43.0 的取舍：不再让 App「猜」该走哪条无线链路（之前自动在 BLE 与
 * Wi-Fi 之间切换，结果既不可预期、又会把相机在两种模式间来回踢），而是把
 * 模式明确交回用户 —— 所见即所得，操作符合预期。
 *
 * - USB：数据线 + PTP，最稳，照片最多；
 * - BLE：只做配对、校时、位置注入，不传照片；
 * - AP：相机自己开热点，手机连上去传照片（App 能全程自动化，也能自动退出）；
 * - STA：相机加入手机所在网络，手机保持联网（相机侧需一次性配置）。
 */
export enum CameraLinkMode {
  USB = 0,
  BLE = 1,
  AP = 2,
  STA = 3
}

/** 默认模式：蓝牙（最省电、最不可能打搅相机）。 */
export const DEFAULT_LINK_MODE: number = CameraLinkMode.BLE;

/** 是否是需要 Wi-Fi 传照片的模式。 */
export function isWifiMode(mode: number): boolean {
  return mode === CameraLinkMode.AP || mode === CameraLinkMode.STA;
}
