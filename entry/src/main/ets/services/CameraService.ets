import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { abilityAccessCtrl } from '@kit.AbilityKit';
import { wantAgent, type WantAgent } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import usbManager from '@ohos.usbManager';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { decodeThumbnailTask, decodeFullPhotoTask } from '../workers/ImageDecoder';
import { PtpSession, PtpPriority, PtpEndpointKind, setPtpLog, setPtpQuietOps, PtpError,
  PTP_ERR_USB, PTP_ERR_NOT_OPEN, type DeviceInfo, type ObjectInfo, type PtpEndpoint,
  type PtpTransport } from '../pages/PtpHost';
import { PtpScheduler } from './PtpScheduler';
import { WifiPtpSession } from './WifiPtpSession';
import { NsdScanner, type WifiCameraInfo } from './NsdScanner';
import { SubnetScanner } from './SubnetScanner';
import { BleScanner, BleCameraLink, type BleCameraDevice } from './BleScanner';
import { BleIdentityStore } from './BleIdentityStore';
import { WifiLinkStore } from './WifiLinkStore';
import { collectLocalNetworks, networkHint } from './LocalNetworks';
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
/** 全图预览解码的最长边：先快速出图，再后台解 3072 全尺寸。 */
const PREVIEW_DECODE_MAX_EDGE = 2048;

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
/**
 * 断点续扫的有效期。
 *
 * 只有「上一轮扫描没跑完」（`metadata_cache.json` 里 `complete=false`）才会进入续扫。
 * 超过这个时间就当缓存不可信，宁可全量重读。
 */
const RESUME_MAX_AGE_MS = 24 * 60 * 60 * 1000;
/** 交织扫描时每隔多少张把元数据落一次盘（断点续扫用）。 */
const SCAN_PERSIST_EVERY = 256;
/**
 * 交织扫描的批大小：每读 64 张的元数据就先把这一批的缩略图取回来。
 * 太小会让「发布相册列表」过频，太大又会让首屏多等。
 */
const SCAN_CHUNK = 64;
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
  /**
   * 当前会话是否走 Wi-Fi（PTP/IP）。USB 为 false。
   *
   * 无线模式下 `scanForCamera()` 不再枚举 USB 设备，直接复用已建立的
   * PTP/IP 会话；`syncSessionMode()` 也不会把 session 换回 USB。
   */
  @Trace wireless: boolean = false;
  /** 最近一次无线连接使用的主机（展示与重连用）。 */
  @Trace wifiHost: string = '';
  /** 最近一次无线连接使用的端口。 */
  @Trace wifiPort: number = 15740;
  /** 相机要求的配对验证码（0x952B）；空串表示相机不要求配对。 */
  @Trace pairingCode: string = '';
  /** 相机正在等待主机注册，UI 应显示配对核对入口而不是扫描结果。 */
  @Trace pairingRequired: boolean = false;
  /** 当前无线会话实例，配对命令要直接落在它上面（PtpScheduler 不转发）。 */
  private wifiSession: WifiPtpSession | null = null;
  /** mDNS 发现的局域网相机。 */
  @Trace wifiCameras: WifiCameraInfo[] = [];
  /** mDNS 浏览是否进行中。 */
  @Trace wifiScanning: boolean = false;
  /**
   * 蓝牙配对落定后正在自动找/连无线。
   *
   * 与 `wifiScanning`（用户手点的 mDNS 浏览）分开：这条是链路自己推进的，
   * UI 要能把「蓝牙好了，正在接无线」讲出来，而不是显示成两张互不相干的卡。
   */
  @Trace wifiAutoConnecting: boolean = false;
  /** 无线会话掉线后正在自动重连。 */
  @Trace wifiReconnecting: boolean = false;
  /** 扫不到相机时的原因（空串 = 网络没问题，是相机那边的事）。 */
  @Trace wifiHint: string = '';
  /** 本机网络一句话快照（地址 / SSID / 热点），诊断与 UI 提示都用。 */
  @Trace networkSummary: string = '';
  private nsdScanner: NsdScanner | null = null;
  private subnetScanner: SubnetScanner | null = null;
  private wifiScanTimer: number = -1;
  /**
   * mDNS 浏览窗口的结束回调。
   *
   * `scanWifiCameras()` 等的是「窗口到点」这个 promise；`stopWifiScan()` 提前
   * 清掉计时器时必须把这个 promise 也 resolve 掉，否则它永远不 settle，
   * `await scanWifiCameras()` 会把调用方（自动接续 / 重连）一起挂死。
   */
  private wifiScanResolve: (() => void) | null = null;
  private wifiReconnectTimer: number = -1;
  private wifiReconnectIndex: number = 0;
  /** 无线自动重连退避（与 BLE 同款节奏）。 */
  private readonly wifiBackoffMs: number[] = [2000, 3000, 5000, 8000, 12000, 20000, 30000];
  /** 用户显式断开时置位，避免自动重连把刚断开的相机又接回来。 */
  private wifiAutoReconnectArmed: boolean = false;
  /** BLE 扫描到的相机（实验功能）。 */
  @Trace bleCameras: BleCameraDevice[] = [];
  @Trace bleScanning: boolean = false;
  /** BLE 连接进行中（bond + GATT 最长几十秒，UI 必须给反馈）。 */
  @Trace bleConnecting: boolean = false;
  /** BLE 已连接。 */
  @Trace bleConnected: boolean = false;
  /** 已连接相机的 GATT 服务列表（调试用）。 */
  @Trace bleServices: string[] = [];
  /** 配对成功后相机回报的序列号；空串表示未配对。 */
  @Trace bleSerial: string = '';
  /** 已配对相机的广播名（UI 展示用，比序列号好认）。 */
  @Trace bleCameraName: string = '';
  /** 断链后正在自动重连（相机会休眠，链路断了自己爬起来）。 */
  @Trace bleReconnecting: boolean = false;
  private bleScanner: BleScanner | null = null;
  private bleLink: BleCameraLink | null = null;
  private bleScanTimer: number = -1;
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
  /** metadata_cache.json 是否来自一轮**跑完**的扫描；false 表示可用于断点续扫。 */
  private metadataCacheComplete: boolean = true;

  // Orientation cache (EXIF Orientation → rotate/flipH/flipV)
  private orientationMap: Map<number, OrientationTransform> = new Map();

  // Orientations pre-loaded via GetPartialObject during scan, used to
  // apply correct rotate/flip at first thumbnail decode (no re-decode needed).
  private preloadedOrientations: Map<number, OrientationTransform> = new Map();

  // Original photo dimensions read from EXIF during scan (via GetPartialObject).
  // Used to compute precise thumbnail content area for black-bar-free cropping.
  private exifOrigDims: Map<number, OrientedSize> = new Map();

  // ---- 扫描阶段性能测量与自适应（每轮扫描重置） ----
  /** 遍历目录耗时。 */
  private statWalkMs: number = 0;
  /** 逐张 GetObjectInfo 的总耗时与次数。 */
  private statInfoMs: number = 0;
  private statInfoCount: number = 0;
  /** GetThumb 的总耗时与次数。 */
  private statThumbMs: number = 0;
  private statThumbCount: number = 0;
  /** GetPartialObject（读原图 EXIF 头）的总耗时与次数。 */
  private statExifMs: number = 0;
  private statExifCount: number = 0;
  /** 缩略图阶段累计：磁盘命中 / USB 读取（交织时按批累加）。 */
  private thumbCacheHits: number = 0;
  private thumbUsbLoads: number = 0;
  /** 命中 manifest 但文件已失效、被迫回退 USB 的张数。 */
  private thumbCacheFallback: number = 0;
  /** 缩略图写缓存盘的总耗时。 */
  private statSaveMs: number = 0;
  /** 缩略图 TaskPool 解码的总耗时。 */
  private statDecodeMs: number = 0;
  /** GetObjectPropList 探测是否已做过（每个会话只试一次）。 */
  private propListProbed: boolean = false;
  /** 相机自报支持的操作码，用来判断 GetObjectPropList(0x9805) 值不值得试。 */
  private deviceOps: number[] = [];
  /**
   * 缩略图 JPEG 自带的 EXIF 方向是否可信：
   * `null` = 还在验证，`0` = 不可信（继续读原图），`1` = 可信（省掉 GetPartialObject）。
   * 只靠“缩略图有 EXIF”就相信它是危险的：相机可能给缩略图写的是“不旋转”。
   * 因此先用一小批照片与原图比对，全部一致、且样本里包含竖拍，才切换到可信模式。
   */
  private thumbExifTrust: number | null = null;
  private thumbExifSamples: number = 0;
  private thumbExifPortrait: number = 0;
  private thumbExifMismatch: number = 0;
  private thumbExifMissing: number = 0;

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

  /**
   * 连接 Wi-Fi 相机（PTP/IP over TCP 15740）。
   *
   * 只负责建立会话、取设备身份；照片扫描复用 `scanForCamera()`——它会
   * 识别 `wireless` 并跳过 USB 枚举。
   *
   * 前置条件：手机与相机在同一网络。既可以是相机 STA 模式加入同一路由器，
   * 也可以是手机开热点、相机连热点。连接失败时优先检查：相机 Wi-Fi 是否
   * 开启、是否已完成「主机注册」、15740 端口是否可达。
   */
  async connectWifi(host: string, port: number = 15740, silent: boolean = false): Promise<boolean> {
    const target = host.trim();
    if (target === '') {
      this.reportScanFailure(L10n.tr('camera_status_wifi_empty_host'));
      return false;
    }
    if (this.connected) {
      await this.disconnect();
    }
    this.syncSessionMode();
    const wifi = this.makeWifiSession();
    this.wifiSession = wifi;
    this.session = new PtpScheduler(wifi);
    this.wireless = true;
    this.wifiHost = target;
    this.wifiPort = port;
    this.connected = false;
    this.usable = false;
    this.statusText = L10n.tr('camera_status_wifi_connecting', target);

    const endpoint: PtpEndpoint = {
      kind: PtpEndpointKind.WIFI,
      host: target,
      port: port,
      label: target
    };
    const ok = await this.session.connect(endpoint, PtpPriority.FOREGROUND);
    if (!ok) {
      this.wireless = false;
      this.connected = false;
      this.wifiSession = null;
      this.session = new PtpScheduler(new PtpSession());
      if (!silent) {
        this.reportScanFailure(L10n.tr('camera_status_wifi_connect_failed', target));
      }
      return false;
    }

    this.connected = true;
    this.usable = false;
    this.statusText = L10n.tr('camera_status_connected');
    const deviceInfo = await this.session.getDeviceInfo();
    if (deviceInfo) {
      this.deviceManufacturer = deviceInfo.manufacturer;
      this.deviceSerialNumber = deviceInfo.serialNumber;
      this.deviceVersion = deviceInfo.deviceVersion;
      this.deviceOps = deviceInfo.operationsSupported ?? [];
      this.cameraIdentity = this.buildWifiCameraIdentity(deviceInfo, target);
      this.cameraName = deviceInfo.model || deviceInfo.manufacturer || target;
      this.log.add(`Wi-Fi DeviceInfo: manu="${deviceInfo.manufacturer}" model="${deviceInfo.model}" ` +
        `serial="${deviceInfo.serialNumber}"`);
    } else {
      this.cameraIdentity = `wifi_${target.replace(/[^a-zA-Z0-9_.-]/g, '_')}`;
      this.cameraName = target;
      this.log.add('Wi-Fi DeviceInfo 未取到，用地址作为身份');
    }
    this.log.add(`无线连接建立: ${target}:${port}，身份 ${this.cameraIdentity}`);
    // 地址落盘：下次冷启动 / 断线重连先试这个地址，不用每次都扫一遍网段。
    WifiLinkStore.getInstance().save(target, port, this.cameraName);
    this.wifiAutoReconnectArmed = true;
    this.wifiHint = '';

    // 相机在「连接向导」里等主机注册时，会先开 15740 让我们连上，再等
    // 0x952B/0x935A 确认；不确认就 10 秒后自行收线，且 Wi-Fi 配置不落盘。
    const code = await wifi.getPairingCode();
    if (code !== null) {
      this.pairingCode = code;
      this.pairingRequired = true;
      this.statusText = L10n.tr('camera_status_wifi_pairing', code);
      this.log.add(`相机要求配对，验证码 ${code}，等待用户核对后确认`);
      return true;
    }
    this.pairingRequired = false;
    this.pairingCode = '';
    this.checkCachingState();
    return true;
  }

  /**
   * 完成主机注册（0x935A，参数 0x2001）。
   *
   * Z50II 实测：相机在回响应之前就收线，随后用它保存的配置重开 Wi-Fi。
   * 所以这里不把断链当失败，等一拍后直接重连；重连后再探一次配对码，
   * 拿不到才算配对完成，并接着触发扫描。
   */
  async completeWifiPairing(): Promise<boolean> {
    const wifi = this.wifiSession;
    if (!wifi) {
      this.reportScanFailure(L10n.tr('camera_status_wifi_connect_failed', this.wifiHost));
      return false;
    }
    this.statusText = L10n.tr('camera_status_wifi_pairing_confirm');
    this.log.add('发送 CompletePairing');
    await wifi.completePairing();
    this.pairingRequired = false;
    this.pairingCode = '';
    this.connected = false;
    this.wireless = false;
    this.wifiSession = null;
    this.session = new PtpScheduler(new PtpSession());

    const host = this.wifiHost;
    const port = this.wifiPort;
    // 相机收线后要重启 Wi-Fi 服务才会重新监听 15740。Z50II 实测约 6–7 秒，
    // 只试一次必然抢跑；这里按退避自动重试，别把「再点一次」甩给用户。
    const delays: number[] = [2000, 3000, 5000, 8000, 12000];
    let ok = false;
    for (let i = 0; i < delays.length; i++) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, delays[i]);
      });
      if (i > 0) {
        this.statusText = L10n.tr('camera_status_wifi_reconnecting', i + 1);
      }
      ok = await this.connectWifi(host, port, true);
      if (ok) {
        this.log.add(`配对后第 ${i + 1} 次重连成功`);
        break;
      }
      this.log.add(`配对后第 ${i + 1} 次重连失败`);
    }
    if (ok && !this.pairingRequired) {
      this.statusText = L10n.tr('camera_status_wifi_pairing_done');
      this.scanForCamera(true, true);
    } else if (!ok) {
      this.reportScanFailure(L10n.tr('camera_status_wifi_pairing_timeout', host));
    }
    return ok;
  }

  /**
   * 搜索局域网内的相机（mDNS `_ptp._tcp`），结果写进 `wifiCameras`。
   *
   * 浏览持续 [durationMs] 后自动收起；期间发现的相机随时追加，用户点哪台
   * 就连哪台，不需要手填 IP。
   */
  async scanWifiCameras(durationMs: number = 8000): Promise<void> {
    const ctx = this.context;
    if (ctx === null || this.wifiScanning) return;
    this.wifiScanning = true;
    this.wifiCameras = [];
    this.wifiHint = '';
    // 先摸一遍本机网络：扫不到相机时，是「网络前提不成立」还是「相机没进
    // Wi-Fi 模式」，这一步决定了给用户哪句提示。
    const nets = await collectLocalNetworks();
    this.networkSummary = nets.summary;
    this.wifiHint = networkHint(nets);
    this.log.add(`本机网络: ${nets.summary}`);
    if (this.nsdScanner === null) {
      this.nsdScanner = new NsdScanner(ctx,
        (camera: WifiCameraInfo) => {
          this.mergeWifiCamera(camera, 'mDNS');
        },
        (name: string) => {
          this.wifiCameras = this.wifiCameras.filter((c: WifiCameraInfo) => c.name !== name);
        },
        (msg: string) => { this.log.add(msg); });
    }
    try {
      await this.nsdScanner.start();
    } catch (err) {
      this.log.add(`mDNS 启动失败: ${(err as Error).message}`);
    }

    // mDNS 被客户端隔离挡掉时一个都收不到，同时跑一遍 /24 端口扫描兜底。
    if (this.subnetScanner === null) {
      this.subnetScanner = new SubnetScanner((msg: string) => { this.log.add(msg); });
    }
    const mdnsWindow = new Promise<void>((resolve: () => void) => {
      if (this.wifiScanTimer >= 0) clearTimeout(this.wifiScanTimer);
      this.wifiScanResolve = resolve;
      this.wifiScanTimer = setTimeout(() => {
        this.wifiScanTimer = -1;
        this.wifiScanResolve = null;
        resolve();
      }, durationMs);
    });
    const subnetWork = this.subnetScanner.scan().then((found: WifiCameraInfo[]) => {
      for (const camera of found) {
        this.mergeWifiCamera(camera, '网段扫描');
      }
    }).catch((err: Error) => {
      this.log.add(`网段扫描失败: ${err.message}`);
    });
    await Promise.all([mdnsWindow, subnetWork]);
    this.wifiScanning = false;
    this.wifiScanResolve = null;
    if (this.wifiCameras.length === 0 && this.wifiHint === '') {
      // 网络前提成立却一台都没找到：问题在相机那边（没进 Wi-Fi 模式、
      // 被客户端隔离、或相机把上一个会话还挂在 15740 上）。
      this.wifiHint = '同一网络里没有发现相机。确认相机已进入「连接至智能设备」的 Wi-Fi 模式。';
    }
  }

  /**
   * 扫一段，**一发现相机就提前收工**。
   *
   * 网段扫描一轮要三十秒（507 个候选 × 700ms / 12 并发）。自动接续如果等满
   * 整轮，用户会以为卡住了；而 mDNS 命中往往只要一两秒。所以按 500ms 轮询，
   * 一看到相机就停扫、立刻去连。
   */
  private async scanUntilCamera(maxWaitMs: number): Promise<WifiCameraInfo | null> {
    const scan = this.scanWifiCameras(6000);
    const deadline = Date.now() + maxWaitMs;
    let found: WifiCameraInfo | null = null;
    while (Date.now() < deadline) {
      found = this.pickWifiCamera();
      if (found !== null) break;
      if (!this.wifiScanning) break;
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 500);
      });
    }
    if (found !== null) {
      this.log.add(`自动无线: 提前收工，命中 ${found.name}`);
      this.stopWifiScan();
    }
    await scan;
    return found !== null ? found : this.pickWifiCamera();
  }

  private mergeWifiCamera(camera: WifiCameraInfo, source: string): void {
    if (this.wifiCameras.some((c: WifiCameraInfo) =>
      c.name === camera.name || c.host === camera.host)) {
      return;
    }
    this.wifiCameras = this.wifiCameras.concat([camera]);
    this.log.add(`${source} 发现相机: ${camera.name} @ ${camera.host}:${camera.port}`);
  }

  /** 停止 mDNS 浏览、取消网段扫描并清掉计时器。 */
  stopWifiScan(): void {
    if (this.nsdScanner !== null) {
      this.nsdScanner.stop();
    }
    if (this.subnetScanner !== null) {
      this.subnetScanner.cancel();
    }
    if (this.wifiScanTimer >= 0) {
      clearTimeout(this.wifiScanTimer);
      this.wifiScanTimer = -1;
    }
    // 必须把窗口 promise 兑现：只清计时器会让 `await scanWifiCameras()`
    // 永远等下去（自动接续就卡在这儿）。
    const resolve = this.wifiScanResolve;
    this.wifiScanResolve = null;
    if (resolve !== null) {
      resolve();
    }
    this.wifiScanning = false;
  }

  /** 申请蓝牙权限（ACCESS_BLUETOOTH 是 user_grant，首次会弹系统框）。 */
  private async ensureBlePermission(): Promise<boolean> {
    const ctx = this.context;
    if (ctx === null) return false;
    try {
      const at = abilityAccessCtrl.createAtManager();
      const result = await at.requestPermissionsFromUser(ctx, ['ohos.permission.ACCESS_BLUETOOTH']);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (err) {
      this.log.add(`BLE 权限申请失败: ${(err as Error).message}`);
      return false;
    }
  }

  /** 搜索 BLE 相机（实验）。只发现，不配对。 */
  async scanBleCameras(durationMs: number = 8000): Promise<void> {
    if (this.bleScanning) return;
    if (!await this.ensureBlePermission()) {
      this.reportScanFailure(L10n.tr('camera_status_ble_permission'));
      return;
    }
    this.bleScanning = true;
    this.bleCameras = [];
    if (this.bleScanner === null) {
      this.bleScanner = new BleScanner(
        (device: BleCameraDevice) => {
          if (!this.bleCameras.some((d: BleCameraDevice) => d.deviceId === device.deviceId)) {
            this.bleCameras = this.bleCameras.concat([device]);
          }
        },
        (msg: string) => { this.log.add(msg); });
    }
    this.bleScanner.start();
    if (this.bleScanTimer >= 0) clearTimeout(this.bleScanTimer);
    this.bleScanTimer = setTimeout(() => {
      this.bleScanTimer = -1;
      if (this.bleScanner !== null) this.bleScanner.stop();
      this.bleScanning = false;
    }, durationMs);
  }

  /** 停止 BLE 扫描。 */
  stopBleScan(): void {
    if (this.bleScanner !== null) this.bleScanner.stop();
    if (this.bleScanTimer >= 0) {
      clearTimeout(this.bleScanTimer);
      this.bleScanTimer = -1;
    }
    this.bleScanning = false;
  }

  /** 连接一台 BLE 相机并列出 GATT 服务（验证 BLE 通道用）。 */
  async connectBle(deviceId: string, deviceName: string = ''): Promise<boolean> {
    if (this.bleConnecting) {
      this.log.add('BLE 正在连接中，忽略重复点击');
      return false;
    }
    this.stopBleScan();
    this.bleConnecting = true;
    this.bleConnected = false;
    this.bleServices = [];
    try {
      if (this.bleLink === null) {
        this.bleLink = new BleCameraLink(
          (msg: string) => { this.log.add(msg); },
          (connected: boolean) => {
            this.bleConnected = connected;
            if (!connected) {
              this.bleServices = [];
              this.bleSerial = '';
            }
          });
      }
      this.bleCameraName = deviceName;
      const ok = await this.bleLink.connect(deviceId);
      if (!ok) {
        this.bleServices = [];
        this.reportScanFailure(L10n.tr('camera_status_ble_connect_failed'));
        return false;
      }
      this.bleConnected = true;
      this.bleServices = await this.bleLink.listServices();
      for (const line of this.bleServices) {
        this.log.add(`GATT ${line}`);
      }
      this.log.add(`BLE 服务枚举完成: ${this.bleServices.length} 行`);
      // 服务枚举完直接走两段式配对（相机需停在「开始配对」页）。
      // 广播名要传给配对层：经典蓝牙绑定时靠它匹配相机。
      // 无线会话已经在用的时候不写 0x2005：那一笔可能让相机重启 Wi-Fi，
      // 把正在传照片的 PTP 会话一起掐断（BLE 掉线重连时就会踩到）。
      const wakeWifi = !(this.connected && this.wireless);
      const serial = await this.bleLink.pair(deviceName, wakeWifi);
      if (serial === null) {
        this.bleSerial = '';
        this.log.add('BLE 配对失败（相机可能不在「开始配对」页，或已配对过）');
        return false;
      }
      this.bleSerial = serial;
      this.log.add(`BLE 配对成功，相机序列号 ${serial}`);

      // 断链自动重连：相机会休眠，链路断了自己爬起来（用保存的身份复用握手）。
      this.bleLink.onReconnected = (serial: string) => {
        this.bleSerial = serial;
        this.bleConnected = true;
        this.bleReconnecting = false;
        this.log.add(`BLE 已自动重连（序列号 ${serial}）`);
        this.startBleKeepalive(0);
        // 相机睡醒之后无线也得重新唤起，否则照片那半条永远是断的。
        if (!this.connected) {
          this.autoLinkWifi('ble-reconnected').catch((err: Error) => {
            this.log.add(`重连后自动无线失败: ${err.message}`);
          });
        }
      };
      this.bleLink.onReconnecting = (reconnecting: boolean) => {
        this.bleReconnecting = reconnecting;
      };
      this.bleLink.enableAutoReconnect();
      // 配对成功后才允许写 0x2006/0x2007：先校时，再按 45s 保活（顺带持续校时）。
      // 首笔要等 2.5 秒（ZPill 的 writeGate）：相机刚收口时注入会话还没醒，
      // 立刻写会被拒收甚至被踢链。
      this.startBleKeepalive(2500);
      // 蓝牙是「无线」的前置：配对一落定就接着把 Wi-Fi 那半条接上。
      // 否则用户看到的是「蓝牙已连接 + 无线未连接」，还得自己去点扫描。
      this.autoLinkWifi('ble-paired').catch((err: Error) => {
        this.log.add(`自动无线启动失败: ${err.message}`);
      });
      return true;
    } finally {
      this.bleConnecting = false;
    }
  }

  /**
   * 原地起保活（首次连接延迟首写门，自动重连时立刻恢复）。
   */
  private startBleKeepalive(delayMs: number): void {
    const offsetMinutes = -new Date().getTimezoneOffset();
    const apply = (): void => {
      if (this.bleLink === null) return;
      try {
        this.bleLink.writeTime(offsetMinutes).then(() => {
          if (this.bleLink === null) return;
          this.bleLink.startKeepalive(45000, offsetMinutes, () => {
            const fix = GpsRecorder.getInstance().lastFix;
            if (fix === null) return null;
            return {
              latitude: fix.latitude,
              longitude: fix.longitude,
              altitude: fix.altitude,
              satellites: 0,
              utc: new Date()
            };
          });
          this.log.add(`BLE 校时已写入（offset ${offsetMinutes}min），保活 45s 已启动`);
        }).catch((err: Error) => {
          this.log.add(`BLE 校时失败: ${err.message}`);
        });
      } catch (err) {
        this.log.add(`BLE 保活启动失败: ${(err as Error).message}`);
      }
    };
    if (delayMs <= 0) {
      apply();
      return;
    }
    setTimeout(apply, delayMs);
  }

  /**
   * App 启动 / 回前台时自动接上已配对的相机。
   *
   * 相机休眠时 BLE 仍可连，握手阶段的 stage1 重发负责把它唤醒；连不上就
   * 置空交给用户的显式操作，不在前台反复刷扫描。
   */
  async autoConnectBle(): Promise<boolean> {
    if (this.bleConnected || this.bleConnecting) return this.bleConnected;
    const store = BleIdentityStore.getInstance();
    if (!store.hasIdentity() || store.deviceId.length === 0) {
      // 没有 BLE 身份不代表无线也连不上：上次连过的无线地址还在，值得先试
      // 一次（用户可能只想要相册，不需要蓝牙保活/地理标记）。
      await this.autoLinkWifi('cold-start-no-ble', false);
      return false;
    }
    this.log.add(`BLE 自动连接已配对相机（${store.cameraName}）`);
    if (await this.connectBle(store.deviceId, store.cameraName)) {
      return true;
    }
    // 相机每轮广播都换随机地址，上次存的地址可能已经失效；按尼康 deviceId
    // 重扫一次（休眠相机的广播没有名字，只能靠厂商数据认）。
    this.log.add('BLE 直连未成，按设备号重扫相机');
    const devices = await this.scanForNikonDeviceId(store.identityDevice, 6000);
    for (const dev of devices) {
      if (await this.connectBle(dev.deviceId, dev.name)) {
        return true;
      }
    }
    // BLE 这条路彻底不通时，无线这半条仍单独试一次（比如蓝牙被系统关了、
    // 但手机还挂在相机所在的热点上）。
    await this.autoLinkWifi('cold-start-ble-failed', false);
    return false;
  }

  /** 按尼康 deviceId 扫一段时间的相机（会自己停）。 */
  private async scanForNikonDeviceId(nikonDeviceId: number,
                                     durationMs: number): Promise<BleCameraDevice[]> {
    return new Promise<BleCameraDevice[]>((resolve: (v: BleCameraDevice[]) => void) => {
      const found: BleCameraDevice[] = [];
      const scanner = new BleScanner(
        (dev: BleCameraDevice) => { found.push(dev); },
        (msg: string) => this.log.add(msg),
        nikonDeviceId);
      scanner.start();
      setTimeout(() => {
        scanner.stop();
        resolve(found);
      }, durationMs);
    });
  }

  /** 断开 BLE。 */
  async disconnectBle(): Promise<void> {
    // 用户显式断开：先撤掉无线侧的自动重连，免得刚点完「断开」又被接回来。
    this.wifiAutoReconnectArmed = false;
    this.cancelWifiReconnect();
    if (this.bleLink !== null) {
      // 无线会话还在用的时候不能写 0x2005=0x80：STA 模式下这一笔会让相机
      // 退出网络，顺手把正在用的 PTP 会话也断掉。只在「只连着蓝牙」时关。
      if (!this.wireless) {
        await this.bleLink.closeCameraWifi();
      }
      await this.bleLink.disconnect();
    }
    this.bleConnected = false;
    this.bleReconnecting = false;
    this.bleServices = [];
    this.bleSerial = '';
  }

  /** 取消排队中的无线自动重连。 */
  private cancelWifiReconnect(): void {
    if (this.wifiReconnectTimer >= 0) {
      clearTimeout(this.wifiReconnectTimer);
      this.wifiReconnectTimer = -1;
    }
    this.wifiReconnecting = false;
    this.wifiReconnectIndex = 0;
  }

  private makeWifiSession(): WifiPtpSession {
    const s = new WifiPtpSession();
    s.setLog((m: string) => this.log.add(m));
    // 链路意外断开（相机休眠、热点掉了、相机主动收线）时排一次自动重连。
    // 以前这里没有任何上报口：断链之后 App 还停在「已连接」，点什么都失败。
    s.setBrokenHandler((reason: string) => { this.onWifiBroken(reason); });
    return s;
  }

  /**
   * 无线链路掉线：清会话状态并按退避重连。
   *
   * 与 BLE 侧同节奏：先试记住的地址（快），连不上再重扫（相机换网段/DHCP
   * 重发地址的情况）。用户显式断开后 `wifiAutoReconnectArmed` 为 false，
   * 自动重连不会启动。
   */
  private onWifiBroken(reason: string): void {
    if (!this.wifiAutoReconnectArmed) {
      this.log.add(`无线链路断开（未启用自动重连）: ${reason}`);
      return;
    }
    if (this.wifiReconnecting) return;
    this.log.add(`无线链路断开，准备自动重连: ${reason}`);
    this.wifiReconnecting = true;
    this.connected = false;
    this.usable = false;
    this.wifiReconnectIndex = 0;
    this.scheduleWifiReconnect();
  }

  private scheduleWifiReconnect(): void {
    if (this.wifiReconnectTimer >= 0) {
      clearTimeout(this.wifiReconnectTimer);
      this.wifiReconnectTimer = -1;
    }
    if (!this.wifiAutoReconnectArmed) {
      this.wifiReconnecting = false;
      return;
    }
    const delay = this.wifiBackoffMs[Math.min(this.wifiReconnectIndex,
      this.wifiBackoffMs.length - 1)];
    this.statusText = L10n.tr('camera_status_wifi_reconnecting', this.wifiReconnectIndex + 1);
    this.wifiReconnectTimer = setTimeout(() => {
      this.wifiReconnectTimer = -1;
      this.tryWifiReconnect().catch((err: Error) => {
        this.log.add(`无线自动重连异常: ${err.message}`);
      });
    }, delay);
  }

  private async tryWifiReconnect(): Promise<void> {
    if (!this.wifiAutoReconnectArmed) {
      this.wifiReconnecting = false;
      return;
    }
    this.wifiReconnectIndex++;
    const ok = await this.autoLinkWifi('reconnect');
    if (ok) {
      this.wifiReconnecting = false;
      this.wifiReconnectIndex = 0;
      this.log.add('无线自动重连成功');
      return;
    }
    if (this.wifiReconnectIndex >= this.wifiBackoffMs.length) {
      this.wifiReconnecting = false;
      this.wifiReconnectIndex = 0;
      this.log.add('无线自动重连放弃（退避用尽）');
      this.statusText = L10n.tr('camera_status_wifi_connect_failed', this.wifiHost);
      return;
    }
    this.scheduleWifiReconnect();
  }

  /**
   * 把无线链路接起来（自动路径的唯一入口）。
   *
   * 顺序刻意是「记得的地址 → mDNS/网段扫描」：
   * 1. 地址几乎从不变化，先直连能把冷启动从十几秒压到一两秒；
   * 2. 直连失败才扫，避免每次都跑 254 个地址的端口探测。
   *
   * 成功后顺带把照片扫一遍，让「蓝牙连上 → 无线连上 → 相册出来」是一条
   * 连续的链路，而不是要用户再点一次「搜索相机」。
   */
  async autoLinkWifi(source: string, allowScan: boolean = true): Promise<boolean> {
    if (this.connected && this.wireless) return true;
    if (this.wifiAutoConnecting) {
      this.log.add(`自动无线已在进行中，忽略 ${source} 的重复触发`);
      return false;
    }
    this.wifiAutoConnecting = true;
    try {
      const nets = await collectLocalNetworks();
      this.networkSummary = nets.summary;
      this.log.add(`自动无线（${source}）: ${nets.summary}`);

      const store = WifiLinkStore.getInstance();
      if (store.hasHost()) {
        this.log.add(`自动无线: 先试上次地址 ${store.host}:${store.port}`);
        if (await this.connectWifi(store.host, store.port, true)) {
          await this.finishAutoLink();
          return true;
        }
        this.log.add('自动无线: 上次地址不通，改为扫描');
      }
      if (!allowScan) {
        this.log.add('自动无线: 本次不走网段扫描（冷启动先只试记住的地址）');
        return false;
      }

      // 上限比一整轮网段扫描还长：命中就提前收工，没命中就让它跑完，
      // 不人为截断搜索（截断会把「慢但能找到」变成「找不到」）。
      const camera = await this.scanUntilCamera(45000);
      if (camera === null) {
        this.log.add(`自动无线: 没有发现相机。${this.wifiHint}`);
        return false;
      }
      this.log.add(`自动无线: 命中 ${camera.name} @ ${camera.host}`);
      if (await this.connectWifi(camera.host, camera.port, true)) {
        await this.finishAutoLink();
        return true;
      }
      return false;
    } finally {
      this.wifiAutoConnecting = false;
    }
  }

  /** 自动连上之后的收口：相机要注册就先注册，然后直接扫照片。 */
  private async finishAutoLink(): Promise<void> {
    this.wifiAutoReconnectArmed = true;
    this.wifiHint = '';
    if (this.pairingRequired) {
      await this.completeWifiPairing();
      return;
    }
    if (!this.connected) return;
    await this.scanForCamera(true, true);
  }

  /**
   * 从扫描结果里挑一台。
   *
   * mDNS 的实例名就是相机名，比「网段扫描得到的裸 IP」可信得多，所以优先；
   * 同类里优先名字像尼康机身的（`Z50_2_...`），再不行才取第一台。
   */
  private pickWifiCamera(): WifiCameraInfo | null {
    if (this.wifiCameras.length === 0) return null;
    const byName = this.wifiCameras.filter((c: WifiCameraInfo) => !this.isRawIpName(c.name));
    const named = byName.find((c: WifiCameraInfo) => /^[A-Za-z]/.test(c.name));
    if (named !== undefined) return named;
    if (byName.length > 0) return byName[0];
    return this.wifiCameras[0];
  }

  /** 网段扫描的候选名就是 IP 本身，用它区分「有名字的 mDNS 结果」。 */
  private isRawIpName(name: string): boolean {
    return /^\d{1,3}(\.\d{1,3}){3}$/.test(name);
  }

  private buildWifiCameraIdentity(info: DeviceInfo, host: string): string {
    const sanitize = (s: string): string => s.replace(/[^a-zA-Z0-9_.-]/g, '_').substring(0, 64);
    const manu = (info.manufacturer || '').trim();
    const model = (info.model || '').trim();
    const serial = (info.serialNumber || '').trim();
    if (serial) {
      return sanitize(`${manu}_${model}_${serial}`);
    }
    return sanitize(`${manu}_${model}_wifi_${host}`);
  }

  /**
   * 建立/复用 USB 会话。无线模式不走这里，直接复用 `connectWifi()` 建好的会话。
   * 返回 false 时由调用方收尾（清 scanning / 已在内部报过错）。
   */
  private async ensureUsbSession(): Promise<boolean> {
    const cameras = this.sessionIsMock ? MockPtpDevice.findCameras() : PtpSession.findCameras();
    if (cameras.length === 0) {
      this.connected = false;
      this.cameraName = '';
      this.reportScanFailure(L10n.tr('camera_status_no_camera'));
      this.scanning = false;
      return false;
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
  

      const usbEndpoint: PtpEndpoint = {
        kind: PtpEndpointKind.USB,
        device: cameras[0],
        label: cameras[0].name
      };
      const ok = await this.session.connect(usbEndpoint);
      if (!ok) {
        this.connected = false;
        // 0x201E：相机里还留着上一次崩溃时的会话，光重试没有用，要用户拔插一次线。
        this.reportScanFailure(L10n.tr(this.session.sessionConflict === true
          ? 'camera_status_session_conflict' : 'camera_status_connect_failed'));
        this.scanning = false;
        return false;
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
        this.deviceOps = deviceInfo.operationsSupported ?? [];
        this.log.add(`PTP 支持操作 ${this.deviceOps.length} 个` +
          `${this.deviceOps.includes(0x9805) ? '（含 GetObjectPropList）' : '（无 GetObjectPropList）'}`);
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
    return true;
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
      if (this.wireless) {
        // 无线会话已在 connectWifi() 里建立；这里只确认它还在。
        if (!this.connected) {
          this.reportScanFailure(L10n.tr('camera_status_wifi_disconnected'));
          this.scanning = false;
          return;
        }
        this.statusText = L10n.tr('camera_status_connected');
      } else {
        const ready = await this.ensureUsbSession();
        if (!ready) {
          this.scanning = false;
          return;
        }
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
   * 试一次 GetObjectPropList（MTP 0x9805），判断能不能用一次事务拿回全部对象属性。
   *
   * 扫描的瓶颈是「每张一次 USB 往返」：Nikon 上 GetObjectInfo 约 30ms，
   * 1288 张就是 40s。若相机支持这个 MTP 扩展，同样 1288 张只要一笔事务。
   * 相机不支持是正常情况（返回 0x2005），这里只记录，不改变扫描流程。
   */
  private async probeObjectPropList(): Promise<void> {
    if (this.propListProbed) return;
    this.propListProbed = true;
    const advertised = this.deviceOps.includes(0x9805);
    // Nikon Z50_2 实测：不支持时 0x9805 不回响应，IN 端点在 10s 超时后才放弃，
    // 而且之后 3 条命令各失败一次、丢了 3 张照片（2026-11-09 真机）。
    // 所以“先试一下”只对自报支持的相机做，别再拿真实相机赌。
    if (!advertised) {
      this.log.add('[PROP_LIST] 相机未列出 GetObjectPropList，跳过探测');
      return;
    }
    const t0 = Date.now();
    try {
      const list = await this.session.getObjectPropList(0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF);
      const ms = Date.now() - t0;
      this.log.add(`[PROP_LIST] 耗时 ${ms}ms，声明 ${list.declared} / 解析 ${list.objects.length} 条 ` +
        `/ ${list.bytes}B / 完整=${list.complete ? '是' : '否'}（相机自报=${advertised ? '支持' : '未列出'}）`);
      const codes: string[] = [];
      for (const c of list.codes) {
        codes.push('0x' + c.toString(16));
      }
      this.log.add(`[PROP_LIST] 属性码 ${codes.length} 个: ${codes.join(',')}`);
      this.log.add(`[PROP_LIST] 数据头: ${list.head}`);
      if (list.objects.length > 0) {
        const f = list.objects[0];
        this.log.add(`[PROP_LIST] 样例 ${f.filename} size=${f.size} ` +
          `fmt=0x${f.format.toString(16)} date=${f.dateCreated || '(空)'} parent=0x${f.parent.toString(16)}`);
        const withName = list.objects.filter((o) => o.filename.length > 0).length;
        const withSize = list.objects.filter((o) => o.size > 0).length;
        const withDate = list.objects.filter((o) => o.dateCreated.length > 0).length;
        this.log.add(`[PROP_LIST] 字段覆盖: 文件名 ${withName} / 体积 ${withSize} / 日期 ${withDate}`);
      }
    } catch (err) {
      const ms = Date.now() - t0;
      this.log.add(`[PROP_LIST] 不可用（${ms}ms）: ${(err as Error).message}` +
        `（相机自报=${advertised ? '支持' : '未列出'}）`);
    }
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
    // 逐笔事务的流水日志在 1288 张时会把日志环形缓冲冲掉，也白花拼串时间。
    setPtpQuietOps(true);
    this.statWalkMs = 0;
    this.statInfoMs = 0;
    this.statInfoCount = 0;
    this.statThumbMs = 0;
    this.statThumbCount = 0;
    this.statExifMs = 0;
    this.statExifCount = 0;
    this.statSaveMs = 0;
    this.statDecodeMs = 0;
    this.thumbCacheHits = 0;
    this.thumbUsbLoads = 0;
    this.thumbCacheFallback = 0;
    this.thumbDecoded = 0;

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
      const walkStart = Date.now();
      const allHandles = await this.collectPhotoHandles(storageIDs, 0xFFFFFFFF, 0,
        (count: number) => {
          foundCount += count;
          this.photoCount = foundCount;
        });
      this.statWalkMs = Date.now() - walkStart;
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
      const reuseMeta = canReuse ? cachedMeta : new Map<number, PhotoEntry>();
      // 续扫时缓存只覆盖一部分 handle，仍需逐张读剩下的。
      const fullReuse = canReuse && reuseMeta.size >= handles.length;

      // 只有本轮真的要逐张读元数据时才值得探测合批能力（复用缓存时探测纯属浪费）。
      if (!canReuse) {
        await this.probeObjectPropList();
      }

      const photoList: PhotoEntry[] = [];
      const validCacheKeys: Set<string> = new Set();
      let reused = 0;
      let fetched = 0;
      let infoFailed = 0;

      // 交织只在“真的要读相机”时有意义：整份复用缓存时元数据是瞬时的，
      // 先一次读完再统一取缩略图更省事。断点续扫要读剩下的几千张，必须交织，
      // 否则用户要盯着旧快照一动不动地等到元数据读完。
      // 反过来 `!interleave` 就等价于「整份命中缓存」，循环里不会有 USB 调用。
      const interleave = !fullReuse;
      const chunkSize = interleave ? SCAN_CHUNK : handles.length;
      if (interleave) {
        // 相机 handle 基本按拍摄顺序递增，从后往前读：画廊顶部（最新）那几行最先有图。
        handles.reverse();
        this.scanPhaseText = L10n.tr('camera_phase_loading_photos');
      }

      let processed = 0;
      let lastPersisted = 0;
      while (processed < handles.length) {
        const chunkEnd = Math.min(processed + chunkSize, handles.length);
        for (; processed < chunkEnd; processed++) {
          const h = handles[processed];
          let entry: PhotoEntry | null = null;
          const cached = reuseMeta.get(h);
          if (cached) {
            entry = cached;
            reused++;
          } else {
            try {
              const infoStart = Date.now();
              const info = await this.session.getObjectInfo(h);
              this.statInfoMs += Date.now() - infoStart;
              this.statInfoCount++;
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
          this.scanProgress = processed + 1;
        }

        if (interleave) {
          // 已有缓存快照时列表「只增不减」：否则画廊会先缩到 64 张再慢慢长回去。
          // 冷启动（photos 为空）时这条恒成立，行为与之前一致。
          if (photoList.length >= this.photos.length) {
            this.publishPhotoList(photoList);
          }
          // 先把这一批的缩略图取回来，再读下一批元数据。总时长不变，
          // 但首屏不用等 1285 张元数据全部读完（真机实测那要 28s）。
          await this.loadThumbnailsRowByRow(validCacheKeys, false, false);
          this.scanTotal = handles.length;
          this.scanProgress = processed;

          // 断点续扫：每读 256 张就把已完成的条目落盘（complete=false）。
          // 应用被杀 / 退后台被回收 / 扫描失败时，下次全量扫描能从这里接着走。
          if (this.cameraIdentity && this.cachingEnabled &&
              fetched > 0 && processed - lastPersisted >= SCAN_PERSIST_EVERY) {
            this.saveMetadataCache(photoList, false);
            lastPersisted = processed;
          }
        }
      }

      this.publishPhotoList(photoList);

      // cleanupStaleMemoryCache: remove entries for deleted photos
      const validHandles = new Set<number>();
      for (const p of photoList) {
        validHandles.add(p.handle);
      }
      this.cleanupStaleMemoryCache(validHandles);

      // 元数据读完了，但缩略图可能还没取完：先按“未完成”落盘，
      // 缩略图全取完再改成 complete=true。整份复用缓存时不重写（内容没变）。
      if (this.cameraIdentity && this.cachingEnabled && fetched > 0) {
        this.saveMetadataCache(photoList, false);
      }

      this.log.add(`元数据获取完成: ${photoList.length} 张` +
        `（复用 ${reused} / 读取 ${fetched} / 失败 ${infoFailed}）`);

      // ---- Phase 2b: 缩略图 ----
      if (interleave) {
        // 交织模式下每批都已取过图，这里只做最后的发布与缓存收尾。
        await this.loadThumbnailsRowByRow(validCacheKeys, true, false);
        this.scanProgress = handles.length;
      } else {
        this.scanPhaseText = L10n.tr('camera_phase_thumbnails');
        this.statusText = L10n.tr('camera_phase_loading_thumbnails');
        await this.loadThumbnailsRowByRow(validCacheKeys);
      }

      // 缩略图阶段才拿到的方向/尺寸回写元数据缓存：下次快速扫描连 16KB EXIF 头都不用读。
      // 这一步同时把缓存标记为 complete=true，下一次全量扫描就不会误走断点续扫。
      if (this.cameraIdentity && this.cachingEnabled) {
        this.saveMetadataCache(this.photos, true);
      }

      // Compute scan stats for UI display
      {
        const total = this.photoCount;
        this.scanStatsText = L10n.tr('camera_scan_stats',
          L10n.plural('photo_count', total, total));
        this.log.add(this.scanStatsText);
      }

      this.log.add('缩略图加载完成');
      this.logScanTiming();

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
      setPtpQuietOps(false);
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
   * 可复用的元数据。返回空 Map 表示这次必须逐张读。
   *
   * 两条路径：
   * - **快速扫描**：缓存（7 天有效期）整份复用，只对新增 handle 读；
   * - **全量扫描**：只有当上一轮扫描**没跑完**（`complete=false`，24 小时内）才断点续扫，
   *   复用已读到的条目。跑完过的缓存不参与全量扫描，保持“全量＝重读一遍”的语义。
   */
  private prepareMetadataReuse(quickMode: boolean): Map<number, PhotoEntry> {
    if (!this.cachingEnabled || !this.cameraIdentity) {
      return new Map<number, PhotoEntry>();
    }
    const entries = this.loadMetadataCache();
    if (!entries || entries.length === 0) {
      return new Map<number, PhotoEntry>();
    }
    if (!quickMode && this.metadataCacheComplete) {
      // 上一次扫描完整跑完：全量扫描就是要重读，不复用。
      return new Map<number, PhotoEntry>();
    }
    const maxAge = quickMode ? METADATA_REUSE_MAX_AGE_MS : RESUME_MAX_AGE_MS;
    if (this.metadataCacheSavedAt <= 0 ||
        Date.now() - this.metadataCacheSavedAt > maxAge) {
      this.log.add('元数据缓存超过有效期，本次重新读取');
      return new Map<number, PhotoEntry>();
    }
    if (!this.metadataCacheComplete) {
      // 断点续扫：快速扫描也会走这条路（半份缓存），所以不能按扫描模式判断。
      const minutes = Math.max(1, Math.round((Date.now() - this.metadataCacheSavedAt) / 60000));
      this.log.add(`断点续扫: 上次扫描未完成，复用 ${entries.length} 条元数据（${minutes} 分钟前保存）`);
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
    // 从「缓存里真的有」的 handle 中均匀抽样。断点续扫时缓存只覆盖一部分 handle，
    // 若按全部 handle 抽样，命中率可能低到 1 个甚至 0 个（0 个会直接放弃复用，
    // 白白丢掉续扫进度）。
    const present: number[] = [];
    for (const h of handles) {
      if (cachedMeta.has(h)) {
        present.push(h);
      }
    }
    if (present.length === 0) {
      this.log.add('元数据缓存与相机不匹配：缓存里的 handle 都不在相机上，本次全量重读');
      return false;
    }
    const probed: number[] = [];
    const step = Math.max(1, Math.floor(present.length / METADATA_REUSE_PROBE));
    for (let i = 0; i < present.length && probed.length < METADATA_REUSE_PROBE; i += step) {
      probed.push(present[i]);
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
    validCacheKeys: Set<string>,
    finalize: boolean = true,
    manageProgress: boolean = true
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

    if (manageProgress) {
      this.scanProgress = 0;
      this.scanTotal = photos.length;
      this.lastDecodedHandle = -1;
    }

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
        const cacheKey = `${photo.filename}::${photo.size}`;
        try {
          if (cached) {
            const ok = await this.loadCachedThumbnail(photo.handle, cacheKey, cached);
            if (!ok) {
              // manifest 里的条目指向的文件已经不在了（例如「缓存管理」刚清过缓存）。
              // 必须回退到 USB，否则这张会永远停在占位符。
              this.thumbCacheFallback++;
              await this.loadSingleThumbnail(photo, cacheKey, photo.modificationDate || '');
            }
          } else {
            await this.loadSingleThumbnail(photo, cacheKey,
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
    if (manageProgress) {
      this.scanProgress = this.connected ? photos.length : completed;
    }

    this.thumbCacheHits += cacheHits;
    this.thumbUsbLoads += usbLoads;
    if (finalize) {
      this.log.add(`缩略图阶段: 磁盘命中 ${this.thumbCacheHits} / USB 读取 ${this.thumbUsbLoads}` +
        ` / 解码成功 ${this.thumbDecoded}` +
        `${this.thumbCacheFallback > 0 ? ` / 缓存失效回退 ${this.thumbCacheFallback}` : ''}`);
    }

    // Phase 2b complete: final cleanup（交织模式下每批都调，收尾只做一次）
    if (finalize && this.cachingEnabled) {
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
      const thumbStart = Date.now();
      const thumbData = await this.session.getThumb(h);
      this.statThumbMs += Date.now() - thumbStart;
      this.statThumbCount++;
      if (!thumbData || thumbData.length === 0) {
        this.log.add(`[NO_THUMB] handle=0x${h.toString(16)} ${photo.filename}`);
        return;
      }

      // 方向：元数据缓存 → 本次扫描已解析 → 缩略图自带 EXIF → 读原图 EXIF 头
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

      // 缩略图 JPEG 常常原样带着原图的 EXIF，能直接读到方向。
      // 省掉一次 GetPartialObject 就是省掉每张一次 USB 往返（实测 15–30ms）。
      let thumbOrient: OrientationTransform | null = null;
      if (orient === null && this.thumbExifTrust !== 0) {
        thumbOrient = await CameraService.readThumbOrientation(thumbData);
        if (thumbOrient === null) {
          this.thumbExifMissing++;
          if (this.thumbExifSamples === 0 && this.thumbExifMissing >= 8) {
            this.thumbExifTrust = 0;
            this.log.add('缩略图不带 EXIF 方向，继续逐张读原图 EXIF 头');
          }
        } else if (this.thumbExifTrust === 1) {
          orient = thumbOrient;
        }
      }

      // 还要不要读原图 16KB：
      //   尺寸未知 → 必须读（读不到原始比例，缩略图的黑边就裁不掉）
      //   方向未知 → 必须读
      //   验证期且缩略图给了方向 → 也要读一次，用原图方向做真值比对
      const verifying = thumbOrient !== null && this.thumbExifTrust === null;
      const needPartial = dim === null || orient === null || verifying;

      if (needPartial) {
        const exifStart = Date.now();
        let partial: Uint8Array | null = null;
        try {
          partial = await this.session.getPartialObject(h, 0, 16384);
        } catch (err) {
          // 相机不支持 GetPartialObject 时不该让整张缩略图失败
          this.log.add(`[EXIF] handle=0x${h.toString(16)} 读取失败: ${(err as Error).message}`);
        }
        this.statExifMs += Date.now() - exifStart;
        this.statExifCount++;
        if (partial && partial.length > 0) {
          try {
            if (orient === null) {
              const origOrient = await this.getOrientation(h, partial.buffer as ArrayBuffer);
              orient = origOrient;
              if (verifying) {
                this.trackThumbExif(origOrient, thumbOrient!);
              }
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
        cacheLoads.push(this.loadCachedThumbnail(entry.handle, key, cached).then(() => {}));
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
      // 旧文件没有 complete 字段，按“已完成”处理。
      this.metadataCacheComplete = raw['complete'] !== false;
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
  private saveMetadataCache(entries: PhotoEntry[], complete: boolean = true): void {
    if (!this.cameraIdentity) return;
    try {
      fileIo.mkdirSync(this.thumbCache.getCacheDir(), true);
    } catch (_e) { /* best effort */ }
    try {
      const path = this.thumbCache.getCacheDir() + '/metadata_cache.json';
      // `complete=false` 表示这轮扫描还没跑完：下次全量扫描据它决定是否断点续扫。
      // 扫描结束时再写一次 `complete=true`，从此刻起缓存只用于快速扫描的复用。
      const text = JSON.stringify({ version: 2, savedAt: Date.now(), complete: complete, entries: entries });
      AtomicFile.writeText(path, text);
      this.metadataCacheComplete = complete;
      // 同步内存索引，让同一进程内下一次快速扫描也能复用。
      this.metadataCacheByHandle = new Map<number, PhotoEntry>();
      for (const entry of entries) {
        this.metadataCacheByHandle.set(entry.handle, entry);
      }
      this.metadataCacheSavedAt = Date.now();
      this.log.add(`元数据缓存已保存: ${entries.length} 条` +
        `${complete ? '' : '（扫描未完成，可续扫）'}`);
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

  /**
   * 从 GetThumb 返回的 JPEG 里读 EXIF 方向。
   *
   * 相机没写 EXIF、或属性为空时返回 `null`，调用方回退到「读原图 16KB」。
   * 这里只解析元数据、不解码像素，单张约 1ms。
   */
  private static async readThumbOrientation(data: Uint8Array): Promise<OrientationTransform | null> {
    try {
      const buf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const src = image.createImageSource(buf);
      try {
        const raw = await src.getImageProperty(image.PropertyKey.ORIENTATION);
        if (!raw) return null;
        return CameraService.mapExifOrientation(raw);
      } finally {
        try { src.release(); } catch (_e) { /* best effort */ }
      }
    } catch (_e) {
      return null;
    }
  }

  /**
   * 缩略图 EXIF 方向的取样比对。
   *
   * 只要出现一次不一致，就永久判为不可信（本会话），后续继续逐张读原图；
   * 样本够多且包含竖拍（rotate≠0 或 flip）才敢切换，否则“全是横拍”的
   * 全部一致无法证明什么。
   */
  private trackThumbExif(orig: OrientationTransform, thumb: OrientationTransform): void {
    const same = orig.rotate === thumb.rotate && orig.flipH === thumb.flipH &&
      orig.flipV === thumb.flipV;
    this.thumbExifSamples++;
    if (!same) {
      this.thumbExifMismatch++;
      if (this.thumbExifTrust !== 0) {
        this.thumbExifTrust = 0;
        this.log.add(`缩略图EXIF方向与原图不一致（原图 ${orig.rotate}/${orig.flipH}/${orig.flipV}，` +
          `缩略图 ${thumb.rotate}/${thumb.flipH}/${thumb.flipV}），继续读原图 EXIF`);
      }
      return;
    }
    if (orig.rotate !== 0 || orig.flipH || orig.flipV) {
      this.thumbExifPortrait++;
    }
    if (this.thumbExifTrust === null && this.thumbExifSamples >= 12 && this.thumbExifPortrait >= 3) {
      this.thumbExifTrust = 1;
      this.log.add(`缩略图EXIF方向可信：${this.thumbExifSamples} 个样本（竖拍 ${this.thumbExifPortrait}）` +
        `全部一致，后续跳过 GetPartialObject`);
    }
  }

  /** 把本轮的阶段耗时汇总成一行日志，用来判断下一次该优化哪一段。 */
  private logScanTiming(): void {
    const avg = (ms: number, n: number): string => n > 0 ? `${Math.round(ms / n)}` : '-';
    this.log.add(`扫描耗时: 遍历 ${this.statWalkMs}ms | ` +
      `元数据 ${this.statInfoMs}ms/${this.statInfoCount}张(均${avg(this.statInfoMs, this.statInfoCount)}ms) | ` +
      `缩略图USB ${this.statThumbMs}ms/${this.statThumbCount}张(均${avg(this.statThumbMs, this.statThumbCount)}ms) | ` +
      `EXIF头 ${this.statExifMs}ms/${this.statExifCount}次(均${avg(this.statExifMs, this.statExifCount)}ms) | ` +
      `落盘 ${this.statSaveMs}ms | 解码 ${this.statDecodeMs}ms`);
    const trustText = this.thumbExifTrust === 1 ? '可信（已跳过读原图）'
      : this.thumbExifTrust === 0 ? '不可信（继续读原图）' : '样本不足';
    this.log.add(`缩略图EXIF方向: ${trustText} / 样本 ${this.thumbExifSamples} ` +
      `/ 竖拍 ${this.thumbExifPortrait} / 不一致 ${this.thumbExifMismatch} / 无EXIF ${this.thumbExifMissing}`);
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
        const saveStart = Date.now();
        await this.thumbCache.saveRawThumbnail(cacheKey, modDate, data, handle,
          orient?.rotate ?? 0, orient?.flipH ?? false, orient?.flipV ?? false,
          exifDim?.w, exifDim?.h);
        this.statSaveMs += Date.now() - saveStart;
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
        const decodeStart = Date.now();
        const pixelMap = await taskpool.execute(task) as image.PixelMap;
        this.statDecodeMs += Date.now() - decodeStart;
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

  /** PTP 元数据里的原图长边；未知返回 0。 */
  private photoLongEdge(handle: number): number {
    for (const p of this.photos) {
      if (p.handle === handle) {
        const w = p.imagePixWidth ?? 0;
        const h = p.imagePixHeight ?? 0;
        return Math.max(w, h);
      }
    }
    return 0;
  }

  /**
   * 取一张照片的**原始压缩字节**（相机返回的 JPEG，不重新编码）。
   *
   * 预览器「分享原图」用：优先命中 compressedCache（查看原图时已经取过）；
   * 未命中时复用串行 USB 取图，结果也放进缓存。扫描中直接返回 null，
   * 避免和扫描队列抢同一条 USB 管道。
   */
  async getOriginalBytes(handle: number,
    priority: PtpPriority = PtpPriority.FOREGROUND): Promise<Uint8Array | null> {
    if (this.scanning) return null;
    if (this.compressedCache.has(handle)) {
      return this.compressedCache.get(handle)!;
    }
    if (this.preloadingSet.has(handle)) {
      await this.waitForPreload(handle, 5000);
      if (this.compressedCache.has(handle)) {
        return this.compressedCache.get(handle)!;
      }
    }
    return this.fetchFullPhotoForeground(handle, Date.now(), false, priority);
  }

  async loadFullPhoto(handle: number,
    priority: PtpPriority = PtpPriority.FOREGROUND,
    onPreview?: (pm: image.PixelMap, w: number, h: number) => void): Promise<DecodedPhotoResult | null> {
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

      // 先解一张屏幕级预览：用户很快看到可用的图，3072 全尺寸在后台继续解。
      const srcEdge = this.photoLongEdge(handle);
      const previewUseful = srcEdge <= 0 || srcEdge > PREVIEW_DECODE_MAX_EDGE;
      if (onPreview !== undefined && priority === PtpPriority.FOREGROUND && previewUseful) {
        try {
          const previewBuf = decodeBuf.slice(0);
          const previewTask = new taskpool.Task(
            decodeFullPhotoTask,
            previewBuf,
            orient.rotate,
            orient.flipH,
            orient.flipV,
            PREVIEW_DECODE_MAX_EDGE
          );
          const preview = await taskpool.execute(previewTask) as image.PixelMap;
          const previewInfo = await preview.getImageInfo();
          onPreview(preview, previewInfo.size.width, previewInfo.size.height);
        } catch (_e) {
          // 预览失败不阻塞全尺寸解码
        }
      }

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
      this.log.add(`全尺寸加载失败: handle=0x${handle.toString(16)} ` +
        `${(err as Error).message}`);
      if (err instanceof PtpError && err.code === PTP_ERR_USB) {
        // 取图过程中 USB 链路已经死了：关会话，下一次搜索重新连接，
        // 避免后续每张图都继续打这条死管道。
        this.connected = false;
        this.usable = false;
        await this.session.closeSessionAndPipe();
      }
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
    // 无线会话由 connectWifi() 自己装配，调试开关不应该把它换回 USB/虚拟相机。
    if (this.wireless) return;
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
    // 用户主动断开：撤掉自动重连，避免刚断开就被自己接回来。
    this.wifiAutoReconnectArmed = false;
    this.cancelWifiReconnect();
    await this.session.closeSessionAndPipe();
    if (this.wireless) {
      // 回到 USB 默认实现，下一次「搜索相机」才不会把 USB 端点喂给 Wi-Fi 会话。
      this.session = new PtpScheduler(new PtpSession());
      this.wireless = false;
    }
    this.wifiSession = null;
    this.pairingCode = '';
    this.pairingRequired = false;
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
    this.resetSessionCapabilities();
    this.clearFullCache();
    this.thumbCache.close();
    this.statusText = L10n.tr('camera_status_disconnected');
    this.log.add('已断开连接');
  }

  /**
   * 换相机/断线时清掉「这台相机学到的能力」：换一台相机后，
   * 上一台的 GetObjectPropList 支持情况、缩略图 EXIF 可信度都不再成立。
   */
  private resetSessionCapabilities(): void {
    this.deviceOps = [];
    this.propListProbed = false;
    this.thumbExifTrust = null;
    this.thumbExifSamples = 0;
    this.thumbExifPortrait = 0;
    this.thumbExifMismatch = 0;
    this.thumbExifMissing = 0;
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
   *
   * @returns true 表示已经从磁盘画出缩略图；false 表示这条缓存已失效
   *          （文件被删/读不出来），调用方必须回退到 USB 取图。
   */
  private async loadCachedThumbnail(handle: number, key: string,
    entry: CacheEntry): Promise<boolean> {
    try {
      const filePath = this.thumbCache.getCacheDir() + '/' + entry.cacheFileName;
      const fileBuf: ArrayBuffer | null = await this.thumbCache.readFileToBuffer(filePath);
      if (!fileBuf) {
        // manifest 说命中、磁盘上却没有：把这条记录摘掉，避免下次扫描继续“命中”它。
        this.thumbCache.invalidate(key);
        hilog.info(DOMAIN, TAG, '[CACHE_HIT] stale entry handle=0x%{public}s',
          handle.toString(16));
        return false;
      }

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
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[CACHE_HIT] FAIL handle=0x%{public}s err=%{public}s',
        handle.toString(16), JSON.stringify(err));
      this.log.add(`缓存加载失败: handle=0x${handle.toString(16)}`);
      this.thumbCache.invalidate(key);
      return false;
    }
  }

  formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }
}
