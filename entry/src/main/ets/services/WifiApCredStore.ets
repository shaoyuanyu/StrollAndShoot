import { PersistenceV2 } from '@kit.ArkUI';

/**
 * 一台相机的热点凭据（1.68.0）。
 *
 * 来源是 BLE 握手时读到的 `0x2004`（`NikonWifiCredentials` 解密后的
 * SSID / 密码 / 安全类型），`host` 是上次真的连上 PTP 的地址（相机热点的
 * 网关）。存下来的唯一目的是：**浏览照片不再依赖相机的 BLE**——
 * 相机停在 Wi-Fi 模式、或者干脆不回落蓝牙时，App 也能直接加入热点看图。
 *
 * 这是一份本机设备凭据，和现有的 BLE 配对材料（`ble_identity` /
 * `saved_cameras`）同一级别：只落在应用沙箱的持久化里，不上传、不共享。
 */
export interface WifiApCred {
  /** 相机序列号（`SavedCamera.serial`，与标题栏角标同源）。 */
  serial: string;
  ssid: string;
  password: string;
  /** 0x2004 的安全模式字节：0x00 开放 / 0x01 WPA2 / 0x02 WPA3 / 0x03 WPA2+WPA3。 */
  security: number;
  /** 上次成功连上 PTP 的地址（相机热点网关，通常 192.168.1.1）。 */
  host: string;
  updatedAt: number;
}

/**
 * 相机热点凭据仓库（每台相机一条）。
 *
 * 单独一个 PersistenceV2 key，不往 `SavedCamera` 里加字段：旧记录恢复时不会
 * 补上新增字段，混在一起会把老用户的配对记录写坏（1.66.1 的教训）。按序列号
 * 对齐，序列号为空（不该发生）就不存——宁可下次走 BLE，也不写一条认不出的凭据。
 */
@ObservedV2
export class WifiApCredStore {
  static readonly KEY = 'wifi_ap_creds';

  /** 已保存的凭据，整体替换数组，V2 才能追踪。 */
  @Trace creds: WifiApCred[] = [];

  private static instance_: WifiApCredStore;

  static getInstance(): WifiApCredStore {
    if (!WifiApCredStore.instance_) {
      WifiApCredStore.instance_ = PersistenceV2.globalConnect({
        type: WifiApCredStore,
        key: WifiApCredStore.KEY,
        defaultCreator: () => new WifiApCredStore()
      })!;
    }
    return WifiApCredStore.instance_;
  }

  /** 找一台相机的热点凭据；没有就返回 null。 */
  find(serial: string): WifiApCred | null {
    if (serial === '') return null;
    for (const c of this.creds) {
      if (c.serial === serial) return c;
    }
    return null;
  }

  /**
   * 记下一台相机的热点凭据（同序列号覆盖）。
   *
   * 只留最近 8 台：相机数量不多，但持久化不该无限长；顺序按最近使用，
   * 覆盖时把这条挪到末尾。
   */
  save(serial: string, ssid: string, password: string, security: number,
       host: string): void {
    if (serial === '' || ssid === '') return;
    const next: WifiApCred = {
      serial: serial,
      ssid: ssid,
      password: password,
      security: security,
      host: host,
      updatedAt: Date.now()
    };
    const out: WifiApCred[] = [];
    for (const c of this.creds) {
      if (c.serial !== serial) out.push(c);
    }
    out.push(next);
    while (out.length > 8) {
      out.shift();
    }
    this.creds = out;
  }

  /** 忘记一台相机的热点凭据（解除配对时用）。 */
  forget(serial: string): void {
    if (serial === '') return;
    const out: WifiApCred[] = [];
    for (const c of this.creds) {
      if (c.serial !== serial) out.push(c);
    }
    if (out.length !== this.creds.length) this.creds = out;
  }
}
