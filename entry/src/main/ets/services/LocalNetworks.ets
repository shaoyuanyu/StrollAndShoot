import { connection } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';

/**
 * 本机可用的 IPv4 网络清单：mDNS 与网段扫描的共同前置。
 *
 * 只用 `connection.getAllNets()` 是不够的 —— 它**不保证**列出没有 INTERNET
 * 能力的热点网络（本项目 SERVICES.md 早就记过这条）。而「BLE + Wi-Fi STA」
 * 链路里最典型的网络恰好就是手机热点：相机接在热点上、热点没有外网。于是
 * 网段扫描可能连候选地址都生成不出来，PTP 还没开始就结束了。
 *
 * 这里把三条来源并起来：
 * 1. `connection.getAllNets()` 的链路地址（权威，但可能漏热点）；
 * 2. `wifiManager.getIpInfo()` 的 STA 地址（`getAllNets` 偶尔也漏 STA）；
 * 3. 热点开启时补一个已知热点网段（三方应用拿不到热点接口地址，
 *    `getHotspotConfig` 之类要系统权限，只能按平台约定猜）。
 *
 * 第 3 条是启发式，所以只在「热点确实开着、且前两条没覆盖到」时才加。
 */

/** 一条本机网络快照。 */
export interface LocalNetworkInfo {
  /** 本机所有 IPv4 地址（已去重，不含回环与链路本地）。 */
  addresses: string[];
  /** 由 [addresses] 推出的 /24 前缀（`192.168.43` 这种）。 */
  subnets: string[];
  /** Wi-Fi STA 是否已连接。 */
  wifiConnected: boolean;
  /** 当前 Wi-Fi 的 SSID，拿不到为空串。 */
  wifiSsid: string;
  /** 手机热点是否开着。 */
  hotspotActive: boolean;
  /** 热点补出来的网段前缀，没补为空串。 */
  hotspotSubnet: string;
  /** 一句话人话描述，给日志与 UI 用。 */
  summary: string;
}

/**
 * 平台约定里的热点网段。
 *
 * 鸿蒙手机热点默认落在 `192.168.43.x`（本项目真机实测 `wlan1` =
 * `192.168.43.1`）。三方应用没有任何接口能读到热点接口自己的地址：
 * `getHotspotConfig` / `getHotspotIpInfo` 一类都需要系统权限。所以只能在
 * 「热点开着但没枚举到」时按约定补一个。
 */
const KNOWN_HOTSPOT_SUBNETS: string[] = ['192.168.43'];

function isIpv4(ip: string): boolean {
  const parts = ip.split('.');
  if (parts.length !== 4) return false;
  for (const p of parts) {
    const n = Number.parseInt(p, 10);
    if (!Number.isFinite(n) || n < 0 || n > 255) return false;
  }
  return true;
}

function isUsableIpv4(ip: string): boolean {
  if (!isIpv4(ip)) return false;
  return !ip.startsWith('127.') && !ip.startsWith('169.254.') && ip !== '0.0.0.0';
}

/** `a.b.c.d` → `a.b.c`。 */
export function prefixOf(ip: string): string {
  const parts = ip.split('.');
  return parts.length === 4 ? `${parts[0]}.${parts[1]}.${parts[2]}` : '';
}

/**
 * IpInfo 里的地址是整数，按 Android DhcpInfo 的老约定存：**小端**。
 * 即 `192.168.1.1` 存成 `0x0101A8C0`（低字节是第一个点分段）。
 */
function ipv4FromIntLe(value: number): string {
  const v = value >>> 0;
  return `${v & 0xFF}.${(v >>> 8) & 0xFF}.${(v >>> 16) & 0xFF}.${(v >>> 24) & 0xFF}`;
}

function ipv4FromIntBe(value: number): string {
  const v = value >>> 0;
  return `${(v >>> 24) & 0xFF}.${(v >>> 16) & 0xFF}.${(v >>> 8) & 0xFF}.${v & 0xFF}`;
}

/**
 * 私有网段的粗略打分（0 = 看着像公网地址）。
 *
 * 只用来给「同一个整数两种字节序读法」挑一个更像本机地址的，不做任何安全
 * 判断。手机所在的局域网几乎总是私网，所以这一条能把两种读法分开。
 */
function privateScore(ip: string): number {
  if (ip.startsWith('10.')) return 3;
  if (ip.startsWith('192.168.')) return 3;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(ip)) return 3;
  return 0;
}

/**
 * 取 Wi-Fi STA 的地址。
 *
 * `IpInfo.ipAddress` 的字节序没有官方文档背书：社区口径是 Android DhcpInfo 的
 * 小端约定，但本项目真机实测 `getIpInfo()` 给的是**网络序**（`10.15.98.124`
 * 读小端会变成 `124.98.15.10`）。所以两种读法都算出来，按「私网打分 + 与网关
 * 同 /24」打分取高者，**平手时选大端**（真机实测口径）。
 */
function staAddress(): string {
  try {
    const info: wifiManager.IpInfo = wifiManager.getIpInfo();
    const ip = info.ipAddress >>> 0;
    const gateway = info.gateway >>> 0;
    if (ip === 0) return '';
    const candidates: string[] = [ipv4FromIntLe(ip), ipv4FromIntBe(ip)];
    const gwLe = ipv4FromIntLe(gateway);
    const gwBe = ipv4FromIntBe(gateway);
    let best = '';
    let bestScore = -1;
    for (const candidate of candidates) {
      if (!isUsableIpv4(candidate)) continue;
      let score = privateScore(candidate);
      if (gateway !== 0) {
        const prefix = prefixOf(candidate);
        if (prefix === prefixOf(gwLe) || prefix === prefixOf(gwBe)) {
          score += 5;
        }
      }
      // `>=` 让后一个（大端）在平手时胜出。
      if (score >= bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  } catch (_e) {
    return '';
  }
}

/** 从 `connection.getAllNets()` 收集链路地址。 */
async function addressesFromNets(): Promise<string[]> {
  const out: string[] = [];
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
        if (isUsableIpv4(ip)) {
          out.push(ip);
        }
      }
    }
  } catch (_e) {
    // 拿不到网络列表不是致命错：后面还有 Wi-Fi 与热点兜底
  }
  return out;
}

function pushUnique(list: string[], value: string): void {
  if (value !== '' && !list.includes(value)) {
    list.push(value);
  }
}

/**
 * 收集本机网络信息。**任何一步失败都只降级，不抛异常** —— 调用方是扫描
 * 与自动连接，宁可少一个网段也不能因为权限/能力缺失整个流程挂掉。
 */
export async function collectLocalNetworks(): Promise<LocalNetworkInfo> {
  const addresses: string[] = [];
  for (const ip of await addressesFromNets()) {
    pushUnique(addresses, ip);
  }

  let wifiConnected = false;
  let wifiSsid = '';
  try {
    wifiConnected = wifiManager.isConnected();
  } catch (_e) {
    wifiConnected = false;
  }
  if (wifiConnected) {
    try {
      wifiSsid = wifiManager.getLinkedInfoSync().ssid ?? '';
    } catch (_e) {
      wifiSsid = '';
    }
    // 只有 `getAllNets()` 没给出同一 /24 时才补 STA 地址：`getIpInfo()` 的
    // 字节序靠猜，能不用就不用，免得把整轮扫描打到错误的网段上。
    const sta = staAddress();
    if (sta !== '' && isUsableIpv4(sta) && privateScore(sta) > 0 &&
        !addresses.some((ip: string) => prefixOf(ip) === prefixOf(sta))) {
      pushUnique(addresses, sta);
    }
  }

  let hotspotActive = false;
  try {
    hotspotActive = wifiManager.isHotspotActive();
  } catch (_e) {
    hotspotActive = false;
  }

  const subnets: string[] = [];
  for (const ip of addresses) {
    pushUnique(subnets, prefixOf(ip));
  }

  // 热点开了但枚举不到它的网段：按平台约定补一个（只补第一个没被覆盖的）。
  let hotspotSubnet = '';
  if (hotspotActive) {
    for (const guess of KNOWN_HOTSPOT_SUBNETS) {
      if (!subnets.includes(guess)) {
        hotspotSubnet = guess;
        subnets.push(guess);
        break;
      }
    }
  }

  return {
    addresses: addresses,
    subnets: subnets,
    wifiConnected: wifiConnected,
    wifiSsid: wifiSsid,
    hotspotActive: hotspotActive,
    hotspotSubnet: hotspotSubnet,
    summary: buildSummary(addresses, wifiSsid, hotspotActive, hotspotSubnet)
  };
}

/**
 * 一句话快照，只进日志（相机页不再常驻显示本机网络）。
 *
 * SSID 放最前面：拿它跟相机那边连的网络核对，比一串点分地址更好认。
 * 地址跟在后面，多个地址用 `/` 并排；热点是推断出来的，单独一句并注明。
 */
function buildSummary(addresses: string[], ssid: string, hotspotActive: boolean,
                      hotspotSubnet: string): string {
  const parts: string[] = [];
  if (ssid !== '') {
    parts.push(`Wi-Fi「${ssid}」`);
  }
  if (addresses.length > 0) {
    parts.push(addresses.join(' / '));
  } else {
    parts.push('无 IP');
  }
  if (hotspotActive) {
    parts.push(hotspotSubnet !== '' ? `热点 ${hotspotSubnet}.x（推断）` : '热点已开');
  }
  return parts.join(' · ');
}

/**
 * 给用户看的「为什么扫不到相机」。
 *
 * 返回空串表示网络前提没问题，扫不到就是相机那边的事；非空表示先把网络
 * 收拾好再试。
 */
export function networkHint(info: LocalNetworkInfo): string {
  if (info.addresses.length === 0) {
    return '手机当前没有任何可用网络。STA 模式需要手机先开热点或连上同一 Wi-Fi。';
  }
  if (!info.wifiConnected && !info.hotspotActive) {
    return 'Wi-Fi 与热点都没开，相机不在任何可达网络里。';
  }
  if (info.subnets.length === 0) {
    return '没有可探测的网段，无法搜索相机。';
  }
  return '';
}
