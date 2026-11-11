import { ble, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 扫描到的一台 BLE 相机。 */
export interface BleCameraDevice {
  deviceId: string;
  name: string;
  rssi: number;
}

/** 尼康智能设备模式的 GATT 服务（LSS / DE00 族）。 */
export const NIKON_BLE_SERVICE = '0000de00-3dd4-4255-8d62-6dc7b9bd5561';
export const NIKON_BLE_SERVICE_ALT = '0000de01-3dd4-4255-8d62-6dc7b9bd5561';

/**
 * 判断广播名是不是尼康相机。
 *
 * 相机广播名形如 `Z50_2_8079350`、`Z_f_8014411`、`Z_8_...`，都以 `Z` 开头、
 * 含下划线。**不能只按服务 UUID 过滤**：ZPill 实测相机在等待配对时广播里
 * 不带 `0x0399`（服务 UUID），按服务过滤会直接扫不到。
 */
function looksLikeNikon(name: string): boolean {
  if (name.length < 3) return false;
  const upper = name.toUpperCase();
  if (!upper.startsWith('Z')) return false;
  return name.includes('_') || /^Z\d/.test(upper);
}

/**
 * BLE 扫描器。
 *
 * 只负责发现，不做配对——配对算法（Blowfish 四步握手）是下一步。
 * 扫描用空过滤（扫全部），收到结果后再按广播名筛，避免漏掉「等待配对」
 * 状态下不带服务 UUID 的相机。
 */
export class BleScanner {
  private readonly onFound: (device: BleCameraDevice) => void;
  private readonly onLog: (msg: string) => void;
  private scanning: boolean = false;
  private readonly seen: Set<string> = new Set();

  private readonly handleFind = (results: Array<ble.ScanResult>): void => {
    for (const result of results) {
      const id = result.deviceId;
      if (this.seen.has(id)) continue;
      const name = result.deviceName ?? '';
      if (!looksLikeNikon(name)) continue;
      this.seen.add(id);
      this.onLog(`BLE 发现: ${name} (${id}) rssi=${result.rssi}`);
      this.onFound({ deviceId: id, name: name, rssi: result.rssi });
    }
  };

  constructor(onFound: (device: BleCameraDevice) => void,
              onLog: (msg: string) => void) {
    this.onFound = onFound;
    this.onLog = onLog;
  }

  start(): void {
    if (this.scanning) return;
    this.scanning = true;
    this.seen.clear();
    const options: ble.ScanOptions = {
      interval: 0,
      dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
      matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
    };
    try {
      ble.on('BLEDeviceFind', this.handleFind);
      ble.startBLEScan([], options);
      this.onLog('BLE 开始扫描');
    } catch (err) {
      this.scanning = false;
      this.onLog(`BLE 扫描启动失败: ${(err as BusinessError).message}`);
    }
  }

  stop(): void {
    if (!this.scanning) return;
    this.scanning = false;
    try {
      ble.stopBLEScan();
    } catch (_e) {
      // 已经停了
    }
    try {
      ble.off('BLEDeviceFind', this.handleFind);
    } catch (_e) {
      // 取消订阅失败不影响
    }
    this.onLog('BLE 停止扫描');
  }
}

/**
 * 一台相机的 GATT 连接。
 *
 * 只做到「连上 + 列出服务/特征」，读写特征值和配对留到下一步。这一步用来
 * 确认三件事：BLE 广播可见、服务是 `de00` 族、`0x2009` 能力位能读到。
 */
export class BleCameraLink {
  private gatt: ble.GattClientDevice | null = null;
  private readonly onLog: (msg: string) => void;
  connected: boolean = false;

  constructor(onLog: (msg: string) => void) {
    this.onLog = onLog;
  }

  async connect(deviceId: string): Promise<boolean> {
    await this.disconnect();
    try {
      const gatt = ble.createGattClientDevice(deviceId);
      this.gatt = gatt;
      const ok = await new Promise<boolean>((resolve: (v: boolean) => void) => {
        let settled = false;
        const finish = (v: boolean): void => {
          if (settled) return;
          settled = true;
          resolve(v);
        };
        try {
          gatt.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
            if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
              finish(true);
            } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
              this.connected = false;
              finish(false);
            }
          });
          gatt.connect();
        } catch (err) {
          this.onLog(`BLE 连接异常: ${(err as BusinessError).message}`);
          finish(false);
        }
        setTimeout(() => { finish(false); }, 10000);
      });
      this.connected = ok;
      if (ok) {
        this.onLog(`BLE 已连接 ${deviceId}`);
      }
      return ok;
    } catch (err) {
      this.onLog(`BLE 连接失败: ${(err as BusinessError).message}`);
      return false;
    }
  }

  /** 列出服务与特征 UUID，用于确认相机 GATT 结构。 */
  async listServices(): Promise<string[]> {
    const gatt = this.gatt;
    if (gatt === null) return [];
    try {
      const services = await gatt.getServices();
      const lines: string[] = [];
      for (const service of services) {
        const chars = service.characteristics ?? [];
        lines.push(`${service.serviceUuid} (${chars.length} 个特征)`);
        for (const ch of chars) {
          lines.push(`  ${ch.characteristicUuid}`);
        }
      }
      this.onLog(`BLE 服务: ${lines.length} 行`);
      return lines;
    } catch (err) {
      this.onLog(`BLE 取服务失败: ${(err as BusinessError).message}`);
      return [];
    }
  }

  async disconnect(): Promise<void> {
    const gatt = this.gatt;
    this.gatt = null;
    this.connected = false;
    if (gatt === null) return;
    try {
      gatt.disconnect();
    } catch (_e) {
      // 已断开
    }
    try {
      gatt.close();
    } catch (_e) {
      // 已关闭
    }
  }
}
