import { deviceManager } from '@kit.DriverDevelopmentKit';
import { rpc } from '@kit.IPCKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import rawPtp from 'libentry.so';

const TAG = 'PtpIpcClient';

interface PtpApi {
  parseDeviceInfo(data: Uint8Array): DeviceInfo;
  parseStorageIDs(data: Uint8Array): number[];
  parseObjectHandles(data: Uint8Array): number[];
  parseObjectInfo(data: Uint8Array, handle: number): ObjectInfo;
}

interface DeviceInfo {
  manufacturer: string;
  model: string;
  deviceVersion: string;
  serialNumber: string;
  vendorExtensionID: number;
}

interface ObjectInfo {
  filename: string;
  objectCompressedSize: number;
  objectFormat: number;
  captureDate: string;
  imagePixWidth: number;
  imagePixHeight: number;
  storageId: number;
}

const ptpNative = rawPtp as PtpApi;

// Session-like interface matching PtpSession for drop-in replacement
export class PtpIpcClient {
  private remote: rpc.IRemoteObject | null = null;
  private deviceId: number = -1;
  private cameraDevice: deviceManager.USBDevice | null = null;

  static findCameras(): deviceManager.USBDevice[] {
    const cameras: deviceManager.USBDevice[] = [];
    try {
      hilog.info(0x0000, TAG, 'findCameras: checking BusType');
      const busType = deviceManager.BusType;
      hilog.info(0x0000, TAG, 'findCameras: BusType=%{public}s', JSON.stringify(busType));
      if (!busType || busType.USB === undefined || busType.USB === null) {
        hilog.error(0x0000, TAG, 'findCameras: BusType.USB not available');
        return cameras;
      }
      hilog.info(0x0000, TAG, 'findCameras: calling queryDevices');
      const devices = deviceManager.queryDevices(busType.USB);
      hilog.info(0x0000, TAG, 'queryDevices: %{public}d devices', devices.length);
      for (const dev of devices) {
        const usbDev = dev as deviceManager.USBDevice;
        hilog.info(0x0000, TAG, 'USB: vid=%{public}s pid=%{public}s',
          usbDev.vendorId.toString(16), usbDev.productId.toString(16));
        cameras.push(usbDev);
      }
    } catch (err) {
      hilog.error(0x0000, TAG, 'findCameras error: %{public}s', JSON.stringify(err));
    }
    return cameras;
  }

  async connect(device: deviceManager.USBDevice): Promise<boolean> {
    try {
      // Find deviceId matching vid/pid
      const devices = deviceManager.queryDevices(deviceManager.BusType.USB);
      let foundId = -1;
      for (const dev of devices) {
        const usbDev = dev as deviceManager.USBDevice;
        if (usbDev.vendorId === device.vendorId && usbDev.productId === device.productId) {
          foundId = dev.deviceId;
          break;
        }
      }
      if (foundId < 0) {
        hilog.error(0x0000, TAG, 'Device not found');
        return false;
      }
      this.deviceId = foundId;
      this.cameraDevice = device;

      const driver = await deviceManager.bindDeviceDriver(foundId,
        (_err: BusinessError, _id: number) => {
          hilog.warn(0x0000, TAG, 'Driver disconnected');
          this.remote = null;
        });

      this.remote = driver.remote;
      hilog.info(0x0000, TAG, 'Driver bound');

      // Init device on driver side
      const ok = await this.initDevice(foundId);
      if (!ok) return false;
      // Open PTP session
      const sessionOk = await this.openSession(1);
      hilog.info(0x0000, TAG, 'OpenSession: %{public}s', sessionOk ? 'ok' : 'fail');
      return sessionOk;
    } catch (err) {
      hilog.error(0x0000, TAG, 'connect error');
      return false;
    }
  }

  close(): void {
    if (this.remote) {
      this.ipcExec(2); // releaseDevice
    }
    if (this.deviceId >= 0) {
      try { deviceManager.unbindDriverWithDeviceId(this.deviceId); } catch (_e) {}
      this.deviceId = -1;
    }
    this.remote = null;
    this.cameraDevice = null;
  }

  // ---- PTP operations (matching PtpSession interface) ----

  async getDeviceInfo(): Promise<DeviceInfo | null> {
    const data = await this.execute('getDeviceInfo', 0);
    if (!data || data.length === 0) return null;
    return ptpNative.parseDeviceInfo(data);
  }

  async getStorageIDs(): Promise<number[]> {
    const data = await this.execute('getStorageIDs', 0);
    if (!data || data.length === 0) return [];
    return ptpNative.parseStorageIDs(data);
  }

  async getObjectHandles(storageId: number, _formatCode?: number, parent?: number): Promise<number[]> {
    const data = await this.execute('getObjectHandles', parent ?? 0xFFFFFFFF);
    if (!data || data.length === 0) return [];
    return ptpNative.parseObjectHandles(data);
  }

  async getObjectInfo(handle: number): Promise<ObjectInfo | null> {
    const data = await this.execute('getObjectInfo', handle);
    if (!data || data.length === 0) return null;
    return ptpNative.parseObjectInfo(data, handle);
  }

  async getThumb(handle: number): Promise<Uint8Array | null> {
    return this.execute('getThumb', handle);
  }

  async getObject(handle: number): Promise<Uint8Array | null> {
    return this.getLargeData(handle);
  }

  // ---- Internal IPC helpers ----

  private async initDevice(deviceId: number): Promise<boolean> {
    const result = await this.ipcExec(1, (data: rpc.MessageSequence) => {
      data.writeInt(deviceId);
    });
    return result !== null;
  }

  private async openSession(sessionId: number): Promise<boolean> {
    const data = await this.execute('openSession', sessionId);
    return data !== null && data.length > 0 && data[0] === 1;
  }

  /**
   * Execute a PTP command via IPC. Returns raw data bytes or null on failure.
   */
  private async execute(cmd: string, arg: number): Promise<Uint8Array | null> {
    return this.ipcExec(3, (data: rpc.MessageSequence) => {
      data.writeString(cmd);
      data.writeInt(arg);
    });
  }

  private async getLargeData(handle: number): Promise<Uint8Array | null> {
    return this.ipcExec(10, (data: rpc.MessageSequence) => {
      data.writeInt(handle);
    });
  }

  private async ipcExec(code: number,
                        setup?: (data: rpc.MessageSequence) => void): Promise<Uint8Array | null> {
    if (!this.remote) return null;
    try {
      const data = new rpc.MessageSequence();
      const reply = new rpc.MessageSequence();
      const option = new rpc.MessageOption();

      if (setup) setup(data);

      await this.remote.sendMessageRequest(code, data, reply, option);

      const len = reply.readInt();
      if (len <= 0) {
        // Boolean false or error
        return len === 1 ? new Uint8Array([1]) : null;
      }
      // Byte array response
      const arr = new Array<number>(len);
      reply.readByteArray(arr);
      return new Uint8Array(arr);
    } catch (err) {
      hilog.error(0x0000, TAG, 'IPC error');
      return null;
    }
  }
}
