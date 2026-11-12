import { vibrator } from '@kit.SensorServiceKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 触觉反馈。
 *
 * **克制是硬规则**：只在「用户做了一次会改变界面的明确选择」时用一次，
 * 且只用 10ms 的 `touch` 场景（官方定义就是「屏幕触摸、按键操作等反馈，
 * 振动极短，提供操作确认感」）。滚动、悬停、普通点击、列表里每一下都不震——
 * 振动一旦铺开就变成噪音，用户会去系统设置里把整台机器的触感关掉。
 *
 * 调用点目前只有一个：相机页切换连接模式（见 `CameraPage.ModePicker`）。
 */
export class Haptics {
  private static readonly TAG: string = 'Haptics';

  /**
   * 一次极短的触摸确认。
   *
   * 没有马达、权限被拒、系统关了触感，都会让 `startVibration` 失败——
   * 这些都不是错误，静默跳过即可，绝不能影响交互本身。
   */
  static tap(): void {
    const effect: vibrator.VibrateTime = { type: 'time', duration: 10 };
    const attribute: vibrator.VibrateAttribute = { usage: 'touch' };
    try {
      vibrator.startVibration(effect, attribute, (err: BusinessError) => {
        if (err) {
          hilog.warn(0x0000, Haptics.TAG, 'vibrate failed: %{public}d', err.code);
        }
      });
    } catch (err) {
      hilog.warn(0x0000, Haptics.TAG, 'vibrate unavailable: %{public}s', JSON.stringify(err));
    }
  }
}
