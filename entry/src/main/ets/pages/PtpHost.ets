import usbManager from '@ohos.usbManager';
import rawPtp from 'libentry.so';
import hilog from '@ohos.hilog';
import { AppLog } from '../services/AppLog';

const TAG = 'PtpHost';

interface PtpApi {
  buildOpenSession(sessionId: number): Uint8Array;
  buildCloseSession(): Uint8Array;
  buildGetDeviceInfo(): Uint8Array;
  buildGetStorageIDs(): Uint8Array;
  buildGetObjectHandles(storageId: number, formatCode?: number, parentHandle?: number): Uint8Array;
  buildGetObjectInfo(objectHandle: number): Uint8Array;
  buildGetThumb(objectHandle: number): Uint8Array;
  buildGetObject(objectHandle: number): Uint8Array;
  buildGetPartialObject(objectHandle: number, offset: number, maxBytes: number): Uint8Array;
  processResponse(data: Uint8Array, expectData: boolean): ProcessResult;
  parseDeviceInfo(data: Uint8Array): DeviceInfo;
  parseStorageIDs(data: Uint8Array): number[];
  parseObjectHandles(data: Uint8Array): number[];
  parseObjectInfo(data: Uint8Array, handle: number): ObjectInfo;
}

interface ProcessResult {
  action: number;
  responseCode?: number;
  data?: Uint8Array;
}
export interface DeviceInfo {
  manufacturer: string;
  model: string;
  deviceVersion: string;
  serialNumber: string;
  vendorExtensionID: number;
}
export interface ObjectInfo {
  filename: string;
  objectCompressedSize: number;
  objectFormat: number;
  captureDate: string;
  modificationDate: string;
  imagePixWidth: number;
  imagePixHeight: number;
  storageId: number;
}

const ptpNative = rawPtp as PtpApi;

/** 传输/通道层失败（bulkTransfer 返回负值、超时、IN 读失败等）。 */
export const PTP_ERR_USB = -1;
/** 会话未打开（OpenSession 未成功或被关闭）。 */
export const PTP_ERR_NOT_OPEN = -2;

/**
 * PTP 事务失败。
 *
 * `code > 0` 是相机返回的 PTP 响应码（例如 `0x200F AccessDenied`），
 * `code < 0` 是传输层错误（见 `PTP_ERR_USB` / `PTP_ERR_NOT_OPEN`）。
 * 以前这里把失败折叠成 `null` / `[]`，业务层无法区分「拒绝访问」与「没有存储」，
 * 于是把 `0x200F` 误报成「相机没有存储设备」。
 */
export class PtpError extends Error {
  readonly operation: string;
  readonly code: number;

  constructor(operation: string, code: number, detail?: string) {
    super(detail ?? `${operation} failed (code=${code >= 0 ? '0x' + code.toString(16) : code})`);
    this.name = 'PtpError';
    this.operation = operation;
    this.code = code;
  }
}

/** 响应码 → 可读名字，仅用于日志与文案。 */
export function ptpResponseName(code: number): string {
  switch (code) {
    case 0x2001: return 'OK';
    case 0x2002: return 'GeneralError';
    case 0x2003: return 'SessionNotOpen';
    case 0x2004: return 'InvalidTransactionID';
    case 0x2005: return 'OperationNotSupported';
    case 0x2006: return 'ParameterNotSupported';
    case 0x2008: return 'InvalidStorageId';
    case 0x2009: return 'InvalidObjectHandle';
    case 0x200A: return 'DevicePropNotSupported';
    case 0x200B: return 'InvalidObjectFormatCode';
    case 0x200C: return 'StoreFull';
    case 0x200D: return 'ObjectWriteProtected';
    case 0x200E: return 'StoreReadOnly';
    case 0x200F: return 'AccessDenied';
    case 0x2010: return 'NoThumbnailPresent';
    case 0x2013: return 'StoreNotAvailable';
    case 0x2019: return 'DeviceBusy';
    default: return '';
  }
}

let sharedLog: AppLog | null = null;
export function setPtpLog(log: AppLog): void { sharedLog = log; }
function log(msg: string): void {
  // AppLog.add 内部已经写 hilog；以前这里再写一次，导致每条 PTP 报文在
  // hilog 里出现两遍（ISSUE-007 的日志放大）。
  if (sharedLog) {
    sharedLog.add(msg);
  } else {
    hilog.info(0x0000, TAG, '%{public}s', msg);
  }
}
function logHex(label: string, data: Uint8Array): void {
  let hex = '';
  const len = data.length < 32 ? data.length : 32;
  for (let i = 0; i < len; i++) {
    const b = data[i];
    hex = hex + (b < 16 ? '0' : '') + b.toString(16) + ' ';
  }
  log(`${label} (${data.length}B): ${hex}`);
}

const USB_CLASS_IMAGE = 0x06;
const USB_SUBCLASS_SIC = 0x01;
const USB_PROTO_PTP = 0x01;

export { type PhotoEntry } from '../model/PhotoEntry';

/**
 * 相机会话的传输契约。
 *
 * `CameraService` 只依赖这组方法，因此调试包可以换上一台假的 PTP 设备
 * （见 `debug/MockPtpSession.ets`），让“搜索 → 连接 → 遍历 → 取元数据 →
 * 取缩略图”的完整流程原样跑一遍，而不需要在业务代码里插数据。
 */
export interface PtpTransport {
  readonly connectedDeviceName: string;
  /** 相机侧残留了上一次会话（0x201E 且补发 CloseSession 未恢复）。调试用的虚拟相机不提供。 */
  readonly sessionConflict?: boolean;
  connect(device: usbManager.USBDevice): Promise<boolean>;
  getDeviceInfo(): Promise<DeviceInfo | null>;
  getStorageIDs(): Promise<number[]>;
  getObjectHandles(storageId: number, parent?: number, formatCode?: number): Promise<number[]>;
  getObjectInfo(handle: number): Promise<ObjectInfo | null>;
  getThumb(handle: number): Promise<Uint8Array | null>;
  getObject(handle: number): Promise<Uint8Array | null>;
  getPartialObject(handle: number, offset: number, maxBytes: number): Promise<Uint8Array | null>;
  closeSessionAndPipe(): Promise<void>;
}

export class PtpSession implements PtpTransport {
  private device: usbManager.USBDevice | null = null;
  private pipe: usbManager.USBDevicePipe | null = null;
  private bulkIn: usbManager.USBEndpoint | null = null;
  private bulkOut: usbManager.USBEndpoint | null = null;
  private intEp: usbManager.USBEndpoint | null = null;
  private sessionOpen: boolean = false;
  private usbBusy: boolean = false;
  /** 最近一条命令的响应码；0 表示还没收到过响应。 */
  private lastResponseCode: number = 0;
  /**
   * 相机侧还挂着上一次的 PTP 会话（OpenSession 返回 0x201E），且补发 CloseSession 也没救回来。
   * 应用崩溃/被系统杀掉时不会走 closeSessionAndPipe，相机会一直保留那个会话。
   */
  sessionConflict: boolean = false;

  get connectedDeviceName(): string {
    return this.device?.name ?? '';
  }

  static findCameras(): usbManager.USBDevice[] {
    const cameras: usbManager.USBDevice[] = [];
    try {
      const devices = usbManager.getDevices();
      log(`USB设备总数: ${devices.length}`);
      for (const dev of devices) {
        log(`Device: name=${dev.name} vid=0x${dev.vendorId.toString(16)} pid=0x${dev.productId.toString(16)} manu=${dev.manufacturerName} product=${dev.productName}`);
        for (const cfg of dev.configs) {
          for (const iface of cfg.interfaces) {
            if (iface.clazz === USB_CLASS_IMAGE &&
                iface.subClass === USB_SUBCLASS_SIC &&
                iface.protocol === USB_PROTO_PTP) {
              cameras.push(dev);
            }
          }
        }
      }
      log(`Found ${cameras.length} camera(s)`);
    } catch (err) {
      log(`findCameras error: ${JSON.stringify(err)}`);
    }
    return cameras;
  }

  async connect(device: usbManager.USBDevice): Promise<boolean> {
    // Close any existing connection properly before starting a new one
    if (this.pipe) {
      await this.closeSessionAndPipe();
    }

    try {
      if (!usbManager.hasRight(device.name)) {
        log(`Requesting permission for ${device.name}`);
        const granted = await usbManager.requestRight(device.name);
        if (!granted) {
          log('Permission denied');
          return false;
        }
      }

      this.pipe = usbManager.connectDevice(device);
      this.device = device;
      log(`Connected to ${device.name}`);

      if (!this.findAndClaimInterface()) {
        await this.closeSessionAndPipe();
        return false;
      }

      // Drain interrupt EP
      if (this.intEp) {
        const buf = new Uint8Array(64);
        await usbManager.bulkTransfer(this.pipe, this.intEp, buf, 150);
      }

      // Open PTP session
      const openCmd = ptpNative.buildOpenSession(1);
      let ok = await this.ptpCommand(openCmd, false);
      if (!ok && this.lastResponseCode === 0x201E) {
        // 0x201E = SessionAlreadyOpen。上一次进程崩溃/被杀时没来得及 CloseSession，
        // 相机会一直保留那个会话。规范给的恢复方式是补发 CloseSession，不必拔线。
        this.sessionConflict = true;
        log('OpenSession: 相机仍挂着上一次的会话 (0x201E)，补发 CloseSession 后重试');
        await this.ptpCommand(ptpNative.buildCloseSession(), false);
        ok = await this.ptpCommand(openCmd, false);
        log(ok ? '补发 CloseSession 后 OpenSession 成功' : '补发 CloseSession 后仍然失败');
      }
      if (!ok) {
        log(`OpenSession failed`);
        await this.closeSessionAndPipe();
        return false;
      }
      this.sessionConflict = false;
      this.sessionOpen = true;
      log('PTP session opened');
      return true;
    } catch (err) {
      log(`connect error: ${JSON.stringify(err)}`);
      if (this.pipe) {
        await this.closeSessionAndPipe();
      }
      return false;
    }
  }

  async getDeviceInfo(): Promise<DeviceInfo | null> {
    if (!this.pipe) return null;
    log('Getting device info...');
    const cmd = ptpNative.buildGetDeviceInfo();
    try {
      const data = await this.ptpCommandGetData(cmd, 'GetDeviceInfo');
      if (!data) {
        log('GetDeviceInfo returned no data');
        return null;
      }
      return ptpNative.parseDeviceInfo(data);
    } catch (err) {
      // 设备信息只用于相机身份与展示，拿不到时由调用方退回 USB 级信息，不中断扫描。
      log(`GetDeviceInfo failed: ${(err as Error).message}`);
      return null;
    }
  }

  async getStorageIDs(): Promise<number[]> {
    if (!this.sessionOpen) throw new PtpError('GetStorageIDs', PTP_ERR_NOT_OPEN);
    const cmd = ptpNative.buildGetStorageIDs();
    const data = await this.ptpCommandGetData(cmd, 'GetStorageIDs');
    if (!data) throw new PtpError('GetStorageIDs', PTP_ERR_USB, 'GetStorageIDs: empty data package');
    return ptpNative.parseStorageIDs(data);
  }

  async getObjectHandles(storageId: number, parent?: number, formatCode?: number): Promise<number[]> {
    if (!this.sessionOpen) throw new PtpError('GetObjectHandles', PTP_ERR_NOT_OPEN);
    const parentHandle = parent ?? 0xFFFFFFFF;
    const code = formatCode ?? 0;
    const cmd = ptpNative.buildGetObjectHandles(storageId, code, parentHandle);
    const data = await this.ptpCommandGetData(cmd, 'GetObjectHandles');
    if (!data) throw new PtpError('GetObjectHandles', PTP_ERR_USB, 'GetObjectHandles: empty data package');
    return ptpNative.parseObjectHandles(data);
  }

  async getObjectInfo(handle: number): Promise<ObjectInfo | null> {
    if (!this.sessionOpen) throw new PtpError('GetObjectInfo', PTP_ERR_NOT_OPEN);
    const cmd = ptpNative.buildGetObjectInfo(handle);
    const data = await this.ptpCommandGetData(cmd, 'GetObjectInfo');
    if (!data) throw new PtpError('GetObjectInfo', PTP_ERR_USB, 'GetObjectInfo: empty data package');
    return ptpNative.parseObjectInfo(data, handle);
  }

  async closeSessionAndPipe(): Promise<void> {
    if (this.sessionOpen && this.pipe && this.bulkOut && this.bulkIn) {
      try {
        const closeCmd = ptpNative.buildCloseSession();
        log('Sending CloseSession');
        const acked = await this.ptpCommand(closeCmd, false);
        if (acked) {
          log('CloseSession acknowledged');
        } else {
          // 旧代码在 OUT failed 之后仍然打印 acknowledged 并把会话记为已关闭，
          // 属于状态误报（ISSUE-006）：相机侧可能还留着旧会话。
          log('CloseSession NOT acknowledged (command send failed)');
        }
      } catch (_e) {
        log(`CloseSession error: ${JSON.stringify(_e)}`);
      }
      // 管道随后一定会被关掉，内存中的会话状态统一归位；但日志不再撒谎。
    }
    this.sessionOpen = false;
    if (this.pipe) {
      try { usbManager.closePipe(this.pipe); } catch (_e) { /* best effort */ }
      this.pipe = null;
    }
    this.device = null;
    this.bulkIn = null;
    this.bulkOut = null;
    log('Session closed');
  }

  async getThumb(handle: number): Promise<Uint8Array | null> {
    if (!this.sessionOpen) throw new PtpError('GetThumb', PTP_ERR_NOT_OPEN);
    for (let wait = 0; wait < 150; wait++) {
      if (!this.usbBusy) break;
      await new Promise<void>((r: () => void) => { setTimeout(r, 200); });
    }
    if (this.usbBusy) return null;
    this.usbBusy = true;
    try {
      log(`Getting thumb for handle 0x${handle.toString(16)}`);
      const cmd = ptpNative.buildGetThumb(handle);
      return await this.ptpCommandGetLargeData(cmd, 'GetThumb');
    } finally {
      this.usbBusy = false;
    }
  }

  async getObject(handle: number): Promise<Uint8Array | null> {
    if (!this.sessionOpen) throw new PtpError('GetObject', PTP_ERR_NOT_OPEN);
    // Wait for USB pipe to become free (up to 30s)
    for (let wait = 0; wait < 150; wait++) {
      if (!this.usbBusy) break;
      await new Promise<void>((r: () => void) => setTimeout(r, 200));
    }
    if (this.usbBusy) {
      log('USB busy timeout');
      return null;
    }
    this.usbBusy = true;
    try {
      log(`Getting object for handle 0x${handle.toString(16)}`);
      const cmd = ptpNative.buildGetObject(handle);
      return await this.ptpCommandGetLargeData(cmd, 'GetObject');
    } finally {
      this.usbBusy = false;
    }
  }

  /**
   * Read a partial segment of an object via PTP GetPartialObject.
   * Used to fetch the first 16KB of a photo for EXIF orientation reading
   * without downloading the full image.
   * @param handle PTP object handle
   * @param offset byte offset (typically 0)
   * @param maxBytes number of bytes to read (typically 16384)
   * @returns the partial data, or null if the camera doesn't support this operation
   */
  async getPartialObject(handle: number, offset: number, maxBytes: number): Promise<Uint8Array | null> {
    if (!this.sessionOpen) throw new PtpError('GetPartialObject', PTP_ERR_NOT_OPEN);
    // Wait for USB pipe to become free
    for (let wait = 0; wait < 150; wait++) {
      if (!this.usbBusy) break;
      await new Promise<void>((r: () => void) => setTimeout(r, 200));
    }
    if (this.usbBusy) {
      log('USB busy timeout');
      return null;
    }
    this.usbBusy = true;
    try {
      log(`Getting partial object for handle 0x${handle.toString(16)} offset=${offset} maxBytes=${maxBytes}`);
      const cmd = ptpNative.buildGetPartialObject(handle, offset, maxBytes);
      const result = await this.ptpCommandGetLargeData(cmd, 'GetPartialObject');
      if (result && result.length > 0) {
        log(`Got partial data: ${result.length} bytes`);
      } else {
        log('GetPartialObject returned no data (camera may not support it)');
      }
      return result;
    } finally {
      this.usbBusy = false;
    }
  }

  // ---- PTP transaction helpers ----

  /**
   * Send a command with no data phase. Returns true if response is OK.
   */
  private async ptpCommand(cmd: Uint8Array, expectData: boolean): Promise<boolean> {
    logHex('CMD OUT', cmd);
    let n = -1;
    try {
      n = await usbManager.bulkTransfer(this.pipe!, this.bulkOut!, cmd, 5000);
    } catch (err) {
      log(`OUT exception: ${JSON.stringify(err)}`);
      return false;
    }
    if (n < 0) {
      log(`OUT failed: ${n}`);
      return false;
    }

    // Read and process IN data until we get a response
    for (let attempt = 0; attempt < 10; attempt++) {
      const buf = new Uint8Array(1024);
      let rn = -1;
      try {
        rn = await usbManager.bulkTransfer(this.pipe!, this.bulkIn!, buf, 10000);
      } catch (err) {
        log(`IN exception: ${JSON.stringify(err)}`);
        return false;
      }
      if (rn < 0) {
        log(`IN failed: ${rn}`);
        return false;
      }
      if (rn === 0) {
        log('Zero-length packet, reading again');
        continue;
      }

      const inData = new Uint8Array(buf.buffer, 0, rn);
      logHex('RAW IN', inData);
      const result = ptpNative.processResponse(inData, expectData);
      log(`processResponse: action=${result.action} code=0x${(result.responseCode ?? 0).toString(16)} dataLen=${result.data ? result.data.length : 0}`);

      if (result.action === 2) { // response
        this.lastResponseCode = result.responseCode ?? 0;
        return this.lastResponseCode === 0x2001;
      }
      if (result.action === -1) { // error
        return false;
      }
      // action 0 or 1: continue reading
    }
    return false;
  }

  /**
   * Send a command that returns data.
   *
   * 成功时返回数据包；相机返回非 0x2001 响应码时抛 `PtpError`（带原始 code），
   * USB/通道失败时抛 `PtpError(PTP_ERR_USB)`。这样业务层才能区分
   * 「拒绝访问」与「没有数据」，见 ISSUE-002。
   */
  private async ptpCommandGetData(cmd: Uint8Array, op: string = 'PTP'): Promise<Uint8Array | null> {
    logHex('CMD OUT', cmd);
    let n = -1;
    try {
      n = await usbManager.bulkTransfer(this.pipe!, this.bulkOut!, cmd, 5000);
    } catch (err) {
      log(`OUT exception: ${JSON.stringify(err)}`);
      throw new PtpError(op, PTP_ERR_USB, `${op}: command send failed`);
    }
    if (n < 0) {
      log(`OUT failed: ${n}`);
      throw new PtpError(op, PTP_ERR_USB, `${op}: command send failed (${n})`);
    }

    let dataPayload: Uint8Array | null = null;

    // Read IN until we get both data and response
    for (let attempt = 0; attempt < 10; attempt++) {
      const buf = new Uint8Array(1024);
      let rn = -1;
      try {
        rn = await usbManager.bulkTransfer(this.pipe!, this.bulkIn!, buf, 10000);
      } catch (err) {
        log(`IN exception: ${JSON.stringify(err)}`);
        throw new PtpError(op, PTP_ERR_USB, `${op}: read failed`);
      }
      if (rn < 0) {
        log(`IN failed: ${rn}`);
        throw new PtpError(op, PTP_ERR_USB, `${op}: read failed (${rn})`);
      }
      if (rn === 0) {
        continue; // zero-length packet
      }

      const inData = new Uint8Array(buf.buffer, 0, rn);
      logHex('RAW IN', inData);
      const result = ptpNative.processResponse(inData, true);
      log(`processResponse: action=${result.action} code=0x${(result.responseCode ?? 0).toString(16)} dataLen=${result.data ? result.data.length : 0}`);

      if (result.action === 1 && result.data && result.data.length > 0) {
        dataPayload = result.data;
      }
      if (result.action === 2) { // got response
        const code = result.responseCode ?? 0;
        if (code === 0x2001) {
          return dataPayload;
        }
        log(`Response error: 0x${code.toString(16)} (${ptpResponseName(code)})`);
        throw new PtpError(op, code);
      }
      if (result.action === -1) {
        throw new PtpError(op, PTP_ERR_USB, `${op}: malformed response`);
      }
    }
    throw new PtpError(op, PTP_ERR_USB, `${op}: no response from camera`);
  }

  /**
   * Same as ptpCommandGetData but with larger buffer for image data (thumbnails, full photos).
   * 失败语义与 `ptpCommandGetData` 一致：相机错误码或 USB 失败都抛 `PtpError`。
   */
  private async ptpCommandGetLargeData(cmd: Uint8Array, op: string = 'PTP'): Promise<Uint8Array | null> {
    logHex('CMD OUT', cmd);
    let n = -1;
    try {
      n = await usbManager.bulkTransfer(this.pipe!, this.bulkOut!, cmd, 5000);
    } catch (err) {
      log(`OUT exception: ${JSON.stringify(err)}`);
      throw new PtpError(op, PTP_ERR_USB, `${op}: command send failed`);
    }
    if (n < 0) {
      log(`OUT failed: ${n}`);
      throw new PtpError(op, PTP_ERR_USB, `${op}: command send failed (${n})`);
    }

    let dataPayload: Uint8Array | null = null;
    let rawCount = 0;

    // Read IN until we get both data and response.
    const buf = new Uint8Array(196608);  // 192KB — under HMOS 200KB limit
    for (let attempt = 0; attempt < 350; attempt++) {
      let rn = -1;
      try {
        rn = await usbManager.bulkTransfer(this.pipe!, this.bulkIn!, buf, 10000);
      } catch (err) {
        log(`IN exception: ${JSON.stringify(err)}`);
        throw new PtpError(op, PTP_ERR_USB, `${op}: read failed`);
      }
      if (rn < 0) {
        log(`IN failed: ${rn}`);
        throw new PtpError(op, PTP_ERR_USB, `${op}: read failed (${rn})`);
      }
      if (rn === 0) {
        continue;
      }

      const result = ptpNative.processResponse(buf.subarray(0, rn), true);

      if (result.action === 0) {
        rawCount++;
        continue; // data accumulation in progress
      }

      if (result.action === 1 && result.data && result.data.length > 0) {
        dataPayload = result.data;
        log(`Got data: ${result.data.length} bytes (${rawCount} raw reads)`);
        continue; // wait for response
      }

      if (result.action === 2) {
        const code = result.responseCode ?? 0;
        if (code === 0x2001) {
          return dataPayload;
        }
        log(`Response error: 0x${code.toString(16)} (${ptpResponseName(code)})`);
        throw new PtpError(op, code);
      }
      if (result.action === -1) {
        throw new PtpError(op, PTP_ERR_USB, `${op}: malformed response`);
      }
    }
    log('Too many iterations, giving up');
    throw new PtpError(op, PTP_ERR_USB, `${op}: transfer timeout`);
  }

  // ---- USB setup ----

  private findAndClaimInterface(): boolean {
    if (!this.pipe || !this.device) return false;
    for (const cfg of this.device.configs) {
      try {
        usbManager.setConfiguration(this.pipe, cfg);
      } catch (err) {
        log(`setConfiguration failed: ${JSON.stringify(err)}`);
        continue;
      }
      for (const iface of cfg.interfaces) {
        log(`Interface id=${iface.id} class=0x${iface.clazz.toString(16)} sub=0x${iface.subClass.toString(16)} proto=0x${iface.protocol.toString(16)}`);
        if (iface.clazz === USB_CLASS_IMAGE &&
            iface.subClass === USB_SUBCLASS_SIC &&
            iface.protocol === USB_PROTO_PTP) {
          try {
            usbManager.claimInterface(this.pipe, iface, true);
          } catch (err) {
            log(`claimInterface failed: ${JSON.stringify(err)}`);
            continue;
          }
          for (const ep of iface.endpoints) {
            const ts = ep.type === 2 ? 'BULK' : (ep.type === 3 ? 'INT' : `type${ep.type}`);
            log(`  EP addr=0x${ep.address.toString(16)} dir=${ep.direction === 0x80 ? 'IN' : 'OUT'} type=${ts}`);
            if (ep.type === 2) {
              if (ep.direction === 0x80) this.bulkIn = ep;
              else this.bulkOut = ep;
            } else if (ep.type === 3 && ep.direction === 0x80) {
              this.intEp = ep;
            }
          }
          if (this.bulkIn && this.bulkOut) {
            log(`Endpoints: IN=0x${this.bulkIn.address.toString(16)} OUT=0x${this.bulkOut.address.toString(16)}`);
            return true;
          }
        }
      }
    }
    return false;
  }
}
