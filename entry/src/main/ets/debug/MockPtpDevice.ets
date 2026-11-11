import usbManager from '@ohos.usbManager';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
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
/**
 * 多色块测试图的色板。
 *
 * 以前每张图是一条同色系水平渐变：截图里几乎是一块纯色，看不出 Contain / Cover
 * 的裁切差异、也看不出缩放锚点与方向。现在原图与缩略图都是 4×3 色块网格：
 * 白框标出图片边界、中心十字标出几何中心、左上角固定深色块作为不对称参照。
 */
const MOCK_GRID: number[][] = [
  [0xE5, 0x39, 0x35], [0xFB, 0x8C, 0x00], [0xFD, 0xD8, 0x35], [0x43, 0xA0, 0x47],
  [0x00, 0xAC, 0xC1], [0x1E, 0x88, 0xE5], [0x8E, 0x24, 0xAA], [0xEC, 0x40, 0x7A],
  [0xFF, 0x70, 0x43], [0x7C, 0xB3, 0x42], [0x1E, 0x40, 0xD8], [0x79, 0x55, 0x48]
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

async function makeJpeg(w: number, h: number, paletteIndex: number): Promise<Uint8Array> {
  const t0 = Date.now();
  const tFill0 = Date.now();
  const rowLen = w * 4;
  const buf = new ArrayBuffer(rowLen * h);
  const u8 = new Uint8Array(buf);
  const cols = 4;
  const rows = 3;
  const blockW = Math.max(1, Math.ceil(w / cols));
  const bandH = Math.max(1, Math.ceil(h / rows));
  const frame = Math.max(2, Math.round(Math.min(w, h) * 0.012));
  const cx = Math.floor(w / 2);
  // 行缓冲仍然只算一遍再 memcpy：每个「色带行」内部横向只由 4 个色块组成，
  // 与旧的水平渐变同一量级，不会把生成成本推回 100ms+（AGENTS.md 记过这个坑）。
  for (let band = 0; band < rows; band++) {
    const row = new Uint8Array(rowLen);
    for (let x = 0; x < w; x++) {
      const col = Math.min(cols - 1, Math.floor(x / blockW));
      const color = (band === 0 && col === 0)
        ? [0x1B, 0x2A, 0x4A]
        : MOCK_GRID[(paletteIndex + band * cols + col) % MOCK_GRID.length];
      const i = x * 4;
      row[i] = color[0];
      row[i + 1] = color[1];
      row[i + 2] = color[2];
      row[i + 3] = 255;
    }
    // 中心竖线：缩放、双击的锚点是否落在几何中心，截图一眼就能看出来
    for (let x = cx - 1; x <= cx + 1; x++) {
      if (x >= 0 && x < w) {
        const i = x * 4;
        row[i] = 255;
        row[i + 1] = 255;
        row[i + 2] = 255;
      }
    }
    // 左右白框：缩略图的 Cover 裁切会先裁掉框，原图的 Contain 应该完整露出
    for (let x = 0; x < frame && x < w; x++) {
      const li = x * 4;
      row[li] = 255;
      row[li + 1] = 255;
      row[li + 2] = 255;
      const ri = (w - 1 - x) * 4;
      row[ri] = 255;
      row[ri + 1] = 255;
      row[ri + 2] = 255;
    }
    const y0 = band * bandH;
    const y1 = Math.min(h, y0 + bandH);
    for (let y = y0; y < y1; y++) {
      u8.set(row, y * rowLen);
    }
  }
  // 上下白框 + 中心横线：整行白色，直接复制
  const whiteRow = new Uint8Array(rowLen);
  for (let x = 0; x < w; x++) {
    const i = x * 4;
    whiteRow[i] = 255;
    whiteRow[i + 1] = 255;
    whiteRow[i + 2] = 255;
    whiteRow[i + 3] = 255;
  }
  for (let y = 0; y < frame && y < h; y++) {
    u8.set(whiteRow, y * rowLen);
  }
  for (let y = Math.max(0, h - frame); y < h; y++) {
    u8.set(whiteRow, y * rowLen);
  }
  const cy = Math.floor(h / 2);
  for (let y = cy - 1; y <= cy + 1; y++) {
    if (y >= 0 && y < h) {
      u8.set(whiteRow, y * rowLen);
    }
  }
  const tFill = Date.now() - tFill0;
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
  hilog.info(0x0000, 'MockPtp', 'jpeg %{public}dx%{public}d %{public}dms (fill %{public}dms)',
    w, h, Date.now() - t0, tFill);
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
    const bytes = await makeJpeg(THUMB_W, THUMB_H, o.paletteIndex);
    MockPtpDevice.thumbCache.set(handle, bytes);
    return bytes;
  }

  /** 相机返回的原图 JPEG（打开预览器或下载时才生成）。 */
  static async fullJpeg(handle: number): Promise<Uint8Array | null> {
    const cached = MockPtpDevice.fullCache.get(handle);
    if (cached) return cached;
    const o = MockPtpDevice.find(handle);
    if (!o) return null;
    const bytes = await makeJpeg(FULL_W, FULL_H, o.paletteIndex);
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
        f.paletteIndex = (day * 3 + i) % MOCK_GRID.length;
        tree.push(f);
        handle++;
      }
    }

    MockPtpDevice.tree = tree;
    return tree;
  }
}
