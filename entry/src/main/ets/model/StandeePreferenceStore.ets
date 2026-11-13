import { PersistenceV2 } from '@kit.ArkUI';
import { cameraStandeeKeys } from '../utils/CameraStandee';

/**
 * 默认相机立牌（看板）。
 *
 * 标题为「相机」（尚未识别机型、正在配新相机）时，封面没有真实型号可匹配，
 * 立牌显示哪一台由用户在这里选。真实型号一旦识别出来，仍以真实型号为准，
 * 不会被这个默认值覆盖。
 *
 * 单独一个 PersistenceV2 key，不追加到 `SettingsStore`：旧对象恢复时不会补上
 * 新增的 `@Trace` 字段，加进旧类会导致字段既不恢复也不落盘。
 *
 * `''` 表示「不显示」，不是回退到某台固定机型。
 */
@ObservedV2
export class StandeePreferenceStore {
  static readonly KEY = 'standee_preference';

  @Trace defaultKey: string = '';

  private static instance_: StandeePreferenceStore;

  static getInstance(): StandeePreferenceStore {
    if (!StandeePreferenceStore.instance_) {
      StandeePreferenceStore.instance_ = PersistenceV2.globalConnect({
        type: StandeePreferenceStore,
        key: StandeePreferenceStore.KEY,
        defaultCreator: () => new StandeePreferenceStore()
      })!;
      StandeePreferenceStore.instance_.normalize();
    }
    return StandeePreferenceStore.instance_;
  }

  /** 只接受立牌表里的型号；旧版本/手改配置里的非法值一律回「不显示」。 */
  setDefaultKey(key: string): void {
    this.defaultKey = cameraStandeeKeys().includes(key) ? key : '';
  }

  private normalize(): void {
    if (this.defaultKey !== '' && !cameraStandeeKeys().includes(this.defaultKey)) {
      this.defaultKey = '';
    }
  }
}
