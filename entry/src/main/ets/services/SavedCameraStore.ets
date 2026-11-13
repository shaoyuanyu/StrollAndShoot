import { PersistenceV2 } from '@kit.ArkUI';
import { CameraModelStore } from '../model/CameraModelStore';
import { BleIdentityStore } from './BleIdentityStore';
import { cameraSerialFromBleName } from '../utils/CameraStandee';

/**
 * 一台已经配对过的相机。
 *
 * `key` 是稳定标识（优先序列号）；BLE 地址会随相机每轮广播变化，只作为
 * 快速重连的提示，不作为身份。`identityDevice` / `identityNonce` 是相机侧
 * 认的那份配对身份，必须原样保留。
 */
export interface SavedCamera {
  key: string;
  deviceId: string;
  cameraName: string;
  identityDevice: number;
  identityNonce: number;
  /** 展示用序列号（和标题栏角标一致）；旧记录没有这个字段时退回 serial。 */
  serial: string;
  /** BLE stage4 的身份序列号，和展示序列号不是同一个数，不能混用。 */
  identitySerial?: string;
  modelKey: string;
  lastConnectedAt: number;
}

/**
 * 多相机配对仓库。
 *
 * 相机只认同一份 BLE 身份，但手机端可以保存多台相机的身份。当前真正喂给
 * `BleScanner` 的仍是 `BleIdentityStore`（它是「活动身份」，很多底层代码直接
 * 读它）；切换相机时把对应记录载入活动身份即可，不必改动整条 BLE 状态机。
 *
 * 单独一个 PersistenceV2 key，不复用 `ble_identity`：旧对象恢复时不会补上
 * 新增的数组字段，复用会把老用户的配对丢掉。首次启动从 `BleIdentityStore`
 * 迁移一条，之后不再迁移。
 */
@ObservedV2
export class SavedCameraStore {
  static readonly KEY = 'saved_cameras';

  /** 已保存的相机，整体替换数组，V2 才能追踪。 */
  @Trace cameras: SavedCamera[] = [];
  /** 当前查看/操作的相机；空串表示「准备连接新相机」。 */
  @Trace currentKey: string = '';
  /** 上一次真正连接成功的相机：冷启动默认回到它。 */
  @Trace lastConnectedKey: string = '';
  /** 旧 `ble_identity` 是否已经迁移过。 */
  @Trace migrated: boolean = false;

  private static instance_: SavedCameraStore;
  private static bootstrapped: boolean = false;

  static getInstance(): SavedCameraStore {
    if (!SavedCameraStore.instance_) {
      SavedCameraStore.instance_ = PersistenceV2.globalConnect({
        type: SavedCameraStore,
        key: SavedCameraStore.KEY,
        defaultCreator: () => new SavedCameraStore()
      })!;
    }
    if (!SavedCameraStore.bootstrapped) {
      SavedCameraStore.bootstrapped = true;
      SavedCameraStore.instance_.bootstrap();
    }
    return SavedCameraStore.instance_;
  }

  /** 首次迁移，以及每次冷启动把 current 归位到 lastConnected。 */
  private bootstrap(): void {
    if (!this.migrated) {
      const legacy = BleIdentityStore.getInstance();
      if (legacy.hasIdentity()) {
        const model = CameraModelStore.getInstance();
        const fromName = cameraSerialFromBleName(legacy.cameraName);
        const serial = model.serial !== '' ? model.serial
          : (fromName !== '' ? fromName : legacy.serial);
        const key = this.makeKey(legacy.deviceId, legacy.cameraName, legacy.identityDevice, serial);
        // 只有在仓库还是空的时候才迁移；旧键可能因为中断没清掉，不能反过来
        // 把新仓库里已经保存的多相机覆盖成一条。
        if (key !== '' && this.cameras.length === 0) {
          const rec: SavedCamera = {
            key,
            deviceId: legacy.deviceId,
            cameraName: legacy.cameraName,
            identityDevice: legacy.identityDevice,
            identityNonce: legacy.identityNonce,
            serial,
            identitySerial: legacy.serial,
            modelKey: model.key,
            lastConnectedAt: Date.now()
          };
          this.cameras = [rec];
          this.lastConnectedKey = key;
        }
      }
      this.migrated = true;
    }

    // 当前选择不跨进程保留：重新启动时要求默认显示上一次连接的相机。
    if (this.lastConnectedKey !== '' && this.find(this.lastConnectedKey) !== null) {
      this.activate(this.lastConnectedKey);
      return;
    }
    const sorted = this.sorted();
    if (sorted.length > 0) {
      this.lastConnectedKey = sorted[0].key;
      this.activate(sorted[0].key);
      return;
    }
    this.currentKey = '';
  }

  /** 按上次连接时间倒序，菜单直接用。 */
  sorted(): SavedCamera[] {
    const next = this.cameras.slice();
    next.sort((a: SavedCamera, b: SavedCamera): number => b.lastConnectedAt - a.lastConnectedAt);
    return next;
  }

  find(key: string): SavedCamera | null {
    for (const cam of this.cameras) {
      if (cam.key === key) return cam;
    }
    return null;
  }

  current(): SavedCamera | null {
    return this.currentKey !== '' ? this.find(this.currentKey) : null;
  }

  hasAny(): boolean {
    return this.cameras.length > 0;
  }

  /** 把某台已保存相机切成活动身份；不负责清 Wi-Fi 地址，调用方按场景处理。 */
  activate(key: string): boolean {
    const rec = this.find(key);
    if (rec === null) return false;
    const active = BleIdentityStore.getInstance();
    const identitySerial = rec.identitySerial !== undefined && rec.identitySerial !== ''
      ? rec.identitySerial : rec.serial;
    active.save(rec.deviceId, rec.cameraName, rec.identityDevice,
      rec.identityNonce, identitySerial);
    this.currentKey = rec.key;
    const model = CameraModelStore.getInstance();
    model.clear();
    if (rec.modelKey !== '') model.set(rec.modelKey);
    if (rec.serial !== '') model.setSerial(rec.serial);
    return true;
  }

  /** 准备连一台新相机：只清活动身份，保留所有已保存记录。 */
  beginNew(): void {
    BleIdentityStore.getInstance().clear();
    this.currentKey = '';
  }

  /** 配对成功后把活动身份写入仓库，并更新「上次连接」。 */
  rememberActive(): SavedCamera | null {
    const active = BleIdentityStore.getInstance();
    if (!active.hasIdentity()) return null;
    const model = CameraModelStore.getInstance();
    const fromName = cameraSerialFromBleName(active.cameraName);
    const serial = model.serial !== '' ? model.serial
      : (fromName !== '' ? fromName : active.serial);
    const key = this.makeKey(active.deviceId, active.cameraName, active.identityDevice, serial);
    if (key === '') return null;
    const rec: SavedCamera = {
      key,
      deviceId: active.deviceId,
      cameraName: active.cameraName,
      identityDevice: active.identityDevice,
      identityNonce: active.identityNonce,
      serial,
      identitySerial: active.serial,
      modelKey: model.key,
      lastConnectedAt: Date.now()
    };
    const next = this.cameras.slice();
    const idx = this.indexOf(rec);
    if (idx >= 0) {
      next[idx] = rec;
    } else {
      next.push(rec);
    }
    this.cameras = next;
    this.currentKey = key;
    this.lastConnectedKey = key;
    return rec;
  }

  /** 机型/序列号后补到当前记录（PTP 连接后才认出来的情况）。 */
  updateCurrentMeta(modelKey: string, serial: string): void {
    if (this.currentKey === '') return;
    const idx = this.indexOfKey(this.currentKey);
    if (idx < 0) return;
    const cur = this.cameras[idx];
    if (modelKey === '' && serial === '') return;
    if ((modelKey === '' || modelKey === cur.modelKey)
      && (serial === '' || serial === cur.serial)) {
      return;
    }
    const next = this.cameras.slice();
    next[idx] = {
      key: cur.key,
      deviceId: cur.deviceId,
      cameraName: cur.cameraName,
      identityDevice: cur.identityDevice,
      identityNonce: cur.identityNonce,
      serial: serial !== '' ? serial : cur.serial,
      identitySerial: cur.identitySerial !== undefined ? cur.identitySerial : cur.serial,
      modelKey: modelKey !== '' ? modelKey : cur.modelKey,
      lastConnectedAt: cur.lastConnectedAt
    };
    this.cameras = next;
  }

  private makeKey(deviceId: string, cameraName: string, identityDevice: number,
                  serial: string): string {
    if (serial !== '') return serial;
    if (cameraName !== '') return cameraName;
    if (deviceId !== '') return deviceId;
    return identityDevice > 0 ? `${identityDevice}` : '';
  }

  private indexOf(rec: SavedCamera): number {
    for (let i = 0; i < this.cameras.length; i++) {
      const cam = this.cameras[i];
      if (rec.serial !== '' && cam.serial === rec.serial) return i;
      if (rec.cameraName !== '' && cam.cameraName === rec.cameraName) return i;
      if (rec.identityDevice !== 0 && cam.identityDevice === rec.identityDevice) return i;
      if (cam.key === rec.key) return i;
    }
    return -1;
  }

  private indexOfKey(key: string): number {
    for (let i = 0; i < this.cameras.length; i++) {
      if (this.cameras[i].key === key) return i;
    }
    return -1;
  }
}
