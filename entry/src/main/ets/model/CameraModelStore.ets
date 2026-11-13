import { PersistenceV2 } from '@kit.ArkUI';

/**
 * 上次认出机型的相机立牌（落盘）。
 *
 * 只存 `key`（如 `z50ii`），不存图片——立牌是打包在 `resources/base/media` 里的
 * 静态资源，key 决定用哪一张（见 `utils/CameraStandee.ets`）。
 *
 * UI 靠它在上次连过的相机还没连上时也能先摆出立牌，连接成功后页面形状不跳。
 */
@ObservedV2
export class CameraModelStore {
  static readonly KEY = 'camera_model';

  /** 立牌 key；`''` 表示还没认出过任何机型。 */
  @Trace key: string = '';
  /** 机身序列号（BLE 名尾段或 PTP 序列号去掉前导零）。 */
  @Trace serial: string = '';

  private static instance_: CameraModelStore;

  static getInstance(): CameraModelStore {
    if (!CameraModelStore.instance_) {
      CameraModelStore.instance_ = PersistenceV2.globalConnect({
        type: CameraModelStore,
        key: CameraModelStore.KEY,
        defaultCreator: () => new CameraModelStore()
      })!;
    }
    return CameraModelStore.instance_;
  }

  set(key: string): void {
    this.key = key;
  }

  /** 清空当前展示的机型与序列号（切到一台还没认出机型的新相机时用）。 */
  clear(): void {
    this.key = '';
    this.serial = '';
  }

  /** 序列号（标题栏型号右下角的角标）。空串表示不知道，UI 不渲染。 */
  setSerial(serial: string): void {
    // PTP 的序列号是 32 位、前面补零；去掉前导零才是相机菜单里那串
    if (serial !== '') this.serial = serial.replace(/^0+/, '');
  }
}
