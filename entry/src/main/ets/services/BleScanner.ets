import { ble, connection as btConnection, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NikonBlowfish } from './NikonBlowfish';
import { NikonPairing, decodePairingMessage } from './NikonPairing';

/** 扫描到的一台 BLE 相机。 */
export interface BleCameraDevice {
  deviceId: string;
  name: string;
  rssi: number;
}

/** 尼康智能设备模式的 GATT 服务（LSS / DE00 族）。 */
export const NIKON_BLE_SERVICE = '0000de00-3dd4-4255-8d62-6dc7b9bd5561';
export const NIKON_BLE_SERVICE_ALT = '0000de01-3dd4-4255-8d62-6dc7b9bd5561';
/** 配对认证特征（indicate，17 字节握手帧）。 */
export const NIKON_CHAR_PAIRING = '00002000-3dd4-4255-8d62-6dc7b9bd5561';
/** 标准 CCCD：开通知/指示必须带上它，否则 setCharacteristicChangeIndication 报 401。 */
const CCCD_UUID = '00002902-0000-1000-8000-00805f9b34fb';

function cccdDescriptor(charUuid: string, indicate: boolean): ble.BLEDescriptor {
  const value = new Uint8Array(2);
  value[0] = indicate ? 0x02 : 0x01;
  value[1] = 0x00;
  return {
    serviceUuid: NIKON_BLE_SERVICE,
    characteristicUuid: charUuid,
    descriptorUuid: CCCD_UUID,
    descriptorValue: value.buffer as ArrayBuffer
  };
}

interface PendingChar {
  uuid: string;
  resolve: (v: Uint8Array) => void;
  timer: number;
}

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
    try {
      ble.on('BLEDeviceFind', this.handleFind);
      // 空数组会被拒（401 Invalid parameter）；一个空 filter 对象表示「不过滤」。
      const filter: ble.ScanFilter = {};
      ble.startBLEScan([filter]);
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
  private readonly onState: (connected: boolean) => void;
  private pendingChar: PendingChar | null = null;
  connected: boolean = false;

  constructor(onLog: (msg: string) => void,
              onState: (connected: boolean) => void = (_c: boolean) => {}) {
    this.onLog = onLog;
    this.onState = onState;
  }

  /**
   * 系统蓝牙配对（bond）。
   *
   * 尼康相机的 BLE 要求先完成系统层绑定再开 GATT，否则 `connect()` 一直不
   * 回调（本项目实测：10 秒超时、没有任何状态事件）。ZPill 在 HarmonyOS 上
   * 的流程也是 `pairDevice` → 等 `BOND_STATE_BONDED` → `createGattClientDevice`。
   */
  private async bond(deviceId: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      let settled = false;
      const finish = (v: boolean): void => {
        if (settled) return;
        settled = true;
        resolve(v);
      };
      const cb = (param: btConnection.BondStateParam): void => {
        if (param.deviceId !== deviceId) return;
        this.onLog(`BLE 配对状态: ${param.state}`);
        if (param.state === btConnection.BondState.BOND_STATE_BONDED) {
          btConnection.off('bondStateChange', cb);
          finish(true);
        } else if (param.state !== btConnection.BondState.BOND_STATE_BONDING) {
          btConnection.off('bondStateChange', cb);
          finish(false);
        }
      };
      try {
        btConnection.on('bondStateChange', cb);
        btConnection.pairDevice(deviceId).catch((err: BusinessError) => {
          this.onLog(`pairDevice 失败: ${err.code} ${err.message}`);
          btConnection.off('bondStateChange', cb);
          finish(false);
        });
        setTimeout(() => {
          btConnection.off('bondStateChange', cb);
          this.onLog('BLE 配对超时');
          finish(false);
        }, 30000);
      } catch (err) {
        this.onLog(`pairDevice 异常: ${(err as BusinessError).message}`);
        finish(false);
      }
    });
  }

  /**
   * 连接一台相机。
   *
   * 顺序：**先 GATT 直连**（多数相机不要求系统绑定，8 秒内能连上），失败
   * 再走 `pairDevice` + 重连。之前是「先 bond 再 GATT」，bond 的 30 秒超时
   * 会把每次点击都拖成半分钟，UI 又没反馈，用户只能反复点，反而把刚连上
   * 的会话踢掉。
   */
  async connect(deviceId: string): Promise<boolean> {
    await this.disconnect();
    this.onLog(`BLE 直连 ${deviceId}`);
    if (await this.connectGatt(deviceId)) {
      return true;
    }
    this.onLog('BLE 直连失败，尝试系统配对后重连');
    const bonded = await this.bond(deviceId);
    this.onLog(bonded ? 'BLE 系统配对完成' : 'BLE 系统配对未完成');
    if (!bonded) {
      return false;
    }
    return await this.connectGatt(deviceId);
  }

  private async connectGatt(deviceId: string): Promise<boolean> {
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
            this.onLog(`BLE 连接状态: ${state.state}`);
            if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
              // 连上就请求 MTU：相机在发现服务前长时间收不到 MTU 请求会断链。
              try {
                gatt.setBLEMtuSize(517);
              } catch (_e) {
                // MTU 协商失败不阻断服务发现
              }
              this.connected = true;
              this.onState(true);
              // 服务发现要等 MTU 协商完；2 秒兜底，避免相机不回 BLEMtuChange
              // 时把连接判成失败。
              setTimeout(() => { finish(true); }, 2000);
            } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
              this.connected = false;
              this.onState(false);
              finish(false);
            }
          });
          gatt.on('BLEMtuChange', (mtu: number) => {
            this.onLog(`BLE MTU: ${mtu}`);
            finish(true);
          });
          gatt.on('BLECharacteristicChange', (data: ble.BLECharacteristic) => {
            const uuid = (data.characteristicUuid ?? '').toLowerCase();
            const value = new Uint8Array(data.characteristicValue);
            this.onLog(`BLE 通知 ${uuid} (${value.length}B)`);
            const pending = this.pendingChar;
            if (pending !== null && pending.uuid === uuid) {
              this.pendingChar = null;
              clearTimeout(pending.timer);
              pending.resolve(value);
            }
          });
          gatt.connect();
        } catch (err) {
          this.onLog(`BLE 连接异常: ${(err as BusinessError).message}`);
          finish(false);
        }
        setTimeout(() => {
          this.onLog('BLE 连接超时（10s 无状态事件）');
          finish(false);
        }, 10000);
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
    // 服务发现是异步的：刚连上/刚协商完 MTU 时 getServices 可能返回空，
    // 这里重试三次（间隔 600ms），拿到非空结果为止。
    for (let attempt = 0; attempt < 3; attempt++) {
      const gatt = this.gatt;
      if (gatt === null) return [];
      try {
        const services = await gatt.getServices();
        if (services.length > 0) {
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
        }
      } catch (err) {
        this.onLog(`BLE 取服务失败(${attempt + 1}/3): ${(err as BusinessError).message}`);
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 600);
      });
    }
    this.onLog('BLE 服务枚举为空（3 次重试均无结果）');
    return [];
  }

  /** 打开某个特征的 indicate（0x2000 配对用 indicate，不是 notify）。 */
  async enableIndication(charUuid: string): Promise<void> {
    const gatt = this.gatt;
    if (gatt === null) throw new Error('BLE 未连接');
    const char: ble.BLECharacteristic = {
      serviceUuid: NIKON_BLE_SERVICE,
      characteristicUuid: charUuid,
      characteristicValue: new Uint8Array(0).buffer as ArrayBuffer,
      descriptors: [cccdDescriptor(charUuid, true)]
    };
    await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        reject(new Error('indicate 开启超时'));
      }, 5000);
      gatt.setCharacteristicChangeIndication(char, true, (err: BusinessError) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (err) {
          reject(new Error(`indicate ${err.code}: ${err.message}`));
        } else {
          resolve();
        }
      });
    });
  }

  /** 写一个特征值（带响应）。 */
  async writeCharacteristic(charUuid: string, value: Uint8Array): Promise<void> {
    const gatt = this.gatt;
    if (gatt === null) throw new Error('BLE 未连接');
    const char: ble.BLECharacteristic = {
      serviceUuid: NIKON_BLE_SERVICE,
      characteristicUuid: charUuid,
      characteristicValue: value.slice().buffer as ArrayBuffer,
      descriptors: []
    };
    await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        reject(new Error('写特征超时'));
      }, 5000);
      gatt.writeCharacteristicValue(char, ble.GattWriteType.WRITE, (err: BusinessError) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (err) {
          reject(new Error(`write ${err.code}: ${err.message}`));
        } else {
          resolve();
        }
      });
    });
  }

  /** 等某个特征的下一次通知/指示。 */
  waitCharacteristic(charUuid: string, timeoutMs: number): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve: (v: Uint8Array) => void,
                                    reject: (e: Error) => void) => {
      const key = charUuid.toLowerCase();
      const timer = setTimeout(() => {
        const pending = this.pendingChar;
        if (pending !== null && pending.uuid === key) {
          this.pendingChar = null;
        }
        reject(new Error('等待特征通知超时'));
      }, timeoutMs);
      this.pendingChar = { uuid: key, resolve: resolve, timer: timer };
    });
  }

  /**
   * 四步配对（0x2000，indicate）。
   *
   * 先跑 Blowfish 标准向量自测，再用尼康定键 CBC-MAC 走 stage1 → 2 → 3 → 4。
   * 成功后相机把本客户端记为已配对主机，stage4 的字节 9–16 是相机序列号。
   */
  async pair(): Promise<string | null> {
    try {
      return await this.pairInternal();
    } catch (err) {
      this.onLog(`配对异常: ${(err as Error).message}`);
      return null;
    }
  }

  private async pairInternal(): Promise<string | null> {
    const blowfish = new NikonBlowfish(this.onLog);
    if (!await blowfish.selfTest()) {
      this.onLog('配对: Blowfish 自测失败，终止');
      return null;
    }
    const pairing = new NikonPairing(blowfish, this.onLog);
    const stage1 = pairing.createStage1();
    this.onLog('配对: 开启 0x2000 indicate');
    await this.enableIndication(NIKON_CHAR_PAIRING);
    this.onLog('配对: indicate 已开启');
    const stage2Promise = this.waitCharacteristic(NIKON_CHAR_PAIRING, 15000);
    await this.writeCharacteristic(NIKON_CHAR_PAIRING, stage1.raw);
    this.onLog('配对: stage1 已发送');
    const stage2raw = await stage2Promise;
    const stage2 = decodePairingMessage(stage2raw);
    this.onLog(`配对: stage2 stage=${stage2.stage} len=${stage2raw.length}`);
    const result = await pairing.verifyStage2AndBuildStage3(stage1, stage2);
    if (result === null) {
      return null;
    }
    const stage4Promise = this.waitCharacteristic(NIKON_CHAR_PAIRING, 15000);
    await this.writeCharacteristic(NIKON_CHAR_PAIRING, result.message.raw);
    this.onLog('配对: stage3 已发送');
    const stage4raw = await stage4Promise;
    const stage4 = decodePairingMessage(stage4raw);
    const serial = pairing.extractSerial(stage4);
    this.onLog(`配对完成: 相机序列号 ${serial}`);
    return serial;
  }

  async disconnect(): Promise<void> {
    const gatt = this.gatt;
    const wasConnected = this.connected;
    this.gatt = null;
    this.connected = false;
    if (wasConnected) {
      this.onState(false);
    }
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
