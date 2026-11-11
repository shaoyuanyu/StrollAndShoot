import { ble, connection as btConnection, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NikonBlowfish } from './NikonBlowfish';
import { BleTimePayload, BleGeoPayload, type BleGeoFix } from './BlePayloads';
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
  private keepaliveTimer: number = -1;
  /** 配对握手是否已完成（只有完成后才应答 0x2008）。 */
  private paired: boolean = false;
  connected: boolean = false;

  constructor(onLog: (msg: string) => void,
              onState: (connected: boolean) => void = (_c: boolean) => {}) {
    this.onLog = onLog;
    this.onState = onState;
  }

  /**
   * 系统蓝牙配对（bond）。
   *
   * 尼康相机把控制器名（0x2002）和 Wi-Fi 凭据（0x2004）挂在**加密权限**上：
   * 链路没绑定时写 0x2002 不报错但相机静默丢弃、读 0x2004 直接失败，表现
   * 就是「四步握手全过、相机却一直停在开始配对页」。SnapBridge 挂上 GATT
   * 后会补一次 SMP，本项目之前只做 GATT 直连、跳过了这一步。
   */
  private async bond(deviceId: string, timeoutMs: number = 30000): Promise<boolean> {
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
          this.onLog(`BLE 配对超时（${Math.round(timeoutMs / 1000)}s）`);
          finish(false);
        }, timeoutMs);
      } catch (err) {
        this.onLog(`pairDevice 异常: ${(err as BusinessError).message}`);
        finish(false);
      }
    });
  }

  /**
   * 连接一台相机。
   *
   * 顺序：**先 GATT 直连**（GATT 通了才说明相机在场），连上后立刻补一次
   * 系统绑定（bond）。之前完全跳过 bond：GATT 能连、四步握手也能跑完，但
   * 相机把控制器名与 Wi-Fi 凭据都挂在加密权限上，未绑定的链路上写 0x2002
   * 被静默丢弃、读 0x2004 必失败，于是相机永远停在「开始配对」页。
   *
   * bond 失败不阻断后续流程（部分相机会自己发起 SMP），只记日志。
   */
  async connect(deviceId: string): Promise<boolean> {
    await this.disconnect();
    this.onLog(`BLE 直连 ${deviceId}`);
    if (!await this.connectGatt(deviceId)) {
      this.onLog('BLE 直连失败，尝试系统配对后重连');
      const bonded = await this.bond(deviceId);
      this.onLog(bonded ? 'BLE 系统配对完成' : 'BLE 系统配对未完成');
      if (!bonded) {
        return false;
      }
      return await this.connectGatt(deviceId);
    }
    // GATT 已通，补系统绑定。相机在配对页会接受 SMP；成功链路即变加密链路。
    const bonded = await this.bond(deviceId, 12000);
    this.onLog(bonded ? 'BLE 系统绑定完成（链路已加密）' : 'BLE 系统绑定未完成，继续尝试握手');
    if (bonded) {
      // 绑定完成后链路会重新协商加密，等一拍再继续，避免紧接着的读写撞上
      // 2900099（前序操作未完成）。
      await BleCameraLink.sleep(600);
      if (!this.connected) {
        // 部分相机在 SMP 完成后主动拆链再重连，这里补一次。
        this.onLog('系统绑定后链路断开，重连一次');
        await this.disconnect();
        if (!await this.connectGatt(deviceId)) {
          return false;
        }
      }
    }
    return true;
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
    // 先开 0x2008 通知并读一次电池把相机叫醒（半睡时 GATT 不回 stage2）。
    try {
      await this.enableIndication(NIKON_CHAR_CONTROL);
      this.onLog('配对: 0x2008 indicate 已开启');
    } catch (err) {
      this.onLog(`配对: 0x2008 notify 失败: ${(err as Error).message}`);
    }
    try {
      const battery = await this.readCharacteristic(NIKON_CHAR_BATTERY);
      this.onLog(`配对: 唤醒 poke 0x2a19 → ${battery === null ? 'null' : battery.length + 'B'}`);
    } catch (_e) {
      this.onLog('配对: 唤醒 poke 未回，继续握手');
    }
    // 读关键特征：相机要靠「访问加密读权限的特征」收口配对。
    await this.readKeyCharacteristics();
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
    this.onLog(`配对: stage4 序列号 ${serial}`);

    // 名字必须**立刻**写，不能等 0x2008。
    // ZPill 真机注释写得很明确：相机收下 0x2002 控制器名之后才发 0x2008 确认，
    // 「等 NOT1 再写名会让双方互等到超时」。之前按 N-link 的 2.5 秒等待版本
    // 反而把自己卡死在这儿。
    const name = 'StrollAndShoot';
    const namePayload = new Uint8Array(32);
    for (let i = 0; i < name.length && i < 32; i++) {
      namePayload[i] = name.charCodeAt(i) & 0xFF;
    }
    await this.writeCharacteristic(NIKON_CHAR_NAME, namePayload);
    this.onLog(`配对: 0x2002 控制器名已写 (${name})`);

    // 关键收口动作：写 0x2005=0x01 唤起相机无线。SnapBridge 在 BLE 配对完成
    // 后必然发这一笔；只写名字不写它会停在「开始配对」页不往下走。
    try {
      await BleCameraLink.sleep(200);
      await this.writeEstablishment(0x01);
      this.onLog('配对: 0x2005=0x01 已写（唤起相机无线）');
    } catch (err) {
      this.onLog(`配对: 0x2005 写入失败: ${(err as Error).message}`);
    }

    // 相机认不认这次配对，看 0x2004 给不给内容。给 97B 就是真配对成功。
    await BleCameraLink.sleep(400);
    const config = await this.readConnectionConfig();
    if (config !== null && config.length > 0) {
      this.onLog(`配对: 0x2004 凭据 ${config.length}B`
        + BleCameraLink.describeBytes(config) + ' ← 相机已承认本次配对');
    } else {
      this.onLog('配对: 0x2004 仍为空 ← 相机未承认本次配对');
    }

    this.paired = true;
    this.onLog('配对完成: 0x2002 控制器名 + 0x2005 已写');
    return serial;
  }

  async disconnect(): Promise<void> {
    this.stopKeepalive();
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
