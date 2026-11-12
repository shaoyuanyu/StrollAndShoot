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
  /**
   * 调试包专用：虚拟相机上报的机型（营销名，如 `Z 50II`）。
   *
   * 空串表示上报「Virtual PTP Camera」，也就是认不出的机器——用来验证没有立牌、
   * 标题退回「相机」的分支。改完要重新搜索一次才生效（型号是设备身份的一部分）。
   */
  @Trace mockCameraModel: string = '';
  /**
   * 调试包专用：关闭磨砂玻璃（沉浸光感）材质与模糊。
   * 模拟器 GPU 不支持磨砂着色器，材质叠加时会出现乱画的多边形；
   * 打开后所有材质换成空材质、模糊半径归零，便于截图排查布局。
   */
  @Trace debugDisableGlass: boolean = false;

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
