/**
 * HandednessService.ets
 *
 * 握持手感知。
 *
 * 官方《智感握姿》把「浮动按钮/面板根据握持手自动左右切换位置，始终处于拇指可达
 * 区域」列为首要适用场景，本项目用它决定下载进度浮岛贴左侧还是右侧。
 *
 * 能力边界（官方文档原文）：
 * - 握持手识别自 API 20 起提供，`motion.on('holdingHandChanged')`；
 * - 仅部分机型支持，系统设置里要有「智感握姿」开关，没有则订阅抛 801；
 * - 需要 `ohos.permission.DETECT_GESTURE`（normal / system_grant，声明即授予）。
 *
 * 因此这里一律「失败即保持默认」：默认右侧，只有明确识别到左手握持才切到左侧。
 */
import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'Handedness';

@ObservedV2
export class HandednessService {
  private static instance: HandednessService | null = null;

  /** true 表示左手握持，浮岛贴左侧；默认 false（右侧）。 */
  @Trace leftHanded: boolean = false;

  private subscribed: boolean = false;

  static getInstance(): HandednessService {
    if (HandednessService.instance === null) {
      HandednessService.instance = new HandednessService();
    }
    return HandednessService.instance;
  }

  /** 订阅握持手变化。设备不支持或机型未开放时静默降级，保持默认右侧。 */
  start(): void {
    if (this.subscribed) return;
    if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
      hilog.info(DOMAIN, TAG, '%{public}s', 'motion capability unavailable, keep right');
      return;
    }
    try {
      motion.on('holdingHandChanged', this.onHoldingHandChanged);
      this.subscribed = true;
      hilog.info(DOMAIN, TAG, '%{public}s', 'subscribed holdingHandChanged');
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'subscribe failed code=%{public}d', e.code);
    }
  }

  stop(): void {
    if (!this.subscribed) return;
    try {
      motion.off('holdingHandChanged', this.onHoldingHandChanged);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'unsubscribe failed code=%{public}d', e.code);
    }
    this.subscribed = false;
  }

  /**
   * 只在明确识别到单手时切换。
   * 双手握持、未握持、未识别都保持原位 —— 手机放桌上或换手途中，浮岛不该来回跳。
   */
  private onHoldingHandChanged = (status: motion.HoldingHandStatus): void => {
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
      this.leftHanded = true;
    } else if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      this.leftHanded = false;
    }
  };
}
