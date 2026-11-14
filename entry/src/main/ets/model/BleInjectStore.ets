import { PersistenceV2 } from '@kit.ArkUI';

/**
 * 蓝牙相机的对时 / 位置注入开关（1.66.17）。
 *
 * 单独一个 PersistenceV2 key：`SettingsStore` 是早期就落盘的全局对象，**旧对象恢复
 * 时不会补上新加的 `@Trace` 字段**（新字段读出来是 undefined）。给它加字段会踩这个
 * 坑，所以按项目惯例另开一个 key，默认值天然就是「开」。
 */
@ObservedV2
export class BleInjectStore {
  static readonly KEY = 'ble_inject';

  /** 连上相机后写 0x2006（相机对时）。 */
  @Trace clockSync: boolean = true;
  /** 连上相机后写 0x2007（位置注入）。 */
  @Trace locationInject: boolean = true;

  private static instance_: BleInjectStore;

  static getInstance(): BleInjectStore {
    if (!BleInjectStore.instance_) {
      BleInjectStore.instance_ = PersistenceV2.globalConnect({
        type: BleInjectStore,
        key: BleInjectStore.KEY,
        defaultCreator: () => new BleInjectStore()
      })!;
    }
    return BleInjectStore.instance_;
  }
}
