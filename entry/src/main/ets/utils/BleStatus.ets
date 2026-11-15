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

  /** 唤醒状态文案（`0x2001` 枚举，-1 = 未读到）。 */
  static powerText(state: number): ResourceStr {
    if (state === 3) return $r('app.string.camera_power_valid_wake');
    if (state === 1) return $r('app.string.camera_power_wake_wait');
    if (state === 2) return $r('app.string.camera_power_invalid_wake');
    if (state === 0) return $r('app.string.camera_power_stop');
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

  /**
   * 唤醒状态图标：已唤醒 = 实心闪电、唤醒中 = 空心闪电、未唤醒 = 月亮、
   * 已停止 = 电源键；读不到用问号。
   */
  static powerSymbol(state: number): Resource {
    if (state === 3) return $r('sys.symbol.bolt_fill');
    if (state === 1) return $r('sys.symbol.bolt');
    if (state === 2) return $r('sys.symbol.moon_z_fill');
    if (state === 0) return $r('sys.symbol.power');
    return $r('sys.symbol.questionmark_circle');
  }

  /** 未唤醒 / 已停止算警示；「唤醒中」是过渡态、「未知」是没读到，都不上红。 */
  static powerWarn(state: number): boolean {
    return state === 0 || state === 2;
  }
}
