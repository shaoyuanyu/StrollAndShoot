import usbManager from '@ohos.usbManager';
import { image } from '@kit.ImageKit';
import { bundleManager } from '@kit.AbilityKit';
import { SettingsStore } from '../model/SettingsStore';
import type { DeviceInfo, ObjectInfo } from '../pages/PtpHost';

/** PTP 目录格式码 */
export const MOCK_FORMAT_DIR: number = 0x3001;
/** PTP JPEG 格式码 */
export const MOCK_FORMAT_JPEG: number = 0x3801;
/** storage 根的父 handle */
export const MOCK_ROOT: number = 0xFFFFFFFF;

const STORAGE_ID: number = 0x00010001;
const DEVICE_NAME: string = 'MOCK-PTP-CAMERA';
const THUMB_W: number = 180;
const THUMB_H: number = 120;
const FULL_W: number = 1200;
const FULL_H: number = 800;
const DAY_COUNT: number = 5;
const PALETTE: number[][] = [
  [0x42, 0x85, 0xF4], [0xEA, 0x43, 0x35], [0xFB, 0xBC, 0x05],
  [0x34, 0xA8, 0x53], [0x9C, 0x27, 0xB0], [0xFF, 0x70, 0x43],
  [0x00, 0xAC, 0xC1], [0x79, 0x55, 0x48]
];

/** 假相机里的一棵树节点（目录或文件）。 */
export class MockPtpObject {
  handle: number = 0;
  filename: string = '';
  objectFormat: number = MOCK_FORMAT_JPEG;
  parent: number = MOCK_ROOT;
  captureDate: string = '';
  modificationDate: string = '';
  size: number = 0;
  width: number = 0;
  height: number = 0;
  /** 用于生成缩略图/原图时的取色下标 */
  paletteIndex: number = 0;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/** PTP 时间串 YYYYMMDDThhmmss */
function ptpDate(daysAgo: number, idx: number): string {
  const d = new Date(2026, 9, 20 - daysAgo, 9 + (idx % 8), (idx * 7) % 60, 0);
  return `${d.getFullYear()}${pad2(d.getMonth() + 1)}${pad2(d.getDate())}` +
    `T${pad2(d.getHours())}${pad2(d.getMinutes())}${pad2(d.getSeconds())}`;
}

async function makeJpeg(w: number, h: number, rgb: number[]): Promise<Uint8Array> {
  const buf = new ArrayBuffer(w * h * 4);
  const u8 = new Uint8Array(buf);
  const total = w + h;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      const shade = 0.55 + 0.45 * ((x + y) / total);
      u8[i] = Math.round(rgb[0] * shade);
      u8[i + 1] = Math.round(rgb[1] * shade);
      u8[i + 2] = Math.round(rgb[2] * shade);
      u8[i + 3] = 255;
    }
  }
  const initOpts: image.InitializationOptions = {
    size: { width: w, height: h },
    srcPixelFormat: image.PixelMapFormat.RGBA_8888,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    editable: false
  };
  const pixelMap: image.PixelMap = await image.createPixelMap(buf, initOpts);
  const packer: image.ImagePacker = image.createImagePacker();
  let encoded: ArrayBuffer = new ArrayBuffer(0);
  try {
    const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 90 };
    encoded = await packer.packToData(pixelMap, packOpts);
  } catch (_e) {
    encoded = new ArrayBuffer(0);
  } finally {
    try {
      packer.release();
    } catch (_e) { /* best effort */ }
    try {
      pixelMap.release();
    } catch (_e) { /* best effort */ }
  }
  return new Uint8Array(encoded);
}

/**
 * 调试包专用的假 PTP 相机。
 *
 * 不开这个开关时 `CameraService` 走真实 USB；打开后 `findCameras()` 返回一台
 * 虚拟相机，`MockPtpSession` 提供完整的设备信息、存储、目录树与 JPEG 数据，
 * 于是「搜索相机 → 连接 → 遍历目录 → 取元数据 → 取缩略图」全部走真实代码路径，
 * 画廊里看到的就是扫描结果，而不是直接塞进去的数组。
 *
 * release 包里 `isEnabled()` 恒为 false。
 */
export class MockPtpDevice {
  private static debugCache: boolean | undefined = undefined;
  private static tree: MockPtpObject[] | null = null;
  private static thumbCache: Map<number, Uint8Array> = new Map();
  private static fullCache: Map<number, Uint8Array> = new Map();

  /** 当前安装的是否为 debug 包。 */
  static isDebugBuild(): boolean {
    if (MockPtpDevice.debugCache !== undefined) {
      return MockPtpDevice.debugCache;
    }
    let debug = false;
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      debug = info.appInfo.debug;
    } catch (_e) {
      debug = false;
    }
    MockPtpDevice.debugCache = debug;
    return debug;
  }

  /** 是否应当用假相机替代真实 USB 相机。 */
  static isEnabled(): boolean {
    return MockPtpDevice.isDebugBuild() && SettingsStore.getInstance().mockCameraEnabled;
  }

  /** 虚拟相机的 USB 描述符，字段与真实设备一致，便于走同一套连接逻辑。 */
  static findCameras(): usbManager.USBDevice[] {
    const device: usbManager.USBDevice = {
      busNum: 1,
      devAddress: 2,
      serial: 'MOCK-USB-0001',
      name: DEVICE_NAME,
      manufacturerName: 'Mock',
      productName: 'Virtual PTP Camera',
      version: '1.0',
      vendorId: 0x1209,
      productId: 0x0001,
      clazz: 0x06,
      subClass: 0x01,
      protocol: 0x01,
      configs: []
    };
    const list: usbManager.USBDevice[] = [device];
    return list;
  }

  static deviceInfo(): DeviceInfo {
    const info: DeviceInfo = {
      manufacturer: 'Mock',
      model: 'Virtual PTP Camera',
      deviceVersion: '1.0',
      serialNumber: 'MOCK-0001',
      vendorExtensionID: 6
    };
    return info;
  }

  static storageIds(): number[] {
    const ids: number[] = [STORAGE_ID];
    return ids;
  }

  /** 按 存储 / 父目录 / 格式码 过滤，语义与真实 GetObjectHandles 一致。 */
  static handles(storageId: number, parent: number, formatCode: number): number[] {
    if (storageId !== STORAGE_ID) return [];
    const result: number[] = [];
    for (const o of MockPtpDevice.objects()) {
      if (o.parent !== parent) continue;
      if (formatCode !== 0 && o.objectFormat !== formatCode) continue;
      result.push(o.handle);
    }
    return result;
  }

  static info(handle: number): ObjectInfo | null {
    const o = MockPtpDevice.find(handle);
    if (!o) return null;
    const info: ObjectInfo = {
      filename: o.filename,
      objectCompressedSize: o.size,
      objectFormat: o.objectFormat,
      captureDate: o.captureDate,
      modificationDate: o.modificationDate,
      imagePixWidth: o.width,
      imagePixHeight: o.height,
      storageId: STORAGE_ID
    };
    return info;
  }

  /** 相机返回的缩略图 JPEG。 */
  static async thumbJpeg(handle: number): Promise<Uint8Array | null> {
    const cached = MockPtpDevice.thumbCache.get(handle);
    if (cached) return cached;
    const o = MockPtpDevice.find(handle);
    if (!o) return null;
    const bytes = await makeJpeg(THUMB_W, THUMB_H, PALETTE[o.paletteIndex]);
    MockPtpDevice.thumbCache.set(handle, bytes);
    return bytes;
  }

  /** 相机返回的原图 JPEG（打开预览器或下载时才生成）。 */
  static async fullJpeg(handle: number): Promise<Uint8Array | null> {
    const cached = MockPtpDevice.fullCache.get(handle);
    if (cached) return cached;
    const o = MockPtpDevice.find(handle);
    if (!o) return null;
    const bytes = await makeJpeg(FULL_W, FULL_H, PALETTE[o.paletteIndex]);
    MockPtpDevice.fullCache.set(handle, bytes);
    return bytes;
  }

  /** 断开连接时清掉生成过的 JPEG，避免占内存。 */
  static release(): void {
    MockPtpDevice.thumbCache.clear();
    MockPtpDevice.fullCache.clear();
  }

  private static find(handle: number): MockPtpObject | undefined {
    for (const o of MockPtpDevice.objects()) {
      if (o.handle === handle) return o;
    }
    return undefined;
  }

  /**
   * 目录树：根 → DCIM → 100MOCK / 101MOCK → JPEG。
   * 两个子目录是为了让递归遍历真正走两层，与真实相机一致。
   */
  private static objects(): MockPtpObject[] {
    if (MockPtpDevice.tree) return MockPtpDevice.tree;
    const tree: MockPtpObject[] = [];

    const dcim = new MockPtpObject();
    dcim.handle = 0x10;
    dcim.filename = 'DCIM';
    dcim.objectFormat = MOCK_FORMAT_DIR;
    dcim.parent = MOCK_ROOT;
    tree.push(dcim);

    const folders: number[] = [0x11, 0x12];
    const names: string[] = ['100MOCK', '101MOCK'];
    for (let i = 0; i < folders.length; i++) {
      const dir = new MockPtpObject();
      dir.handle = folders[i];
      dir.filename = names[i];
      dir.objectFormat = MOCK_FORMAT_DIR;
      dir.parent = dcim.handle;
      tree.push(dir);
    }

    let handle = 1001;
    for (let day = 0; day < DAY_COUNT; day++) {
      const count = 6 + (day % 3) * 2;
      for (let i = 0; i < count; i++) {
        const stamp = ptpDate(day, i);
        const f = new MockPtpObject();
        f.handle = handle;
        f.filename = `DSC_${String(handle).padStart(4, '0')}.JPG`;
        f.objectFormat = MOCK_FORMAT_JPEG;
        // 前 12 张放在 100MOCK，其余放 101MOCK
        f.parent = handle <= 1012 ? folders[0] : folders[1];
        f.captureDate = stamp;
        f.modificationDate = stamp;
        f.width = FULL_W;
        f.height = FULL_H;
        f.size = 2400000 + handle * 37;
        f.paletteIndex = (day * 3 + i) % PALETTE.length;
        tree.push(f);
        handle++;
      }
    }

    MockPtpDevice.tree = tree;
    return tree;
  }
}
