import { PersistenceV2 } from '@kit.ArkUI';
import { CameraLinkMode, DEFAULT_LINK_MODE } from './CameraLinkMode';

/** 相机页当前选中的链路模式（落盘，默认「蓝牙」）。 */
@ObservedV2
export class CameraLinkModeStore {
  static readonly KEY = 'camera_link_mode';

  /** 取值见 CameraLinkMode。 */
  @Trace mode: number = DEFAULT_LINK_MODE;

  private static instance_: CameraLinkModeStore;

  static getInstance(): CameraLinkModeStore {
    if (!CameraLinkModeStore.instance_) {
      CameraLinkModeStore.instance_ = PersistenceV2.globalConnect({
        type: CameraLinkModeStore,
        key: CameraLinkModeStore.KEY,
        defaultCreator: () => new CameraLinkModeStore()
      })!;
    }
    return CameraLinkModeStore.instance_;
  }

  set(mode: number): void {
    if (mode >= CameraLinkMode.USB && mode <= CameraLinkMode.STA) {
      this.mode = mode;
    }
  }
}
