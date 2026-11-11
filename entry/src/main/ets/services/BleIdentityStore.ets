import { PersistenceV2 } from '@kit.ArkUI';

/**
 * BLE 首配后落盘的客户端身份。
 *
 * 相机**只认 savedDevice/savedNonce 这一份身份**：每次扫描列表再点都发全新
 * stage1 的话，相机会直接回 `Remote device has an error` 秒拒（ZPill
 * 2026-10-13 真机实证，本项目 2026-11-11 复现）。所以首配成功后必须把身份
 * 存下来，之后每次连接都用它复用握手。
 */
@ObservedV2
export class BleIdentityStore {
  static readonly KEY = 'ble_identity';

  /** 已配对的相机 BLE 地址。 */
  @Trace deviceId: string = '';
  /** 相机广播名（经典蓝牙发现时按它匹配）。 */
  @Trace cameraName: string = '';
  /** stage1 里用过、相机记下的 deviceId。 */
  @Trace identityDevice: number = 0;
  /** stage1 里用过、相机记下的 nonce。 */
  @Trace identityNonce: number = 0;
  /** stage4 给出的相机序列号。 */
  @Trace serial: string = '';

  private static instance_: BleIdentityStore;

  static getInstance(): BleIdentityStore {
    if (!BleIdentityStore.instance_) {
      BleIdentityStore.instance_ = PersistenceV2.globalConnect({
        type: BleIdentityStore,
        key: BleIdentityStore.KEY,
        defaultCreator: () => new BleIdentityStore()
      })!;
    }
    return BleIdentityStore.instance_;
  }

  /** 有没有可用身份（device 为 0 说明从没配对成功过）。 */
  hasIdentity(): boolean {
    return this.identityDevice !== 0;
  }

  save(deviceId: string, cameraName: string, device: number, nonce: number,
       serial: string): void {
    this.deviceId = deviceId;
    this.cameraName = cameraName;
    this.identityDevice = device;
    this.identityNonce = nonce;
    this.serial = serial;
  }

  clear(): void {
    this.deviceId = '';
    this.cameraName = '';
    this.identityDevice = 0;
    this.identityNonce = 0;
    this.serial = '';
  }
}
