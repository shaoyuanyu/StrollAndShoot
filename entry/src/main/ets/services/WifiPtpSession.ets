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

  /** 与 USB 实现保持一致：0x201E 且 CloseSession 救不回来时置位。 */
  sessionConflict: boolean = false;

  get connectedDeviceName(): string {
    return this.label !== '' ? this.label : (this.link?.cameraName ?? '');
  }

  setLog(fn: (msg: string) => void): void {
    this.log = fn;
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
