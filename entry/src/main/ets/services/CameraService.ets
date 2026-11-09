import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, type WantAgent } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import usbManager from '@ohos.usbManager';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { decodeThumbnailTask, decodeFullPhotoTask } from '../workers/ImageDecoder';
import { PtpSession, PtpPriority, setPtpLog, PtpError, PTP_ERR_USB, PTP_ERR_NOT_OPEN, type DeviceInfo, type ObjectInfo, type PtpTransport } from '../pages/PtpHost';
import { PtpScheduler } from './PtpScheduler';
import { AtomicFile } from '../utils/AtomicFile';
import { AppLog } from './AppLog';
import { GpsRecorder } from './GpsRecorder';
import { ExifGeotagger } from './ExifGeotagger';
import { TransferNotice } from './TransferNotice';
import { CameraCachePrefs } from './CameraCachePrefs';
import { ThumbnailCache, type CacheEntry } from './ThumbnailCache';
import { L10n } from '../utils/L10n';
import { MockPtpDevice } from '../debug/MockPtpDevice';
import { MockPtpSession } from '../debug/MockPtpSession';
import type { PhotoEntry, DownloadRecord, DownloadProgress, DownloadResult } from '../model/PhotoEntry';

const DOMAIN = 0x0000;
const TAG = 'CameraService';

/**
 * 全尺寸解码的最长边上限（px）。
 *
 * 预览器最大 5x 捏合，而手机屏幕长边约 2700px：3072px 的源图已经够用。
 * 不限制时 24MP 原图是 96MB/张，预览器「当前 + 前后各 3 张」同时驻留会把
 * 内存和纹理带宽打满，捏合、翻页都会发涩。
 */
const FULL_DECODE_MAX_EDGE = 3072;

/** 两次扫描的最小间隔，避免失败后连点把一次点击放大成多次 USB 会话（ISSUE-004）。 */
const SCAN_MIN_INTERVAL_MS = 800;
/**
 * 快速扫描复用元数据的有效期。
 *
 * 复用依据是「handle 仍在同一台相机的列表里」，PTP 不提供低成本的“对象是否变化”
 * 信号。超过这个时间就强制重读一遍，弥补相机侧改动/格式化等边界情况；用户随时
 * 可以用「全量扫描」强制刷新。
 */
const METADATA_REUSE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
/** 元数据分批上屏的粒度（ISSUE-008）。 */
const METADATA_BATCH_SIZE = 100;
/** 复用元数据前的抽样校验条数（防止卡被格式化后 handle 被重用导致张冠李戴）。 */
const METADATA_REUSE_PROBE = 8;
/**
 * 缩略图流水线的并发任务数。
 *
 * PTP 管道本身是串行的，这里并发的是「取图 + 解码」：一个任务在等 USB 时，
 * 另一个任务可以在 TaskPool 里解码。8 足够把管道喂饱，又不会一次占太多内存。
 */
const THUMB_PIPELINE = 8;
/** 等用户回答「是否启用缓存」的上限；超时按启用处理，避免扫描被对话框卡死。 */
const CACHING_PROMPT_TIMEOUT_MS = 90 * 1000;

// ---- EXIF orientation types (classes required for ArkTS object literal compliance) ----

class OrientationTransform {
  rotate: number = 0;
  flipH: boolean = false;
  flipV: boolean = false;
  constructor(rotate: number = 0, flipH: boolean = false, flipV: boolean = false) {
    this.rotate = rotate;
    this.flipH = flipH;
    this.flipV = flipV;
  }
}

class OrientedSize {
  w: number = 0;
  h: number = 0;
  constructor(w: number = 0, h: number = 0) {
    this.w = w;
    this.h = h;
  }
}

class DecodedPhotoResult {
  pixelMap: image.PixelMap;
  displayW: number;
  displayH: number;
  constructor(pixelMap: image.PixelMap, displayW: number, displayH: number) {
    this.pixelMap = pixelMap;
    this.displayW = displayW;
    this.displayH = displayH;
  }
}

/** 下载注册表快照的 schema 信封。 */
interface DownloadRegistryFile {
  version: number;
  records: Record<string, DownloadRecord>;
}

/** 注册表最多保留多少条，避免多年使用后无限增长。 */
const MAX_DOWNLOAD_RECORDS = 50000;
/** 图库“最近删除”保留 30 天；超过这个时间的失效记录可以安全丢掉。 */
const MISSING_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

/** 每成功保存一张照片就追加一行，崩溃后可从 journal 恢复。 */
interface DownloadJournalEntry {
  key: string;
  record: DownloadRecord;
}

@ObservedV2
export class CameraService {
  private static instance: CameraService;
  private session: PtpTransport = new PtpScheduler(new PtpSession());
  /** 当前 session 是不是调试用的假相机，用来判断是否需要换回真实 USB。 */
  private sessionIsMock: boolean = false;
  private log: AppLog = new AppLog();

  // State
  @Trace statusText: string = L10n.isReady() ? L10n.tr('camera_status_ready') : '';
  @Trace cameraName: string = '';
  @Trace photoCount: number = 0;
  @Trace photos: PhotoEntry[] = [];
  @Trace scanning: boolean = false;
  /**
   * USB/PTP 会话是否建立。注意它**不等于**“相机可用”：会话建好但存储读不到时
   * 仍然是 `connected === true`，界面要看 `usable` 才能给出正确结论（ISSUE-003）。
   */
  @Trace connected: boolean = false;
  /** 存储是否可读（GetStorageIDs 成功）。 */
  @Trace usable: boolean = false;
  /** 最近一次扫描失败的原因，供 toast 与状态卡显示。 */
  @Trace lastScanError: string = '';
  /** 每次扫描失败递增；界面据此弹一次 toast，避免重复提示。 */
  @Trace scanErrorVersion: number = 0;

  // Thumbnail cache
  thumbnailPixelMapMap: Map<number, image.PixelMap> = new Map();
  thumbnailLoadedSet: Set<number> = new Set();
  @Trace thumbnailVersion: number = 0;

  /**
   * 取缩略图供界面渲染。
   * 方法内先读一次 thumbnailVersion，建立 V2 依赖：调用方组件在缩略图更新时会重建。
   * Map 本身不参与状态跟踪，不读版本号的话单元格会永远停在占位图。
   */
  thumbForRender(handle: number): image.PixelMap | undefined {
    if (this.thumbnailVersion < 0) return undefined;
    return this.thumbnailPixelMapMap.get(handle);
  }

  // Orientation-corrected display dimensions (populated during thumbnail/full decode)
  orientedDisplaySizes: Map<number, OrientedSize> = new Map();

  // Full-resolution compressed cache for preloading
  private compressedCache: Map<number, Uint8Array> = new Map();
  private preloadingSet: Set<number> = new Set();
  /** 等待某张原图预加载完成的调用方；用完成通知替代 200ms 轮询。 */
  private preloadWaiters: Map<number, Array<(ok: boolean) => void>> = new Map();
  private cacheTotalBytes: number = 0;
  private cacheMaxBytes: number = 200 * 1048576;
  private detailIndex: number = -1;
  private prevDetailIndex: number = -1;
  /**
   * 邻近照片预加载半径。
   *
   * 以前是 5（前后各 5 张），每翻一张照片就排队下载最多 10 张原图。真机上
   * USB 是串行管道，这些下载会和「用户正在等的那一张」抢带宽；预览器自己也
   * 有一套 ±3 的加载队列，所以 5 纯属重复劳动。收到 2 之后，预览器打开期间
   * 还会整体挂起（`suspendNeighborPreload`），把管道让给当前照片。
   */
  private preloadRadius: number = 2;
  private preloading: boolean = false;
  /** 预览器打开时挂起邻近预加载，避免与预览器自己的加载队列抢 USB。 */
  private neighborPreloadSuspended: boolean = false;

  // Scan progress
  @Trace scanProgress: number = 0;
  @Trace scanTotal: number = 0;
  @Trace scanStatsText: string = '';
  /** Quick-scan phase description ("获取元数据" / "加载缩略图") */
  @Trace scanPhaseText: string = '';
  /** Last decoded thumbnail handle — consumed by PhotoViewer for on-screen refresh */
  @Trace lastDecodedHandle: number = -1;

  // Format filter support detection (cached across directory levels)
  private formatFilterWorks: boolean | null = null;

  /** 上一次扫描开始时间（节流用）。 */
  private lastScanStartMs: number = 0;
  /** 本轮扫描成功解码的缩略图数（只用于扫描结束时的摘要日志）。 */
  private thumbDecoded: number = 0;
  /** 磁盘元数据缓存：handle → PhotoEntry，快速扫描时复用。 */
  private metadataCacheByHandle: Map<number, PhotoEntry> = new Map();
  /** metadata_cache.json 的写入时间，用于判断是否还能复用。 */
  private metadataCacheSavedAt: number = 0;

  // Orientation cache (EXIF Orientation → rotate/flipH/flipV)
  private orientationMap: Map<number, OrientationTransform> = new Map();

  // Orientations pre-loaded via GetPartialObject during scan, used to
  // apply correct rotate/flip at first thumbnail decode (no re-decode needed).
  private preloadedOrientations: Map<number, OrientationTransform> = new Map();

  // Original photo dimensions read from EXIF during scan (via GetPartialObject).
  // Used to compute precise thumbnail content area for black-bar-free cropping.
  private exifOrigDims: Map<number, OrientedSize> = new Map();

  // ---- Camera identity & thumbnail caching ----

  /** Unique camera identity (serial/model/manufacturer based). */
  @Trace cameraIdentity: string = '';
  /** Whether thumbnail disk caching is enabled for the current camera. */
  @Trace cachingEnabled: boolean = false;
  /** True when the UI should show a caching opt-in dialog. */
  @Trace cachingDialogRequired: boolean = false;
  /** Camera ID for the pending dialog. */
  pendingCamIdForDialog: string = '';
  /** Camera name for the pending dialog. */
  pendingCamNameForDialog: string = '';
  // ---- Debug identity info (displayed on CameraPage) ----
  @Trace deviceManufacturer: string = '';
  @Trace deviceSerialNumber: string = '';
  @Trace deviceVersion: string = '';
  @Trace usbVidPid: string = '';
  @Trace usbSerialNumber: string = '';
  /** Thumbnail disk cache manager. */
  private thumbCache: ThumbnailCache = new ThumbnailCache();
  /** Camera cache preferences (cross-camera). */
  private cachePrefs: CameraCachePrefs = CameraCachePrefs.getInstance();
  /** Application files dir (for cache dir construction). */
  private filesDir: string = '';

  /**
   * Map EXIF Orientation value (1–8) to DecodingOptions rotation + pixelMap flip.
   * Reference: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/image-rotate-faq
   *
   * HarmonyOS getImageProperty(PropertyKey.ORIENTATION) returns the string name
   * (e.g. "Top-left"), not the numeric string. Both formats are handled here for safety.
   */
  private static mapExifOrientation(orientation: string): OrientationTransform {
    switch (orientation) {
      // String names (HarmonyOS getImageProperty return value)
      case 'Top-left':     return new OrientationTransform(0, false, false);
      case 'Top-right':    return new OrientationTransform(0, true, false);
      case 'Bottom-right': return new OrientationTransform(180, false, false);
      case 'Bottom-left':  return new OrientationTransform(0, false, true);
      case 'Left-top':     return new OrientationTransform(90, true, false);
      case 'Right-top':    return new OrientationTransform(90, false, false);
      case 'Right-bottom': return new OrientationTransform(270, true, false);
      case 'Left-bottom':  return new OrientationTransform(270, false, false);
      // Numeric strings (fallback for other implementations)
      case '1': return new OrientationTransform(0, false, false);
      case '2': return new OrientationTransform(0, true, false);
      case '3': return new OrientationTransform(180, false, false);
      case '4': return new OrientationTransform(0, false, true);
      case '5': return new OrientationTransform(90, true, false);
      case '6': return new OrientationTransform(90, false, false);
      case '7': return new OrientationTransform(270, true, false);
      case '8': return new OrientationTransform(270, false, false);
      // Unknown / unsupported → no transform
      default:
        return new OrientationTransform(0, false, false);
    }
  }

  /**
   * Manually parse EXIF TIFF structure from raw JPEG data to extract
   * original image dimensions (ImageWidth/ImageLength).
   * The getImageProperty API fails for these tags (error 62980123).
   */
  private static parseExifDims(data: ArrayBuffer): OrientedSize | null {
    const bytes = new Uint8Array(data);
    if (bytes.length < 20) {
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] data too short: %{public}d', bytes.length);
      return null;
    }

    // Locate TIFF header: either at start (RAW/TIFF) or after JPEG APP1 Exif marker.
    let off = 0;
    const isTiff = (bytes[0] === 0x49 && bytes[1] === 0x49) || (bytes[0] === 0x4D && bytes[1] === 0x4D);
    hilog.info(DOMAIN, TAG, '[EXIF_PARSE] format=%{public}s totalBytes=%{public}d',
      isTiff ? 'TIFF/RAW' : 'JPEG', bytes.length);
    if (!isTiff) {
      // Must be JPEG — find APP1/Exif marker
      if (bytes[0] !== 0xFF || bytes[1] !== 0xD8) {
        hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] not JPEG SOI, b0=0x%{public}x b1=0x%{public}x', bytes[0], bytes[1]);
        return null; // not a recognized format
      }
      const foundApp1 = false;
      while (off < bytes.length - 14) {
        if (bytes[off] === 0xFF && bytes[off + 1] === 0xE1) {
          const app1Size = (bytes[off + 2] << 8) | bytes[off + 3];
          // Check "Exif\0\0" identifier
          if (off + 6 <= bytes.length &&
              bytes[off + 4] === 0x45 && bytes[off + 5] === 0x78 &&
              bytes[off + 6] === 0x69 && bytes[off + 7] === 0x66 &&
              bytes[off + 8] === 0x00 && bytes[off + 9] === 0x00) {
            hilog.info(DOMAIN, TAG, '[EXIF_PARSE] found APP1 Exif at offset=%{public}d size=%{public}d', off, app1Size);
            off += 10; // skip to TIFF header
            break;
          }
          // Skip to next marker (even if APP1 exceeds buffer, we already
          // checked the Exif\0\0 identifier above)
          off += 2 + app1Size;
        } else if (bytes[off] === 0xFF && bytes[off + 1] >= 0xE0 && bytes[off + 1] <= 0xEF) {
          const skip = (bytes[off + 2] << 8) | bytes[off + 3];
          off += 2 + (skip || 2);
        } else {
          off++;
        }
      }
      if (off >= bytes.length - 14) {
        hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] APP1 not found within %{public}d bytes', bytes.length);
        return null;
      }
    }
    // Now `off` points to TIFF header (II\0x2A\0 or MM\0x00\x2A)

    // Determine byte order: "II" (little-endian) or "MM" (big-endian)
    const le = (bytes[off] === 0x49 && bytes[off + 1] === 0x49);
    const be = (bytes[off] === 0x4D && bytes[off + 1] === 0x4D);
    if (!le && !be) {
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] unknown byte order: b0=%{public}d b1=%{public}d', bytes[off], bytes[off + 1]);
      return null;
    }

    // Helper: read 2 bytes at offset p
    const r16 = (p: number): number => {
      if (p + 2 > bytes.length) return 0;
      return le ? (bytes[p] | (bytes[p + 1] << 8)) : ((bytes[p] << 8) | bytes[p + 1]);
    };
    // Helper: read 4 bytes at offset p
    const r32 = (p: number): number => {
      if (p + 4 > bytes.length) return 0;
      if (le) return bytes[p] | (bytes[p + 1] << 8) | (bytes[p + 2] << 16) | (bytes[p + 3] << 24);
      return (bytes[p] << 24) | (bytes[p + 1] << 16) | (bytes[p + 2] << 8) | bytes[p + 3];
    };

    // Validate TIFF magic 0x002A
    if (r16(off + 2) !== 0x002A) {
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] invalid TIFF magic 0x%{public}x', r16(off + 2));
      return null;
    }

    // IFD0 offset is relative to start of TIFF header
    const ifd0Off = off + r32(off + 4);

    let imgW = 0, imgH = 0;
    let exifIfdOff = 0;

    // Parse IFD0 entries (12 bytes each).
    // 以前这里对每张 NEF 打印 25 行 IFD0 明细，1288 张就是几万行日志（ISSUE-007）；
    // 明细对定位“尺寸在 SubIFD”没有额外价值，只保留失败时的汇总。
    const entryCount = r16(ifd0Off);
    for (let i = 0; i < entryCount; i++) {
      const eOff = ifd0Off + 2 + i * 12;
      if (eOff + 12 > bytes.length) break;
      const tag = r16(eOff);
      const typ = r16(eOff + 2);
      if (tag === 0x0100) { // ImageWidth in IFD0
        imgW = (typ === 3) ? r16(eOff + 8) : r32(eOff + 8);
      } else if (tag === 0x0101) { // ImageLength in IFD0
        imgH = (typ === 3) ? r16(eOff + 8) : r32(eOff + 8);
      } else if (tag === 0x8769) { // ExifIFD pointer
        exifIfdOff = off + r32(eOff + 8);
      } else if (tag === 0x014A) { // SubIFD — beyond 192KB USB limit, skip
      } else if (tag === 0x0201) { // JPEGInterchangeFormat (embedded JPEG offset)
        if (imgW === 0 || imgH === 0) {
          // Parse the embedded JPEG preview's SOF marker for dimensions
          const jpegOff = off + r32(eOff + 8);
          if (jpegOff + 4 < bytes.length && bytes[jpegOff] === 0xFF && bytes[jpegOff + 1] === 0xD8) {
            // Scan JPEG markers for SOF (0xFFC0, 0xFFC1, 0xFFC2)
            let sp = jpegOff + 2;
            while (sp + 8 < bytes.length) {
              if (bytes[sp] !== 0xFF) break;
              const marker = bytes[sp + 1];
              if (marker >= 0xC0 && marker <= 0xC3) {
                imgH = (bytes[sp + 5] << 8) | bytes[sp + 6];
                imgW = (bytes[sp + 7] << 8) | bytes[sp + 8];
                break;
              }
              const segLen = (bytes[sp + 2] << 8) | bytes[sp + 3];
              sp += 2 + segLen;
            }
          }
        }
      }
    }

    if (imgW > 0 && imgH > 0) {
      hilog.info(DOMAIN, TAG, '[EXIF_PARSE] IFD0/SubIFD found %{public}dx%{public}d', imgW, imgH);
      return new OrientedSize(imgW, imgH);
    }

    // Try ExifIFD sub-directory
    if (exifIfdOff > 0 && exifIfdOff + 2 <= bytes.length) {
      const exifCount = r16(exifIfdOff);
      hilog.info(DOMAIN, TAG, '[EXIF_PARSE] ExifIFD at 0x%{public}x entries=%{public}d', exifIfdOff, exifCount);
      for (let i = 0; i < exifCount; i++) {
        const eOff = exifIfdOff + 2 + i * 12;
        if (eOff + 12 > bytes.length) break;
        const tag = r16(eOff);
        const typ = r16(eOff + 2);
        if (tag === 0xA002) { // ExifImageWidth
          imgW = (typ === 3) ? r16(eOff + 8) : r32(eOff + 8);
        } else if (tag === 0xA003) { // ExifImageLength
          imgH = (typ === 3) ? r16(eOff + 8) : r32(eOff + 8);
        }
      }
    } else if (exifIfdOff > 0) {
      // 指针存在但落在读取窗口之外：这是 16KB 头读不到 NEF 尺寸的真实原因，
      // 文案要如实说“越界”，否则会被误判成没有指针（ISSUE-012 顺带记录）。
      hilog.warn(DOMAIN, TAG,
        '[EXIF_PARSE] ExifIFD out of window: off=%{public}d len=%{public}d',
        exifIfdOff, bytes.length);
    } else {
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] no ExifIFD pointer (tag 0x8769) in IFD0');
    }

    if (imgW > 0 && imgH > 0) {
      hilog.info(DOMAIN, TAG, '[EXIF_PARSE] ExifIFD found %{public}dx%{public}d', imgW, imgH);
      return new OrientedSize(imgW, imgH);
    }
    hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] FAILED ifd0W=%{public}d ifd0H=%{public}d exifIfdOff=%{public}d entryCount=%{public}d', imgW, imgH, exifIfdOff, entryCount);
    return null;
  }

  /**
   * Read EXIF Orientation from raw image data and return the corresponding transform.
   * Caches result by handle so subsequent decodes skip re-parsing.
   */
  private async getOrientation(handle: number, data: ArrayBuffer): Promise<OrientationTransform> {
    if (this.orientationMap.has(handle)) {
      return this.orientationMap.get(handle)!;
    }
    try {
      const imgSrc = image.createImageSource(data);
      const orientation = await imgSrc.getImageProperty(image.PropertyKey.ORIENTATION);
      imgSrc.release();
      hilog.info(DOMAIN, TAG, `[ORIENT] handle=0x%{public}s raw="%{public}s"`, handle.toString(16), orientation);
      const result = CameraService.mapExifOrientation(orientation);
      hilog.info(DOMAIN, TAG, `[ORIENT] handle=0x%{public}s → rotate=%{public}d flipH=%{public}s flipV=%{public}s`,
        handle.toString(16), result.rotate, result.flipH.toString(), result.flipV.toString());
      this.orientationMap.set(handle, result);
      return result;
    } catch (err) {
      // No EXIF / unsupported format → treat as normal
      hilog.error(DOMAIN, TAG, `[ORIENT] getOrientation FAIL handle=0x%{public}s err=%{public}s`,
        handle.toString(16), JSON.stringify(err));
      const result = new OrientationTransform(0, false, false);
      this.orientationMap.set(handle, result);
      return result;
    }
  }

  // Download registry — persisted across sessions
  private downloadRegistry: Map<string, DownloadRecord> = new Map();
  private downloadDir: string = '';
  private downloadTempDir: string = '';
  private downloadAborted: boolean = false;
  private registryLoaded: boolean = false;
  private registryLoading: Promise<void> | null = null;
  /** 用于按 URI 查询媒体库；没有 context 或没有权限时退化为逐个打开 URI。 */
  private context: common.UIAbilityContext | null = null;
  /**
   * 传输期间申请的 DATA_TRANSFER 长时任务。
   *
   * 传输（扫描缩略图 / 批量下载）是用户可感知的长任务，不申请长时任务的话，
   * 应用一退到后台就会被挂起，USB 传输直接停掉。这里用引用计数：
   * 扫描与下载可能同时进行，最后一个结束时才取消。
   */
  private transferTaskRefs: number = 0;
  private transferTaskOn: boolean = false;
  /** 通知栏进度环（系统 downloadTemplate）的定时刷新句柄与当前进度。 */
  private noticeTimerId: number = -1;
  private noticeCurrent: number = 0;
  private noticeTotal: number = 0;
  private noticeLabel: string = '';
  private phAccessHelper: photoAccessHelper.PhotoAccessHelper | null = null;
  private mediaQuerySupported: boolean | null = null;

  // Change tracking
  @Trace registryVersion: number = 0;
  @Trace photosVersion: number = 0;

  static getInstance(): CameraService {
    if (!CameraService.instance) {
      CameraService.instance = new CameraService();
    }
    return CameraService.instance;
  }

  private constructor() {
    setPtpLog(this.log);
    this.log.add('App 启动');
  }

  getLog(): AppLog {
    return this.log;
  }

  initLogPath(dir: string): void {
    this.log.setFilePath(dir + '/app_log.txt');
  }

  initDownloadDir(dir: string, ctx?: common.UIAbilityContext): void {
    this.filesDir = dir;
    this.downloadDir = dir;
    if (ctx !== undefined) {
      this.context = ctx;
    }
    this.downloadTempDir = dir + '/download_temp';
    // 上次中断留下的沙箱临时图片不再需要；先清空再建目录。
    AtomicFile.deleteDirRecursive(this.downloadTempDir);
    try {
      fileIo.mkdirSync(this.downloadTempDir, true);
    } catch (_e) {
      // best effort
    }
    this.cachePrefs.init(dir);
    this.loadRegistry();
  }

  /** 应用进入后台时强制把待写缓存落盘。 */
  async flushPersistence(): Promise<void> {
    try {
      if (this.cachingEnabled) {
        await this.thumbCache.flush();
        this.thumbCache.close();
      }
    } catch (_e) {
      // best effort
    }
  }

  makeDownloadKey(filename: string, size: number): string {
    return `${this.cameraIdentity}::${filename}::${size}`;
  }

  /** 旧版本的全局键：没有相机身份，只在没有新记录时兼容读取。 */
  private makeLegacyDownloadKey(filename: string, size: number): string {
    return `${filename}::${size}`;
  }

  /** 先找当前相机的记录，再回退到旧版无相机字段的记录。 */
  private findDownloadRecord(filename: string, size: number): DownloadRecord | null {
    const current = this.downloadRegistry.get(this.makeDownloadKey(filename, size));
    if (current !== undefined) return current;
    const legacy = this.downloadRegistry.get(this.makeLegacyDownloadKey(filename, size));
    if (legacy !== undefined &&
        (legacy.cameraId === undefined || legacy.cameraId === '')) {
      return legacy;
    }
    return null;
  }

  @Trace downloadedCount: number = 0;

  getDownloadedKeys(): string[] {
    const keys: string[] = [];
    for (const p of this.photos) {
      const record = this.findDownloadRecord(p.filename, p.size);
      if (record !== null && record.missingSince === undefined) {
        // 返回当前相机键，GalleryPage 用 makeDownloadKey() 计算出的键才能命中。
        keys.push(this.makeDownloadKey(p.filename, p.size));
      }
    }
    this.downloadedCount = keys.length;
    return keys;
  }

  cancelDownload(): void {
    this.downloadAborted = true;
  }



  /** 传输期间每秒刷新一次通知栏进度环（系统 downloadTemplate）。 */
  private startNoticeTimer(): void {
    if (this.noticeTimerId >= 0) {
      return;
    }
    this.noticeTimerId = setInterval(() => { this.tickTransferNotice(); }, 1000);
  }

  private stopNoticeTimer(): void {
    if (this.noticeTimerId >= 0) {
      clearInterval(this.noticeTimerId);
      this.noticeTimerId = -1;
    }
    this.noticeCurrent = 0;
    this.noticeTotal = 0;
    this.noticeLabel = '';
  }

  private tickTransferNotice(): void {
    if (this.context === null) {
      return;
    }
    let current = 0;
    let total = 0;
    let label = '';
    if (this.scanning && this.scanTotal > 0) {
      current = this.scanProgress;
      total = this.scanTotal;
      label = this.scanPhaseText;
    } else if (this.noticeTotal > 0) {
      current = this.noticeCurrent;
      total = this.noticeTotal;
      label = this.noticeLabel;
    }
    if (total <= 0) {
      return;
    }
    const pct = Math.round(current * 100 / total);
    const detail = `${current}/${total}` + (label !== '' ? ` · ${label}` : '');
    TransferNotice.update(this.context, '正在导入照片', detail, pct).catch((_e: Error) => { /* 通知失败不影响传输 */ });
  }

  /** 传输开始：申请后台长时任务（可重入，按引用计数）。 */
  private async beginTransferTask(): Promise<void> {
    this.transferTaskRefs++;
    this.startNoticeTimer();
    if (this.transferTaskOn || this.context === null) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'io.github.shaoyuanyu.strollandshoot',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1,
        actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
      };
      const wa: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, wa);
      this.transferTaskOn = true;
      this.log.add('后台传输长时任务已申请');
    } catch (err) {
      // 与定位长时任务冲突（同一 UIAbility 同时只允许一个）或系统拒绝时不要打断传输，
      // 只是退到后台后可能被挂起。
      this.log.add(`后台传输长时任务申请失败: ${(err as BusinessError).message}`);
    }
  }

  /** 传输结束：最后一个引用释放时取消长时任务。 */
  private async endTransferTask(): Promise<void> {
    if (this.transferTaskRefs > 0) {
      this.transferTaskRefs--;
    }
    if (this.transferTaskRefs > 0 || !this.transferTaskOn || this.context === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.log.add('后台传输长时任务已取消');
    } catch (err) {
      this.log.add(`后台传输长时任务取消失败: ${(err as BusinessError).message}`);
    }
    this.transferTaskOn = false;
    this.stopNoticeTimer();
    await TransferNotice.cancel();
  }

  async downloadPhotos(
    handles: number[],
    onProgress: (progress: DownloadProgress) => void,
    context: common.UIAbilityContext
  ): Promise<DownloadResult[]> {
    // Ensure registry is loaded before starting
    await this.loadRegistry();

    const results: DownloadResult[] = [];
    const errors: string[] = [];

    const batch: PhotoEntry[] = [];
    let totalBytes = 0;
    for (const h of handles) {
      for (const p of this.photos) {
        if (p.handle === h) {
          batch.push(p);
          totalBytes += p.size;
          break;
        }
      }
    }

    if (batch.length === 0) {
      onProgress({
        phase: 'error', currentIndex: 0, totalCount: 0,
        currentFilename: '', currentSizeBytes: 0,
        downloadedCount: 0, totalBytes: 0, downloadedBytes: 0,
        errors: ['No matching photos found for selected handles']
      });
      return results;
    }

    // 批量下载同样是长任务：退到后台不能停，申请 DATA_TRANSFER 长时任务
    await this.beginTransferTask();

    this.downloadAborted = false;
    let downloadedBytes = 0;
    for (let i = 0; i < batch.length; i++) {
      if (this.downloadAborted) {
        this.downloadAborted = false;
        this.log.add('下载已取消');
        errors.push('用户取消下载');
        onProgress({
          phase: 'complete', currentIndex: i, totalCount: batch.length,
          currentFilename: '', currentSizeBytes: 0,
          downloadedCount: results.filter((r: DownloadResult) => r.success).length,
          totalBytes, downloadedBytes, errors
        });
        break;
      }

      const photo = batch[i];
      this.noticeCurrent = i + 1;
      this.noticeTotal = batch.length;
      this.noticeLabel = photo.filename;

      const key = this.makeDownloadKey(photo.filename, photo.size);

      const existing = this.findDownloadRecord(photo.filename, photo.size);
      if (existing !== null && existing.missingSince === undefined) {
        results.push({ handle: photo.handle, key, success: true, localPath: existing.localPath });
        onProgress({
          phase: 'downloading', currentIndex: i, totalCount: batch.length,
          currentFilename: photo.filename, currentSizeBytes: photo.size,
          downloadedCount: results.filter((r: DownloadResult) => r.success).length,
          totalBytes, downloadedBytes, errors
        });
        continue;
      }

      onProgress({
        phase: 'downloading', currentIndex: i, totalCount: batch.length,
        currentFilename: photo.filename, currentSizeBytes: photo.size,
        downloadedCount: results.filter((r: DownloadResult) => r.success).length,
        totalBytes, downloadedBytes, errors
      });

      let data: Uint8Array | null = null;

      // Reuse preloaded data from cache to avoid re-downloading via USB
      if (this.compressedCache.has(photo.handle)) {
        data = this.compressedCache.get(photo.handle)!;
        this.log.add(`下载(缓存命中): ${photo.filename} (${this.formatSize(data.length)})`);
      } else {
        try {
          data = await this.session.getObject(photo.handle);
        } catch (err) {
          const msg = `${photo.filename}: USB传输失败: ${JSON.stringify(err)}`;
          errors.push(msg);
          results.push({ handle: photo.handle, key, success: false, localPath: '', error: msg });
          continue;
        }
      }

      if (!data || data.length === 0) {
        errors.push(`${photo.filename}: USB传输返回空数据`);
        results.push({ handle: photo.handle, key, success: false,
          localPath: '', error: 'USB transfer returned empty data' });
        continue;
      }

      onProgress({
        phase: 'saving', currentIndex: i, totalCount: batch.length,
        currentFilename: photo.filename, currentSizeBytes: photo.size,
        downloadedCount: results.filter((r: DownloadResult) => r.success).length,
        totalBytes, downloadedBytes, errors
      });

      const localFilename = this.sanitizeFilename(photo.filename);
      const localPath = this.downloadTempDir + '/' + localFilename;
      try {
        const f = await fileIo.open(localPath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        await fileIo.write(f.fd, data.buffer as ArrayBuffer);
        await fileIo.close(f);
      } catch (err) {
        const msg = `${photo.filename}: 写入文件失败: ${JSON.stringify(err)}`;
        errors.push(msg);
        results.push({ handle: photo.handle, key, success: false, localPath: '', error: msg });
        continue;
      }

      downloadedBytes += data.length;
      results.push({ handle: photo.handle, key, success: true, localPath: localPath });

      // Apply GPS geotagging to the sandbox file before Gallery save
      if (photo.captureDate) {
        const gpsRecorder = GpsRecorder.getInstance();
        const gpsRecords = gpsRecorder.getRecords();
        if (gpsRecords.length > 0) {
          const photoTime = GpsRecorder.parseCaptureDate(photo.captureDate);
          const gps = gpsRecorder.findClosest(photo.captureDate);
          this.log.add(`GPS匹配: ${photo.filename} captureDate=${photo.captureDate} photoTime=${photoTime} gpsRange=[${gpsRecords[0].timestamp}..${gpsRecords[gpsRecords.length-1].timestamp}] match=${gps ? 'yes' : 'no'}`);
          if (gps) {
            const tagged = await ExifGeotagger.applyGps(localPath, gps);
            if (tagged) {
              this.log.add(`GPS标记: ${photo.filename} (${gps.latitude.toFixed(4)},${gps.longitude.toFixed(4)})`);
            }
          }
        }
      } else {
        this.log.add(`GPS跳过: ${photo.filename} 无captureDate`);
      }

      this.log.add(`沙箱暂存 [${i + 1}/${batch.length}]: ${photo.filename} (${this.formatSize(photo.size)})`);
    }

    // Phase: save to system Gallery via showAssetsCreationDialog
    const sandboxSuccesses = results.filter((r: DownloadResult) => r.success);
    if (sandboxSuccesses.length > 0) {
      onProgress({
        phase: 'saving', currentIndex: batch.length, totalCount: batch.length,
        currentFilename: '正在保存到相册...', currentSizeBytes: 0,
        downloadedCount: sandboxSuccesses.length, totalBytes, downloadedBytes, errors
      });

      const onSaved = (result: DownloadResult, galleryUri: string): void => {
        const photo = batch.find((p: PhotoEntry) => p.handle === result.handle);
        if (!photo) return;
        const record: DownloadRecord = {
          key: result.key,
          cameraId: this.cameraIdentity,
          filename: photo.filename,
          size: photo.size,
          localPath: galleryUri,
          downloadDate: new Date().toISOString()
        };
        // 每成功一张就写 journal；整批结束再压缩成快照。
        this.addDownloadRecord(record);
      };

      let galleryUris: Map<string, string> = new Map();
      try {
        galleryUris = await this.moveToGallery(sandboxSuccesses, context, onSaved);
      } catch (err) {
        this.log.add(`保存到相册失败: ${JSON.stringify(err)}`);
      }

      if (galleryUris.size > 0) {
        await this.compactRegistry();
      }
    }

    onProgress({
      phase: 'complete', currentIndex: batch.length - 1, totalCount: batch.length,
      currentFilename: '', currentSizeBytes: 0,
      downloadedCount: results.filter((r: DownloadResult) => r.success).length,
      totalBytes, downloadedBytes, errors
    });

    this.log.add(`批量下载完成: ${results.filter((r: DownloadResult) => r.success).length}/${batch.length} 成功`);
    if (errors.length > 0) {
      this.log.add(`错误: ${errors.join('; ')}`);
    }

    await this.endTransferTask();
    return results;
  }

  /**
   * Moves successfully downloaded sandbox files to the system Gallery
   * via showAssetsCreationDialog. User confirms once for all files.
   * Returns a map from download key to Gallery URI for successfully copied files.
   */
  private async moveToGallery(
    sandboxResults: DownloadResult[],
    context: common.UIAbilityContext,
    onSaved?: (result: DownloadResult, galleryUri: string) => void
  ): Promise<Map<string, string>> {
    const galleryUris = new Map<string, string>();
    const srcFileUris: string[] = [];
    const photoCreationConfigs: photoAccessHelper.PhotoCreationConfig[] = [];

    const prefix = this.sanitizeCameraName(this.cameraName);

    for (const r of sandboxResults) {
      const ext = this.getFileExtension(r.localPath);
      srcFileUris.push(fileUri.getUriFromPath(r.localPath));
      const fileName = r.localPath.substring(r.localPath.lastIndexOf('/') + 1);
      const nameWithoutExt = fileName.substring(0, fileName.lastIndexOf('.'));
      const title = prefix ? `${prefix}_${nameWithoutExt}` : nameWithoutExt;
      photoCreationConfigs.push({
        title: title,
        fileNameExtension: ext,
        photoType: photoAccessHelper.PhotoType.IMAGE,
      });
    }

    const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    let desFileUris: string[] = [];
    try {
      desFileUris = await phAccessHelper.showAssetsCreationDialog(
        srcFileUris, photoCreationConfigs
      );
    } catch (err) {
      this.log.add(`保存到相册弹窗失败: ${JSON.stringify(err)}`);
      return galleryUris;
    }

    if (desFileUris.length === 0) {
      this.log.add('用户取消保存到相册，文件保留在应用沙箱');
      return galleryUris;
    }

    // Copy from sandbox to Gallery URIs
    let copied = 0;
    for (let i = 0; i < desFileUris.length; i++) {
      try {
        const srcFile = fileIo.openSync(srcFileUris[i], fileIo.OpenMode.READ_ONLY);
        const desFile = fileIo.openSync(desFileUris[i],
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        fileIo.copyFileSync(srcFile.fd, desFile.fd);
        fileIo.closeSync(srcFile);
        fileIo.closeSync(desFile);
        if (i < sandboxResults.length) {
          galleryUris.set(sandboxResults[i].key, desFileUris[i]);
          if (onSaved !== undefined) {
            onSaved(sandboxResults[i], desFileUris[i]);
          }
        }
        copied++;
      } catch (err) {
        this.log.add(`相册写入失败 [${i}]: ${JSON.stringify(err)}`);
      }
    }

    // Delete sandbox temp files
    for (const r of sandboxResults) {
      try { fileIo.unlink(r.localPath); } catch (_e) { /* best effort */ }
    }

    this.log.add(`已保存到相册: ${copied}/${desFileUris.length} 张`);
    return galleryUris;
  }

  private sanitizeCameraName(name: string): string {
    if (!name) return '';
    return name.replace(/[\\/:*?"<>| ]/g, '_').substring(0, 32);
  }

  private getFileExtension(path: string): string {
    const dot = path.lastIndexOf('.');
    if (dot < 0) return 'jpg';
    return path.substring(dot + 1).toLowerCase();
  }


  private sanitizeFilename(name: string): string {
    return name.replace(/[/\\:*?"<>|]/g, '_');
  }

  private registryPath(): string {
    return this.downloadDir + '/download_registry.json';
  }

  private registryJournalPath(): string {
    return this.downloadDir + '/download_registry.jsonl';
  }

  private async loadRegistry(): Promise<void> {
    if (this.registryLoaded) return;
    const loading = this.registryLoading;
    if (loading !== null) {
      await Promise.resolve(loading);
      return;
    }
    const task = this.doLoadRegistry();
    this.registryLoading = task;
    try {
      await task;
    } finally {
      this.registryLoading = null;
    }
  }

  private async doLoadRegistry(): Promise<void> {
    const text = AtomicFile.readText(this.registryPath());
    if (text !== null && text !== '') {
      try {
        const parsed = JSON.parse(text) as Record<string, Object>;
        const version = parsed['version'];
        const raw = version !== undefined ? parsed['records'] : parsed;
        if (raw !== undefined && raw !== null) {
          const map = raw as Record<string, DownloadRecord>;
          for (const k of Object.keys(map)) {
            this.downloadRegistry.set(k, map[k]);
          }
        }
        this.log.add(`加载下载记录: ${this.downloadRegistry.size} 条`);
      } catch (err) {
        this.log.add(`加载下载记录失败: ${JSON.stringify(err)}`);
      }
    }
    this.registryVersion++;

    // 逐张追加的 journal 比整份快照更耐崩溃：先合并，再压缩回快照。
    const journalText = AtomicFile.readText(this.registryJournalPath());
    if (journalText !== null && journalText !== '') {
      let applied = 0;
      const lines = journalText.split('\n');
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed === '') continue;
        try {
          const entry = JSON.parse(trimmed) as DownloadJournalEntry;
          if (entry.key !== undefined && entry.key !== '' &&
              entry.record !== undefined && entry.record !== null) {
            this.downloadRegistry.set(entry.key, entry.record);
            applied++;
          }
        } catch (_e) {
          // 最后一行可能只写了一半，忽略
        }
      }
      if (applied > 0) {
        this.log.add(`下载记录 journal 恢复: ${applied} 条`);
      }
      await this.compactRegistry();
    }

    // 超过上限时按下载时间淘汰最旧记录。
    if (this.pruneDownloadRegistry()) {
      await this.compactRegistry();
    }

    // Prune entries whose Gallery files no longer exist (e.g. user deleted from Album)
    await this.validateRegistry();
    this.registryLoaded = true;
  }

  /** 注册表超过 MAX_DOWNLOAD_RECORDS 时删除最旧记录；返回是否删除过。 */
  private pruneDownloadRegistry(): boolean {
    if (this.downloadRegistry.size <= MAX_DOWNLOAD_RECORDS) return false;
    const keys: string[] = [];
    this.downloadRegistry.forEach((_record: DownloadRecord, key: string) => {
      keys.push(key);
    });
    keys.sort((a: string, b: string): number => {
      const da = this.downloadRegistry.get(a)?.downloadDate ?? '';
      const db = this.downloadRegistry.get(b)?.downloadDate ?? '';
      return da.localeCompare(db);
    });
    const drop = keys.length - MAX_DOWNLOAD_RECORDS;
    for (let i = 0; i < drop; i++) {
      this.downloadRegistry.delete(keys[i]);
    }
    this.log.add(`下载注册表超过 ${MAX_DOWNLOAD_RECORDS} 条，已清理最旧 ${drop} 条`);
    return true;
  }

  /**
   * 校验下载记录与系统图库的实际状态。
   *
   * 图库删除会先进「最近删除」，此时 media URI 打开失败（常见 13900001），
   * 但 30 天内仍可恢复。因此不做物理删除，只打 missingSince 标记：
   * 绿点只按 active 记录计算，恢复后下一次校验清掉标记即可回来。
   */
  private async validateRegistry(): Promise<void> {
    const keys: string[] = [];
    this.downloadRegistry.forEach((_record: DownloadRecord, key: string) => {
      keys.push(key);
    });
    const now = Date.now();
    let markedMissing = 0;
    let restored = 0;
    let changed = false;
    const skipped: string[] = [];
    for (const key of keys) {
      const record = this.downloadRegistry.get(key);
      if (!record || !record.localPath) continue;
      const state = await this.checkRecordAvailability(record);
      if (state === true) {
        if (record.missingSince !== undefined) {
          record.missingSince = undefined;
          restored++;
          changed = true;
        }
      } else if (state === false) {
        if (record.missingSince === undefined) {
          record.missingSince = now;
          markedMissing++;
          changed = true;
        }
      } else {
        skipped.push(record.filename);
      }
    }
    // 超过图库「最近删除」保留期的记录不再可能恢复，清掉避免无限增长。
    const expired: string[] = [];
    this.downloadRegistry.forEach((record: DownloadRecord, key: string) => {
      if (record.missingSince !== undefined &&
          now - record.missingSince > MISSING_RETENTION_MS) {
        expired.push(key);
      }
    });
    for (const key of expired) {
      this.downloadRegistry.delete(key);
    }
    if (changed || expired.length > 0) {
      await this.compactRegistry();
    }
    if (markedMissing > 0) {
      this.log.add(`下载记录标记失效: ${markedMissing} 条（可能在“最近删除”）`);
    }
    if (restored > 0) {
      this.log.add(`下载记录恢复: ${restored} 条`);
    }
    if (expired.length > 0) {
      this.log.add(`下载记录清理: 移除 ${expired.length} 条超过 30 天的失效记录`);
    }
    if (skipped.length > 0) {
      this.log.add(`下载记录校验跳过 ${skipped.length} 条（未知错误）`);
    }
  }

  /**
   * 判断一条下载记录是否仍可在图库中访问。
   * 先试 URI；失败时再按 URI 查询媒体库，查询不可用则按错误码判断。
   */
  private async checkRecordAvailability(record: DownloadRecord): Promise<boolean | null> {
    try {
      const f = await fileIo.open(record.localPath, fileIo.OpenMode.READ_ONLY);
      await fileIo.close(f);
      return true;
    } catch (err) {
      const code = (err as BusinessError).code;
      const isMediaUri = record.localPath.startsWith('file://media/');
      const likelyGone = code === 13900002 ||
        (isMediaUri && (code === 13900001 || code === 13900012 || code === 201));
      if (!likelyGone) {
        return null;
      }
      const mediaFound = await this.queryMediaAsset(record.localPath);
      if (mediaFound !== null) {
        return mediaFound;
      }
      return false;
    }
  }

  /**
   * 按 URI 查询媒体库，判断资产是否仍存在。
   * 未声明 READ_IMAGEVIDEO 时可能失败；失败返回 null，由调用方退化为 URI 探测。
   */
  private async queryMediaAsset(uri: string): Promise<boolean | null> {
    if (this.mediaQuerySupported === false || this.context === null) {
      return null;
    }
    try {
      if (this.phAccessHelper === null) {
        this.phAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context);
      }
      const predicates = new dataSharePredicates.DataSharePredicates();
      predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
      const options: photoAccessHelper.FetchOptions = {
        predicates: predicates,
        fetchColumns: [photoAccessHelper.PhotoKeys.URI]
      };
      const result = await this.phAccessHelper.getAssets(options);
      const count = result.getCount();
      result.close();
      this.mediaQuerySupported = true;
      return count > 0;
    } catch (err) {
      const code = (err as BusinessError).code;
      this.mediaQuerySupported = false;
      this.log.add(`媒体库查询不可用: code=${code}`);
      return null;
    }
  }

  private async saveRegistry(): Promise<boolean> {
    const records: Record<string, DownloadRecord> = {};
    this.downloadRegistry.forEach((v: DownloadRecord, k: string) => {
      records[k] = v;
    });
    const file: DownloadRegistryFile = {
      version: 1,
      records: records
    };
    try {
      AtomicFile.writeText(this.registryPath(), JSON.stringify(file));
      this.registryVersion++;
      return true;
    } catch (err) {
      this.log.add(`保存下载记录失败: ${JSON.stringify(err)}`);
      return false;
    }
  }

  /** 快照写成功后删除 journal；写失败则保留，下次启动继续恢复。 */
  private async compactRegistry(): Promise<void> {
    const ok = await this.saveRegistry();
    if (ok) {
      AtomicFile.delete(this.registryJournalPath());
    }
  }

  /** 单条记录立即写 journal，避免批次被杀时整批下载历史丢失。 */
  private appendRegistryRecord(record: DownloadRecord): void {
    this.downloadRegistry.set(record.key, record);
    this.registryVersion++;
    try {
      const entry: DownloadJournalEntry = { key: record.key, record: record };
      AtomicFile.appendText(this.registryJournalPath(), JSON.stringify(entry) + '\n');
    } catch (err) {
      this.log.add(`下载记录 journal 写入失败: ${JSON.stringify(err)}`);
    }
  }

  private addDownloadRecord(record: DownloadRecord): void {
    // 从「最近删除」恢复后重新下载同一张时，覆盖旧记录的 URI 与缺失标记。
    this.appendRegistryRecord(record);
  }

  async scanForCamera(quickMode: boolean = true, bypassThrottle: boolean = false): Promise<void> {
    const startedAt = Date.now();
    if (this.scanning || this.pendingCachingResolve !== null) {
      this.log.add('[节流] 已有扫描在进行中，忽略本次请求');
      return;
    }
    if (!bypassThrottle && this.lastScanStartMs > 0 &&
        startedAt - this.lastScanStartMs < SCAN_MIN_INTERVAL_MS) {
      this.log.add(`[节流] 距上次扫描 ${startedAt - this.lastScanStartMs}ms，忽略本次请求`);
      return;
    }
    this.lastScanStartMs = startedAt;
    this.scanning = true;
    this.log.add('=== 开始扫描 ===');
    // 扫描全程（元数据 + 缩略图）都是 USB 传输，退后台要继续，先申请长时任务
    await this.beginTransferTask();

    // Debug builds only: swap in the virtual camera before searching.
    this.syncSessionMode();

    this.statusText = L10n.tr('camera_status_searching');


    try {
      const cameras = this.sessionIsMock ? MockPtpDevice.findCameras() : PtpSession.findCameras();
      if (cameras.length === 0) {
        this.connected = false;
        this.cameraName = '';
        this.reportScanFailure(L10n.tr('camera_status_no_camera'));
        this.scanning = false;
        return;
      }

      const sameDevice = this.connected &&
        this.session.connectedDeviceName === cameras[0].name;

      if (sameDevice) {
        // Same camera — keep USB session alive.
        // 不再清空 photos：一次失败的快速扫描不该让已经有内容的画廊先空一下
        // （ISSUE-005）。缩略图内存缓存仍然清掉，Phase 0 / Phase 2b 会重新填。
        this.thumbnailPixelMapMap.clear();
        this.thumbnailLoadedSet.clear();
        this.preloadedOrientations.clear();
        this.exifOrigDims.clear();
        this.orientationMap.clear();
        this.orientedDisplaySizes.clear();
        this.clearFullCache();
        this.statusText = L10n.tr('camera_status_connected');

        // Refresh camera identity from PTP if not already set
        if (!this.cameraIdentity) {
          const deviceInfo = await this.session.getDeviceInfo();
          if (deviceInfo) {
            this.cameraIdentity = this.buildCameraIdentity(deviceInfo, cameras[0]);
            this.cameraName = deviceInfo.model || deviceInfo.manufacturer || this.cameraName;
            this.log.add(`相机身份(刷新): ${this.cameraIdentity}`);
          }
        }
        // Re-check caching state (user may have changed prefs in settings)
        this.checkCachingState();

      } else {
        // Different camera or first connect
        if (this.connected) {
          await this.disconnect();
        }

        this.statusText = L10n.tr('camera_status_found_camera', cameras[0].productName);
    

        const ok = await this.session.connect(cameras[0]);
        if (!ok) {
          this.connected = false;
          // 0x201E：相机里还留着上一次崩溃时的会话，光重试没有用，要用户拔插一次线。
          this.reportScanFailure(L10n.tr(this.session.sessionConflict === true
            ? 'camera_status_session_conflict' : 'camera_status_connect_failed'));
          this.scanning = false;
          return;
        }

        this.cameraName = cameras[0].productName || cameras[0].manufacturerName ||
                          cameras[0].name;
        this.statusText = L10n.tr('camera_status_connected');
        this.connected = true;
        this.usable = false;

        // Fetch PTP device identity for unique camera identification
        const deviceInfo = await this.session.getDeviceInfo();
        this.deviceManufacturer = deviceInfo?.manufacturer || cameras[0].manufacturerName || '';
        this.deviceSerialNumber = deviceInfo?.serialNumber || cameras[0].serial || '';
        this.deviceVersion = deviceInfo?.deviceVersion || '';
        this.usbVidPid = `VID_${cameras[0].vendorId.toString(16).padStart(4,'0')}_PID_${cameras[0].productId.toString(16).padStart(4,'0')}`;
        this.usbSerialNumber = cameras[0].serial || '';
        if (deviceInfo) {
          this.log.add(`PTP DeviceInfo: manu="${deviceInfo.manufacturer}" model="${deviceInfo.model}" serial="${deviceInfo.serialNumber}" ver="${deviceInfo.deviceVersion}"`);
          this.cameraIdentity = this.buildCameraIdentity(deviceInfo, cameras[0]);
          this.cameraName = deviceInfo.model || deviceInfo.manufacturer || this.cameraName;
        } else {
          // Fallback: use USB-level info
          this.cameraIdentity = `vid_${cameras[0].vendorId.toString(16).padStart(4,'0')}_pid_${cameras[0].productId.toString(16).padStart(4,'0')}`;
          this.log.add(`USB fallback identity: ${this.cameraIdentity}`);
        }
        this.log.add(`相机身份: ${this.cameraIdentity}`);

        // Check caching preference for this camera
        this.checkCachingState();
      }

      // 新相机：连接成功后立刻问「要不要缓存」，问完再扫。
      // 早前是「先按启用缓存扫完，再弹窗追问」，弹窗要等元数据 + 全部缩略图都传完
      // （1288 张要好几分钟）才出现，时机完全错位。
      if (this.pendingCachingPrompt) {
        this.statusText = L10n.tr('camera_status_choose_cache');
        this.scanning = false;
        const cacheChosen = await this.askCachingPreference();
        this.pendingCachingPrompt = false;
        this.log.add(`缓存询问结果: ${cacheChosen ? '启用' : '不启用'}，继续扫描`);
        this.scanning = true;
        this.statusText = L10n.tr('camera_status_connected');
      }

      // Phase 0: deploy cached snapshot (quick mode only, caching enabled, known camera)
      if (quickMode && this.cachingEnabled && this.cameraIdentity &&
          this.cachePrefs.hasCamera(this.cameraIdentity)) {
        this.log.add('[快速扫描] 部署缓存快照...');
        this.statusText = L10n.tr('camera_status_loading_cache');
        // Manifest must be loaded before findCached() can hit anything.
        this.thumbCache.init(this.filesDir, this.cameraIdentity);
        await this.thumbCache.loadManifest();
        await this.deployCacheSnapshot();
        this.log.add(`[快速扫描] 缓存快照就绪: ${this.photoCount} 张`);
      }

      // scanning stays true for the entire scan (Phase 1 → 2a → 2b)
      this.scanning = true;
      this.statusText = L10n.tr('camera_status_scanning');

      // Phase 1 + 2a + 2b (replaces old loadPhotosAndThumbnails)
      const scanOk = await this.loadPhotosAndThumbnails(quickMode);
      if (scanOk) {
        this.lastScanError = '';
      }

      // Defer registry validation so UI becomes responsive immediately
      this.validateRegistry().catch((_e: Error) => { /* best effort */ });
    } catch (err) {
      hilog.error(DOMAIN, TAG, `scan error: ${JSON.stringify(err)}`);
      this.reportScanFailure(this.describeScanError(err as Object));
      this.connected = false;
    } finally {
      this.scanning = false;
      await this.endTransferTask();
    }
  }

  /** 把扫描失败统一落到状态文案 + toast 计数上（ISSUE-001）。 */
  private reportScanFailure(message: string): void {
    this.statusText = message;
    this.lastScanError = message;
    this.scanErrorVersion++;
    this.usable = false;
    this.log.add(`扫描失败: ${message}`);
  }

  /** `PtpError` → 用户能看懂、且指得出下一步动作的文案（ISSUE-002）。 */
  private describeScanError(err: Object): string {
    if (err instanceof PtpError) {
      switch (err.code) {
        case 0x200F:
          return L10n.tr('camera_status_access_denied');
        case 0x200E:
          return L10n.tr('camera_status_store_readonly');
        case 0x2008:
          return L10n.tr('camera_status_invalid_storage');
        case PTP_ERR_NOT_OPEN:
          return L10n.tr('camera_status_session_lost');
        default:
          if (err.code < 0) return L10n.tr('camera_status_usb_error');
          return L10n.tr('camera_status_ptp_error', `0x${err.code.toString(16)}`);
      }
    }
    return L10n.tr('camera_status_scan_error');
  }

  /**
   * Recursively collect all photo handles by traversing the directory tree.
   * Uses GetObjectHandles format filtering (0x0000 vs 0x3001) to separate
   * files from directories with just 2 USB calls per directory level.
   * Detects format filter support once (via JPEG 0x3801 test) and caches
   * the result across all recursive levels.
   */
  private async collectPhotoHandles(
    storageIDs: number[], parent: number, depth: number,
    onBatchFound: (count: number) => void
  ): Promise<number[]> {
    if (depth > 10) return [];

    const result: number[] = [];
    for (const sid of storageIDs) {
      const allHandles = await this.session.getObjectHandles(sid, parent, 0);
      if (allHandles.length === 0) continue;

      // Detect format filter support once (only at first directory level)
      if (this.formatFilterWorks === null) {
        const jpegHandles = await this.session.getObjectHandles(sid, parent, 0x3801);
        this.formatFilterWorks = jpegHandles.length < allHandles.length;
      }

      if (this.formatFilterWorks) {
        const dirHandles = await this.session.getObjectHandles(sid, parent, 0x3001);
        const dirSet = new Set(dirHandles);
        const files: number[] = [];
        const dirs: number[] = [];
        for (const h of allHandles) {
          if (dirSet.has(h)) {
            dirs.push(h);
          } else {
            files.push(h);
          }
        }
        if (files.length > 0) {
          result.push(...files);
          onBatchFound(files.length);
        }
        for (const dh of dirs) {
          const sub = await this.collectPhotoHandles(storageIDs, dh, depth + 1, onBatchFound);
          result.push(...sub);
        }
      } else {
        // Camera doesn't support format filtering — per-handle getObjectInfo
        const dirs: number[] = [];
        for (const h of allHandles) {
          let info: ObjectInfo | null = null;
          try {
            info = await this.session.getObjectInfo(h);
          } catch (err) {
            this.log.add(`目录判定失败 handle=0x${h.toString(16)}: ${(err as Error).message}`);
            continue;
          }
          if (!info) continue;
          if (info.objectFormat === 0x3001) {
            dirs.push(h);
            hilog.info(DOMAIN, TAG,
              `Dir 0x${h.toString(16)}: ${info.filename}`);
          } else {
            result.push(h);
            onBatchFound(1);
          }
        }
        for (const dh of dirs) {
          const sub = await this.collectPhotoHandles(storageIDs, dh, depth + 1, onBatchFound);
          result.push(...sub);
        }
      }

      break;
    }
    return result;
  }

  /**
   * Traverse directories (instant with format filtering), then load photo
   * metadata and thumbnails in a single pass with a progress bar.
   *
   * 返回 true 表示存储可读、整轮扫描没有被中断。失败原因写进
   * `statusText` / `lastScanError`，并且**不清空已有照片**（ISSUE-005）。
   */
  private async loadPhotosAndThumbnails(quickMode: boolean): Promise<boolean> {
    this.statusText = L10n.tr('camera_status_fetching_list');
    this.scanProgress = 0;
    this.scanTotal = 0;

    try {
      const storageIDs = await this.session.getStorageIDs();
      hilog.info(DOMAIN, TAG, `StorageIDs count: ${storageIDs.length}`);

      if (storageIDs.length === 0) {
        // 相机明确返回空列表：这才是“没有存储”。与 0x200F“拒绝访问”区分开。
        this.reportScanFailure(L10n.tr('camera_status_no_storage'));
        return false;
      }
      // 存储读得到才算“可用”；`connected` 只表示 PTP 会话建立（ISSUE-003）。
      this.usable = true;

      // ---- Phase 1: traverse directories (2 getObjectHandles per level) ----
      this.statusText = L10n.tr('camera_status_walking_dirs');
      this.formatFilterWorks = null; // re-detect for this connection

      let foundCount = 0;
      const allHandles = await this.collectPhotoHandles(storageIDs, 0xFFFFFFFF, 0,
        (count: number) => {
          foundCount += count;
          this.photoCount = foundCount;
        });
      const handles = allHandles;
      hilog.info(DOMAIN, TAG, `ObjectHandles total: ${allHandles.length}`);

      // ---- Phase 2a: metadata (reuse disk cache on quick scans) ----
      this.log.add(`开始加载 ${handles.length} 张照片元数据...`);
      this.scanProgress = 0;
      this.scanTotal = handles.length;
      this.scanPhaseText = L10n.tr('camera_phase_metadata');
      this.statusText = L10n.tr('camera_phase_loading_metadata');

      // Initialize thumbnail cache if enabled
      if (this.cameraIdentity) {
        this.thumbCache.init(this.filesDir, this.cameraIdentity);
        if (this.cachingEnabled) {
          await this.thumbCache.loadManifest();
          this.log.add('缩略图缓存已加载');
        }
        hilog.info(DOMAIN, TAG, '[CACHE] init done en=%{public}s id=%{public}s', this.cachingEnabled.toString(), this.cameraIdentity);
      }

      // 快速扫描的增量路径：handle 集合是相机的真话，缓存里有同 handle 的条目就直接复用，
      // 只对新增照片调 GetObjectInfo。抽样校验防止卡被格式化后 handle 被重用（ISSUE-009）。
      const cachedMeta = this.prepareMetadataReuse(quickMode);
      const canReuse = cachedMeta.size > 0 && await this.verifyMetadataSample(cachedMeta, handles);

      const photoList: PhotoEntry[] = [];
      const validCacheKeys: Set<string> = new Set();
      // 缓存为空时才需要渐进上屏：已有缓存快照时画廊本来就有内容（ISSUE-008）。
      const progressive = this.photos.length === 0;
      let reused = 0;
      let fetched = 0;
      let infoFailed = 0;

      for (let i = 0; i < handles.length; i++) {
        const h = handles[i];
        let entry: PhotoEntry | null = null;
        const cached = canReuse ? cachedMeta.get(h) : undefined;
        if (cached) {
          entry = cached;
          reused++;
        } else {
          try {
            const info = await this.session.getObjectInfo(h);
            if (info) {
              entry = {
                handle: h,
                filename: info.filename,
                size: info.objectCompressedSize,
                objectFormat: info.objectFormat,
                captureDate: info.captureDate || '',
                modificationDate: info.modificationDate || '',
                imagePixWidth: info.imagePixWidth || 0,
                imagePixHeight: info.imagePixHeight || 0,
                storageId: info.storageId || 0
              };
              fetched++;
            }
          } catch (err) {
            // 单张失败（相机可能在扫描途中删了文件）不打断整轮扫描。
            infoFailed++;
            if (infoFailed <= 3) {
              this.log.add(`元数据失败 handle=0x${h.toString(16)}: ${(err as Error).message}`);
            }
          }
        }
        if (entry) {
          photoList.push(entry);
          validCacheKeys.add(`${entry.filename}::${entry.size}`);
        }
        this.scanProgress = i + 1;

        if (progressive && (i + 1) % METADATA_BATCH_SIZE === 0 && photoList.length > 0) {
          this.publishPhotoList(photoList);
        }
      }

      this.publishPhotoList(photoList);

      // cleanupStaleMemoryCache: remove entries for deleted photos
      const validHandles = new Set<number>();
      for (const p of photoList) {
        validHandles.add(p.handle);
      }
      this.cleanupStaleMemoryCache(validHandles);

      // Persist metadata cache for next quick scan
      if (this.cameraIdentity && this.cachingEnabled) {
        this.saveMetadataCache(photoList);
      }

      this.log.add(`元数据获取完成: ${photoList.length} 张` +
        `（复用 ${reused} / 读取 ${fetched} / 失败 ${infoFailed}）`);

      // ---- Phase 2b: load thumbnails, row by row ----
      this.scanPhaseText = L10n.tr('camera_phase_thumbnails');
      this.statusText = L10n.tr('camera_phase_loading_thumbnails');
      await this.loadThumbnailsRowByRow(validCacheKeys);

      // 缩略图阶段才拿到的方向/尺寸回写元数据缓存：下次快速扫描连 16KB EXIF 头都不用读。
      if (this.cameraIdentity && this.cachingEnabled) {
        this.saveMetadataCache(this.photos);
      }

      // Compute scan stats for UI display
      {
        const total = this.photoCount;
        this.scanStatsText = L10n.tr('camera_scan_stats',
          L10n.plural('photo_count', total, total));
        this.log.add(this.scanStatsText);
      }

      this.log.add('缩略图加载完成');

      this.statusText = L10n.tr('camera_status_photo_count',
        L10n.plural('photo_count', this.photoCount, this.photoCount));
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `loadPhotos error: ${JSON.stringify(err)}`);
      // 相机休眠/线松动后 USB pipe 已经死了。不主动关会话的话，下一次扫描
      // 仍会走进 sameDevice 分支复用这个死 pipe，表现为反复“USB 通信失败”。
      if (err instanceof PtpError && err.code === PTP_ERR_USB) {
        this.connected = false;
        this.usable = false;
        await this.session.closeSessionAndPipe();
      }
      // 不清空 photos / photoCount：失败时保留上一轮内容（ISSUE-005）。
      this.reportScanFailure(this.describeScanError(err as Object));
      this.scanStatsText = '';
      return false;
    } finally {
      this.scanProgress = 0;
      this.scanTotal = 0;
    }
  }

  /** 排序（拍摄时间 → 修改时间 → handle 降序）后整体替换 photos，触发画廊刷新。 */
  private publishPhotoList(photoList: PhotoEntry[]): void {
    photoList.sort((a: PhotoEntry, b: PhotoEntry): number => {
      const da = a.captureDate || '';
      const db = b.captureDate || '';
      if (da !== db) return db.localeCompare(da);
      const ma = a.modificationDate || '';
      const mb = b.modificationDate || '';
      if (ma !== mb) return mb.localeCompare(ma);
      return b.handle - a.handle;
    });
    this.photos = photoList.slice();
    this.photoCount = this.photos.length;
    this.photosVersion++;
  }

  /**
   * 快速扫描可复用的元数据。返回空 Map 表示这次必须全量读取。
   * `loadMetadataCache()` 会顺带填充 `metadataCacheByHandle` 与写入时间。
   */
  private prepareMetadataReuse(quickMode: boolean): Map<number, PhotoEntry> {
    if (!quickMode || !this.cachingEnabled || !this.cameraIdentity) {
      return new Map<number, PhotoEntry>();
    }
    const entries = this.loadMetadataCache();
    if (!entries || entries.length === 0) {
      return new Map<number, PhotoEntry>();
    }
    if (this.metadataCacheSavedAt <= 0 ||
        Date.now() - this.metadataCacheSavedAt > METADATA_REUSE_MAX_AGE_MS) {
      this.log.add('元数据缓存超过有效期，本次全量重读');
      return new Map<number, PhotoEntry>();
    }
    return this.metadataCacheByHandle;
  }

  /**
   * 抽样校验缓存与相机是否仍然一致。
   *
   * 只靠 handle 复用有风险：存储卡被格式化后，新文件可能拿到与旧缓存相同的 handle，
   * 于是界面会显示错误的文件名/日期，甚至会下载到“张冠李戴”的文件。
   * 这里对均匀抽取的少量 handle 重新调 GetObjectInfo 比对文件名与体积，
   * 不一致就放弃复用。代价约 8 × 31ms，远小于全量 39s。
   */
  private async verifyMetadataSample(
    cachedMeta: Map<number, PhotoEntry>,
    handles: number[]
  ): Promise<boolean> {
    if (cachedMeta.size === 0 || handles.length === 0) {
      return false;
    }
    const probed: number[] = [];
    const step = Math.max(1, Math.floor(handles.length / METADATA_REUSE_PROBE));
    for (let i = 0; i < handles.length && probed.length < METADATA_REUSE_PROBE; i += step) {
      if (cachedMeta.has(handles[i])) {
        probed.push(handles[i]);
      }
    }
    if (probed.length === 0) {
      return false;
    }
    for (const h of probed) {
      const cached = cachedMeta.get(h)!;
      try {
        const info = await this.session.getObjectInfo(h);
        if (!info) {
          return false;
        }
        if (info.filename !== cached.filename ||
            info.objectCompressedSize !== cached.size) {
          this.log.add(`元数据缓存与相机不一致(handle=0x${h.toString(16)})，本次全量重读`);
          return false;
        }
      } catch (_e) {
        return false;
      }
    }
    this.log.add(`元数据复用校验通过: ${probed.length} 个样本一致，复用 ${cachedMeta.size} 条`);
    return true;
  }

  /**
   * Phase 2b: load thumbnails row by row (row width ≈ column count).
   * After each row is fully loaded, bump thumbnailVersion so GalleryPage
   * re-evaluates row completeness and shows the row all at once.
   */
  /**
   * Phase 2b: 缩略图流水线。
   *
   * 旧实现每行 4 张 `await Promise.all`：USB 串行，行内 3 张要等 200ms 轮询，
   * 行末还要等 4 张全部解码完才放下一行，USB 与解码互相卡。
   * 现在改成固定并发的工作池：取图（USB，调度器串行）与解码（TaskPool）重叠，
   * 每行在自己的 4 张都完成后才递增 `thumbnailVersion`，所以视觉上仍是整行出现。
   */
  private async loadThumbnailsRowByRow(
    validCacheKeys: Set<string>
  ): Promise<void> {
    const photos = this.photos;
    if (photos.length === 0) return;

    const rowWidth = 4;
    const rowCount = Math.ceil(photos.length / rowWidth);
    const rowRemaining: number[] = [];
    for (let r = 0; r < rowCount; r++) {
      rowRemaining.push(0);
    }

    // 先判定每张的路径，worker 里不再重复查缓存。
    const skip: boolean[] = [];
    const cachedEntries: Array<CacheEntry | null> = [];
    let cacheHits = 0;
    let usbLoads = 0;
    for (let i = 0; i < photos.length; i++) {
      const photo = photos[i];
      skip.push(false);
      cachedEntries.push(null);
      // 两个集合要同时命中才算真的“已有图”，否则会漏加载、单元格永远停在占位符。
      if (this.thumbnailLoadedSet.has(photo.handle)
        && this.thumbnailPixelMapMap.has(photo.handle)) {
        skip[i] = true;
        continue;
      }
      const key = `${photo.filename}::${photo.size}`;
      const modDate = photo.modificationDate || '';
      if (this.cachingEnabled && key) {
        const cachedEntry = this.thumbCache.findCached(key, modDate);
        if (cachedEntry) {
          cachedEntries[i] = cachedEntry;
          cacheHits++;
          rowRemaining[Math.floor(i / rowWidth)]++;
          continue;
        }
      }
      usbLoads++;
      rowRemaining[Math.floor(i / rowWidth)]++;
    }

    this.thumbDecoded = 0;
    this.scanProgress = 0;
    this.scanTotal = photos.length;
    this.lastDecodedHandle = -1;

    let completed = 0;
    let lastProgressAt = Date.now();
    const bumpProgress = (): void => {
      const now = Date.now();
      if (now - lastProgressAt >= 100 || completed >= photos.length) {
        this.scanProgress = completed;
        lastProgressAt = now;
      }
    };

    // 8 个 worker 会让第 N+1 行先于第 N 行完成；这里按行号顺序发布，
    // 只把「从最上面开始连续完成的行」一次性刷给画廊，视觉上仍然是自上而下整行出现。
    const rowDone: boolean[] = [];
    for (let r = 0; r < rowCount; r++) {
      rowDone.push(rowRemaining[r] === 0);
    }
    let publishedRow = 0;
    const publishCompletedRows = (): void => {
      let advanced = false;
      while (publishedRow < rowCount && rowDone[publishedRow]) {
        publishedRow++;
        advanced = true;
      }
      if (!advanced) return;
      this.thumbnailVersion++;
      this.thumbCache.maybePersist();
      // 预览器刷新用：取刚发布区域最后一行的最后一个已有图 handle。
      const rowStart = (publishedRow - 1) * rowWidth;
      const rowEnd = Math.min(rowStart + rowWidth, photos.length);
      for (let j = rowEnd - 1; j >= rowStart; j--) {
        if (this.thumbnailLoadedSet.has(photos[j].handle)) {
          this.lastDecodedHandle = photos[j].handle;
          break;
        }
      }
    };

    const finishOne = (index: number): void => {
      completed++;
      const row = Math.floor(index / rowWidth);
      rowRemaining[row]--;
      if (rowRemaining[row] === 0) {
        rowDone[row] = true;
        publishCompletedRows();
      }
      bumpProgress();
    };

    let next = 0;
    const worker = async (): Promise<void> => {
      while (this.connected) {
        const i = next++;
        if (i >= photos.length) return;
        if (skip[i]) {
          completed++;
          bumpProgress();
          continue;
        }
        const photo = photos[i];
        const cached = cachedEntries[i];
        try {
          if (cached) {
            await this.loadCachedThumbnail(photo.handle, cached);
          } else {
            await this.loadSingleThumbnail(photo, `${photo.filename}::${photo.size}`,
              photo.modificationDate || '');
          }
        } finally {
          finishOne(i);
        }
      }
    };

    const workerCount = Math.min(THUMB_PIPELINE, photos.length);
    const workers: Promise<void>[] = [];
    for (let w = 0; w < workerCount; w++) {
      workers.push(worker());
    }
    await Promise.all(workers);

    // 断连时 worker 会提前退出，不要把进度条补满成“已完成”。
    this.scanProgress = this.connected ? photos.length : completed;

    this.log.add(`缩略图阶段: 磁盘命中 ${cacheHits} / USB 读取 ${usbLoads} / 解码成功 ${this.thumbDecoded}`);

    // Phase 2b complete: final cleanup
    if (this.cachingEnabled) {
      await this.thumbCache.flush();
      if (validCacheKeys.size > 0) {
        const purged = await this.thumbCache.purgeStale(validCacheKeys);
        if (purged > 0) {
          this.log.add(`缓存清理: 移除了 ${purged} 个过期条目`);
        }
      }
      this.thumbCache.close();
    }
  }

  /**
   * Load a single photo's thumbnail via USB: getThumb + EXIF + decode + cache save.
   *
   * 三处省时（ISSUE-007）：
   * 1. 方向已缓存在 metadata_cache.json 时不再读 16KB EXIF 头；
   * 2. 原始尺寸优先用 PTP ObjectInfo 的 imagePixWidth/Height（NEF 也拿得到），
   *    只有 PTP 给 0 时才回退到 EXIF；
   * 3. 只落一次盘：原始 JPEG + manifest 里的变换参数，解码时再裁剪，
   *    不再“先存原始、解码后再编码覆盖同一文件”。
   */
  private async loadSingleThumbnail(
    photo: PhotoEntry,
    cacheKey: string,
    modDate: string
  ): Promise<void> {
    try {
      const h = photo.handle;
      const thumbData = await this.session.getThumb(h);
      if (!thumbData || thumbData.length === 0) {
        this.log.add(`[NO_THUMB] handle=0x${h.toString(16)} ${photo.filename}`);
        return;
      }

      // 方向：元数据缓存 → 本次扫描已解析 → 读 EXIF 头
      let orient: OrientationTransform | null = null;
      if (photo.exifRotate !== undefined && photo.exifFlipH !== undefined &&
          photo.exifFlipV !== undefined) {
        orient = new OrientationTransform(photo.exifRotate, photo.exifFlipH, photo.exifFlipV);
      } else if (this.orientationMap.has(h)) {
        orient = this.orientationMap.get(h)!;
      }

      // 原始尺寸：PTP 元数据优先（NEF 的 EXIF 尺寸在 SubIFD，16KB 窗口读不到）
      let dim: OrientedSize | null = null;
      if (photo.imagePixWidth !== undefined && photo.imagePixWidth > 0 &&
          photo.imagePixHeight !== undefined && photo.imagePixHeight > 0) {
        dim = new OrientedSize(photo.imagePixWidth, photo.imagePixHeight);
      }

      if (orient === null || dim === null) {
        let partial: Uint8Array | null = null;
        try {
          partial = await this.session.getPartialObject(h, 0, 16384);
        } catch (err) {
          // 相机不支持 GetPartialObject 时不该让整张缩略图失败
          this.log.add(`[EXIF] handle=0x${h.toString(16)} 读取失败: ${(err as Error).message}`);
        }
        if (partial && partial.length > 0) {
          try {
            if (orient === null) {
              orient = await this.getOrientation(h, partial.buffer as ArrayBuffer);
            }
            if (dim === null) {
              dim = CameraService.parseExifDims(partial.buffer as ArrayBuffer);
            }
          } catch (_e) { /* best effort */ }
        }
      }

      if (orient !== null) {
        this.preloadedOrientations.set(h, orient);
        // 回写到 PhotoEntry，扫描结束时随 metadata_cache.json 落盘
        photo.exifRotate = orient.rotate;
        photo.exifFlipH = orient.flipH;
        photo.exifFlipV = orient.flipV;
      }
      if (dim !== null) {
        this.exifOrigDims.set(h, dim);
      }

      await this.decodeThumbnail(h, thumbData, cacheKey, modDate);
    } catch (err) {
      this.log.add(`缩略图加载失败: ${photo.filename} ${(err as Error).message}`);
    }
  }

  /** Deploy cached metadata + thumbnails for instant gallery rendering (Phase 0). */
  async deployCacheSnapshot(): Promise<void> {
    const entries = this.loadMetadataCache();
    if (!entries || entries.length === 0) return;

    // Sort cached entries newest-first (same as Phase 2a sorting)
    entries.sort((a: PhotoEntry, b: PhotoEntry): number => {
      const da = a.captureDate || '';
      const db = b.captureDate || '';
      if (da !== db) return db.localeCompare(da);
      const ma = a.modificationDate || '';
      const mb = b.modificationDate || '';
      if (ma !== mb) return mb.localeCompare(ma);
      return b.handle - a.handle;
    });

    // Populate photos (triggers gallery to show dates + placeholders)
    this.photos = entries;
    this.photoCount = entries.length;
    this.photosVersion++;

    // Load all cached thumbnails from disk
    const cacheLoads: Promise<void>[] = [];
    for (const entry of entries) {
      const key = `${entry.filename}::${entry.size}`;
      const modDate = entry.modificationDate || '';
      const cached = this.thumbCache.findCached(key, modDate);
      if (cached) {
        cacheLoads.push(this.loadCachedThumbnail(entry.handle, cached));
      }
    }

    if (cacheLoads.length > 0) {
      await Promise.all(cacheLoads);
    }
    this.thumbnailVersion++;
    this.log.add(`缓存快照: ${entries.length} 张照片, ${cacheLoads.length} 个缩略图`);
  }

  /** Load cached PhotoEntry[] from metadata_cache.json */
  private loadMetadataCache(): PhotoEntry[] | null {
    if (!this.cameraIdentity) return null;
    const path = this.thumbCache.getCacheDir() + '/metadata_cache.json';
    const text = AtomicFile.readText(path);
    if (text === null || text === '') return null;
    try {
      const raw: Record<string, Object> = JSON.parse(text);
      const rawEntries = raw['entries'] as PhotoEntry[] | undefined;
      const savedAt = raw['savedAt'] as number;
      this.metadataCacheSavedAt = typeof savedAt === 'number' ? savedAt : 0;
      this.metadataCacheByHandle = new Map<number, PhotoEntry>();
      if (rawEntries) {
        for (const entry of rawEntries) {
          this.metadataCacheByHandle.set(entry.handle, entry);
        }
      }
      if (rawEntries && rawEntries.length > 0) {
        this.log.add(`元数据缓存加载: ${rawEntries.length} 条`);
        return rawEntries;
      }
    } catch (_e) {
      this.log.add('元数据缓存损坏，忽略');
    }
    return null;
  }

  /** Persist PhotoEntry[] to metadata_cache.json */
  private saveMetadataCache(entries: PhotoEntry[]): void {
    if (!this.cameraIdentity) return;
    try {
      fileIo.mkdirSync(this.thumbCache.getCacheDir(), true);
    } catch (_e) { /* best effort */ }
    try {
      const path = this.thumbCache.getCacheDir() + '/metadata_cache.json';
      const text = JSON.stringify({ version: 2, savedAt: Date.now(), entries: entries });
      AtomicFile.writeText(path, text);
      // 同步内存索引，让同一进程内下一次快速扫描也能复用。
      this.metadataCacheByHandle = new Map<number, PhotoEntry>();
      for (const entry of entries) {
        this.metadataCacheByHandle.set(entry.handle, entry);
      }
      this.metadataCacheSavedAt = Date.now();
      this.log.add(`元数据缓存已保存: ${entries.length} 条`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'saveMetadataCache failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Clean up stale in-memory caches for handles no longer in the photo list. */
  private cleanupStaleMemoryCache(validHandles: Set<number>): void {
    const stale: number[] = [];
    this.thumbnailPixelMapMap.forEach((_pm: image.PixelMap, h: number) => {
      if (!validHandles.has(h)) {
        stale.push(h);
      }
    });
    for (const h of stale) {
      const pm = this.thumbnailPixelMapMap.get(h);
      if (pm) { try { pm.release(); } catch (_e) { /* best effort */ } }
      this.thumbnailPixelMapMap.delete(h);
      this.thumbnailLoadedSet.delete(h);
      this.preloadedOrientations.delete(h);
      this.exifOrigDims.delete(h);
      this.orientationMap.delete(h);
      this.orientedDisplaySizes.delete(h);
    }
    if (stale.length > 0) {
      this.log.add(`内存缓存清理: 移除了 ${stale.length} 个失效条目`);
    }
  }

  private async decodeThumbnail(
    handle: number,
    data: Uint8Array,
    cacheKey?: string,
    modDate?: string
  ): Promise<void> {
    try {
      const orient = this.preloadedOrientations.get(handle);
      const exifDim = this.exifOrigDims.get(handle);

      // 1) Persist the raw JPEG together with the EXIF transform. 缓存里不再
      //    存“纠正后重新编码”的第二份文件：解码时本来就要裁剪，缓存命中时
      //    按 manifest 里的 rotate/flip/origWidth/origHeight 再裁一次即可。
      //    这样就少了每张一次的 ImagePacker 编码 + 覆盖写（ISSUE-007）。
      if (this.cachingEnabled && cacheKey && modDate) {
        await this.thumbCache.saveRawThumbnail(cacheKey, modDate, data, handle,
          orient?.rotate ?? 0, orient?.flipH ?? false, orient?.flipV ?? false,
          exifDim?.w, exifDim?.h);
      }

      // 为 TaskPool 复制一份 ArrayBuffer（源数据不会被缓存，直接转移所有权）
      const decodeBuf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);

      const task = new taskpool.Task(
        decodeThumbnailTask,
        decodeBuf,
        orient?.rotate ?? 0,
        orient?.flipH ?? false,
        orient?.flipV ?? false,
        exifDim?.w ?? 0,
        exifDim?.h ?? 0
      );

      try {
        const pixelMap = await taskpool.execute(task) as image.PixelMap;
        const info = await pixelMap.getImageInfo();
        this.thumbnailPixelMapMap.set(handle, pixelMap);
        this.orientedDisplaySizes.set(handle, new OrientedSize(info.size.width, info.size.height));
        this.thumbnailLoadedSet.add(handle);
        // Notify PhotoViewer of fresh thumbnail
        this.lastDecodedHandle = handle;
        this.thumbDecoded++;
        // 逐张日志只进 hilog：1288 张写进 AppLog 会把有用的摘要顶出 500 条环形缓冲。
        hilog.info(DOMAIN, TAG, '[TASKPOOL_THUMB] handle=0x%{public}s done %{public}dx%{public}d',
          handle.toString(16), info.size.width, info.size.height);
      } catch (err) {
        hilog.error(DOMAIN, TAG, `[TASKPOOL_THUMB] FAIL handle=0x%{public}s err=%{public}s`,
          handle.toString(16), JSON.stringify(err));
        this.log.add(`缩略图解码失败(worker): handle=0x${handle.toString(16)}`);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `[THUMB_SUBMIT] FAIL handle=0x%{public}s err=%{public}s`,
        handle.toString(16), JSON.stringify(err));
      this.log.add(`缩略图提交失败: handle=0x${handle.toString(16)}`);
    }
  }

  // (redecodeThumbnailWithOrientation removed — orientation is now applied
  // at initial thumbnail decode via preloadedOrientations)

  /**
   * 前台取一张原图并放进缓存。
   *
   * `preloadingSet` 用来阻止同一张被邻近预加载重复下载；调度器会把这次
   * `getObject` 排到 PRELOAD/SCAN 前面，用户不用等整条扫描队列。
   */
  private async fetchFullPhotoForeground(handle: number, startedAt: number,
    waited: boolean, priority: PtpPriority): Promise<Uint8Array | null> {
    this.preloadingSet.add(handle);
    try {
      const data = await this.session.getObject(handle, priority);
      if (!data || data.length === 0) return null;
      const t1 = Date.now();
      const sizeMB = (data.length / 1048576).toFixed(1);
      const usbSec = ((t1 - startedAt) / 1000).toFixed(1);
      this.log.add(`USB下载${waited ? '(等超时)' : ''}: ${sizeMB}MB ${usbSec}s`);
      this.addToCache(handle, data);
      return data;
    } finally {
      this.preloadingSet.delete(handle);
    }
  }

  async loadFullPhoto(handle: number,
    priority: PtpPriority = PtpPriority.FOREGROUND): Promise<DecodedPhotoResult | null> {
    try {
      const t0 = Date.now();
      let data: Uint8Array | null = null;
      let hit = false;

      if (this.compressedCache.has(handle)) {
        data = this.compressedCache.get(handle)!;
        hit = true;
      } else if (this.preloadingSet.has(handle)) {
        // 邻居预加载正在传这张：等完成通知，不再 200ms 轮询。
        await this.waitForPreload(handle, 5000);
        if (this.compressedCache.has(handle)) {
          data = this.compressedCache.get(handle)!;
          hit = true;
        } else {
          data = await this.fetchFullPhotoForeground(handle, t0, true, priority);
          if (!data) return null;
        }
      } else {
        data = await this.fetchFullPhotoForeground(handle, t0, false, priority);
        if (!data) return null;
      }

      // 取图结束（含等待邻近预加载的时间）
      const tData = Date.now();

      // 读取 EXIF 方向（主线程读取元数据，很快）
      const orient = await this.getPhotoOrientation(handle, data.buffer as ArrayBuffer);
      const tOrient = Date.now();

      // 为 TaskPool 克隆一份 ArrayBuffer，主线程保留原始数据用于缓存
      const decodeBuf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const tCopy = Date.now();

      const task = new taskpool.Task(
        decodeFullPhotoTask,
        decodeBuf,
        orient.rotate,
        orient.flipH,
        orient.flipV,
        FULL_DECODE_MAX_EDGE
      );

      let pixelMap: image.PixelMap;
      try {
        pixelMap = await taskpool.execute(task) as image.PixelMap;
      } catch (err) {
        this.log.add(`全尺寸解码失败(worker): handle=0x${handle.toString(16)}`);
        return null;
      }

      const t2 = Date.now();
      const tag = hit ? '缓存命中' : '下载完成';
      // 分开记「取图 / 方向 / 拷贝 / 解码」四段：真机上这几段里哪一段占大头，
      // 直接决定「第一次打开照片卡一下」该从哪下手（USB 串行管道 vs 主线程拷贝）。
      this.log.add(`${tag}: ${((t2 - t0) / 1000).toFixed(1)}s` +
        ` (取图 ${tData - t0}ms / 方向 ${tOrient - tData}ms` +
        ` / 拷贝 ${tCopy - tOrient}ms / 解码 ${t2 - tCopy}ms)`);

      // 读取旋转后的实际尺寸
      const info = await pixelMap.getImageInfo();
      const displayW = info.size.width;
      const displayH = info.size.height;
      this.orientedDisplaySizes.set(handle, new OrientedSize(displayW, displayH));

      return new DecodedPhotoResult(pixelMap, displayW, displayH);
    } catch (err) {
      this.log.add(`全尺寸加载失败: handle=0x${handle.toString(16)}`);
      return null;
    }
  }

  /**
   * Read EXIF orientation from full photo data. Unlike thumbnails, full-resolution
   * camera files (JPEG/RAW) contain EXIF metadata with the Orientation tag.
   * Falls back to cached orientation (from a prior thumbnail decode) if available.
   */
  private async getPhotoOrientation(handle: number, data: ArrayBuffer): Promise<OrientationTransform> {
    // Check cache first (might have been populated by a prior full decode)
    if (this.orientationMap.has(handle)) {
      const cached = this.orientationMap.get(handle)!;
      if (cached.rotate !== 0 || cached.flipH || cached.flipV) {
        return cached;
      }
    }
    try {
      const imgSrc = image.createImageSource(data);
      const orientation = await imgSrc.getImageProperty(image.PropertyKey.ORIENTATION);
      imgSrc.release();
      hilog.info(DOMAIN, TAG, `[ORIENT] full res handle=0x%{public}s raw="%{public}s"`,
        handle.toString(16), orientation);
      const result = CameraService.mapExifOrientation(orientation);
      this.orientationMap.set(handle, result);
      return result;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `[ORIENT] full res FAIL handle=0x%{public}s err=%{public}s`,
        handle.toString(16), JSON.stringify(err));
      // Fallback: use cached value or default
      const result = new OrientationTransform(0, false, false);
      this.orientationMap.set(handle, result);
      return result;
    }
  }

  private addToCache(handle: number, data: Uint8Array): void {
    if (this.compressedCache.has(handle)) return;
    // Evict if needed
    while (this.cacheTotalBytes + data.length > this.cacheMaxBytes && this.compressedCache.size > 0) {
      this.evictFurthest();
    }
    this.compressedCache.set(handle, data);
    this.cacheTotalBytes += data.length;
  }

  private evictFurthest(): void {
    // Map each cached handle to its position in the viewer's photo list.
    // (Comparing handles directly against a list index evicted the wrong photo.)
    const order: Map<number, number> = new Map();
    for (let i = 0; i < this.preloadPhotos.length; i++) {
      order.set(this.preloadPhotos[i].handle, i);
    }
    let furthestHandle = -1;
    let maxDist = -1;
    this.compressedCache.forEach((_v: Uint8Array, k: number) => {
      const idx = order.get(k);
      const dist = idx === undefined ? Number.MAX_SAFE_INTEGER : Math.abs(idx - this.detailIndex);
      if (dist > maxDist) { maxDist = dist; furthestHandle = k; }
    });
    if (furthestHandle >= 0) {
      const removed = this.compressedCache.get(furthestHandle);
      if (removed) {
        this.cacheTotalBytes -= removed.length;
        this.compressedCache.delete(furthestHandle);
      }
    }
  }

  private preloadPhotos: PhotoEntry[] = [];

  setDetailIndex(idx: number, photos: PhotoEntry[]): void {
    if (this.detailIndex === idx) return;
    this.prevDetailIndex = this.detailIndex;
    this.detailIndex = idx;
    this.preloadPhotos = photos;
    this.schedulePreload(photos.length);
  }

  private preloadTimer: number = -1;

  private schedulePreload(total: number): void {
    if (this.preloadTimer >= 0) clearTimeout(this.preloadTimer);
    this.preloadTimer = setTimeout(() => { this.preloadAdjacent(total); }, 200);
  }

  private detectSwipeDirection(): number {
    if (this.prevDetailIndex < 0) return 1; // initial, assume right
    return this.detailIndex - this.prevDetailIndex;
  }

  private async preloadAdjacent(total: number): Promise<void> {
    if (this.preloading) return;
    // 预览器打开时整体让路：它自己的队列会按需取图，两边同时下载只会
    // 在串行的 USB 管道上互相插队，把「正在看的这张」拖慢。
    if (this.neighborPreloadSuspended) return;
    this.preloading = true;

    const direction = this.detectSwipeDirection();
    // Build priority queue: photos ordered by distance from current, biased by direction
    const queue: number[] = [];
    for (let d = 1; d <= this.preloadRadius; d++) {
      const ahead = this.detailIndex + d * direction;
      const behind = this.detailIndex - d * direction;
      if (ahead >= 0 && ahead < total) queue.push(ahead);
      if (behind >= 0 && behind < total) queue.push(behind);
    }

    for (const qi of queue) {
      if (!this.preloading) break;
      if (this.neighborPreloadSuspended) break;
      const photo = this.preloadPhotos[qi];
      if (!photo) continue;
      if (this.compressedCache.has(photo.handle)) continue;
      if (this.preloadingSet.has(photo.handle)) continue;
      this.preloadingSet.add(photo.handle);
      let loaded = false;
      try {
        // PRELOAD 低于前台取图，但高于扫描：用户在看的那张永远先走。
        const data = await this.session.getObject(photo.handle, PtpPriority.PRELOAD);
        if (data && data.length > 0) {
          this.addToCache(photo.handle, data);
          loaded = true;
          const sizeMB = (data.length / 1048576).toFixed(1);
          this.log.add(`预加载[${qi}]: ${sizeMB}MB (缓存${this.compressedCache.size}张/${(this.cacheTotalBytes/1048576).toFixed(0)}MB)`);
        }
      } catch (_e) {
        // preload failure is non-critical
      } finally {
        this.preloadingSet.delete(photo.handle);
        this.notifyPreloadWaiters(photo.handle, loaded);
      }
    }
    this.preloading = false;
  }

  /**
   * 等某张原图的预加载完成。超时返回 false，由调用方前台直取。
   * 以前这里是 25 次 200ms 轮询；现在由 `notifyPreloadWaiters` 立即唤醒。
   */
  private waitForPreload(handle: number, timeoutMs: number): Promise<boolean> {
    if (this.compressedCache.has(handle)) return Promise.resolve(true);
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      let settled = false;
      let timer: number = -1;
      const finish = (ok: boolean): void => {
        if (settled) return;
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        const waiters = this.preloadWaiters.get(handle);
        if (waiters) {
          const idx = waiters.indexOf(finish);
          if (idx >= 0) waiters.splice(idx, 1);
          if (waiters.length === 0) this.preloadWaiters.delete(handle);
        }
        resolve(ok);
      };
      timer = setTimeout(() => { finish(this.compressedCache.has(handle)); }, timeoutMs);
      let waiters = this.preloadWaiters.get(handle);
      if (!waiters) {
        waiters = [];
        this.preloadWaiters.set(handle, waiters);
      }
      waiters.push(finish);
    });
  }

  /** 唤醒所有等这张照片的调用方。 */
  private notifyPreloadWaiters(handle: number, ok: boolean): void {
    const waiters = this.preloadWaiters.get(handle);
    if (!waiters) return;
    this.preloadWaiters.delete(handle);
    for (const cb of waiters) {
      cb(ok);
    }
  }

  cancelPreload(): void {
    if (this.preloadTimer >= 0) {
      clearTimeout(this.preloadTimer);
      this.preloadTimer = -1;
    }
    this.preloading = false;
    // 刻意不清 `preloadingSet`：里面可能有正在传的 handle，清掉会让别的路径
    // 误以为它没在传，从而在串行的 USB 管道上再开一个并发传输。
    // 循环自己会在每张结束后 delete。
  }

  /**
   * 挂起邻近照片的字节预加载（预览器打开时调用）。
   * 只阻止「开始新的下载」，已经在传的那一张会正常结束，不会打断 USB 事务。
   */
  suspendNeighborPreload(): void {
    this.neighborPreloadSuspended = true;
    if (this.preloadTimer >= 0) {
      clearTimeout(this.preloadTimer);
      this.preloadTimer = -1;
    }
  }

  /** 恢复邻近预加载（预览器关闭时调用）。 */
  resumeNeighborPreload(): void {
    this.neighborPreloadSuspended = false;
    if (this.preloadPhotos.length > 0) {
      this.schedulePreload(this.preloadPhotos.length);
    }
  }

  clearFullCache(): void {
    // 清缓存时唤醒等待者，让它们改走前台直取，不要干等到 5s 超时。
    const waiting: number[] = [];
    this.preloadWaiters.forEach((_v: Array<(ok: boolean) => void>, k: number) => waiting.push(k));
    for (const h of waiting) {
      this.notifyPreloadWaiters(h, false);
    }
    this.compressedCache.clear();
    this.preloadingSet.clear();
    this.cacheTotalBytes = 0;
    this.detailIndex = -1;
    this.prevDetailIndex = -1;
    this.preloadPhotos = [];
  }

  /**
   * 调试开关变化后调用：断开当前相机，让下一次「搜索相机」重新挑选传输实现。
   * 注意不要在这里改 `sessionIsMock`，否则 `syncSessionMode()` 会以为已经切换过
   * 而跳过真正的替换。
   */
  onMockCameraToggled(): void {
    if (this.connected) {
      this.disconnect().catch((_e: Error) => { /* best effort */ });
    }
  }

  /**
   * 按调试开关选择传输实现。真实 USB 与虚拟相机实现同一个 `PtpTransport`，
   * 上层扫描流程完全一致。
   */
  private syncSessionMode(): void {
    const wantMock = MockPtpDevice.isEnabled();
    if (wantMock === this.sessionIsMock) return;
    const previous: PtpTransport = this.session;
    if (this.connected) {
      previous.closeSessionAndPipe().catch((_e: Error) => { /* best effort */ });
      this.connected = false;
    }
    this.session = new PtpScheduler(wantMock ? new MockPtpSession() : new PtpSession());
    this.sessionIsMock = wantMock;
    this.log.add(wantMock ? '[Mock] 使用虚拟相机' : '[Mock] 使用真实 USB 相机');
  }

  async disconnect(): Promise<void> {
    await this.session.closeSessionAndPipe();
    this.connected = false;
    this.usable = false;
    this.lastScanError = '';
    this.cameraName = '';
    this.cameraIdentity = '';
    this.deviceManufacturer = '';
    this.deviceSerialNumber = '';
    this.deviceVersion = '';
    this.usbVidPid = '';
    this.usbSerialNumber = '';
    // Flush BEFORE clearing the flag — the old order made this branch dead and
    // silently dropped pending thumbnail writes on disconnect.
    if (this.cachingEnabled) {
      await this.thumbCache.flush();
    }
    this.cachingEnabled = false;
    this.cachingDialogRequired = false;
    this.pendingCamIdForDialog = '';
    this.pendingCamNameForDialog = '';
    this.pendingCachingPrompt = false;
    this.photoCount = 0;
    this.photos = [];
    this.thumbnailPixelMapMap.clear();
    this.thumbnailLoadedSet.clear();
    this.preloadedOrientations.clear();
    this.exifOrigDims.clear();
    this.orientationMap.clear();
    this.orientedDisplaySizes.clear();
    this.scanPhaseText = '';
    this.lastDecodedHandle = -1;
    this.metadataCacheByHandle.clear();
    this.metadataCacheSavedAt = 0;
    this.clearFullCache();
    this.thumbCache.close();
    this.statusText = L10n.tr('camera_status_disconnected');
    this.log.add('已断开连接');
  }

  /**
   * Build a unique, filesystem-safe camera identity string from PTP DeviceInfo.
   * Priority: serialNumber > model+manufacturer > USB vid/pid fallback.
   */
  private buildCameraIdentity(info: DeviceInfo, usbDevice: usbManager.USBDevice): string {
    const sanitize = (s: string): string => s.replace(/[^a-zA-Z0-9_.-]/g, '_').substring(0, 64);
    const manu = (info.manufacturer || '').trim();
    const model = (info.model || '').trim();
    const version = (info.deviceVersion || '').trim();

    // Priority 1: PTP serialNumber — unique per camera body
    const serial = (info.serialNumber || '').trim();
    if (serial) {
      return sanitize(`${manu}_${model}_${serial}`);
    }

    // Priority 2: USB serial number (from USB device descriptor)
    if (usbDevice.serial) {
      const usbSerial = usbDevice.serial.trim();
      if (usbSerial) {
        return sanitize(`${manu}_${model}_usb_${usbSerial}`);
      }
    }

    // Priority 3: model + version + vid + pid — identifies model/firmware
    const vid = usbDevice.vendorId.toString(16).padStart(4, '0');
    const pid = usbDevice.productId.toString(16).padStart(4, '0');
    if (manu || model) {
      return sanitize(`${manu}_${model}_${version}_${vid}_${pid}`);
    }

    // Last resort
    return `vid_${vid}_pid_${pid}`;
  }

  /**
   * Check caching preference for the current camera.
   * If the camera has never been seen, sets cachingDialogRequired=true.
   * If previously rejected (cachingEnabled=false), keeps it false.
   * If previously accepted, initializes the thumbnail cache.
   */
  /** 新相机还没问过「要不要缓存」：`scanForCamera()` 会先问再扫。 */
  private pendingCachingPrompt: boolean = false;

  /** 等用户点按钮的 resolver，`setCachingPreference()` 里唤醒。 */
  private pendingCachingResolve: ((enabled: boolean) => void) | null = null;

  private checkCachingState(): void {
    if (!this.cameraIdentity) {
      this.cachingEnabled = false;
      this.cachingDialogRequired = false;
      return;
    }
    const pref = this.cachePrefs.get(this.cameraIdentity);
    if (!pref) {
      // 新相机：**连上就问，问完再扫**。答案直接决定这轮扫描是否落盘缓存。
      // 早前是「先缓存、扫完再问」，图片多时弹窗会被拖到整轮扫描（元数据 + 全部缩略图，
      // 1288 张要好几分钟）之后才出现，用户早就不在看相机页了。
      this.pendingCamIdForDialog = this.cameraIdentity;
      this.pendingCamNameForDialog = this.cameraName;
      // 还没回答之前不知道要不要写缓存，别提前按“启用”处理。
      this.cachingEnabled = false;
      this.cachingDialogRequired = false;
      this.pendingCachingPrompt = true;
      this.log.add(`新相机 ${this.cameraName}，扫描前询问是否启用缓存`);
      return;
    }
    // 已登记过的相机每次连接都刷新 lastSeen / 名称，缓存管理页的“上次连接”才准确。
    this.cachePrefs.touch(this.cameraIdentity, this.cameraName);
    if (pref.cachingEnabled) {
      this.cachingEnabled = true;
      this.cachingDialogRequired = false;
      this.thumbCache.init(this.filesDir, this.cameraIdentity);
      this.log.add(`缓存已启用: ${this.cameraName}`);
    } else {
      this.cachingEnabled = false;
      this.cachingDialogRequired = false;
      this.log.add(`缓存已禁用(用户设置): ${this.cameraName}`);
    }
  }

  /**
   * 弹出「是否启用缩略图缓存」询问，并等用户选择。
   *
   * 由 `scanForCamera()` 在连接成功、还没开始扫的时候调用：`cachingDialogRequired`
   * 置 true 后 MainScreen 的 `@Monitor` 弹对话框，用户点按钮走
   * `setCachingPreference()`，在那里 resolve 本 Promise，扫描接着往下走。
   * 超时兜底：万一对话框没弹出来（页面未挂载等），不能让扫描永远卡住。
   */
  private askCachingPreference(): Promise<boolean> {
    this.pendingCamIdForDialog = this.cameraIdentity;
    this.pendingCamNameForDialog = this.cameraName;
    return new Promise<boolean>((resolve: (enabled: boolean) => void) => {
      this.pendingCachingResolve = resolve;
      this.cachingDialogRequired = true;
      setTimeout(() => {
        if (this.pendingCachingResolve !== resolve) return;
        this.pendingCachingResolve = null;
        this.pendingCachingPrompt = false;
        this.cachingDialogRequired = false;
        this.cachingEnabled = true;
        this.log.add('缓存询问超时（对话框未响应），本轮按启用缓存处理');
        resolve(true);
      }, CACHING_PROMPT_TIMEOUT_MS);
    });
  }

  /**
   * Called from MainScreen after the user responds to the caching dialog.
   * 回答“不启用”时要把可能已经写下的缩略图与元数据快照删掉。
   */
  async setCachingPreference(cameraId: string, enabled: boolean): Promise<void> {
    const camName = this.pendingCamNameForDialog !== ''
      ? this.pendingCamNameForDialog : this.cameraName;
    this.cachePrefs.set(cameraId, camName, enabled);
    this.cachingDialogRequired = false;
    this.cachingEnabled = enabled;
    this.pendingCachingPrompt = false;
    this.log.add(enabled ? `用户已启用缓存: ${this.cameraName}` : `用户拒绝缓存: ${this.cameraName}`);
    if (enabled) {
      // 扫描紧接着就要落盘缩略图，先按这台相机初始化缓存目录。
      this.thumbCache.init(this.filesDir, cameraId);
    } else {
      if (cameraId === this.cameraIdentity) {
        this.thumbCache.reset();
      }
      await ThumbnailCache.deleteCameraCache(this.filesDir, cameraId);
      this.log.add(`已删除相机缓存: ${cameraId}`);
    }
    this.pendingCamIdForDialog = '';
    this.pendingCamNameForDialog = '';
    // 唤醒 scanForCamera() 里等选择的 await：扫描在弹窗之前就暂停了，这里只放行，不重扫。
    const resolve = this.pendingCachingResolve;
    this.pendingCachingResolve = null;
    if (resolve !== null) resolve(enabled);
  }

  /**
   * Load a thumbnail from the disk-based ThumbnailCache.
   * Used instead of USB GetThumb when a valid cache entry exists.
   */
  private async loadCachedThumbnail(handle: number, entry: CacheEntry): Promise<void> {
    try {
      const filePath = this.thumbCache.getCacheDir() + '/' + entry.cacheFileName;
      const fileBuf: ArrayBuffer | null = await this.thumbCache.readFileToBuffer(filePath);
      if (!fileBuf) return;

      // A `corrected` entry already has rotate/flip/crop baked into the JPEG.
      // Anything else is the raw camera thumbnail: apply the recorded EXIF
      // transform now, otherwise rotated photos show sideways after a restart.
      const corrected = entry.corrected === true;
      const rotate = corrected ? 0 : (entry.exifRotate ?? 0);
      const flipH = corrected ? false : (entry.exifFlipH ?? false);
      const flipV = corrected ? false : (entry.exifFlipV ?? false);
      const origW = corrected ? 0 : (entry.origWidth ?? 0);
      const origH = corrected ? 0 : (entry.origHeight ?? 0);

      const decodeBuf = fileBuf.slice(0);
      const task = new taskpool.Task(decodeThumbnailTask, decodeBuf,
        rotate, flipH, flipV, origW, origH);
      const pixelMap = await taskpool.execute(task) as image.PixelMap;
      const info = await pixelMap.getImageInfo();
      this.orientedDisplaySizes.set(handle, new OrientedSize(info.size.width, info.size.height));
      this.thumbnailPixelMapMap.set(handle, pixelMap);
      this.thumbnailLoadedSet.add(handle);
      hilog.info(DOMAIN, TAG, '[CACHE_HIT] handle=0x%{public}s %{public}dx%{public}d',
        handle.toString(16), info.size.width, info.size.height);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[CACHE_HIT] FAIL handle=0x%{public}s err=%{public}s',
        handle.toString(16), JSON.stringify(err));
      this.log.add(`缓存加载失败: handle=0x${handle.toString(16)}`);
    }
  }

  formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }
}
