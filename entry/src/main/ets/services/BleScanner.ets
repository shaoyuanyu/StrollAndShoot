import { ble, connection as btConnection, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NikonBlowfish } from './NikonBlowfish';
import { BleTimePayload, BleGeoPayload, type BleGeoFix } from './BlePayloads';
import { NikonPairing, decodePairingMessage, type PairingMessage } from './NikonPairing';
import { decodeWifiCredentials, type LssHandshakeMaterial,
  type WifiCredentials } from './NikonWifiCredentials';
import { BleIdentityStore } from './BleIdentityStore';

/** 扫描到的一台 BLE 相机。 */
export interface BleCameraDevice {
  deviceId: string;
  name: string;
  rssi: number;
  /** 广播厂商数据（公司 ID 0x0399）里的尼康 deviceId，没带就是 0。 */
  nikonDeviceId: number;
}

/** 尼康在 BLE 厂商数据里用的公司 ID。 */
const NIKON_COMPANY_ID = 0x0399;

/** 尼康智能设备模式的 GATT 服务（LSS / DE00 族）。 */
export const NIKON_BLE_SERVICE = '0000de00-3dd4-4255-8d62-6dc7b9bd5561';
export const NIKON_BLE_SERVICE_ALT = '0000de01-3dd4-4255-8d62-6dc7b9bd5561';
/** 配对认证特征（indicate，17 字节握手帧）。 */
export const NIKON_CHAR_PAIRING = '00002000-3dd4-4255-8d62-6dc7b9bd5561';
/** 标准 CCCD：开通知/指示必须带上它，否则 setCharacteristicChangeIndication 报 401。 */
const CCCD_UUID = '00002902-0000-1000-8000-00805f9b34fb';
/** LSS 控制点：2B 位域 (Connection<<8)|(Location<<4)|Time，相机 notify 请求。 */
export const NIKON_CHAR_CONTROL = '00002008-3dd4-4255-8d62-6dc7b9bd5561';
/** 电池：连接后读一次做「唤醒 poke」，相机半睡时不回 stage2。 */
export const NIKON_CHAR_BATTERY = '00002a19-3dd4-4255-8d62-6dc7b9bd5561';
/** 控制器名（32B ASCII 零填充，配对收口用）。 */
export const NIKON_CHAR_NAME = '00002002-3dd4-4255-8d62-6dc7b9bd5561';
/** 相机 Wi-Fi 凭据（只读 97B，配对完成后才非空）。 */
export const NIKON_CHAR_CONFIG = '00002004-3dd4-4255-8d62-6dc7b9bd5561';
/** 连接建立（写 1B：0x01 唤起相机无线，0x80 关闭）。 */
export const NIKON_CHAR_ESTABLISH = '00002005-3dd4-4255-8d62-6dc7b9bd5561';
/** 校时（10B，兼保活心跳）。 */
export const NIKON_CHAR_TIME = '00002006-3dd4-4255-8d62-6dc7b9bd5561';
/** 位置（41B）。 */
export const NIKON_CHAR_GEO = '00002007-3dd4-4255-8d62-6dc7b9bd5561';

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

  /**
   * 只收这个尼康 deviceId 的相机（0 = 不限，按名字筛）。
   *
   * 相机休眠后广播里往往**没有名字**，只剩厂商数据，所以重连不能只靠
   * `looksLikeNikon(name)` —— 那会一个都扫不到。
   */
  private readonly filterDeviceId: number;

  private readonly handleFind = (results: Array<ble.ScanResult>): void => {
    for (const result of results) {
      const id = result.deviceId;
      if (this.seen.has(id)) continue;
      const name = result.deviceName ?? '';
      const nikonDeviceId = BleScanner.parseNikonDeviceId(result.manufacturerDataMap);
      const nameHit = looksLikeNikon(name);
      const idHit = this.filterDeviceId !== 0 && nikonDeviceId === this.filterDeviceId;
      if (!nameHit && !idHit) continue;
      this.seen.add(id);
      this.onLog(`BLE 发现: ${name === '' ? '(无名)' : name} (${id}) rssi=${result.rssi}`
        + (nikonDeviceId !== 0 ? ` deviceId=${nikonDeviceId}` : ''));
      this.onFound({ deviceId: id, name: name, rssi: result.rssi, nikonDeviceId: nikonDeviceId });
    }
  };

  constructor(onFound: (device: BleCameraDevice) => void,
              onLog: (msg: string) => void,
              filterDeviceId: number = 0) {
    this.onFound = onFound;
    this.onLog = onLog;
    this.filterDeviceId = filterDeviceId;
  }

  /** 从厂商数据解析尼康 deviceId（小端 u32；解析不出来返回 0）。 */
  static parseNikonDeviceId(map: Map<number, Uint8Array> | undefined): number {
    if (map === undefined || map === null) return 0;
    const raw = map.get(NIKON_COMPANY_ID);
    if (raw === undefined || raw === null || raw.length < 4) return 0;
    return (raw[0] | (raw[1] << 8) | (raw[2] << 16) | (raw[3] << 24)) >>> 0;
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
  private keepaliveTimer: number = -1;
  /** 配对握手是否已完成（只有完成后才应答 0x2008）。 */
  private paired: boolean = false;
  connected: boolean = false;
  /** 当前连接的 BLE 地址，断链重连时要用。 */
  private deviceId: string = '';
  /** 相机 BLE 广播名，经典蓝牙发现时按它匹配（经典名与 BLE 名不同形）。 */
  private cameraName: string = '';
  /** 段 1 确定的客户端身份：重连后必须用同一份 device/nonce 复用握手。 */
  private identityDevice: number = 0;
  private identityNonce: number = 0;
  private identitySerial: string = '';
  /** 最近一次成功握手的材料，`0x2004` 会话密钥要从这里派生。 */
  private material: LssHandshakeMaterial | null = null;
  /** 解出来的相机热点凭据（AP 模式用；STA 模式下仅作「配对被相机认可」的凭据）。 */
  private credentials: WifiCredentials | null = null;

  /**
   * 用户取消标记。
   *
   * 配对流程有「断链 → 经典绑定 → 回链」好几段，中途点「取消连接」时如果
   * 不做标记，`reconnectForResume` 会把链路又接回来。每个关键 await 之后
   * 都要查一次。
   */
  private cancelled: boolean = false;
  /** 断链自动重连开关（用户主动断开时要关掉，否则会自己爬起来）。 */
  private autoReconnect: boolean = false;
  private reconnecting: boolean = false;
  private reconnectTimer: number = -1;
  private backoffIndex: number = 0;
  private readonly backoffMs: number[] = [2000, 3000, 5000, 8000, 12000, 20000, 30000];
  /** 重连成功后的回调（上层用它恢复校时与保活）。 */
  onReconnected: (serial: string) => void = (_s: string) => {};
  /** 重连状态变化（true = 正在重连），上层用它驱动 UI 文案。 */
  onReconnecting: (reconnecting: boolean) => void = (_v: boolean) => {};

  constructor(onLog: (msg: string) => void,
              onState: (connected: boolean) => void = (_c: boolean) => {}) {
    this.onLog = onLog;
    this.onState = onState;
  }

  /**
   * 程序化经典蓝牙绑定（首配注册的关键一步）。
   *
   * 鸿蒙上的机制（ZPill 2026-10-22 真机定案，本节照抄它的剧本）：
   *
   * 1. **必须先用 `startBluetoothDiscovery` 做经典蓝牙发现**，从发现结果里
   *    拿相机的经典地址。直接拿 BLE 的 deviceId 调 `pairDevice` 会永远卡在
   *    BONDING（BLE 虚拟地址不是经典地址，系统找不到设备）—— 本项目实测
   *    两次 `BLE 配对状态: 1` 后 12 秒超时，就是这个原因。
   * 2. 匹配按名字（下划线归一后互含）或序列号，防止配到兄弟机身。
   * 3. **必须在 BLE 断开之后做**：相机要等 BLE 链路释放才在配对态暴露经典
   *    蓝牙。首测零缓冲直发配对会把相机射频楔死，只能杀应用。
   */
  private bondClassic(cameraName: string, serial: string,
                      timeoutMs: number = 25000): Promise<boolean> {
    this.onLog(`BLE 经典发现（匹配名「${cameraName}」序列号「${serial}」）`);
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      let matched = false;
      let settled = false;
      const finish = (v: boolean): void => {
        if (settled) return;
        settled = true;
        try {
          btConnection.off('discoveryResult', discoverCb);
        } catch (_e) {
          // 已注销
        }
        resolve(v);
      };
      const norm = (s: string): string => s.replace(/_/g, '').toLowerCase();
      const calcHit = (devName: string): boolean => {
        if (devName.length === 0) return false;
        const d = norm(devName);
        if (cameraName.length > 0) {
          const n = norm(cameraName);
          if (d.includes(n) || n.includes(d)) return true;
        }
        if (serial.length > 0) {
          const s = norm(serial.replace(/-/g, ''));
          if (s.length > 0 && d.includes(s)) return true;
        }
        return false;
      };
      const discoverCb = (data: Array<btConnection.DiscoveryResult>): void => {
        if (matched) return;
        for (const dev of data) {
          const devName = dev.deviceName ?? '';
          const addr = dev.deviceId ?? '';
          if (addr.length === 0) continue;
          this.onLog(`经典发现: ${devName} (${addr})`);
          if (!calcHit(devName)) continue;
          matched = true;
          this.onLog(`经典发现命中 ${devName} ${addr}`);
          try {
            btConnection.stopBluetoothDiscovery();
          } catch (_e) {
            // 发现已停
          }
          this.startBond(addr, timeoutMs, finish);
          return;
        }
      };
      try {
        btConnection.on('discoveryResult', discoverCb);
        btConnection.startBluetoothDiscovery();
      } catch (err) {
        this.onLog(`经典发现启动失败: ${(err as BusinessError).message}`);
        finish(false);
        return;
      }
      setTimeout(() => {
        if (matched) return;
        this.onLog('经典发现超时（未匹配到相机）');
        try {
          btConnection.stopBluetoothDiscovery();
        } catch (_e) {
          // 发现已停
        }
        finish(false);
      }, timeoutMs);
    });
  }

  /** 对已发现的经典地址发起配对，等 BONDED。 */
  private startBond(addr: string, timeoutMs: number, finish: (v: boolean) => void): void {
    let done = false;
    const settle = (v: boolean): void => {
      if (done) return;
      done = true;
      try {
        btConnection.off('bondStateChange', stateCb);
      } catch (_e) {
        // 已注销
      }
      finish(v);
    };
    const stateCb = (param: btConnection.BondStateParam): void => {
      if (param.deviceId !== addr) return;
      this.onLog(`经典绑定状态: ${param.state}`);
      if (param.state === btConnection.BondState.BOND_STATE_BONDED) {
        settle(true);
      } else if (param.state !== btConnection.BondState.BOND_STATE_BONDING) {
        settle(false);
      }
    };
    try {
      // 先挂监听再发配对：BONDED 可能秒回，后挂会丢事件。
      btConnection.on('bondStateChange', stateCb);
      btConnection.pairDevice(addr).catch((err: BusinessError) => {
        this.onLog(`pairDevice 被拒: ${err.code} ${err.message}`);
        settle(false);
      });
    } catch (err) {
      this.onLog(`pairDevice 异常: ${(err as BusinessError).message}`);
      settle(false);
      return;
    }
    setTimeout(() => {
      if (!done) {
        this.onLog(`经典绑定超时（${Math.round(timeoutMs / 1000)}s）`);
      }
      settle(false);
    }, timeoutMs);
  }

  /**
   * 连接一台相机。
   *
   * 顺序：GATT 直连，失败再走经典绑定 + 重连。
   *
   * **不要在 GATT 连接状态下调用 `pairDevice`**：那是 BLE 虚拟地址，系统
   * 找不到对应的经典设备，pairDevice 会一直停在 BONDING 直到超时。经典
   * 绑定只在 BLE 断开之后、由 `pair()` 的段 2 发起。
   */
  async connect(deviceId: string): Promise<boolean> {
    await this.disconnect();
    this.deviceId = deviceId;
    this.onLog(`BLE 直连 ${deviceId}`);
    if (await this.connectGatt(deviceId)) {
      return true;
    }
    this.onLog('BLE 直连失败');
    return false;
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
              const wasConnected = this.connected;
              this.connected = false;
              this.onState(false);
              finish(false);
              // 只对「曾经连上过」的断链排重连；初始连接失败有自己的路径。
              if (wasConnected && !this.reconnecting) {
                this.scheduleReconnect();
              }
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
            if (uuid === NIKON_CHAR_CONTROL) {
              this.handleControlPoint(value);
            }
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
          if (settled) return;
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

  /** 开启某个特征的 notify（0x2008 用 notify，不是 indicate）。 */
  async enableNotification(charUuid: string): Promise<void> {
    const gatt = this.gatt;
    if (gatt === null) throw new Error('BLE 未连接');
    const char: ble.BLECharacteristic = {
      serviceUuid: NIKON_BLE_SERVICE,
      characteristicUuid: charUuid,
      characteristicValue: new Uint8Array(0).buffer as ArrayBuffer,
      descriptors: [cccdDescriptor(charUuid, false)]
    };
    await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        reject(new Error('notify 开启超时'));
      }, 5000);
      gatt.setCharacteristicChangeNotification(char, true, (err: BusinessError) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (err) {
          reject(new Error(`notify ${err.code}: ${err.message}`));
        } else {
          resolve();
        }
      });
    });
  }

  /** 读一个特征值。 */
  async readCharacteristic(charUuid: string): Promise<Uint8Array | null> {
    const gatt = this.gatt;
    if (gatt === null) return null;
    const char: ble.BLECharacteristic = {
      serviceUuid: NIKON_BLE_SERVICE,
      characteristicUuid: charUuid,
      characteristicValue: new Uint8Array(0).buffer as ArrayBuffer,
      descriptors: []
    };
    const out = await new Promise<ble.BLECharacteristic>(
      (resolve: (v: ble.BLECharacteristic) => void, reject: (e: Error) => void) => {
        let settled = false;
        const timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          reject(new Error('read 超时'));
        }, 1500);
        gatt.readCharacteristicValue(char).then((value: ble.BLECharacteristic) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(value);
        }).catch((err: BusinessError) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          reject(new Error(`read ${err.code}: ${err.message}`));
        });
      });
    return new Uint8Array(out.characteristicValue);
  }

  /**
   * 0x2008 位域：`(Connection<<8)|(Location<<4)|Time`。
   *
   * 相机在 notify 里「要时间/位置/连接」，app 供给后写回清位值确认。
   * 只在配对完成后应答——配对事务内写 0x2008 会搅坏注册（ZPill 实测）。
   */
  private handleControlPoint(data: Uint8Array): void {
    if (data.length !== 2) return;
    const raw = data[0] | (data[1] << 8);
    const time = data[0] & 0x0F;
    const loc = (data[0] >> 4) & 0x0F;
    const conn = data[1] & 0x0F;
    this.onLog(`0x2008 ← 0x${raw.toString(16)} (Time=${time} Loc=${loc} Conn=${conn})`);
    if (!this.paired) {
      this.onLog('0x2008 配对未完成，暂不应答');
      return;
    }
    let answer = raw;
    if (time >= 1) answer &= ~0x000F;
    if (loc >= 1) answer &= ~0x00F0;
    if (conn >= 1) answer &= ~0x0100;
    if (answer === raw) return;
    const payload = new Uint8Array(2);
    payload[0] = answer & 0xFF;
    payload[1] = (answer >> 8) & 0xFF;
    this.writeCharacteristic(NIKON_CHAR_CONTROL, payload).then(() => {
      this.onLog(`0x2008 清位应答 0x${answer.toString(16)}`);
    }).catch((err: Error) => {
      this.onLog(`0x2008 应答失败: ${err.message}`);
    });
  }

  /**
   * 读一组已知的关键特征，用于确认读权限并触发相机收口配对。
   *
   * 不遍历全表：HarmonyOS 的 `getServices()` 返回的特征没有可靠的
   * `properties` 字段（实测全被过滤成 0 个），逐个试读又会被只写特征拖到
   * 超时。这里只读 8 个确定有 read 权限的。
   */
  async readKeyCharacteristics(): Promise<number> {
    if (this.gatt === null) return 0;
    const keys: string[] = [
      '00002003-3dd4-4255-8d62-6dc7b9bd5561', // 相机名
      '00002004-3dd4-4255-8d62-6dc7b9bd5561', // 连接配置
      '00002009-3dd4-4255-8d62-6dc7b9bd5561', // LSS 能力位
      '0000200b-3dd4-4255-8d62-6dc7b9bd5561', // 序列号
      '00002a19-3dd4-4255-8d62-6dc7b9bd5561', // 电池
      '00002a24-0000-1000-8000-00805f9b34fb', // 型号
      '00002a26-0000-1000-8000-00805f9b34fb', // 固件
      '00002a29-0000-1000-8000-00805f9b34fb'  // 厂商
    ];
    let count = 0;
    for (const uuid of keys) {
      // 官方错误码 2900099 的一个明确成因是「前一个非监听类 BLE 接口没回调完
      // 就发下一次读写」。连续 8 个 read 打出去会全部撞在这个坑上（实测 0/8），
      // 所以每次读之间留间隔，失败再退避重试。
      await BleCameraLink.sleep(150);
      const value = await this.readCharacteristicRetry(uuid, 3);
      if (value !== null) {
        count++;
        this.onLog(`读特征 ${uuid.slice(4, 8)} → ${value.length}B`
          + BleCameraLink.describeBytes(value));
      }
    }
    this.onLog(`关键特征读取完成: ${count}/${keys.length}`);
    return count;
  }

  /** 读一个特征，失败按 300ms 退避重试 [attempts] 次。 */
  private async readCharacteristicRetry(uuid: string, attempts: number): Promise<Uint8Array | null> {
    let last = '';
    for (let i = 0; i < attempts; i++) {
      try {
        const value = await this.readCharacteristic(uuid);
        if (value !== null) return value;
        last = 'null';
      } catch (err) {
        last = (err as Error).message;
      }
      await BleCameraLink.sleep(300);
    }
    this.onLog(`读特征 ${uuid.slice(4, 8)} 失败(${attempts} 次): ${last}`);
    return null;
  }

  /** 前几个字节的十六进制摘要，日志排障用。 */
  private static describeBytes(value: Uint8Array): string {
    const n = Math.min(value.length, 8);
    let hex = '';
    for (let i = 0; i < n; i++) {
      hex += (value[i] < 16 ? '0' : '') + value[i].toString(16) + ' ';
    }
    return ` [${hex.trim()}]`;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 读相机 Wi-Fi 凭据（0x2004 CONNECTION_CONFIGURATION，97B：32B SSID +
   * 64B 密码 + 1B 安全类型）。
   *
   * 这个特征是**会话激活**的：相机认为本次 BLE 会话已配对完成才会返回内容，
   * 未配对时读空/报错。所以它同时也是「相机侧到底认不认这次配对」的黄金
   * 指标 —— 比任何日志推断都可靠。
   */
  async readConnectionConfig(): Promise<Uint8Array | null> {
    return await this.readCharacteristicRetry(NIKON_CHAR_CONFIG, 3);
  }

  /**
   * 写连接建立（0x2005，1 字节：0x01 唤起相机 Wi-Fi，0x80 关闭）。
   *
   * SnapBridge 在 BLE 配对收口后立刻写 0x2005=0x01 唤起相机无线；相机在
   * 「开始配对」页停留时不认任何只写名字的连接，这一笔才是让它真正收口的
   * 动作（ZPill 的 `wakeCameraWifi`、N-link 的 `0x2005` 同义）。
   */
  async writeEstablishment(value: number): Promise<void> {
    await this.writeCharacteristic(NIKON_CHAR_ESTABLISH, new Uint8Array([value]));
  }

  /**
   * 关掉相机无线（`0x2005 = 0x80`）。
   *
   * 与 `0x01` 是对称的反义操作（ZPill 的 `closeCameraWifi` 同款）。以前只写
   * 开不写关，用户断开相机之后相机热点还一直开着耗电。
   *
   * **只在用户明确「断开相机」时调**：STA 模式下这一笔会让相机退出网络，
   * 顺手把 PTP 会话也断掉。
   */
  async closeCameraWifi(): Promise<void> {
    try {
      await this.writeEstablishment(0x80);
      this.onLog('0x2005=0x80 已写（关闭相机无线）');
    } catch (err) {
      this.onLog(`0x2005 关闭失败: ${(err as Error).message}`);
    }
  }

  /** 写一次相机时钟（0x2006）。 */
  async writeTime(offsetMinutes: number): Promise<void> {
    const payload = BleTimePayload.build(new Date(), offsetMinutes);
    await this.writeCharacteristic(NIKON_CHAR_TIME, payload);
  }

  /** 写一次位置（0x2007）。 */
  async writeLocation(fix: BleGeoFix): Promise<void> {
    const payload = BleGeoPayload.build(fix);
    await this.writeCharacteristic(NIKON_CHAR_GEO, payload);
  }

  /**
   * 保活：每 [intervalMs] 写一次 0x2006（内容就是当前时刻，顺带持续校时）。
   *
   * 相机 2 分钟没有 BLE 流量会断链，45 秒一拍留足余量。位置由
   * [fixProvider] 提供，拿到就一起写；拿不到只写时间。
   */
  startKeepalive(intervalMs: number, offsetMinutes: number,
                 fixProvider: () => BleGeoFix | null): void {
    this.stopKeepalive();
    this.keepaliveTimer = setInterval(() => {
      this.writeTime(offsetMinutes).then(() => {
        const fix = fixProvider();
        if (fix !== null) {
          return this.writeLocation(fix);
        }
        return Promise.resolve();
      }).catch((err: Error) => {
        this.onLog(`BLE 保活失败: ${err.message}`);
      });
    }, intervalMs);
  }

  stopKeepalive(): void {
    if (this.keepaliveTimer >= 0) {
      clearInterval(this.keepaliveTimer);
      this.keepaliveTimer = -1;
    }
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
   * 配对入口。
   *
   * 有落盘身份 → **只做复用握手**（相机只认这一份 device/nonce，发全新
   * stage1 会被 `Remote device has an error` 秒拒）。
   * 没有身份 → 两段式首配（段 1 握手 + 经典蓝牙绑定 + 段 2 复用握手）。
   */
  async pair(cameraName: string = ''): Promise<string | null> {
    this.cancelled = false;
    try {
      const store = BleIdentityStore.getInstance();
      if (store.hasIdentity()) {
        return await this.resumePairing(store);
      }
      return await this.pairFresh(cameraName, store);
    } catch (err) {
      this.onLog(`配对异常: ${(err as Error).message}`);
      return null;
    }
  }

  /** 已配对相机的重连：用保存的身份复用握手，不再打扰相机的配对页。 */
  private async resumePairing(store: BleIdentityStore): Promise<string | null> {
    this.onLog(`配对: 已有身份（serial ${store.serial}），走复用握手`);
    const blowfish = new NikonBlowfish(this.onLog);
    if (!await blowfish.selfTest()) {
      this.onLog('配对: Blowfish 自测失败，终止');
      return null;
    }
    const pairing = new NikonPairing(blowfish, this.onLog);
    const stage1 = pairing.createStage1(store.identityDevice, store.identityNonce);
    const serial = await this.handshake(pairing, stage1, true);
    if (serial === null) {
      this.onLog('配对: 复用握手失败。若相机里已删掉本设备，请在相机菜单重新进入配对页后再连');
      return null;
    }
    this.identityDevice = store.identityDevice;
    this.identityNonce = store.identityNonce;
    this.identitySerial = serial.length > 0 ? serial : store.serial;
    await this.writeControllerName();
    // 复用握手也要唤起相机无线。以前只有首配写这一笔，于是相机休眠/重开之后
    // 走 resume 的路径上相机无线一直是关着的：BLE 全绿、PTP 永远连不上。
    try {
      await BleCameraLink.sleep(200);
      await this.writeEstablishment(0x01);
      this.onLog('配对: 0x2005=0x01 已写（复用握手后唤起相机无线）');
    } catch (err) {
      this.onLog(`配对: 0x2005 写入失败: ${(err as Error).message}`);
    }
    // 相机有没有真正收下，看 0x2004 给不给内容。
    await BleCameraLink.sleep(300);
    await this.logConnectionConfig();
    this.paired = true;
    this.onLog(`配对完成: 复用握手通过，相机序列号 ${this.identitySerial}`);
    return this.identitySerial;
  }

  private async pairFresh(cameraName: string, store: BleIdentityStore): Promise<string | null> {
    const blowfish = new NikonBlowfish(this.onLog);
    if (!await blowfish.selfTest()) {
      this.onLog('配对: Blowfish 自测失败，终止');
      return null;
    }
    this.cameraName = cameraName;
    const pairing = new NikonPairing(blowfish, this.onLog);

    // ---------- 段 1 ----------
    const stage1 = pairing.createStage1();
    const serial = await this.handshake(pairing, stage1);
    if (serial === null) {
      return null;
    }
    // 身份留在本对象里，段 2 的复用握手与之后的保活都用它。
    this.identityDevice = stage1.device;
    this.identityNonce = stage1.nonce;
    this.identitySerial = serial;

    await this.writeControllerName();
    try {
      await BleCameraLink.sleep(200);
      await this.writeEstablishment(0x01);
      this.onLog('配对: 0x2005=0x01 已写（唤起相机无线）');
    } catch (err) {
      this.onLog(`配对: 0x2005 写入失败: ${(err as Error).message}`);
    }
    if (this.cancelled) {
      this.onLog('配对: 用户已取消');
      return null;
    }

    // ---------- 断链让位 + 经典绑定 ----------
    // 相机要等 BLE 释放才暴露经典蓝牙；让位窗太短会把相机射频楔死。
    this.onLog('配对: 段 1 完成，断开 BLE 让相机暴露经典蓝牙');
    await this.disconnect();
    await BleCameraLink.sleep(3000);
    if (this.cancelled) {
      this.onLog('配对: 用户已取消（经典绑定未做）');
      return null;
    }
    const bonded = await this.bondClassic(this.cameraName, serial);
    this.onLog(bonded
      ? '配对: 经典蓝牙绑定完成'
      : '配对: 经典蓝牙绑定未完成（继续尝试回链）');
    await BleCameraLink.sleep(1200);
    if (this.cancelled) {
      this.onLog('配对: 用户已取消（不回链）');
      return null;
    }

    // ---------- 段 2：重连 + 复用握手 ----------
    const reconnected = await this.reconnectForResume();
    if (!reconnected) {
      this.onLog('配对: 回链失败，绑定后的注册未能落地');
      return serial;
    }
    const stage1b = pairing.createStage1(this.identityDevice, this.identityNonce);
    const serial2 = await this.handshake(pairing, stage1b, true);
    if (serial2 === null) {
      // 段 2 没跑通 = 注册没落地。身份仍留在内存里，但先不落盘，
      // 免得下次拿一份相机没认的身份去复用，永远握不上。
      this.onLog('配对: 段 2 复用握手未完成，配对未落地（下次仍需在相机上重新配对）');
      return null;
    }
    if (serial2.length > 0) {
      this.identitySerial = serial2;
    }
    await this.writeControllerName();

    // 身份落盘：之后每次连接都走复用握手，不再打扰相机配对页。
    store.save(this.deviceId, this.cameraName, this.identityDevice,
      this.identityNonce, this.identitySerial);
    this.onLog(`配对: 身份已落盘（serial ${this.identitySerial}）`);

    // 相机认不认这次配对，看 0x2004 给不给内容（102B = LSS 全布局）。
    await BleCameraLink.sleep(400);
    await this.logConnectionConfig();

    this.paired = true;
    this.onLog('配对完成: 段 1 + 经典绑定 + 段 2 复用握手均已落地');
    return this.identitySerial;
  }

  /**
   * 读 `0x2004` 并解出相机热点凭据。
   *
   * 这个特征是**会话激活**的：相机认为本次 BLE 会话已配对完成才会返回内容。
   * 所以它既是 AP 模式的原料，也是「相机侧到底认不认这次配对」的黄金指标 ——
   * 比任何日志推断都可靠。
   */
  private async logConnectionConfig(): Promise<void> {
    const config = await this.readConnectionConfig();
    if (config === null || config.length === 0) {
      this.credentials = null;
      this.onLog('配对: 0x2004 仍为空（相机还没把这台手机当成已配对主机）');
      return;
    }
    this.onLog(`配对: 0x2004 读到 ${config.length}B 密文`);
    const creds = await decodeWifiCredentials(config, this.material,
      (m: string) => this.onLog(m));
    this.credentials = creds;
    if (creds === null) {
      // 解不开不臆造明文：留 null，等下次握手换一组材料再试。
      this.onLog(`配对: 0x2004 未能解出（材料 ${this.material === null ? '缺失' : '齐全'}）`);
      return;
    }
    this.onLog(`配对: 相机热点「${creds.ssid}」· ${creds.securityLabel}`
      + ` · 密码 ${creds.password.length} 字符 · 来源 ${creds.keySource}`);
  }

  /** 相机热点凭据；没读到或没解出来为 null。AP 模式接进来时用。 */
  getCredentials(): WifiCredentials | null {
    return this.credentials;
  }

  /**
   * 确保 GATT 服务表已建好。
   *
   * bond 之后重连时，服务发现缓存通常是空的；没拉过服务表就直接订阅特征，
   * `setCharacteristicChangeIndication` 会报 401 Invalid parameter
   * （2026-11-11 真机实测：段 2 回链后就断在这儿）。
   */
  private async ensureServices(): Promise<void> {
    const gatt = this.gatt;
    if (gatt === null) return;
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const services = await gatt.getServices();
        if (services.length > 0) {
          // 服务表到位后再等一拍，让链路加密/参数更新落定。
          await BleCameraLink.sleep(300);
          return;
        }
      } catch (_e) {
        // 重试
      }
      await BleCameraLink.sleep(400);
    }
    this.onLog('配对: GATT 服务表仍为空，订阅可能失败');
  }

  /** 写 0x2002 控制器名（32B ASCII 零填充）。 */
  private async writeControllerName(): Promise<void> {
    const name = 'StrollAndShoot';
    const payload = new Uint8Array(32);
    for (let i = 0; i < name.length && i < 32; i++) {
      payload[i] = name.charCodeAt(i) & 0xFF;
    }
    await this.writeCharacteristic(NIKON_CHAR_NAME, payload);
    this.onLog(`配对: 0x2002 控制器名已写 (${name})`);
  }

  /**
   * 走一遍 stage1 → 2 → 3 → 4，返回 stage4 里的相机序列号。
   *
   * [resume] 为 true 时是绑定后的复用握手：相机已经注册过这个身份，不再做
   * 全表读取（那只会增加 GATT 流量，增大被踢链的机会）。
   */
  private async handshake(pairing: NikonPairing, stage1: PairingMessage,
                          resume: boolean = false): Promise<string | null> {
    if (!this.connected) {
      this.onLog('配对: 链路不在，握手跳过');
      return null;
    }
    // bond 之后重连，GATT 服务缓存往往是空的；不先拉一次服务表，
    // setCharacteristicChangeIndication 会直接报 401 Invalid parameter。
    await this.ensureServices();
    // 先开 0x2008 通知，相机半睡时也要靠 GATT 流量叫醒。
    try {
      await this.enableIndication(NIKON_CHAR_CONTROL);
      this.onLog('配对: 0x2008 indicate 已开启');
    } catch (err) {
      this.onLog(`配对: 0x2008 订阅失败: ${(err as Error).message}`);
    }
    await this.enableIndication(NIKON_CHAR_PAIRING);
    this.onLog(`配对: 0x2000 indicate 已开启（${resume ? '复用' : '首配'}）`);

    const stage2Promise = this.waitCharacteristic(NIKON_CHAR_PAIRING, 15000);
    await this.writeCharacteristic(NIKON_CHAR_PAIRING, stage1.raw);
    this.onLog('配对: stage1 已发送');
    // 相机半睡时 GATT 服务器不回 stage2，约 12 秒后被踢链。每 2 秒重发一次
    // stage1（重复的握手起始帧是安全的），既给服务器持续唤醒刺激，也不至于
    // 让这次连接白等。
    const stage1Retry = setInterval(() => {
      this.writeCharacteristic(NIKON_CHAR_PAIRING, stage1.raw).catch((_e: Error) => {
        // 链路已断就交给上层重连
      });
    }, 2000);
    let stage2raw: Uint8Array;
    try {
      stage2raw = await stage2Promise;
    } finally {
      clearInterval(stage1Retry);
    }
    const stage2 = decodePairingMessage(stage2raw);
    this.onLog(`配对: stage2 stage=${stage2.stage}`);
    const result = await pairing.verifyStage2AndBuildStage3(stage1, stage2);
    if (result === null) {
      return null;
    }
    const stage4Promise = this.waitCharacteristic(NIKON_CHAR_PAIRING, 15000);
    await this.writeCharacteristic(NIKON_CHAR_PAIRING, result.message.raw);
    this.onLog('配对: stage3 已发送');
    const stage4 = decodePairingMessage(await stage4Promise);
    const serial = pairing.extractSerial(stage4);
    this.onLog(`配对: stage4 序列号 ${serial}${resume ? '（复用握手）' : ''}`);
    // 留住握手材料：0x2004 的会话密钥要从这四帧里派生（见
    // NikonWifiCredentials）。字段一律取**线上原样字节**，不做 NUL 截断 ——
    // key1 是 stage4 的 8B 身份字段，不是「序列号字符串」。
    this.material = {
      key1: stage4.raw.slice(9, 17),
      key2: stage1.raw.slice(9, 17),
      saltIndex: result.saltIndex,
      cameraNonce: stage2.raw.slice(1, 9),
      phoneNonce: stage1.raw.slice(1, 9)
    };
    return serial;
  }

  /** 绑定后重新连上相机：先直连，失败再重扫一次。 */
  private async reconnectForResume(): Promise<boolean> {
    if (this.deviceId.length > 0 && await this.connectGatt(this.deviceId)) {
      this.onLog('配对: 已回链（直连）');
      return true;
    }
    this.onLog('配对: 直连失败，重新扫描相机');
    const found: BleCameraDevice[] = [];
    // 相机休眠后广播里没有名字，必须按厂商数据里的尼康 deviceId 认。
    const scanner = new BleScanner(
      (dev: BleCameraDevice) => { found.push(dev); },
      (msg: string) => this.onLog(msg),
      this.identityDevice);
    scanner.start();
    await BleCameraLink.sleep(8000);
    scanner.stop();
    for (const dev of found) {
      if (await this.connectGatt(dev.deviceId)) {
        this.deviceId = dev.deviceId;
        if (this.cameraName.length === 0) {
          this.cameraName = dev.name;
        }
        this.onLog(`配对: 已回链（扫描命中 ${dev.deviceId}）`);
        return true;
      }
    }
    return false;
  }

  /** 开启断链自动重连（相机会休眠，链路断了自己爬起来）。 */
  enableAutoReconnect(): void {
    this.autoReconnect = true;
    this.backoffIndex = 0;
  }

  /** 关闭自动重连并取消在途重试（用户主动断开时调）。 */
  disableAutoReconnect(): void {
    this.autoReconnect = false;
    this.reconnecting = false;
    this.onReconnecting(false);
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  /** 断链沿：按退避排一次重连。 */
  private scheduleReconnect(): void {
    if (!this.autoReconnect || this.reconnecting || this.reconnectTimer >= 0) return;
    const delay = this.backoffMs[Math.min(this.backoffIndex, this.backoffMs.length - 1)];
    this.backoffIndex++;
    this.onLog(`${Math.round(delay / 1000)} 秒后自动重连（第 ${this.backoffIndex} 次）`);
    this.onReconnecting(true);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      void this.tryAutoReconnect();
    }, delay);
  }

  /**
   * 自动重连：直连优先，失败重扫，连上后用保存的身份复用握手。
   *
   * 相机休眠时链路是「连得上但 GATT 不回包」的状态，所以握手里的 stage1
   * 重发（每 2 秒）就是唤醒手段。
   */
  private async tryAutoReconnect(): Promise<void> {
    if (!this.autoReconnect || this.reconnecting) return;
    const store = BleIdentityStore.getInstance();
    if (!store.hasIdentity()) return;
    this.reconnecting = true;
    this.onLog('BLE 自动重连中…');
    try {
      await this.disconnectInner();
      if (this.deviceId.length > 0 && !await this.connectGatt(this.deviceId)) {
        await this.recoverByScan(store.identityDevice);
      } else if (this.deviceId.length === 0) {
        await this.recoverByScan(store.identityDevice);
      }
      if (!this.connected) {
        throw new Error('没有可用的链路');
      }
      const blowfish = new NikonBlowfish(this.onLog);
      const pairing = new NikonPairing(blowfish, this.onLog);
      const stage1 = pairing.createStage1(store.identityDevice, store.identityNonce);
      const serial = await this.handshake(pairing, stage1, true);
      if (serial === null) {
        throw new Error('复用握手未通过');
      }
      await this.writeControllerName();
      this.paired = true;
      this.backoffIndex = 0;
      this.onLog(`BLE 自动重连成功（序列号 ${serial}）`);
      this.onReconnecting(false);
      this.onReconnected(serial);
    } catch (err) {
      this.onLog(`BLE 自动重连失败: ${(err as Error).message}`);
      this.scheduleReconnect();
    } finally {
      this.reconnecting = false;
    }
  }

  /** 扫描找相机（休眠相机广播无名字，按尼康 deviceId 认）。 */
  private async recoverByScan(nikonDeviceId: number): Promise<void> {
    const found: BleCameraDevice[] = [];
    const scanner = new BleScanner(
      (dev: BleCameraDevice) => { found.push(dev); },
      (msg: string) => this.onLog(msg),
      nikonDeviceId);
    scanner.start();
    await BleCameraLink.sleep(6000);
    scanner.stop();
    for (const dev of found) {
      if (await this.connectGatt(dev.deviceId)) {
        this.deviceId = dev.deviceId;
        if (this.cameraName.length === 0) {
          this.cameraName = dev.name;
        }
        return;
      }
    }
    this.onLog('自动重连: 扫描没有找到相机');
  }

  /** 清链路但保留自动重连开关（重连流程内部用）。 */
  private async disconnectInner(): Promise<void> {
    this.stopKeepalive();
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

  async disconnect(): Promise<void> {
    this.cancelled = true;
    this.disableAutoReconnect();
    this.paired = false;
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
