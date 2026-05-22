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
interface DeviceInfo {
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
  imagePixWidth: number;
  imagePixHeight: number;
  storageId: number;
}

const ptpNative = rawPtp as PtpApi;

let sharedLog: AppLog | null = null;
export function setPtpLog(log: AppLog): void { sharedLog = log; }
function log(msg: string): void {
  hilog.info(0x0000, TAG, '%{public}s', msg);
  if (sharedLog) { sharedLog.add(msg); }
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

export class PtpSession {
  private device: usbManager.USBDevice | null = null;
  private pipe: usbManager.USBDevicePipe | null = null;
  private bulkIn: usbManager.USBEndpoint | null = null;
  private bulkOut: usbManager.USBEndpoint | null = null;
  private intEp: usbManager.USBEndpoint | null = null;
  private sessionOpen: boolean = false;
  private usbBusy: boolean = false;

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
      const ok = await this.ptpCommand(openCmd, false);
      if (!ok) {
        log(`OpenSession failed`);
        await this.closeSessionAndPipe();
        return false;
      }
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
    const data = await this.ptpCommandGetData(cmd);
    if (!data) {
      log('GetDeviceInfo failed');
      return null;
    }
    return ptpNative.parseDeviceInfo(data);
  }

  async getStorageIDs(): Promise<number[]> {
    if (!this.sessionOpen) return [];
    const cmd = ptpNative.buildGetStorageIDs();
    const data = await this.ptpCommandGetData(cmd);
    if (!data) return [];
    return ptpNative.parseStorageIDs(data);
  }

  async getObjectHandles(storageId: number, parent?: number, formatCode?: number): Promise<number[]> {
    if (!this.sessionOpen) return [];
    const parentHandle = parent ?? 0xFFFFFFFF;
    const code = formatCode ?? 0;
    const cmd = ptpNative.buildGetObjectHandles(storageId, code, parentHandle);
    const data = await this.ptpCommandGetData(cmd);
    if (!data) return [];
    return ptpNative.parseObjectHandles(data);
  }

  async getObjectInfo(handle: number): Promise<ObjectInfo | null> {
    if (!this.sessionOpen) return null;
    const cmd = ptpNative.buildGetObjectInfo(handle);
    const data = await this.ptpCommandGetData(cmd);
    if (!data) return null;
    return ptpNative.parseObjectInfo(data, handle);
  }

  async closeSessionAndPipe(): Promise<void> {
    if (this.sessionOpen && this.pipe && this.bulkOut && this.bulkIn) {
      try {
        const closeCmd = ptpNative.buildCloseSession();
        log('Sending CloseSession');
        await this.ptpCommand(closeCmd, false);
        log('CloseSession acknowledged');
      } catch (_e) {
        log(`CloseSession error: ${JSON.stringify(_e)}`);
      }
      this.sessionOpen = false;
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

  close(): void {
    // Best-effort synchronous close. For proper cleanup use closeSessionAndPipe().
    if (this.sessionOpen && this.pipe && this.bulkOut) {
      try {
        const closeCmd = ptpNative.buildCloseSession();
        usbManager.bulkTransfer(this.pipe, this.bulkOut, closeCmd, 1000);
      } catch (_e) { /* best effort */ }
      this.sessionOpen = false;
    }
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
    if (!this.sessionOpen) return null;
    for (let wait = 0; wait < 150; wait++) {
      if (!this.usbBusy) break;
      await new Promise<void>((r: () => void) => { setTimeout(r, 200); });
    }
    if (this.usbBusy) return null;
    this.usbBusy = true;
    log(`Getting thumb for handle 0x${handle.toString(16)}`);
    const cmd = ptpNative.buildGetThumb(handle);
    const result = await this.ptpCommandGetLargeData(cmd);
    this.usbBusy = false;
    return result;
  }

  async getObject(handle: number): Promise<Uint8Array | null> {
    if (!this.sessionOpen) return null;
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
    log(`Getting object for handle 0x${handle.toString(16)}`);
    const cmd = ptpNative.buildGetObject(handle);
    const result = await this.ptpCommandGetLargeData(cmd);
    this.usbBusy = false;
    return result;
  }

  // ---- PTP transaction helpers ----

  /**
   * Send a command with no data phase. Returns true if response is OK.
   */
  private async ptpCommand(cmd: Uint8Array, expectData: boolean): Promise<boolean> {
    logHex('CMD OUT', cmd);
    const n = await usbManager.bulkTransfer(this.pipe!, this.bulkOut!, cmd, 5000);
    if (n < 0) {
      log(`OUT failed: ${n}`);
      return false;
    }

    // Read and process IN data until we get a response
    for (let attempt = 0; attempt < 10; attempt++) {
      const buf = new Uint8Array(1024);
      const rn = await usbManager.bulkTransfer(this.pipe!, this.bulkIn!, buf, 10000);
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
        return result.responseCode === 0x2001;
      }
      if (result.action === -1) { // error
        return false;
      }
      // action 0 or 1: continue reading
    }
    return false;
  }

  /**
   * Send a command that returns data. Returns the data payload.
   */
  private async ptpCommandGetData(cmd: Uint8Array): Promise<Uint8Array | null> {
    logHex('CMD OUT', cmd);
    const n = await usbManager.bulkTransfer(this.pipe!, this.bulkOut!, cmd, 5000);
    if (n < 0) {
      log(`OUT failed: ${n}`);
      return null;
    }

    let dataPayload: Uint8Array | null = null;

    // Read IN until we get both data and response
    for (let attempt = 0; attempt < 10; attempt++) {
      const buf = new Uint8Array(1024);
      const rn = await usbManager.bulkTransfer(this.pipe!, this.bulkIn!, buf, 10000);
      if (rn < 0) {
        log(`IN failed: ${rn}`);
        return null;
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
        if (result.responseCode === 0x2001) {
          return dataPayload;
        }
        log(`Response error: 0x${(result.responseCode ?? 0).toString(16)}`);
        return null;
      }
      if (result.action === -1) {
        return null;
      }
    }
    return null;
  }

  /**
   * Same as ptpCommandGetData but with larger buffer for image data (thumbnails, full photos).
   */
  private async ptpCommandGetLargeData(cmd: Uint8Array): Promise<Uint8Array | null> {
    logHex('CMD OUT', cmd);
    const n = await usbManager.bulkTransfer(this.pipe!, this.bulkOut!, cmd, 5000);
    if (n < 0) {
      log(`OUT failed: ${n}`);
      return null;
    }

    let dataPayload: Uint8Array | null = null;
    let rawCount = 0;

    // Read IN until we get both data and response.
    const buf = new Uint8Array(196608);  // 192KB — under HMOS 200KB limit
    for (let attempt = 0; attempt < 350; attempt++) {
      const rn = await usbManager.bulkTransfer(this.pipe!, this.bulkIn!, buf, 10000);
      if (rn < 0) {
        log(`IN failed: ${rn}`);
        return null;
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
        if (result.responseCode === 0x2001) {
          return dataPayload;
        }
        log(`Response error: 0x${(result.responseCode ?? 0).toString(16)}`);
        return null;
      }
      if (result.action === -1) {
        return null;
      }
    }
    log('Too many iterations, giving up');
    return null;
  }

  // ---- USB setup ----

  private findAndClaimInterface(): boolean {
    if (!this.pipe || !this.device) return false;
    for (const cfg of this.device.configs) {
      usbManager.setConfiguration(this.pipe, cfg);
      for (const iface of cfg.interfaces) {
        log(`Interface id=${iface.id} class=0x${iface.clazz.toString(16)} sub=0x${iface.subClass.toString(16)} proto=0x${iface.protocol.toString(16)}`);
        if (iface.clazz === USB_CLASS_IMAGE &&
            iface.subClass === USB_SUBCLASS_SIC &&
            iface.protocol === USB_PROTO_PTP) {
          usbManager.claimInterface(this.pipe, iface, true);
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
