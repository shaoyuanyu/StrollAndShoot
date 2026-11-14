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

/**
 * 一拍保活/注入的配置（1.66.17）。
 *
 * 对时和位置是两个独立开关：对时不需要任何权限，位置要先拿到定位。
 * `fixProvider` 每次都重新取，走到哪写到哪。
 */
export interface BleKeepaliveConfig {
  /** 两拍之间的间隔。 */
  intervalMs: number;
  /** 时区偏移分钟数（东八区 480），写进 0x2006 的后两个字节。 */
  offsetMinutes: number;
  /** 是否写 0x2006。 */
  writeTime: boolean;
  /** 当前位置；null 表示这次没有定位。 */
  fixProvider: () => BleGeoFix | null;
  /** 每一拍的结论写进 AppLog，真机上排查「相机没反应」全靠它。 */
  onLog: (message: string) => void;
  /** 写完一帧位置后回调一次，用来读回 0x2007 校验相机存没存。 */
  onGeoWritten?: () => void;
}

/** 一次读的结果（诊断用）：值 + 失败原因。 */
export interface BleReadResult {
  value: Uint8Array | null;
  error: string;
}

/** 首次连接 / 配对时等 GATT 上报状态的上限（相机休眠时唤醒要几秒）。 */
const CONNECT_TIMEOUT_MS = 10000;
/** 握手等 stage2 / stage4 的上限。相机醒着是毫秒级，睡着就等满。 */
const HANDSHAKE_TIMEOUT_MS = 15000;
/**
 * 自动重连：一次 GATT 建链的等待上限。
 *
 * **不能当成「地址过期就立刻失败」的短超时**：相机半睡时实测建链要 **8 秒**
 * （2026-11-14：16:51:33 发起 → 41 秒才 STATE_CONNECTED；16:57:25 → 33 同样 8 秒），
 * 原来给 5 秒等于每次都在成功前一秒放弃，日志里就只剩一串
 * 「BLE 连接状态: 1 → 连接超时（5s）」。12 秒留出余量（含 MTU 最多 2 秒兜底）。
 */
const RECONNECT_CONNECT_MS = 12000;
/** 自动重连：扫一轮相机的窗口；扫到第一台就提前结束。 */
const RECONNECT_LISTEN_MS = 20000;
/** 服务表查询的单次超时：相机睡着时 getServices 能挂十秒。 */
const SERVICE_TIMEOUT_MS = 4000;
/**
 * 发现超时后，等服务发现真正落地的最长时间。
 *
 * 超时只是我们不等了，那一笔仍在蓝牙栈里跑（实测约 10 秒才报错）。在这段
 * 时间里订阅或再发一笔发现，都会排到它后面——而这一步是**在自己的线程上同步
 * 等**的，于是整个 JS 主线程跟着一起卡住（2026-11-14 18:29 的 THREAD_BLOCK_6S）。
 */
const SERVICE_LANDING_MS = 12000;
/** 自动重连：复用握手的等待上限（相机醒着时毫秒级就回）。 */
const RECONNECT_HANDSHAKE_MS = 6000;
/** 自动重连：两轮之间的固定间隔（前台）。不做指数退避——相机随时会醒。 */
const RECONNECT_GAP_MS = 1000;
/** 自动重连：后台的间隔（没人看页面，别一直扫）。 */
const RECONNECT_GAP_BACKGROUND_MS = 15000;
/** 自动重连：超过这么久还没扫到相机，就从低延迟扫描降到低功耗扫描。 */
const RECONNECT_FAST_MS = 120000;

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

/** `getServices()` 的结果。「超时」与「真的没有服务」必须分开：前者不能再发第二笔。 */
interface ServiceProbe {
  services: Array<ble.GattService>;
  timedOut: boolean;
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

  /**
   * 扫描档位。官方《蓝牙重连最佳实践》给的用法是「两阶段」：
   * 发现阶段用 `SCAN_MODE_LOW_LATENCY` 抢时间，长期盯着用 `SCAN_MODE_LOW_POWER`
   * 省电——「长时间后台扫描用 LOW_LATENCY 会导致功耗和发热严重」。
   * 不传 `fast` 就是系统默认的 `SCAN_MODE_LOW_POWER`。
   */
  private readonly dutyMode: ble.ScanDuty;

  /**
   * @param filterDeviceId 只收这个尼康 deviceId（0 = 按广播名筛）。
   * @param fast 抢时间用低延迟扫描。只在「用户正等着结果」的短扫描里传 true：
   *   手动搜索、冷启动接回相机、以及刚断链前两分钟的重连。长期盯着必须用
   *   低功耗档，否则功耗和发热都会上来。
   */
  constructor(onFound: (device: BleCameraDevice) => void,
              onLog: (msg: string) => void,
              filterDeviceId: number = 0,
              fast: boolean = false) {
    this.onFound = onFound;
    this.onLog = onLog;
    this.filterDeviceId = filterDeviceId;
    this.dutyMode = fast ? ble.ScanDuty.SCAN_MODE_LOW_LATENCY
      : ble.ScanDuty.SCAN_MODE_LOW_POWER;
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
      // 按**厂商 ID** 过滤是官方推荐的做法：在芯片层就筛掉别人的广播，
      // 功耗和回调频率都低得多。只有「找一台还没配对的新相机」时才留空
      // （相机等待配对时广播里不一定带 0x0399）。
      const filter: ble.ScanFilter = {};
      if (this.filterDeviceId !== 0) filter.manufactureId = NIKON_COMPANY_ID;
      const options: ble.ScanOptions = { dutyMode: this.dutyMode };
      ble.startBLEScan([filter], options);
      this.onLog(`BLE 开始扫描（${this.dutyMode === ble.ScanDuty.SCAN_MODE_LOW_LATENCY
        ? '低延迟' : '低功耗'}${this.filterDeviceId !== 0 ? '，只收尼康广播' : ''}）`);
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
  /**
   * 本次连接是否已经拿到服务表。
   *
   * 这是**订阅特征的前置条件**：`setCharacteristicChangeIndication()` 内部会
   * 同步调 `GattClient::GetService()` → `GetServices()`，服务表不在缓存里时
   * 这段发现会**跑在 JS 主线程上**。相机半睡或链路刚抖过时它能卡 6 秒以上，
   * 系统直接判 2026-11-14 18:29 那次 `THREAD_BLOCK_6S` 闪退。所以服务表没
   * 就绪时宁可这一轮不连，也不能进那次调用。
   */
  private servicesReady: boolean = false;
  /**
   * `getServices()` 超时后，那一笔其实还挂在蓝牙栈里。
   *
   * 在它回来之前**不能再发第二笔**（第二笔会排在它后面，同样卡主线程），
   * 也不能订阅（订阅会等它）。这里存一份句柄，用来等它自己落地。
   */
  private discoveryInFlight: Promise<void> | null = null;
  private readonly onLog: (msg: string) => void;
  private readonly onState: (connected: boolean) => void;
  private pendingChar: PendingChar | null = null;
  private keepaliveTimer: number = -1;
  /** 保活连续失败次数：用来兜底「系统没给断链事件、写入却一直失败」的情况。 */
  private keepaliveFailures: number = 0;
  /** 上一次写出去的位置是否有效：丢星时只补一条 valid=0。 */
  private geoValidSent: boolean = false;
  /** 首帧只打一次 hex，别每 45 秒刷屏。 */
  private loggedTimeFrame: boolean = false;
  private loggedGeoFrame: boolean = false;
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
  /**
   * 自动重连**不做指数退避**（1.66.4）。
   *
   * 退避是给「对端可能永远不回来」的轮询用的；这里对端是用户手上的相机，
   * 半按快门就会回来，退避只会把「几秒能接上」拖成几十秒。现在的策略是
   * **一直监听广播**，代价用「扫描档位」控制：相机不在的前两分钟用
   * `SCAN_MODE_LOW_LATENCY`（官方两阶段里的发现阶段），之后降到
   * `SCAN_MODE_LOW_POWER` 长期盯；退到后台直接用 LOW_POWER。
   */
  private foreground: boolean = true;
  /** 本轮「相机不在」从什么时候开始：用来决定用哪一档扫描。 */
  private outageSince: number = 0;
  /** 自动重连进行中：服务枚举只试一次、超时更短，别把时间耗在等相机上。 */
  private reconnectingFast: boolean = false;
  /** 上层正在主动连接：这段时间内不要再起自动重连，否则两条路会各建一条链路。 */
  private explicitBusy: boolean = false;
  /** 上次直连地址失败过：地址多半已经换了，后面的轮次别再白等。 */
  private staleAddress: boolean = false;
  /** 重连成功后的回调（上层用它恢复校时与保活）。 */
  onReconnected: (serial: string) => void = (_s: string) => {};
  /** 重连状态变化（true = 正在重连），上层用它驱动 UI 文案。 */
  onReconnecting: (reconnecting: boolean) => void = (_v: boolean) => {};
  /**
   * 自动重连扫不到相机（连广播都没有）＝相机多半进了待机。
   *
   * 这时再怎么重试都要等用户把相机唤醒，页面得说清楚，而不是一直
   * 「正在重新连接相机…」。上层用它把状态头的详情行换成「相机可能已休眠」。
   */
  onReconnectStalled: () => void = () => {};

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

  private async connectGatt(deviceId: string, timeoutMs: number = CONNECT_TIMEOUT_MS): Promise<boolean> {
    try {
      const gatt = ble.createGattClientDevice(deviceId);
      // 新客户端 = 服务表缓存空的：这一轮必须重新发现，订阅前先看 `servicesReady`。
      this.servicesReady = false;
      this.discoveryInFlight = null;
      this.gatt = gatt;
      const ok = await new Promise<boolean>((resolve: (v: boolean) => void) => {
        let settled = false;
        // 超时之后放弃了这个客户端：它可能在我们已经转去扫描之后才连上，
        // 那时不能再改 `connected` / 发 `onState`（2026-11-14 实测：超时 3 秒后
        // 仍上报 CONNECTED、6 秒后上报 MTU，留下一条「系统连着、App 以为断了」
        // 的幽灵链路）。
        let abandoned = false;
        const finish = (v: boolean): void => {
          if (settled) return;
          settled = true;
          resolve(v);
        };
        try {
          gatt.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
            this.onLog(`BLE 连接状态: ${state.state}`);
            if (abandoned) return;
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
              // 链路没了，服务表也作废：之后的读写/订阅一律先重新发现。
              this.servicesReady = false;
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
            if (abandoned) return;
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
          abandoned = true;
          this.onLog(`BLE 连接超时（${Math.round(timeoutMs / 1000)}s 无状态事件）`);
          finish(false);
          // 关掉客户端。留着的话它会在我们转去扫描之后才连上，而 `this.gatt`
          // 已经指向别处，之后所有读写都打在一个没人管的对象上。
          // 先 `disconnect()` 再 `close()`：前者才会向相机发终止指示，让相机
          // 尽快放掉这条链路；只 close 的话相机可能还占着它唯一的连接槽，
          // 后续每次连接都得到超时（2026-11-14 实测怀疑点）。
          try {
            gatt.disconnect();
          } catch (_e) {
            // 还没连上，忽略
          }
          try {
            gatt.close();
          } catch (_e) {
            // 已经关了
          }
          if (this.gatt === gatt) this.gatt = null;
        }, timeoutMs);
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
  /**
   * `getServices()` 带超时。
   *
   * 相机睡着时它能**挂十秒才报 Operation failed**（2026-11-14 实测：16:51:46
   * 开始、16:52:03 才回来第二笔），而重连这条路上最不该做的就是等它——
   * 叫醒相机靠的是握手第一帧的重发，不是服务表。所以自己包一层超时。
   */
  private servicesOrTimeout(gatt: ble.GattClientDevice,
                            timeoutMs: number): Promise<ServiceProbe> {
    return new Promise<ServiceProbe>((resolve: (v: ServiceProbe) => void) => {
      let settled = false;
      const finish = (services: Array<ble.GattService>, timedOut: boolean): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve({ services: services, timedOut: timedOut } as ServiceProbe);
      };
      const timer = setTimeout(() => { finish([], true); }, timeoutMs);
      const discovery = gatt.getServices();
      // 记下这一笔：超时只是我们不等了，蓝牙栈里它还在跑。在它落地之前既不能
      // 再发一笔发现（会排队），也不能订阅（订阅会等它）——两者都会卡住主线程。
      this.discoveryInFlight = discovery.then(() => {
        // 等它落地即可，成功失败都不重要：调用方会自己补探。
      }, () => {
        // 同上
      }).then(() => {
        this.discoveryInFlight = null;
      });
      discovery.then((list: Array<ble.GattService>) => {
        finish(list, false);
      }).catch(() => {
        finish([], false);
      });
    });
  }

  /**
   * 断开之前，先等在途的服务发现落地。
   *
   * `gatt.disconnect()` / `gatt.close()` 都是**同步** napi 调用，内部要拿蓝牙栈
   * 里这个 GATT 客户端的锁；服务发现还在跑时，主线程就跟着一起等。2026-11-14
   * 19:01 实测等了 7 秒——faultlog 里那段被算在名为 `getAllNets` 的 EventHandler
   * 任务头上（任务名是投递它的那个 napi 回调，不是真正卡住的地方），真正的栈在
   * 3 秒样本里：`GattClient::Disconnect()` 等锁。
   *
   * 所以断开前统一等一拍：发现落地（成功/失败都算）再断。最多等
   * [SERVICE_LANDING_MS]，等不到也不能一直挂着——那就照断，但至少不是在最忙的
   * 时候撞上去。
   */
  private async settleDiscovery(): Promise<void> {
    if (this.discoveryInFlight === null) return;
    this.onLog('断开前先等服务发现落地（避免主线程等蓝牙栈的锁）');
    await this.waitDiscovery(SERVICE_LANDING_MS);
  }

  /**
   * 等上一次超时的服务发现自己落地（最多 [timeoutMs]）。
   *
   * true = 已经没有在途的发现，可以安全地再探一次；false = 它还挂着，
   * 这一轮只能放弃，绝不能在这时订阅。
   */
  private async waitDiscovery(timeoutMs: number): Promise<boolean> {
    const inFlight = this.discoveryInFlight;
    if (inFlight === null) return true;
    return await new Promise<boolean>((resolve: (v: boolean) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        resolve(false);
      }, timeoutMs);
      inFlight.then(() => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(true);
      }).catch(() => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(true);
      });
    });
  }

  /**
   * 只查一次服务表，纯诊断用（没有界面读它）。
   *
   * **超时之后绝不再发第二笔**：第一笔还挂在蓝牙栈里，第二笔会排队等它，
   * 而这个等待会卡住 JS 主线程——2026-11-14 17:41 就是这么 freeze 的
   * （THREAD_BLOCK_3S/6S，紧接着 `bt_fwk_gatt_client (GetServices)timeout`）。
   */
  async listServices(): Promise<string[]> {
    const gatt = this.gatt;
    if (gatt === null) return [];
    const probe = await this.servicesOrTimeout(gatt, SERVICE_TIMEOUT_MS);
    if (probe.timedOut) {
      this.onLog('BLE 服务表查询超时（不再重试）');
      return [];
    }
    const services = probe.services;
    if (services.length === 0) {
      this.onLog('BLE 服务表为空');
      return [];
    }
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

  /** 开启某个特征的 notify（0x2008 用 notify，不是 indicate）。 */
  async enableNotification(charUuid: string): Promise<void> {
    const gatt = this.gatt;
    if (gatt === null) throw new Error('BLE 未连接');
    if (!this.servicesReady) {
      // 与 enableIndication 同理：订阅会在主线程上同步发现服务。
      throw new Error('服务表未就绪，跳过订阅');
    }
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
    if (!this.servicesReady) {
      // 同写特征：读也要先按 UUID 解析特征，没服务表就可能卡在主线程。
      return null;
    }
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
   * 0x2008 LSS 控制点：**只看不写**（1.66.18，2026-11-14 复核）。
   *
   * ZPill 从 SnapBridge smali 推出的语义是 2B 小端位域
   * `(Connection<<8)|(Location<<4)|Time`：相机 notify 自己的请求位，`01 00`
   * 是「要时间」，不是配对成功标志。它从 2026-10-21 起会写回一个清位值，
   * nsg 的 Android 版与 kotlin-poc 则完全不写。我们的相机在 9 千行日志里
   * 一次都没发过这条通知，没有可应答的内容，所以保持「只记日志、不回写」。
   *
   * 自动传图**不经过这里**：官方 SnapBridge 的 2MP 传输是在蓝牙经典
   * （BTC/SPP）上跑 PTP，见 SERVICES.md「2MP 自动传图走的是蓝牙经典」。
   */
  private handleControlPoint(data: Uint8Array): void {
    const hex = BleCameraLink.describeBytes(data);
    if (data.length !== 2) {
      this.onLog(`0x2008 ← ${data.length}B ${hex}`);
      return;
    }
    const raw = data[0] | (data[1] << 8);
    this.onLog(`0x2008 ← 0x${raw.toString(16)} (${hex}) paired=${this.paired}`);
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
  static describeBytes(value: Uint8Array): string {
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
   * 把相机推到 Wi-Fi 模式（`0x2005 = 0x01`）。
   *
   * BLE 与 Wi-Fi 互斥（Z50II 实测）：这一笔之后相机会把 BLE 关掉，链路随即
   * 断开。调用方必须预期接下来要靠 mDNS/网段找它，而不是继续走 GATT。
   */
  async wakeCameraWifi(): Promise<void> {
    await this.writeEstablishment(0x01);
    this.onLog('0x2005=0x01 已写（把相机推到 Wi-Fi 模式）');
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

  /** 写一次相机时钟（0x2006）。首帧把字节打进日志，方便和参考实现对拍。 */
  async writeTime(offsetMinutes: number): Promise<void> {
    const payload = BleTimePayload.build(new Date(), offsetMinutes);
    if (!this.loggedTimeFrame) {
      this.loggedTimeFrame = true;
      this.onLog(`0x2006 首帧 (${payload.length}B) ${BleCameraLink.describeBytes(payload)}`);
    }
    await this.writeCharacteristic(NIKON_CHAR_TIME, payload);
  }

  /** 写一次位置（0x2007）。 */
  async writeLocation(fix: BleGeoFix): Promise<void> {
    const payload = BleGeoPayload.build(fix);
    await this.writeCharacteristic(NIKON_CHAR_GEO, payload);
  }

  /** 告诉相机「位置已经无效」，让它丢掉保存的位置（只发一次的规矩在调用方）。 */
  async writeLocationInvalid(): Promise<void> {
    await this.writeCharacteristic(NIKON_CHAR_GEO, BleGeoPayload.buildInvalid());
  }

  /**
   * 带失败原因的读（诊断用）。
   *
   * 返回 `value === null` 时 `error` 里是真实的错误码：这样日志能分清「相机不给读」
   * 和「服务表没就绪」——1.66.17 只打了一句「读不到」，没法判断原因。
   */
  async readWithReason(charUuid: string): Promise<BleReadResult> {
    if (this.gatt === null) return { value: null, error: 'BLE 未连接' };
    if (!this.servicesReady) return { value: null, error: '服务表未就绪' };
    try {
      const value = await this.readCharacteristic(charUuid);
      return { value: value, error: value === null ? '空值' : '' };
    } catch (err) {
      return { value: null, error: (err as Error).message };
    }
  }

  /** 读回相机当前的时钟（0x2006）。 */
  readTime(): Promise<BleReadResult> {
    return this.readWithReason(NIKON_CHAR_TIME);
  }

  /** 读回相机保存的位置（0x2007）：全 0 说明相机没把我们的数据记下来。 */
  readGeo(): Promise<BleReadResult> {
    return this.readWithReason(NIKON_CHAR_GEO);
  }

  /** 读回序列号（0x200b）：已知可读，用来证明「读这条通道本身是通的」。 */
  readSerial(): Promise<BleReadResult> {
    return this.readWithReason('0000200b-3dd4-4255-8d62-6dc7b9bd5561');
  }

  /**
   * 保活 + 注入：每一拍写一次 0x2006（对时）和 0x2007（位置）。
   *
   * 相机 2 分钟没有 BLE 流量会断链，45 秒一拍留足余量。位置拿不到时按
   * 「只发一次 valid=0」的规矩通知相机，避免照片带着一个小时的旧坐标。
   */
  startKeepalive(cfg: BleKeepaliveConfig): void {
    this.stopKeepalive();
    this.keepaliveFailures = 0;
    this.geoValidSent = false;
    this.keepaliveTick(cfg).catch((_e: Error) => {
      // keepaliveTick 内部已经处理过失败
    });
    this.keepaliveTimer = setInterval(() => {
      this.keepaliveTick(cfg).catch((_e: Error) => {
        // 同上
      });
    }, cfg.intervalMs);
  }

  private async keepaliveTick(cfg: BleKeepaliveConfig): Promise<void> {
    if (this.gatt === null) {
      this.onLog('BLE 保活失败: BLE 未连接');
      this.handleKeepaliveFailure();
      return;
    }
    try {
      if (cfg.writeTime) {
        await this.writeTime(cfg.offsetMinutes);
      }
      await this.injectLocation(cfg);
      this.keepaliveFailures = 0;
    } catch (err) {
      this.onLog(`BLE 保活失败: ${(err as Error).message}`);
      this.handleKeepaliveFailure();
    }
  }

  private async injectLocation(cfg: BleKeepaliveConfig): Promise<void> {
    const fix = cfg.fixProvider();
    if (fix !== null) {
      const payload = BleGeoPayload.build(fix);
      if (!this.loggedGeoFrame) {
        this.loggedGeoFrame = true;
        cfg.onLog(`0x2007 首帧 (${payload.length}B) ${BleCameraLink.describeBytes(payload)}`);
      }
      await this.writeCharacteristic(NIKON_CHAR_GEO, payload);
      this.geoValidSent = true;
      cfg.onLog(`0x2007 ← ${fix.latitude.toFixed(5)}, ${fix.longitude.toFixed(5)}`
        + ` alt=${Math.round(fix.altitude)}m sat=${fix.satellites}`);
      if (cfg.onGeoWritten !== undefined) cfg.onGeoWritten();
      return;
    }
    if (this.geoValidSent) {
      // 连续多条 valid=0 会被相机拒收，所以只在「有效 → 无效」这一刻发一条。
      await this.writeLocationInvalid();
      this.geoValidSent = false;
      cfg.onLog('0x2007 ← 位置失效（valid=0，只发这一条）');
    }
  }

  /**
   * 保活连续失败 → 判定链路已断（1.66.0）。
   *
   * 相机断电、走出范围时通常会有 `BLEConnectionStateChange`，但偶尔只剩「写入
   * 一直报错、系统不发断链事件」：那之后页面会一直显示「已连接」。连续两次
   * （45 秒一拍，约 90 秒）都写不进去就按断链处理：停保活、关 GATT，交给上层
   * 的自动重连接手。**一次不判**——相机忙的时候偶尔会拒收一笔。
   */
  private handleKeepaliveFailure(): void {
    this.keepaliveFailures++;
    if (this.keepaliveFailures < 2) return;
    this.keepaliveFailures = 0;
    this.onLog('BLE 保活连续失败：判定链路已断，按断链处理');
    this.disconnectInner().then(() => {
      this.scheduleReconnect();
    }).catch((_e: Error) => {
      // 已经断了：重连由上层自己排
    });
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
    if (!this.servicesReady) {
      // 进 setCharacteristicChangeIndication 就会在 JS 主线程上同步发现服务。
      throw new Error('服务表未就绪，跳过订阅');
    }
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
    if (!this.servicesReady) {
      // 写特征同样要按 UUID 找特征（GetGattcCharacteristic → GetServices），
      // 服务表不在缓存里时这段发现在主线程上同步跑——和订阅是同一条险路。
      throw new Error('服务表未就绪，跳过写入');
    }
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
  /**
   * @param wakeWifi 握手完成后要不要写 `0x2005=0x01` 唤起相机无线。
   *   无线会话已经活着的时候必须传 false：这一笔可能让相机重启 Wi-Fi，
   *   把正在用的 PTP 会话一起打断（BLE 掉线重连时就会碰到）。
   */
  async pair(cameraName: string = '', wakeWifi: boolean = true): Promise<string | null> {
    this.cancelled = false;
    try {
      const store = BleIdentityStore.getInstance();
      if (store.hasIdentity()) {
        return await this.resumePairing(store, wakeWifi);
      }
      return await this.pairFresh(cameraName, store);
    } catch (err) {
      this.onLog(`配对异常: ${(err as Error).message}`);
      return null;
    }
  }

  /** 已配对相机的重连：用保存的身份复用握手，不再打扰相机的配对页。 */
  private async resumePairing(store: BleIdentityStore,
                              wakeWifi: boolean = true): Promise<string | null> {
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
    if (wakeWifi) {
      try {
        await BleCameraLink.sleep(200);
        await this.writeEstablishment(0x01);
        this.onLog('配对: 0x2005=0x01 已写（复用握手后唤起相机无线）');
      } catch (err) {
        this.onLog(`配对: 0x2005 写入失败: ${(err as Error).message}`);
      }
    } else {
      this.onLog('配对: 无线会话还活着，跳过 0x2005（避免相机重启 Wi-Fi）');
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
    //
    // **这里必须用 `disconnectInner()`，不能用 `disconnect()`**：后者会置上
    // 用户取消标记（它给「取消连接」按钮用），于是断链 3 秒后自己就会
    // 判定「用户已取消（经典绑定未做）」——首配永远走不到经典绑定这一步。
    // 4b5bd97 引入取消标记时踩过，2026-11-14 真机上就是这个现象。
    this.onLog('配对: 段 1 完成，断开 BLE 让相机暴露经典蓝牙');
    await this.disconnectInner();
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
  /**
   * @param fast 连接的是**已配对**的相机（复用握手）。相机睡着时
   *   `getServices()` 会挂好几秒才失败，等它没意义——叫醒相机靠的是握手
   *   第一帧每 2 秒重发。这时只试一次、2.5 秒就走，把时间让给 stage1。
   * @returns 服务表是否真的拿到。**返回 false 时调用方必须放弃这一轮**：
   *   没有服务表的订阅会在主线程上同步做一遍服务发现，直接把界面卡死。
   */
  private async ensureServices(fast: boolean = false): Promise<boolean> {
    const gatt = this.gatt;
    if (gatt === null) return false;
    this.servicesReady = false;
    const quick = fast || this.reconnectingFast;
    const attempts = quick ? 1 : 5;
    const perCall = quick ? 2500 : SERVICE_TIMEOUT_MS;
    for (let attempt = 0; attempt < attempts; attempt++) {
      const probe = await this.servicesOrTimeout(gatt, perCall);
      if (probe.services.length > 0) {
        // 服务表到位后再等一拍，让链路加密/参数更新落定。
        this.servicesReady = true;
        await BleCameraLink.sleep(300);
        return true;
      }
      // 超时说明这一笔还挂在蓝牙栈里：再发一笔就会排队等它、把 JS 线程卡死。
      if (probe.timedOut) {
        // 等它自己落地，然后补探一次（这次是全新一笔，不会排队）。
        if (!await this.waitDiscovery(SERVICE_LANDING_MS)) {
          this.onLog('配对: 服务发现一直没回来，本轮放弃（不在主线程上冒卡死的险）');
          return false;
        }
        const again = await this.servicesOrTimeout(gatt, perCall);
        if (again.services.length > 0) {
          this.servicesReady = true;
          await BleCameraLink.sleep(300);
          return true;
        }
        return false;
      }
      await BleCameraLink.sleep(400);
    }
    this.onLog('配对: GATT 服务表为空，本轮不订阅');
    return false;
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
                          resume: boolean = false,
                          timeoutMs: number = HANDSHAKE_TIMEOUT_MS): Promise<string | null> {
    if (!this.connected) {
      this.onLog('配对: 链路不在，握手跳过');
      return null;
    }
    // bond 之后重连，GATT 服务缓存往往是空的；不先拉一次服务表，
    // setCharacteristicChangeIndication 会直接报 401 Invalid parameter。
    // 复用握手（连的是一台已配对的相机）时不等服务表：相机半睡时
    // `getServices()` 能挂十秒，而 stage1 重发本身就是叫醒手段。
    if (!await this.ensureServices(resume)) {
      // **拿不到服务表就绝不能往下走**：订阅内部会同步发现服务，相机半睡时
      // 卡满 6 秒，系统判 THREAD_BLOCK_6S 闪退（2026-11-14 18:29）。这一轮
      // 放弃，交给重连循环；下一轮相机多半已经醒了。
      this.onLog('配对: 服务表未就绪，本轮不订阅（避免主线程卡死）');
      return null;
    }
    // 先开 0x2008 通知，相机半睡时也要靠 GATT 流量叫醒。
    // **0x2008 是 notify，不是 indicate**（1.66.18）：nsg 的 Android 实现与
    // kotlin-poc 都用 setNotify(NOT1)，只有 0x2000 用 indicate。之前这里写的是
    // enableIndication，CCCD 置成 indicate 位，相机从来不发通知——9 千行日志里
    // 一次 `BLE 通知 00002008` 都没有，LSS 控制点这条通道等于不存在。
    try {
      await this.enableNotification(NIKON_CHAR_CONTROL);
      this.onLog('配对: 0x2008 notify 已开启');
    } catch (err) {
      this.onLog(`配对: 0x2008 订阅失败: ${(err as Error).message}`);
    }
    await this.enableIndication(NIKON_CHAR_PAIRING);
    this.onLog(`配对: 0x2000 indicate 已开启（${resume ? '复用' : '首配'}）`);

    const stage2Promise = this.waitCharacteristic(NIKON_CHAR_PAIRING, timeoutMs);
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
    const stage4Promise = this.waitCharacteristic(NIKON_CHAR_PAIRING, timeoutMs);
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

  /** 「等相机回来」的循环是否开着（后台保活要看它，别在断链那一瞬间把任务放掉）。 */
  watchArmed(): boolean {
    return this.autoReconnect;
  }

  /** 应用前后台切换：前台重连更勤（用户随时会唤醒相机），后台放缓。 */
  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (!foreground || !this.autoReconnect || this.reconnecting || this.connected) return;
    // 从后台回来时不要把后台那 15 秒等满；顺带兜一层「循环已经断了」的情况：
    // 没有在途重连、也没有排队的计时器，就地补一轮。
    if (this.reconnectTimer >= 0) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      void this.tryAutoReconnect();
    }, 500);
  }

  /**
   * 上层要主动连一次：先把「等相机回来」的循环停掉。
   *
   * 不停的话会出现两条路同时 `createGattClientDevice()` + 握手——同一个特征上
   * 第二次订阅会被拒（`Please call the interface only after the previous callback
   * has been completed`），日志里 17:47 就是两条「BLE 直连」各建了一条链路。
   */
  pauseReconnectWatch(): void {
    this.explicitBusy = true;
    this.disableAutoReconnect();
  }

  /**
   * 现在就把「等相机回来」的循环开起来。
   *
   * 给「已配对、但这次没连上」用：相机睡着了（或者刚被唤醒、还没开始广播），
   * 不需要用户再点一次「连接相机」，后台每秒碰一次，醒了自己接上。
   * 用户点「断开连接」时 `disconnect()` 会把它关掉。
   */
  wakeReconnectWatch(): void {
    this.explicitBusy = false;
    if (!this.autoReconnect) this.enableAutoReconnect();
    // 刚才直连失败的那个地址大概率已经作废，别再每轮白等 5 秒。
    this.staleAddress = true;
    this.scheduleReconnect();
  }

  /** 开启断链自动重连（相机会休眠，链路断了自己爬起来）。 */
  enableAutoReconnect(): void {
    this.explicitBusy = false;
    this.autoReconnect = true;
    this.outageSince = 0;
    this.staleAddress = false;
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

  /**
   * 断链沿：排下一轮重连。
   *
   * 不递增等待时间——相机随时会醒，间隔固定 1 秒（后台 15 秒，没人看）。
   */
  private scheduleReconnect(): void {
    if (!this.autoReconnect || this.reconnecting || this.reconnectTimer >= 0) return;
    const delay = this.foreground ? RECONNECT_GAP_MS : RECONNECT_GAP_BACKGROUND_MS;
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
    if (!this.autoReconnect || this.reconnecting || this.explicitBusy) return;
    const store = BleIdentityStore.getInstance();
    if (!store.hasIdentity()) return;
    this.reconnecting = true;
    this.reconnectingFast = true;
    if (this.outageSince === 0) this.outageSince = Date.now();
    let failed = false;
    this.onLog('BLE 自动重连中…');
    try {
      await this.disconnectInner();
      // 先试上次的地址（`staleAddress` 为假时）：地址没变就能省掉一轮扫描。
      // 超时用 `RECONNECT_CONNECT_MS`——相机半睡时建链要 8 秒，给短了等于
      // 每次都在成功前一秒放弃。
      let direct = false;
      if (this.deviceId.length > 0 && !this.staleAddress) {
        direct = await this.connectGatt(this.deviceId, RECONNECT_CONNECT_MS);
        // 这个地址已经连不上了：相机换了随机地址，下一轮直接跳过它去扫描，
        // 别再每轮白等一个连接超时。
        this.staleAddress = !direct;
      }
      if (!direct) {
        await this.recoverByScan(store.identityDevice, RECONNECT_LISTEN_MS);
      }
      if (!this.connected) {
        throw new Error('没有可用的链路');
      }
      const blowfish = new NikonBlowfish(this.onLog);
      const pairing = new NikonPairing(blowfish, this.onLog);
      const stage1 = pairing.createStage1(store.identityDevice, store.identityNonce);
      // 相机醒着时几毫秒就回 stage2；等 15 秒只会让「这一轮没连上」变成很长的空转。
      const serial = await this.handshake(pairing, stage1, true, RECONNECT_HANDSHAKE_MS);
      if (serial === null) {
        throw new Error('复用握手未通过');
      }
      await this.writeControllerName();
      this.paired = true;
      this.outageSince = 0;
      this.onLog(`BLE 自动重连成功（序列号 ${serial}）`);
      this.onReconnecting(false);
      this.onReconnected(serial);
    } catch (err) {
      failed = true;
      this.onLog(`BLE 自动重连失败: ${(err as Error).message}`);
    } finally {
      this.reconnecting = false;
      this.reconnectingFast = false;
    }
    // **必须放在 finally 之后**：`scheduleReconnect()` 会检查 `reconnecting`，
    // 在 catch 里直接排会被自己挡掉，返回前 `reconnecting` 还是 true。以前就是
    // 这样——每次断链只重试一轮，然后整条重连循环就没了。用户看到的是「相机唤醒
    // 一分钟也没连上」，日志里只有一行「BLE 自动重连失败」然后完全安静
    // （2026-11-14 实测定位）。
    if (failed) this.scheduleReconnect();
  }

  /**
   * 扫描找相机（休眠相机广播无名字，按尼康 deviceId 认）。
   *
   * **扫到第一台就收工**（1.66.3）：相机被半按快门唤醒后 1 秒内就会重新广播，
   * 干等满整个窗口只会推迟连接。窗口是用来兜「还没醒」的，不是用来凑数的。
   */
  private async recoverByScan(nikonDeviceId: number,
                              windowMs: number = RECONNECT_LISTEN_MS): Promise<void> {
    const found: BleCameraDevice[] = [];
    // 两阶段（官方《蓝牙重连最佳实践》）：刚断的前两分钟抢时间用低延迟扫描，
    // 之后降档长期盯；后台一律低功耗。
    const fast = this.foreground
      && (this.outageSince === 0 || Date.now() - this.outageSince < RECONNECT_FAST_MS);
    const scanner = new BleScanner(
      (dev: BleCameraDevice) => { found.push(dev); },
      (msg: string) => this.onLog(msg),
      nikonDeviceId,
      fast);
    scanner.start();
    const deadline = Date.now() + windowMs;
    while (found.length === 0 && Date.now() < deadline) {
      await BleCameraLink.sleep(150);
    }
    scanner.stop();
    if (found.length === 0) {
      this.onLog('自动重连: 扫描没有找到相机');
      this.onReconnectStalled();
      return;
    }
    const dev = found[0];
    if (await this.connectGatt(dev.deviceId, RECONNECT_CONNECT_MS)) {
      this.deviceId = dev.deviceId;
      this.staleAddress = false;
      if (this.cameraName.length === 0) {
        this.cameraName = dev.name;
      }
    } else {
      this.onLog(`自动重连: 扫到相机但连不上（${dev.deviceId}）`);
    }
  }

  /** 清链路但保留自动重连开关（重连流程内部用）。 */
  private async disconnectInner(): Promise<void> {
    await this.settleDiscovery();
    this.stopKeepalive();
    const gatt = this.gatt;
    const wasConnected = this.connected;
    this.gatt = null;
    this.connected = false;
    this.servicesReady = false;
    this.discoveryInFlight = null;
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
    await this.settleDiscovery();
    this.cancelled = true;
    this.disableAutoReconnect();
    this.paired = false;
    const gatt = this.gatt;
    const wasConnected = this.connected;
    this.gatt = null;
    this.connected = false;
    this.servicesReady = false;
    this.discoveryInFlight = null;
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
