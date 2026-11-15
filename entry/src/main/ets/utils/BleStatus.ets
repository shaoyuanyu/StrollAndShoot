/**
 * 蓝牙待机相机状态的展示口径（1.72.3）。
 *
 * 电量与唤醒状态只在这里定义「值 → 文案 / 图标 / 警示色」：相机页标题栏右侧的
 * 两个状态胶囊与相机页脚注都从这里取，避免两处各判一套阈值。数据源仍然是
 * `CameraService.bleBatteryPercent` / `blePowerState`（GATT 只读，1.69.0）。
 *
 * 两个约定：
 * - **图标是编译期资源**：`sys.symbol.*` 的名字不能拼，只能逐个字面量返回；
 * - **警示只给图标**：数字与文字保持主/次级文本色，红色只表示「这一格要看一眼」
 *   （电量低于两成、相机未唤醒 / 已停止），不是错误。
 */
export class BleStatus {
  /** 电量文案：`82%`；读不到（-1）用「未知」。 */
  static batteryText(percent: number): ResourceStr {
    return percent >= 0 ? `${percent}%` : $r('app.string.common_unknown');
  }

  /**
   * 唤醒状态文案（`0x2001` 枚举，-1 = 未读到）。
   *
   * **只给用户两个状态**：唤醒 / 沉睡（用户 2026-11-15；不要「已唤醒 / 未唤醒」这种
   * 「已/未」前缀）。底层四个枚举折叠进来：`3 valid_wake` 与 `1 wake_wait` 都是
   * 醒着（后者是过渡态），`2 invalid_wake` 与 `0 stop` 都是睡着（相机没开机也走
   * 这一档）；读不到才是「未知」。
   */
  static powerText(state: number): ResourceStr {
    if (state === 3 || state === 1) return $r('app.string.camera_power_valid_wake');
    if (state === 2 || state === 0) return $r('app.string.camera_power_invalid_wake');
    return $r('app.string.common_unknown');
  }

  /**
   * 电量图标：按档位取系统符号。
   *
   * 系统符号只有 5/10/15/20/30/40/50/60/70/80/90/100 这些档，所以图标是**粗略**的，
   * 精确值看旁边的数字（82% 会落在 80% 那一档）。读不到用空心 `battery`。
   */
  static batterySymbol(percent: number): Resource {
    if (percent < 0) return $r('sys.symbol.battery');
    if (percent >= 95) return $r('sys.symbol.battery_100percent');
    if (percent >= 85) return $r('sys.symbol.battery_90percent');
    if (percent >= 75) return $r('sys.symbol.battery_80percent');
    if (percent >= 65) return $r('sys.symbol.battery_70percent');
    if (percent >= 55) return $r('sys.symbol.battery_60percent');
    if (percent >= 45) return $r('sys.symbol.battery_50percent');
    if (percent >= 35) return $r('sys.symbol.battery_40percent');
    if (percent >= 25) return $r('sys.symbol.battery_30percent');
    if (percent >= 15) return $r('sys.symbol.battery_20percent');
    if (percent >= 10) return $r('sys.symbol.battery_10percent');
    return $r('sys.symbol.battery_5percent');
  }

  /** 电量低于两成：图标转警示色。 */
  static batteryLow(percent: number): boolean {
    return percent >= 0 && percent <= 20;
  }

  /** 唤醒状态图标：唤醒 = 闪电、沉睡 = 月亮；读不到用问号。 */
  static powerSymbol(state: number): Resource {
    if (state === 3 || state === 1) return $r('sys.symbol.bolt_fill');
    if (state === 2 || state === 0) return $r('sys.symbol.moon_z_fill');
    return $r('sys.symbol.questionmark_circle');
  }

  /** 沉睡算警示（遥控、拍照都用不了）；唤醒与「未知」不上红。 */
  static powerWarn(state: number): boolean {
    return state === 0 || state === 2;
  }
}
