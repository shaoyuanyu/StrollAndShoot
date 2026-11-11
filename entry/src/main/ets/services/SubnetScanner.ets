import { socket } from '@kit.NetworkKit';
import { collectLocalNetworks } from './LocalNetworks';
import type { WifiCameraInfo } from './NsdScanner';

const PTP_PORT = 15740;
/** 单个地址的 TCP connect 预算；相机热点局域网内通常几十毫秒就回。 */
const CONNECT_TIMEOUT_MS = 700;
/** 并发探测数。太高会被相机/路由器当扫描，太低一轮要几十秒。 */
const CONCURRENCY = 12;
/** 候选总量上限，防止 /16 之类的大网段把一轮拖到几分钟。 */
const MAX_CANDIDATES = 512;

/**
 * /24 网段扫描（mDNS 的兜底发现）。
 *
 * 相机在 AP/STA 模式下如果 mDNS 广播被网络设备挡掉（客户端隔离、访客网络），
 * Bonjour 会一个都收不到；这时只能按网段逐个试 15740。做法与 ZPill 的
 * `subnet_scan` 一致：
 *
 * 1. 用 `LocalNetworks` 收集本机所有网段（含热点兜底），各展开 1..254（跳过本机）；
 * 2. 并发 TCP connect，**只连不发送任何字节**——相机的 PTP/IP 服务是单连接
 *    服务器，乱发 Init 会把正在配对的会话踢掉；
 * 3. 端口开放的主机作为候选返回，由用户点选后再走正式 PTP/IP。
 */
export class SubnetScanner {
  private readonly onLog: (msg: string) => void;
  private cancelled: boolean = false;

  constructor(onLog: (msg: string) => void) {
    this.onLog = onLog;
  }

  cancel(): void {
    this.cancelled = true;
  }

  async scan(): Promise<WifiCameraInfo[]> {
    this.cancelled = false;
    const hosts = await this.collectCandidates();
    this.onLog(`网段扫描: ${hosts.length} 个候选地址`);
    const found: WifiCameraInfo[] = [];
    for (let i = 0; i < hosts.length; i += CONCURRENCY) {
      if (this.cancelled) break;
      const batch = hosts.slice(i, i + CONCURRENCY);
      const results = await Promise.all(batch.map((h: string) => this.probe(h)));
      for (const r of results) {
        if (r !== null) {
          found.push(r);
        }
      }
    }
    this.onLog(`网段扫描完成: ${found.length} 个主机开放 ${PTP_PORT}`);
    return found;
  }

  /**
   * 展开候选地址。
   *
   * 网段来源交给 `LocalNetworks`（`getAllNets` + Wi-Fi STA  + 热点启发式），
   * 这里只负责把 /24 展开成主机地址并**排优先级**：手机热点网段排最前，
   * 因为 STA 链路里相机最可能就在那儿；热点没有外网、mDNS 常被挡，网段扫描
   * 往往是唯一出路，不能让它排在办公网后面等十几秒。
   */
  private async collectCandidates(): Promise<string[]> {
    const out: string[] = [];
    if (await this.isCancelled()) return out;
    const info = await collectLocalNetworks();
    this.onLog(`本机网络: ${info.summary}`);
    const ordered: string[] = [];
    if (info.hotspotSubnet !== '') {
      ordered.push(info.hotspotSubnet);
    }
    for (const subnet of info.subnets) {
      if (!ordered.includes(subnet)) {
        ordered.push(subnet);
      }
    }
    const seen = new Set<string>();
    for (const base of ordered) {
      for (let n = 1; n <= 254; n++) {
        const host = `${base}.${n}`;
        if (info.addresses.includes(host) || seen.has(host)) continue;
        seen.add(host);
        out.push(host);
        if (out.length >= MAX_CANDIDATES) return out;
      }
    }
    return out;
  }

  private probe(host: string): Promise<WifiCameraInfo | null> {
    return new Promise<WifiCameraInfo | null>((resolve: (v: WifiCameraInfo | null) => void) => {
      let settled = false;
      const finish = (value: WifiCameraInfo | null): void => {
        if (settled) return;
        settled = true;
        resolve(value);
      };
      let tcp: socket.TCPSocket | null = null;
      try {
        tcp = socket.constructTCPSocketInstance();
        const addr: socket.NetAddress = { address: host, port: PTP_PORT };
        const options: socket.TCPConnectOptions = { address: addr, timeout: CONNECT_TIMEOUT_MS };
        tcp.connect(options).then(() => {
          finish({ name: host, host: host, port: PTP_PORT });
          tcp?.close().catch((_e: Error) => {});
        }).catch((_e: Error) => {
          finish(null);
        });
      } catch (_e) {
        finish(null);
      }
    });
  }

  private async isCancelled(): Promise<boolean> {
    return this.cancelled;
  }
}
