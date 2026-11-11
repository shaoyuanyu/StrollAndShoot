import { socket, connection } from '@kit.NetworkKit';
import type { WifiCameraInfo } from './NsdScanner';

const PTP_PORT = 15740;
/** 单个地址的 TCP connect 预算；相机热点局域网内通常几十毫秒就回。 */
const CONNECT_TIMEOUT_MS = 700;
/** 并发探测数。太高会被相机/路由器当扫描，太低一轮要几十秒。 */
const CONCURRENCY = 12;
/** 候选总量上限，防止 /16 之类的大网段把一轮拖到几分钟。 */
const MAX_CANDIDATES = 512;

function isIpv4(ip: string): boolean {
  const parts = ip.split('.');
  if (parts.length !== 4) return false;
  for (const p of parts) {
    const n = Number.parseInt(p, 10);
    if (!Number.isFinite(n) || n < 0 || n > 255) return false;
  }
  return true;
}

/**
 * /24 网段扫描（mDNS 的兜底发现）。
 *
 * 相机在 AP/STA 模式下如果 mDNS 广播被网络设备挡掉（客户端隔离、访客网络），
 * Bonjour 会一个都收不到；这时只能按网段逐个试 15740。做法与 ZPill 的
 * `subnet_scan` 一致：
 *
 * 1. 取本机所有 IPv4 接口地址，各展开所在 /24 的 1..254（跳过本机）；
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

  private async collectCandidates(): Promise<string[]> {
    const out: string[] = [];
    if (await this.isCancelled()) return out;
    const seen = new Set<string>();
    try {
      const nets = await connection.getAllNets();
      for (const net of nets) {
        let props: connection.ConnectionProperties;
        try {
          props = connection.getConnectionPropertiesSync(net);
        } catch (_e) {
          continue;
        }
        const links = props.linkAddresses;
        if (!links) continue;
        for (const link of links) {
          const ip = link.address.address;
          if (!isIpv4(ip)) continue;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          const parts = ip.split('.');
          const base = `${parts[0]}.${parts[1]}.${parts[2]}`;
          for (let n = 1; n <= 254; n++) {
            const host = `${base}.${n}`;
            if (host === ip || seen.has(host)) continue;
            seen.add(host);
            out.push(host);
            if (out.length >= MAX_CANDIDATES) return out;
          }
        }
      }
    } catch (err) {
      this.onLog(`网段候选获取失败: ${(err as Error).message}`);
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
