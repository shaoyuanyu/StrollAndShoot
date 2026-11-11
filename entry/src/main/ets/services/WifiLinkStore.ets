import { PersistenceV2 } from '@kit.ArkUI';

/**
 * 无线（Wi-Fi STA）会话的落盘信息。
 *
 * BLE 那半条有 `BleIdentityStore`，Wi-Fi 这半条以前什么都没记 —— 于是每次
 * 冷启动都得让用户重新找一次相机 IP，哪怕相机地址几乎从来不变。这里只存
 * 「上次连上过的地址」，用途是**快速通路**：先直连这个地址，连不上再退回
 * mDNS / 网段扫描。
 *
 * 不存身份（序列号、相机名）—— 那些在 `BleIdentityStore` 里；也不存配对码，
 * 那是每次会话现算的。
 */
@ObservedV2
export class WifiLinkStore {
  static readonly KEY = 'wifi_link';

  /** 上次成功建立 PTP/IP 会话的主机地址。 */
  @Trace host: string = '';
  /** 对应端口，默认 15740。 */
  @Trace port: number = 15740;
  /** 上次连上时相机自报的型号，仅用于日志与 UI 提示。 */
  @Trace cameraName: string = '';

  private static instance_: WifiLinkStore;

  static getInstance(): WifiLinkStore {
    if (!WifiLinkStore.instance_) {
      WifiLinkStore.instance_ = PersistenceV2.globalConnect({
        type: WifiLinkStore,
        key: WifiLinkStore.KEY,
        defaultCreator: () => new WifiLinkStore()
      })!;
    }
    return WifiLinkStore.instance_;
  }

  hasHost(): boolean {
    return this.host !== '';
  }

  save(host: string, port: number, cameraName: string): void {
    this.host = host;
    this.port = port > 0 ? port : 15740;
    this.cameraName = cameraName;
  }

  clear(): void {
    this.host = '';
    this.port = 15740;
    this.cameraName = '';
  }
}
