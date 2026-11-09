import usbManager from '@ohos.usbManager';
import rawPtp from 'libentry.so';
import hilog from '@ohos.hilog';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLog } from '../services/AppLog';

const TAG = 'PtpHost';

/**
 * GetObject 数据阶段的单包大小。
 *
 * 真机实测（16.1MB NEF，零拷贝 NAPI，同对象两轮）：
 * 256KB 22.1/12.0；512KB 32.1/28.6；1MB 38.4/42.0 MB/s；
 * 2MB 18.9/51.1；4MB 52.0/15.1；8MB 45.8/38.5（processResponse 峰值 14–17ms）。
 * 1MB 最稳（约 40MB/s，processResponse 峰值 4ms）；再大波动明显变大，
 * 且主线程一次处理的拷贝更长，预览器滑动会重新出现掉帧。
 */
const LARGE_DATA_CHUNK = 1024 * 1024;

/**
 * 邻近预加载的单包大小。
 *
 * 预加载在用户滑动时可能正在跑，256KB 一包的 processResponse 峰值约 2ms，
 * 比 512KB 更不容易和滑动抢主线程；预加载对绝对吞吐不敏感。
 */
const PRELOAD_DATA_CHUNK = 256 * 1024;

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
 * PTP 事务优先级。数值越小越先执行。
 *
 * PTP 会话是单管道：无论上层并发多少请求，同一时刻只有一个事务在跑。
 * 以前用 `usbBusy` + 200ms 轮询排队，一次交接最多白等 200ms；
 * `PtpScheduler` 改成 promise 队列后，前一个事务一结束就立刻交给下一个，
 * 并且前台取图可以插到扫描/预加载前面。
 */
export enum PtpPriority {
  FOREGROUND = 0,
  PRELOAD = 1,
  SCAN = 2
}

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
  connect(device: usbManager.USBDevice, priority?: PtpPriority): Promise<boolean>;
  getDeviceInfo(priority?: PtpPriority): Promise<DeviceInfo | null>;
  getStorageIDs(priority?: PtpPriority): Promise<number[]>;
  getObjectHandles(storageId: number, parent?: number, formatCode?: number,
    priority?: PtpPriority): Promise<number[]>;
  getObjectInfo(handle: number, priority?: PtpPriority): Promise<ObjectInfo | null>;
  getThumb(handle: number, priority?: PtpPriority): Promise<Uint8Array | null>;
  getObject(handle: number, priority?: PtpPriority): Promise<Uint8Array | null>;
  getPartialObject(handle: number, offset: number, maxBytes: number,
    priority?: PtpPriority): Promise<Uint8Array | null>;
  closeSessionAndPipe(priority?: PtpPriority): Promise<void>;
}

export class PtpSession implements PtpTransport {
  private device: usbManager.USBDevice | null = null;
  private pipe: usbManager.USBDevicePipe | null = null;
  private bulkIn: usbManager.USBEndpoint | null = null;
  private bulkOut: usbManager.USBEndpoint | null = null;
  private intEp: usbManager.USBEndpoint | null = null;
  private sessionOpen: boolean = false;
  /** 最近一条命令的响应码；0 表示还没收到过响应。 */
  private lastResponseCode: number = 0;
  /**
   * 相机侧还挂着上一次的 PTP 会话（OpenSession 返回 0x201E），且补发 CloseSession 也没救回来。
   * 应用崩溃/被系统杀掉时不会走 closeSessionAndPipe，相机会一直保留那个会话。
   */
  sessionConflict: boolean = false;

  // ---- 自适应传输参数（按端点/运行时表现调整，避免只适配一台设备） ----
  /** usbSubmitTransfer 同步提交失败时置 true，整个会话退回 bulk。 */
  private asyncBroken: boolean = false;
  /** 当前主图分块（字节）。 */
  private chunkBytes: number = 512 * 1024;
  /** 本端点允许的最大分块。 */
  private chunkMax: number = 1024 * 1024;
  /** 最近一次 processResponse 的最大耗时，用于降档防掉帧。 */
  private lastProcMaxMs: number = 0;
  /** 连续成功次数，用于升档。 */
  private goodStreak: number = 0;

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

  async connect(device: usbManager.USBDevice, _priority?: PtpPriority): Promise<boolean> {
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
      this.initTransferProfile();

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

  async getDeviceInfo(_priority?: PtpPriority): Promise<DeviceInfo | null> {
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

  async getStorageIDs(_priority?: PtpPriority): Promise<number[]> {
    if (!this.sessionOpen) throw new PtpError('GetStorageIDs', PTP_ERR_NOT_OPEN);
    const cmd = ptpNative.buildGetStorageIDs();
    const data = await this.ptpCommandGetData(cmd, 'GetStorageIDs');
    if (!data) throw new PtpError('GetStorageIDs', PTP_ERR_USB, 'GetStorageIDs: empty data package');
    return ptpNative.parseStorageIDs(data);
  }

  async getObjectHandles(storageId: number, parent?: number, formatCode?: number,
    _priority?: PtpPriority): Promise<number[]> {
    if (!this.sessionOpen) throw new PtpError('GetObjectHandles', PTP_ERR_NOT_OPEN);
    const parentHandle = parent ?? 0xFFFFFFFF;
    const code = formatCode ?? 0;
    const cmd = ptpNative.buildGetObjectHandles(storageId, code, parentHandle);
    const data = await this.ptpCommandGetData(cmd, 'GetObjectHandles');
    if (!data) throw new PtpError('GetObjectHandles', PTP_ERR_USB, 'GetObjectHandles: empty data package');
    return ptpNative.parseObjectHandles(data);
  }

  async getObjectInfo(handle: number, _priority?: PtpPriority): Promise<ObjectInfo | null> {
    if (!this.sessionOpen) throw new PtpError('GetObjectInfo', PTP_ERR_NOT_OPEN);
    const cmd = ptpNative.buildGetObjectInfo(handle);
    const data = await this.ptpCommandGetData(cmd, 'GetObjectInfo');
    if (!data) throw new PtpError('GetObjectInfo', PTP_ERR_USB, 'GetObjectInfo: empty data package');
    return ptpNative.parseObjectInfo(data, handle);
  }

  async closeSessionAndPipe(_priority?: PtpPriority): Promise<void> {
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

  /**
   * 这三个取图方法以前各自用 `usbBusy` 标志 + 200ms 轮询互斥。
   * 串行化已经上移到 `PtpScheduler`：同一会话的所有事务都在一条 promise 队列里，
   * 前一个结束立刻放行下一个，不再有 200ms 的交接空档。这里只负责发事务。
   */
  async getThumb(handle: number, _priority?: PtpPriority): Promise<Uint8Array | null> {
    if (!this.sessionOpen) throw new PtpError('GetThumb', PTP_ERR_NOT_OPEN);
    log(`Getting thumb for handle 0x${handle.toString(16)}`);
    const cmd = ptpNative.buildGetThumb(handle);
    return await this.ptpCommandGetLargeData(cmd, 'GetThumb');
  }

  async getObject(handle: number, priority?: PtpPriority): Promise<Uint8Array | null> {
    if (!this.sessionOpen) throw new PtpError('GetObject', PTP_ERR_NOT_OPEN);
    log(`Getting object for handle 0x${handle.toString(16)}`);
    const cmd = ptpNative.buildGetObject(handle);
    if (this.asyncBroken) {
      // 该会话已确认 usbSubmitTransfer 不可用，整条会话退回同步 bulk。
      return await this.ptpCommandGetLargeData(cmd, 'GetObject');
    }
    const chunk = priority === PtpPriority.PRELOAD
      ? Math.min(PRELOAD_DATA_CHUNK, this.chunkBytes) : this.chunkBytes;
    const t0 = Date.now();
    const data = await this.ptpCommandGetObjectData(cmd, 'GetObject', chunk);
    if (priority !== PtpPriority.PRELOAD && !this.asyncBroken) {
      this.adaptAfterTransfer(Date.now() - t0);
    }
    return data;
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
  async getPartialObject(handle: number, offset: number, maxBytes: number,
    _priority?: PtpPriority): Promise<Uint8Array | null> {
    if (!this.sessionOpen) throw new PtpError('GetPartialObject', PTP_ERR_NOT_OPEN);
    log(`Getting partial object for handle 0x${handle.toString(16)} offset=${offset} maxBytes=${maxBytes}`);
    const cmd = ptpNative.buildGetPartialObject(handle, offset, maxBytes);
    const result = await this.ptpCommandGetLargeData(cmd, 'GetPartialObject');
    if (result && result.length > 0) {
      log(`Got partial data: ${result.length} bytes`);
    } else {
      log('GetPartialObject returned no data (camera may not support it)');
    }
    return result;
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

  /**
   * 按端点能力设置初始分块：
   * - USB3.0（bulk mps=1024）：512KB 起步，最多升到 1MB；
   * - USB2.0（mps=512）：512KB 起步，最多 512KB；
   * - 全速（mps<512）：64KB，不再升。
   * 起步不直接用 1MB，避免在没验证过的相机/手机上第一笔就踩大包异常。
   */
  private initTransferProfile(): void {
    const mps = this.bulkIn?.maxPacketSize ?? 512;
    if (mps >= 1024) {
      this.chunkBytes = 512 * 1024;
      this.chunkMax = 1024 * 1024;
    } else if (mps >= 512) {
      this.chunkBytes = 512 * 1024;
      this.chunkMax = 512 * 1024;
    } else {
      this.chunkBytes = 64 * 1024;
      this.chunkMax = 64 * 1024;
    }
    this.asyncBroken = false;
    this.goodStreak = 0;
    this.lastProcMaxMs = 0;
    log(`自适应传输: mps=${mps} 初始分块=${this.chunkBytes / 1024}KB ` +
      `上限=${this.chunkMax / 1024}KB`);
  }

  /** 根据最近一笔的 processResponse 峰值和连续成功次数升/降档。 */
  private adaptAfterTransfer(ms: number): void {
    const minChunk = 256 * 1024;
    const proc = this.lastProcMaxMs;
    if (proc > 8 && this.chunkBytes > minChunk) {
      this.chunkBytes = Math.max(minChunk, Math.floor(this.chunkBytes / 2));
      this.goodStreak = 0;
      log(`自适应传输: processResponse ${proc}ms，分块降到 ${this.chunkBytes / 1024}KB`);
      return;
    }
    if (proc <= 4 && ms > 0) {
      this.goodStreak++;
    } else {
      this.goodStreak = 0;
    }
    if (this.goodStreak >= 2 && this.chunkBytes < this.chunkMax) {
      this.chunkBytes = Math.min(this.chunkMax, this.chunkBytes * 2);
      this.goodStreak = 0;
      log(`自适应传输: 连续 ${proc}ms，分块升到 ${this.chunkBytes / 1024}KB`);
    }
  }

  /**
   * 异步提交不可用时的兜底：命令已经发出，继续用同步 bulk 把当前 GetObject
   * 的数据/响应读完，避免用户第一次取图直接失败。
   */
  private async readObjectBulkAfterCommand(op: string): Promise<Uint8Array | null> {
    const buf = new Uint8Array(196608);
    for (let i = 0; i < 4096; i++) {
      let rn = -1;
      try {
        rn = await usbManager.bulkTransfer(this.pipe!, this.bulkIn!, buf, 15000);
      } catch (err) {
        throw new PtpError(op, PTP_ERR_USB, `${op}: bulk fallback read failed`);
      }
      if (rn < 0) {
        throw new PtpError(op, PTP_ERR_USB, `${op}: bulk fallback read failed (${rn})`);
      }
      if (rn === 0) {
        continue;
      }
      const result = ptpNative.processResponse(buf.subarray(0, rn), true);
      if (result.action === 1 && result.data && result.data.length > 0) {
        log(`Got data: ${result.data.length} bytes (bulk fallback)`);
        return await this.readResponseAfterData(op, result.data);
      }
      if (result.action === 2) {
        const code = result.responseCode ?? 0;
        if (code === 0x2001) {
          return null;
        }
        throw new PtpError(op, code);
      }
      if (result.action === -1) {
        throw new PtpError(op, PTP_ERR_USB, `${op}: malformed response`);
      }
    }
    throw new PtpError(op, PTP_ERR_USB, `${op}: bulk fallback timeout`);
  }

  /**
   * GetObject 的数据阶段：命令仍走 bulk，数据用 usbSubmitTransfer 大块读。
   *
   * 为什么只给 GetObject 用：零拷贝 + 1MB async 把 16MB NEF 从 5.3MB/s
   * 提到约 40MB/s；但 GetThumb / GetPartialObject 这类小数据，async 反而比
   * bulk 慢 3–4ms（每次都要建 ashmem），所以它们继续走 bulk。
   */
  private async ptpCommandGetObjectData(cmd: Uint8Array, op: string = 'GetObject',
    chunkBytes: number = LARGE_DATA_CHUNK): Promise<Uint8Array | null> {
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
    let zeroReads = 0;
    let received = false;
    this.lastProcMaxMs = 0;
    const buf = new Uint8Array(chunkBytes);
    for (let attempt = 0; attempt < 4096; attempt++) {
      let rn = 0;
      try {
        rn = await this.submitAsyncTransfer(this.bulkIn!, buf, 15000);
      } catch (err) {
        log(`async IN exception: ${(err as Error).message}`);
        if (this.asyncBroken && attempt === 0 && !received) {
          log('usbSubmitTransfer 不可用，回退 bulk 读当前 GetObject');
          return await this.readObjectBulkAfterCommand(op);
        }
        throw new PtpError(op, PTP_ERR_USB, `${op}: async read failed`);
      }
      if (rn === 0) {
        zeroReads++;
        if (zeroReads > 8) {
          throw new PtpError(op, PTP_ERR_USB, `${op}: too many zero-length reads`);
        }
        continue;
      }
      zeroReads = 0;
      received = true;
      const procStart = Date.now();
      const result = ptpNative.processResponse(buf.subarray(0, rn), true);
      const procMs = Date.now() - procStart;
      if (procMs > this.lastProcMaxMs) {
        this.lastProcMaxMs = procMs;
      }
      if (result.action === 1 && result.data && result.data.length > 0) {
        dataPayload = result.data;
        log(`Got data: ${result.data.length} bytes (async)`);
        // 响应包只有 12B 左右，用 bulk 读，不再为它建 1MB ashmem。
        return await this.readResponseAfterData(op, dataPayload);
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
    throw new PtpError(op, PTP_ERR_USB, `${op}: transfer timeout`);
  }

  private async readResponseAfterData(op: string, data: Uint8Array | null): Promise<Uint8Array | null> {
    for (let i = 0; i < 6; i++) {
      const buf = new Uint8Array(1024);
      let rn = -1;
      try {
        rn = await usbManager.bulkTransfer(this.pipe!, this.bulkIn!, buf, 10000);
      } catch (err) {
        throw new PtpError(op, PTP_ERR_USB, `${op}: response read failed`);
      }
      if (rn < 0) {
        throw new PtpError(op, PTP_ERR_USB, `${op}: response read failed (${rn})`);
      }
      if (rn === 0) {
        continue;
      }
      const result = ptpNative.processResponse(buf.subarray(0, rn), true);
      if (result.action === 2) {
        const code = result.responseCode ?? 0;
        if (code === 0x2001) {
          return data;
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
   * 异步 bulk 传输（usbSubmitTransfer）。
   *
   * 走 ashmem，不受同步 bulkTransfer 的 200KB 限制；GetObject 的数据阶段
   * 用它一次读 1MB（预加载 256KB）。命令/响应这类小数据仍用 bulkTransfer。
   */
  private submitAsyncTransfer(ep: usbManager.USBEndpoint, buffer: Uint8Array, timeout: number): Promise<number> {
    return new Promise<number>((resolve, reject) => {
      const params: usbManager.UsbDataTransferParams = {
        devPipe: this.pipe!,
        // 当前 HDI 不消费 flags；这里取 0，避免短包被当成错误。
        flags: usbManager.UsbTransferFlags.USB_TRANSFER_SHORT_NOT_OK,
        endpoint: ep.address,
        type: usbManager.UsbEndpointTransferType.TRANSFER_TYPE_BULK,
        timeout: timeout,
        length: buffer.length,
        callback: (err: BusinessError, data: usbManager.SubmitTransferCallback) => {
          if (err) {
            reject(new Error(`async transfer error code=${err.code} message=${err.message}`));
            return;
          }
          if (data.status !== usbManager.UsbTransferStatus.TRANSFER_COMPLETED) {
            reject(new Error(`async transfer status=${data.status} actual=${data.actualLength}`));
            return;
          }
          resolve(data.actualLength);
        },
        userData: new Uint8Array(0),
        buffer: buffer,
        isoPacketCount: 0
      };
      try {
        usbManager.usbSubmitTransfer(params);
      } catch (e) {
        // 同步提交失败通常意味着该设备/HDI 不支持或当前状态不允许异步传输。
        this.asyncBroken = true;
        reject(e as Error);
      }
    });
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
