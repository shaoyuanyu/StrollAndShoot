import usbManager from '@ohos.usbManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MockPtpDevice, MOCK_ROOT } from './MockPtpDevice';
import type { DeviceInfo, ObjectInfo, PtpTransport } from '../pages/PtpHost';

const TAG = 'MockPtpSession';
const DOMAIN = 0x0000;

/** 模拟一次 USB 往返的耗时，让扫描进度条看得见。 */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/**
 * 假相机的 PTP 会话实现。
 *
 * 与 `PtpSession` 实现同一个 `PtpTransport` 契约，因此 `CameraService`
 * 完全不知道自己在跟一台虚拟相机说话：连接、取设备信息、递归遍历目录、
 * 取元数据、取缩略图、取原图都按真实顺序发生。
 */
export class MockPtpSession implements PtpTransport {
  private open: boolean = false;

  get connectedDeviceName(): string {
    return this.open ? 'MOCK-PTP-CAMERA' : '';
  }

  async connect(_device: usbManager.USBDevice): Promise<boolean> {
    hilog.info(DOMAIN, TAG, 'connect: simulating USB handshake');
    await delay(600);
    this.open = true;
    return true;
  }

  async getDeviceInfo(): Promise<DeviceInfo | null> {
    if (!this.open) return null;
    await delay(80);
    return MockPtpDevice.deviceInfo();
  }

  async getStorageIDs(): Promise<number[]> {
    if (!this.open) return [];
    await delay(60);
    return MockPtpDevice.storageIds();
  }

  async getObjectHandles(storageId: number, parent?: number, formatCode?: number): Promise<number[]> {
    if (!this.open) return [];
    await delay(40);
    const parentHandle = parent ?? MOCK_ROOT;
    const code = formatCode ?? 0;
    return MockPtpDevice.handles(storageId, parentHandle, code);
  }

  async getObjectInfo(handle: number): Promise<ObjectInfo | null> {
    if (!this.open) return null;
    await delay(20);
    return MockPtpDevice.info(handle);
  }

  async getThumb(handle: number): Promise<Uint8Array | null> {
    if (!this.open) return null;
    // 每次取图的耗时让 "按行刷新缩略图" 的进度肉眼可见
    await delay(25);
    return MockPtpDevice.thumbJpeg(handle);
  }

  async getObject(handle: number): Promise<Uint8Array | null> {
    if (!this.open) return null;
    // 真实 USB 上单张原图要几百毫秒。这里同样放慢到 520ms，
    // 否则 38 张几秒钟就传完，底部/侧边进度浮岛的各种状态根本来不及看。
    await delay(520);
    return MockPtpDevice.fullJpeg(handle);
  }

  /**
   * 真实相机用 GetPartialObject 读原图前 16KB 取 EXIF 方向。
   * 这里返回缩略图 JPEG 的开头——同样是合法 JPEG，只是不含 EXIF，
   * 于是方向判定走"无 EXIF 视为不旋转"的默认分支。
   */
  async getPartialObject(handle: number, offset: number, maxBytes: number): Promise<Uint8Array | null> {
    if (!this.open) return null;
    const bytes = await MockPtpDevice.thumbJpeg(handle);
    if (!bytes) return null;
    const end = Math.min(bytes.length, offset + maxBytes);
    if (offset >= bytes.length) return new Uint8Array(0);
    return bytes.slice(offset, end);
  }

  async closeSessionAndPipe(): Promise<void> {
    if (!this.open) return;
    this.open = false;
    MockPtpDevice.release();
    hilog.info(DOMAIN, TAG, 'session closed');
  }
}
