import { PersistenceV2 } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';

@ObservedV2
export class SettingsStore {
  static readonly KEY = 'app_settings';

  @Trace darkMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @Trace galleryColumnCount: number = -1;
  @Trace displayMode: string = 'file_first';
  /** 调试包专用：让「搜索相机」连上一台虚拟相机（见 debug/MockPtpDevice）。 */
  @Trace mockCameraEnabled: boolean = false;

  private static instance_: SettingsStore;

  static getInstance(): SettingsStore {
    if (!SettingsStore.instance_) {
      SettingsStore.instance_ = PersistenceV2.globalConnect({
        type: SettingsStore,
        key: SettingsStore.KEY,
        defaultCreator: () => new SettingsStore()
      })!;
    }
    return SettingsStore.instance_;
  }
}
