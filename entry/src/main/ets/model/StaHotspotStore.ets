import { PersistenceV2 } from '@kit.ArkUI';

/**
 * Wi-Fi STA 搜索前的手机热点弹窗开关。
 *
 * 单独一个 PersistenceV2 key，**不要并进 `SettingsStore`**：它是早期落盘的
 * 全局对象，旧对象恢复时不会补新加的 `@Trace` 字段（见 PAGES.md 的教训）。
 */
@ObservedV2
export class StaHotspotStore {
  static readonly KEY = 'sta_hotspot';

  /**
   * 默认关：相机走路由器 Wi-Fi 的用户不需要被提示；只有用手机热点的用户
   * 才打开。HarmonyOS 不允许三方应用自动打开热点，这个开关只控制「搜索前
   * 是否弹窗提醒」。
   */
  @Trace check: boolean = false;

  private static instance_: StaHotspotStore;

  static getInstance(): StaHotspotStore {
    if (!StaHotspotStore.instance_) {
      StaHotspotStore.instance_ = PersistenceV2.globalConnect({
        type: StaHotspotStore,
        key: StaHotspotStore.KEY,
        defaultCreator: () => new StaHotspotStore()
      })!;
    }
    return StaHotspotStore.instance_;
  }
}
