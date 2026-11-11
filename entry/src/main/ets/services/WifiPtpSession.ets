import { PtpPriority, PtpEndpointKind, PtpError, PTP_ERR_USB, PTP_ERR_NOT_OPEN,
  ptpParseDeviceInfo, ptpParseStorageIDs, ptpParseObjectHandles, ptpParseObjectInfo,
  ptpParseObjectPropList, type PtpEndpoint, type PtpTransport, type DeviceInfo,
  type ObjectInfo, type ObjectPropList } from '../pages/PtpHost';
import { WifiPtpLink, type PtpIpResult } from './WifiPtpLink';

/** PTP 操作码（标准 PTP + MTP 扩展）。 */
const OP_GET_DEVICE_INFO = 0x1001;
const OP_OPEN_SESSION = 0x1002;
const OP_CLOSE_SESSION = 0x1003;
const OP_GET_STORAGE_IDS = 0x1004;
const OP_GET_OBJECT_HANDLES = 0x1007;
const OP_GET_OBJECT_INFO = 0x1008;
const OP_GET_OBJECT = 0x1009;
const OP_GET_THUMB = 0x100A;
const OP_GET_PARTIAL_OBJECT = 0x101B;
const OP_GET_OBJECT_PROP_LIST = 0x9805;
const OP_GET_PAIRING_CODE = 0x952B;
const OP_COMPLETE_PAIRING = 0x935A;

const RESPONSE_OK = 0x2001;
const RESPONSE_SESSION_ALREADY_OPEN = 0x201E;
/** SnapBridge 会话可能拒绝 GetStorageIDs：枚举时用这个哨兵。 */
const ALL_STORAGES = 0xFFFFFFFF;

const DEFAULT_PORT = 15740;

/**
 * `PtpTransport` 的 Wi-Fi 实现（PTP/IP over TCP 15740）。
 *
 * 与 `PtpHost.PtpSession`（USB）实现同一个契约，所以 `CameraService` 的
 * 扫描、缩略图、下载流程一行都不用改——只是换了一条链路。
 *
 * 几个尼康实测差异（来自 ZPill / N-Link / Camera_Bridge 的真机记录）：
 * - `GetStorageIDs` 在 SnapBridge 会话里可能被拒，枚举改用 `0xFFFFFFFF`；
 * - 部分机型要求先做一次「主机注册」（0x952B/0x935A）才肯接受会话，
 *   这一步还没接进来，首次连接失败时优先怀疑它；
 * - 相机是单连接服务器，断开后要留一点时间再重连。
 */
export class WifiPtpSession implements PtpTransport {
  private link: WifiPtpLink | null = null;
  private open: boolean = false;
  private broken: boolean = false;
  private label: string = '';
  private log: (msg: string) => void = (_m: string) => {};
  private onBrokenUp: (reason: string) => void = (_r: string) => {};

  /** 与 USB 实现保持一致：0x201E 且 CloseSession 救不回来时置位。 */
  sessionConflict: boolean = false;

  get connectedDeviceName(): string {
    return this.label !== '' ? this.label : (this.link?.cameraName ?? '');
  }

  setLog(fn: (msg: string) => void): void {
    this.log = fn;
  }

  /**
   * 链路意外断开的上报口。
   *
   * 以前 `broken` 只是内部标志：事务里抛个错就完了，上层看到的只是「某次操作
   * 失败」，没人知道整条链路已经死了。相机一休眠，App 就静默停在「已连接」，
   * 点什么都失败。`CameraService` 接这个回调去排自动重连。
   *
   * 注意只报**非主动**断开：`closeSessionAndPipe()` 里会先清掉 handler，
   * 用户自己断开不会触发重连。
   */
  setBrokenHandler(fn: (reason: string) => void): void {
    this.onBrokenUp = fn;
  }

  async connect(endpoint: PtpEndpoint, _priority?: PtpPriority): Promise<boolean> {
    if (endpoint.kind !== PtpEndpointKind.WIFI || endpoint.host === undefined) {
      this.log('WifiPtpSession 只支持 Wi-Fi 端点');
      return false;
    }
    if (this.link) {
      await this.closeSessionAndPipe();
    }

    const host = endpoint.host;
    const port = endpoint.port ?? DEFAULT_PORT;
    this.label = endpoint.label !== undefined && endpoint.label !== '' ? endpoint.label : host;
    this.broken = false;
    this.sessionConflict = false;

    const link = new WifiPtpLink();
    link.setLog(this.log);
    link.setBrokenHandler((reason: string) => {
      this.broken = true;
      this.log(`[Wi-Fi] 链路断开: ${reason}`);
      // `connect()` 失败也会走到这里（同一个 handler）；只有**已经建立过
      // 会话**的断开才算「运行中断链」，否则会在连接失败的瞬间排出重连，
      // 和用户正在点的那次连接打架。
      const wasOpen = this.open;
      this.open = false;
      if (wasOpen) {
        this.onBrokenUp(reason);
      }
    });
    link.onEvent = (code: number, params: number[]) => {
      this.log(`[Wi-Fi] 相机事件 0x${code.toString(16)} params=${params.length}`);
    };
    this.link = link;

    const ok = await link.connect(host, port);
    if (!ok) {
      await link.close();
      this.link = null;
      return false;
    }

    // OpenSession：与 USB 一样，0x201E 时补发一次 CloseSession 再重试。
    let opened = await this.tryOpenSession(1);
    if (!opened) {
      const conflict = await this.tryCloseSession();
      if (conflict) {
        this.sessionConflict = true;
        this.log('OpenSession: 相机仍挂着上一次会话 (0x201E)，补发 CloseSession 后重试');
        opened = await this.tryOpenSession(1);
      }
    }
    if (!opened) {
      this.log('OpenSession 失败');
      await link.close();
      this.link = null;
      return false;
    }
    this.open = true;
    return true;
  }

  private async tryOpenSession(sessionId: number): Promise<boolean> {
    try {
      const r = await this.exec(OP_OPEN_SESSION, [sessionId], false, 'OpenSession');
      return r.code === RESPONSE_OK;
    } catch (err) {
      this.log(`OpenSession 异常: ${(err as Error).message}`);
      return false;
    }
  }

  private async tryCloseSession(): Promise<boolean> {
    try {
      const r = await this.exec(OP_CLOSE_SESSION, [], false, 'CloseSession');
      return r.code === RESPONSE_OK || r.code === 0x2003;
    } catch (_err) {
      return false;
    }
  }

  async getDeviceInfo(_priority?: PtpPriority): Promise<DeviceInfo | null> {
    if (!this.open) return null;
    try {
      const r = await this.exec(OP_GET_DEVICE_INFO, [], true, 'GetDeviceInfo');
      if (r.code !== RESPONSE_OK || !r.data) return null;
      return ptpParseDeviceInfo(r.data);
    } catch (err) {
      this.log(`GetDeviceInfo 失败: ${(err as Error).message}`);
      return null;
    }
  }

  async getStorageIDs(_priority?: PtpPriority): Promise<number[]> {
    if (!this.open) throw new PtpError('GetStorageIDs', PTP_ERR_NOT_OPEN);
    const r = await this.exec(OP_GET_STORAGE_IDS, [], true, 'GetStorageIDs');
    if (r.code !== RESPONSE_OK || !r.data) {
      // 部分机型的 SnapBridge 会话拒绝这条命令；用「所有存储」哨兵继续，
      // 后续 GetObjectHandles 会按 0xFFFFFFFF 枚举。
      this.log(`GetStorageIDs 被拒 (0x${r.code.toString(16)})，改用 0xFFFFFFFF 哨兵`);
      return [ALL_STORAGES];
    }
    const ids = ptpParseStorageIDs(r.data);
    return ids.length > 0 ? ids : [ALL_STORAGES];
  }

  async getObjectHandles(storageId: number, parent?: number, formatCode?: number,
    _priority?: PtpPriority): Promise<number[]> {
    if (!this.open) throw new PtpError('GetObjectHandles', PTP_ERR_NOT_OPEN);
    const r = await this.exec(OP_GET_OBJECT_HANDLES,
      [storageId, formatCode ?? 0, parent ?? 0], true, 'GetObjectHandles');
    if (r.code !== RESPONSE_OK || !r.data) {
      throw new PtpError('GetObjectHandles', r.code);
    }
    return ptpParseObjectHandles(r.data);
  }

  async getObjectInfo(handle: number, _priority?: PtpPriority): Promise<ObjectInfo | null> {
    if (!this.open) return null;
    try {
      const r = await this.exec(OP_GET_OBJECT_INFO, [handle], true, 'GetObjectInfo');
      if (r.code !== RESPONSE_OK || !r.data) return null;
      return ptpParseObjectInfo(r.data, handle);
    } catch (err) {
      this.log(`GetObjectInfo(${handle}) 失败: ${(err as Error).message}`);
      return null;
    }
  }

  async getThumb(handle: number, _priority?: PtpPriority): Promise<Uint8Array | null> {
    if (!this.open) return null;
    try {
      const r = await this.exec(OP_GET_THUMB, [handle], true, 'GetThumb');
      return r.code === RESPONSE_OK ? r.data : null;
    } catch (err) {
      this.log(`GetThumb(${handle}) 失败: ${(err as Error).message}`);
      return null;
    }
  }

  async getObject(handle: number, _priority?: PtpPriority): Promise<Uint8Array | null> {
    if (!this.open) return null;
    try {
      const r = await this.exec(OP_GET_OBJECT, [handle], true, 'GetObject');
      return r.code === RESPONSE_OK ? r.data : null;
    } catch (err) {
      this.log(`GetObject(${handle}) 失败: ${(err as Error).message}`);
      return null;
    }
  }

  async getPartialObject(handle: number, offset: number, maxBytes: number,
    _priority?: PtpPriority): Promise<Uint8Array | null> {
    if (!this.open) return null;
    try {
      const r = await this.exec(OP_GET_PARTIAL_OBJECT, [handle, offset, maxBytes], true,
        'GetPartialObject');
      return r.code === RESPONSE_OK ? r.data : null;
    } catch (err) {
      this.log(`GetPartialObject(${handle}) 失败: ${(err as Error).message}`);
      return null;
    }
  }

  async getObjectPropList(objectHandle: number, formatCode: number, propertyCode: number,
    groupCode: number, depth: number, _priority?: PtpPriority): Promise<ObjectPropList> {
    if (!this.open) throw new PtpError('GetObjectPropList', PTP_ERR_NOT_OPEN);
    const r = await this.exec(OP_GET_OBJECT_PROP_LIST,
      [objectHandle, formatCode, propertyCode, groupCode, depth], true, 'GetObjectPropList');
    if (r.code !== RESPONSE_OK || !r.data) {
      throw new PtpError('GetObjectPropList', r.code);
    }
    return ptpParseObjectPropList(r.data);
  }

  /**
   * 取配对验证码（Nikon 0x952B，data-in）。
   *
   * 数据集是 `count(u32 LE) + count 个字节`，每个字节的十进制值连起来就是
   * 验证码（例：`05 00 07 07` → `"5077"`）。返回 null 表示相机不要求配对
   * （已配对过、或本来就不启用），调用方应直接按已配对处理。
   */
  async getPairingCode(): Promise<string | null> {
    if (!this.open) return null;
    try {
      const r = await this.exec(OP_GET_PAIRING_CODE, [], true, 'GetPtpIpPairingCode');
      if (r.code !== RESPONSE_OK || !r.data || r.data.length < 4) {
        return null;
      }
      const count = r.data[0] | (r.data[1] << 8) | (r.data[2] << 16) | (r.data[3] << 24);
      if (count <= 0 || count > r.data.length - 4) return null;
      let code = '';
      for (let i = 0; i < count; i++) {
        code += r.data[4 + i].toString(10);
      }
      this.log(`配对验证码: ${code}`);
      return code;
    } catch (err) {
      this.log(`GetPtpIpPairingCode 失败: ${(err as Error).message}`);
      return null;
    }
  }

  /**
   * 确认配对（Nikon 0x935A，参数 0x2001）。
   *
   * 相机把本客户端的 16B GUID 记为已配对主机。Z50II 实测：相机在回响应之前
   * 就收线，所以链路异常按「已完成」处理；只有明确的非 OK 拒答才算失败。
   */
  async completePairing(): Promise<boolean> {
    if (!this.open) return false;
    try {
      const r = await this.exec(OP_COMPLETE_PAIRING, [0x2001], false, 'CompletePairing');
      return r.code === RESPONSE_OK;
    } catch (err) {
      this.log(`CompletePairing 链路异常（按配对完成处理）: ${(err as Error).message}`);
      return true;
    }
  }

  async closeSessionAndPipe(_priority?: PtpPriority): Promise<void> {
    const link = this.link;
    if (!link) {
      this.open = false;
      return;
    }
    if (this.open) {
      try {
        await this.exec(OP_CLOSE_SESSION, [], false, 'CloseSession');
      } catch (_err) {
        // 相机已经断开：直接关 socket
      }
    }
    this.open = false;
    this.link = null;
    await link.close();
  }

  private async exec(opcode: number, params: number[], expectData: boolean,
    name: string): Promise<PtpIpResult> {
    const link = this.link;
    if (!link) {
      throw new PtpError(name, PTP_ERR_NOT_OPEN);
    }
    if (this.broken) {
      throw new PtpError(name, PTP_ERR_USB, 'PTP/IP 链路已断开');
    }
    try {
      return await link.transaction(opcode, params, expectData);
    } catch (err) {
      const msg = (err as Error).message;
      this.log(`${name} 失败: ${msg}`);
      throw new PtpError(name, PTP_ERR_USB, msg);
    }
  }
}
