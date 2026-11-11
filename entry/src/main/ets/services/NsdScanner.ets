import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 一条 mDNS 发现的相机记录。 */
export interface WifiCameraInfo {
  /** mDNS 实例名，例如 Z50_2_8079350。 */
  name: string;
  host: string;
  port: number;
}

const SERVICE_TYPE = '_ptp._tcp';
const DEFAULT_PORT = 15740;

/**
 * 局域网相机发现（Bonjour / mDNS `_ptp._tcp`）。
 *
 * 尼康相机在 Wi-Fi 模式（AP 或 STA）下都会广播 `_ptp._tcp`，实例名就是
 * 相机名（`Z50_2_8079350` 这种），SRV 端口是 15740。这是比「手填 IP」
 * 更稳的入口：DHCP 换了地址也不用改配置。
 *
 * 几个 HarmonyOS 上的坑（ZPill 在真机上踩过）：
 * - `serviceFound` 只保证 `serviceName`，IP/端口必须再 `resolveLocalService`；
 * - serviceType **不带尾点**（iOS/Android 的 API 惯例带尾点，HarmonyOS 不带）；
 * - 解析超时是 2204006，属正常现象（相机忙/广播丢了），下一轮会再报。
 */
export class NsdScanner {
  private readonly context: common.Context;
  private readonly onFound: (camera: WifiCameraInfo) => void;
  private readonly onLost: (name: string) => void;
  private readonly onLog: (msg: string) => void;
  private discovery: mdns.DiscoveryService | null = null;
  private readonly known: Map<string, boolean> = new Map();

  private readonly handleFound = (info: mdns.LocalServiceInfo): void => {
    const name = info.serviceName ?? '';
    if (name === '' || this.known.has(name)) return;
    this.known.set(name, true);
    this.resolve(name).catch((err: Error) => {
      this.known.delete(name);
      this.onLog(`mDNS 解析失败 ${name}: ${err.message}`);
    });
  };

  private readonly handleLost = (info: mdns.LocalServiceInfo): void => {
    const name = info.serviceName ?? '';
    if (name === '') return;
    this.known.delete(name);
    this.onLost(name);
  };

  constructor(context: common.Context,
              onFound: (camera: WifiCameraInfo) => void,
              onLost: (name: string) => void,
              onLog: (msg: string) => void) {
    this.context = context;
    this.onFound = onFound;
    this.onLost = onLost;
    this.onLog = onLog;
  }

  /** 开始浏览。幂等：已在浏览时直接返回。 */
  async start(): Promise<void> {
    if (this.discovery !== null) return;
    const discovery = mdns.createDiscoveryService(this.context, SERVICE_TYPE);
    discovery.on('serviceFound', this.handleFound);
    discovery.on('serviceLost', this.handleLost);
    this.discovery = discovery;
    this.known.clear();
    discovery.startSearchingMDNS();
    this.onLog('mDNS 开始浏览 _ptp._tcp');
  }

  /** 停止浏览并释放回调。 */
  stop(): void {
    const discovery = this.discovery;
    if (discovery === null) return;
    this.discovery = null;
    try {
      discovery.stopSearchingMDNS();
    } catch (_e) {
      // 已经停了：忽略
    }
    try {
      discovery.off('serviceFound', this.handleFound);
      discovery.off('serviceLost', this.handleLost);
    } catch (_e) {
      // 取消失败不影响释放
    }
    this.known.clear();
    this.onLog('mDNS 停止浏览');
  }

  private async resolve(name: string): Promise<void> {
    const query: mdns.LocalServiceInfo = {
      serviceType: SERVICE_TYPE,
      serviceName: name
    };
    const info = await mdns.resolveLocalService(this.context, query);
    const host = info.host?.address ?? '';
    if (host === '') {
      this.known.delete(name);
      return;
    }
    const port = info.port !== undefined && info.port > 0 ? info.port : DEFAULT_PORT;
    this.onFound({ name: name, host: host, port: port });
  }
}
