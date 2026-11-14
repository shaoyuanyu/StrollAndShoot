import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 程序化加入相机热点（Wi-Fi AP 模式）。
 *
 * 「BLE + Wi-Fi AP」这条链路的中间一环：BLE 握手时读到的 `0x2004` 里有相机
 * 热点的 SSID / 密码 / 安全类型，写 `0x2005=0x01` 让相机把热点起起来，这里
 * 负责让手机真的连上去。
 *
 * 三方应用只有**候选配置族**可用（`connectToNetwork` / `disconnect` 都要
 * `MANAGE_WIFI_CONNECTION` 系统权限，拿不到），所以：
 *
 * - `addCandidateConfig` + `connectToCandidateConfig`：只要
 *   `ohos.permission.SET_WIFI_INFO`（normal / 系统授权，声明即得），且必须在
 *   前台发起；
 * - 静默连接没有回执，上链与否全靠轮询 `isConnected()` + `getLinkedInfoSync().ssid`；
 * - 6 秒没上链就升级成 `connectToCandidateConfigWithUserAction`（API 20+，
 *   弹系统确认框），弹窗与轮询并行，用户拒绝/不响应就如实收场；
 * - 退出只能 `removeCandidateConfig`：三方应用关不掉 Wi-Fi 总闸，也调不了
 *   `disconnect()`。
 */

/** join 结果：成功时 [host] 是相机在热点网段上的地址（通常就是网关）。 */
export interface ApJoinOutcome {
  ok: boolean;
  host: string;
  reason: string;
}

const POLL_MS = 1000;
/** 上链总限：相机热点要起来、关联、DHCP，给足 30 秒。 */
const JOIN_TIMEOUT_MS = 30000;
/** 静默连接多久没上链就升级成系统确认弹窗。 */
const ESCALATE_AFTER_MS = 6000;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

function ipv4FromIntLe(value: number): string {
  const v = value >>> 0;
  return `${v & 0xFF}.${(v >>> 8) & 0xFF}.${(v >>> 16) & 0xFF}.${(v >>> 24) & 0xFF}`;
}

function ipv4FromIntBe(value: number): string {
  const v = value >>> 0;
  return `${(v >>> 24) & 0xFF}.${(v >>> 16) & 0xFF}.${(v >>> 8) & 0xFF}.${v & 0xFF}`;
}

function prefixOf(ip: string): string {
  const parts = ip.split('.');
  return parts.length === 4 ? `${parts[0]}.${parts[1]}.${parts[2]}` : '';
}

export class WifiApJoiner {
  private readonly onLog: (msg: string) => void;
  private ownedNetworkId: number = -1;
  private joinedSsid: string = '';
  private cancelled: boolean = false;

  constructor(onLog: (msg: string) => void) {
    this.onLog = onLog;
  }

  /**
   * 0x2004 的安全字节 → 系统枚举。
   *
   * 映射与 ZPill 的真机收口一致：0x00 / 0x01 一律按开放（Zf 的开放热点也会
   * 解出「展示用密码」，只看密码非空会配成 WPA2 然后关联失败）；0x03 走
   * SAE（WPA3）；其余有密码的走 PSK。
   */
  private securityTypeOf(security: number, password: string): wifiManager.WifiSecurityType {
    if (security === 0x00 || security === 0x01 || password === '') {
      return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN;
    }
    if (security === 0x03) {
      return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_SAE;
    }
    return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK;
  }

  /** 加入相机热点。 */
  async join(ssid: string, password: string, security: number): Promise<ApJoinOutcome> {
    this.cancelled = false;
    if (ssid === '') {
      return { ok: false, host: '', reason: '相机凭据里没有 SSID（0x2004 没解出来）' };
    }
    try {
      if (!wifiManager.isWifiActive()) {
        // Wi-Fi 总开关在系统手里：enableWifi 要 MANAGE_WIFI_CONNECTION，拿不到。
        return { ok: false, host: '', reason: '手机的 Wi-Fi 总开关是关的，请先打开 Wi-Fi' };
      }
    } catch (err) {
      this.onLog(`isWifiActive 失败: ${(err as BusinessError).message}`);
    }

    // 清掉上一次的候选配置，避免残留里同名网络打架。
    await this.leave();

    const securityType = this.securityTypeOf(security, password);
    const cfg: wifiManager.WifiDeviceConfig = {
      ssid: ssid,
      preSharedKey: securityType === wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN ? '' : password,
      securityType: securityType
    };
    let networkId: number;
    try {
      networkId = await wifiManager.addCandidateConfig(cfg);
    } catch (err) {
      const e = err as BusinessError;
      return { ok: false, host: '', reason: `添加热点配置失败 ${e.code}: ${e.message}` };
    }
    if (networkId < 0) {
      return { ok: false, host: '', reason: '相机热点配置被系统拒绝' };
    }
    this.ownedNetworkId = networkId;
    this.joinedSsid = ssid;
    this.onLog(`加入相机热点「${ssid}」（networkId ${networkId}，安全类型 ${securityType}）`);
    try {
      wifiManager.connectToCandidateConfig(networkId);
    } catch (err) {
      this.onLog(`connectToCandidateConfig 失败: ${(err as BusinessError).message}`);
    }
    return await this.pollJoin(ssid, networkId);
  }

  /** 轮询等上链；6 秒没上链升级成系统确认弹窗。 */
  private async pollJoin(ssid: string, networkId: number): Promise<ApJoinOutcome> {
    const deadline = Date.now() + JOIN_TIMEOUT_MS;
    const escalateAt = Date.now() + ESCALATE_AFTER_MS;
    let escalated = false;
    while (Date.now() < deadline) {
      if (this.cancelled) {
        return { ok: false, host: '', reason: '已取消' };
      }
      if (await this.isLinkedTo(ssid)) {
        const hosts = this.candidateHosts();
        this.onLog(`已连上相机热点「${ssid}」，候选地址 ${hosts.join(' / ')}`);
        return { ok: true, host: hosts.length > 0 ? hosts[0] : '', reason: '' };
      }
      if (!escalated && Date.now() >= escalateAt) {
        escalated = true;
        this.onLog('6 秒未上链，升级为系统确认');
        wifiManager.connectToCandidateConfigWithUserAction(networkId).then(() => {
          this.onLog('系统确认已通过');
        }).catch((err: BusinessError) => {
          this.onLog(`系统确认被拒/无响应 ${err.code}: ${err.message}`);
        });
      }
      await sleep(POLL_MS);
    }
    return { ok: false, host: '', reason: '连接相机热点超时' };
  }

  /**
   * 是否已经挂到相机热点上。
   *
   * **不要用同步版**（1.66.15）：`getLinkedInfoSync()` / `isConnected()` 都是同步
   * napi，绑在 JS 线程上做 binder 往返；这个函数在 `pollJoin()` 里被每 400ms
   * 调一次，热点还在关联时每一次都可能等上几百毫秒，全算在主线程头上。
   * `getLinkedInfo()` 是 Promise 版，失败（没连上）就当未上链。
   */
  private async isLinkedTo(ssid: string): Promise<boolean> {
    try {
      const linked: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo();
      const name = linked.ssid ?? '';
      return name === ssid || (name.length > 0 && name.includes(ssid));
    } catch (_e) {
      return false;
    }
  }

  /**
   * 相机地址候选。
   *
   * 相机 AP 模式下它就是网关，但 `getIpInfo()` 的字节序没有官方文档背书
   * （本项目真机实测是网络序，社区口径是 Android 小端），所以两种读法都
   * 给出来，由调用方逐个试 TCP —— 一次 700ms 的 connect 比猜错强。
   */
  candidateHosts(): string[] {
    const out: string[] = [];
    try {
      const info = wifiManager.getIpInfo();
      const gateway = info.gateway >>> 0;
      const self = info.ipAddress >>> 0;
      if (gateway !== 0) {
        const le = ipv4FromIntLe(gateway);
        const be = ipv4FromIntBe(gateway);
        if (!out.includes(le)) out.push(le);
        if (!out.includes(be)) out.push(be);
      }
      if (self !== 0) {
        const prefix = prefixOf(ipv4FromIntLe(self));
        if (prefix !== '') {
          const guessLe = `${prefix}.1`;
          if (!out.includes(guessLe)) out.push(guessLe);
        }
        const prefixBe = prefixOf(ipv4FromIntBe(self));
        if (prefixBe !== '') {
          const guessBe = `${prefixBe}.1`;
          if (!out.includes(guessBe)) out.push(guessBe);
        }
      }
    } catch (_e) {
      // 拿不到就交给调用方用网段扫描兜底
    }
    return out;
  }

  /** 当前是否就挂在相机热点上。 */
  async isOnCameraAp(): Promise<boolean> {
    return this.joinedSsid !== '' && await this.isLinkedTo(this.joinedSsid);
  }

  /**
   * 离开相机热点。
   *
   * 三方应用唯一的操作是 `removeCandidateConfig` —— 删掉候选配置，系统随后
   * 会从这张网离开。没有 `disconnect()`（要系统权限），所以这里删完要轮询
   * 确认真的脱离了，没脱离就如实报，别让上层以为已经离开。
   */
  async leave(): Promise<void> {
    this.cancelled = true;
    const ssid = this.joinedSsid;
    const networkId = this.ownedNetworkId;
    this.joinedSsid = '';
    this.ownedNetworkId = -1;
    if (networkId < 0) return;
    try {
      await wifiManager.removeCandidateConfig(networkId);
      this.onLog(`已删除相机热点候选配置（networkId ${networkId}）`);
    } catch (err) {
      this.onLog(`removeCandidateConfig 失败: ${(err as BusinessError).message}`);
    }
    if (ssid === '') return;
    // 确认真的下来了；没下来也不抛，上层会按"相机仍在 Wi-Fi"处理。
    for (let i = 0; i < 8; i++) {
      if (!this.isLinkedTo(ssid)) {
        this.onLog('已离开相机热点');
        return;
      }
      await sleep(500);
    }
    this.onLog('仍挂在相机热点上（系统未立即切换），相机的 Wi-Fi 待机计时会接管');
  }
}
