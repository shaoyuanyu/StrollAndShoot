import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { util, taskpool } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import usbManager from '@ohos.usbManager';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { decodeThumbnailTask, decodeFullPhotoTask } from '../workers/ImageDecoder';
import { PtpSession, setPtpLog, type DeviceInfo } from '../pages/PtpHost';
import { AppLog } from './AppLog';
import { GpsRecorder } from './GpsRecorder';
import { ExifGeotagger } from './ExifGeotagger';
import { CameraCachePrefs } from './CameraCachePrefs';
import { ThumbnailCache, type CacheEntry } from './ThumbnailCache';
import type { PhotoEntry, DownloadRecord, DownloadProgress, DownloadResult } from '../model/PhotoEntry';

const DOMAIN = 0x0000;
const TAG = 'CameraService';

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

@ObservedV2
export class CameraService {
  private static instance: CameraService;
  private session: PtpSession = new PtpSession();
  private log: AppLog = new AppLog();

  // State
  @Trace statusText: string = '就绪';
  @Trace cameraName: string = '';
  @Trace photoCount: number = 0;
  @Trace photos: PhotoEntry[] = [];
  @Trace scanning: boolean = false;
  @Trace connected: boolean = false;

  // Thumbnail cache
  thumbnailPixelMapMap: Map<number, image.PixelMap> = new Map();
  thumbnailLoadedSet: Set<number> = new Set();
  @Trace thumbnailVersion: number = 0;

  // Orientation-corrected display dimensions (populated during thumbnail/full decode)
  orientedDisplaySizes: Map<number, OrientedSize> = new Map();

  // Full-resolution compressed cache for preloading
  private compressedCache: Map<number, Uint8Array> = new Map();
  private preloadingSet: Set<number> = new Set();
  private cacheTotalBytes: number = 0;
  private cacheMaxBytes: number = 200 * 1048576;
  private detailIndex: number = -1;
  private prevDetailIndex: number = -1;
  private preloadRadius: number = 5;
  private preloading: boolean = false;

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

    // Parse IFD0 entries (12 bytes each)
    const entryCount = r16(ifd0Off);
    if (isTiff) {
      for (let di = 0; di < entryCount && ifd0Off + 2 + di * 12 + 10 <= bytes.length; di++) {
        const eBase = ifd0Off + 2 + di * 12;
        const tag = r16(eBase);
        const typ = r16(eBase + 2);
        const cnt = r32(eBase + 4);
        const val = r32(eBase + 8);
        hilog.info(DOMAIN, TAG, '[EXIF_PARSE] IFD0[%{public}d] tag=0x%{public}s typ=%{public}d cnt=%{public}d val=%{public}d',
          di, tag.toString(16), typ, cnt, val);
      }
      hilog.info(DOMAIN, TAG, '[EXIF_PARSE] RAW IFD0 entries=%{public}d', entryCount);
    }
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
    } else {
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] no ExifIFD pointer (tag 0x8769) in IFD0: exifIfdOff=%{public}d', exifIfdOff);
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
  private downloadAborted: boolean = false;
  private registryLoaded: boolean = false;

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

  getLogText(): string {
    return this.log.getText();
  }

  initLogPath(dir: string): void {
    this.log.setFilePath(dir + '/app_log.txt');
  }

  initDownloadDir(dir: string): void {
    this.filesDir = dir;
    this.downloadDir = dir;
    this.cachePrefs.init(dir);
    this.loadRegistry();
  }

  makeDownloadKey(filename: string, size: number): string {
    return `${filename}::${size}`;
  }

  isPhotoDownloaded(handle: number): boolean {
    for (const p of this.photos) {
      if (p.handle === handle) {
        return this.downloadRegistry.has(this.makeDownloadKey(p.filename, p.size));
      }
    }
    return false;
  }

  @Trace downloadedCount: number = 0;

  getDownloadedKeys(): string[] {
    const keys: string[] = [];
    for (const p of this.photos) {
      const k = this.makeDownloadKey(p.filename, p.size);
      if (this.downloadRegistry.has(k)) {
        keys.push(k);
      }
    }
    this.downloadedCount = keys.length;
    return keys;
  }

  cancelDownload(): void {
    this.downloadAborted = true;
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
      const key = this.makeDownloadKey(photo.filename, photo.size);

      if (this.downloadRegistry.has(key)) {
        const existing = this.downloadRegistry.get(key)!;
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
      const localPath = this.downloadDir + '/' + localFilename;
      try {
        const f = await fileIo.open(localPath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
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

      let galleryUris: Map<string, string> = new Map();
      try {
        galleryUris = await this.moveToGallery(sandboxSuccesses, context);
      } catch (err) {
        this.log.add(`保存到相册失败: ${JSON.stringify(err)}`);
      }

      // Persist registry for photos successfully saved to Gallery
      for (const r of sandboxSuccesses) {
        if (this.downloadRegistry.has(r.key)) {
          continue;
        }
        const galleryUri = galleryUris.get(r.key);
        if (!galleryUri) {
          this.log.add(`注册跳过(无Gallery URI): ${r.key}`);
          continue;
        }
        const photo = batch.find((p: PhotoEntry) => p.handle === r.handle);
        if (!photo) continue;
        const record: DownloadRecord = {
          key: r.key,
          filename: photo.filename,
          size: photo.size,
          localPath: galleryUri,
          downloadDate: new Date().toISOString()
        };
        this.downloadRegistry.set(r.key, record);
      }
      await this.saveRegistry();
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

    return results;
  }

  /**
   * Moves successfully downloaded sandbox files to the system Gallery
   * via showAssetsCreationDialog. User confirms once for all files.
   * Returns a map from download key to Gallery URI for successfully copied files.
   */
  private async moveToGallery(
    sandboxResults: DownloadResult[],
    context: common.UIAbilityContext
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
    const desFileUris = await phAccessHelper.showAssetsCreationDialog(
      srcFileUris, photoCreationConfigs
    );

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

  private async loadRegistry(): Promise<void> {
    if (this.registryLoaded) return;
    const path = this.downloadDir + '/download_registry.json';
    try {
      const f = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      const stat = await fileIo.stat(path);
      const buf = new ArrayBuffer(stat.size);
      await fileIo.read(f.fd, buf);
      await fileIo.close(f);
      const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
      const obj = JSON.parse(text) as Record<string, DownloadRecord>;
      for (const k of Object.keys(obj)) {
        this.downloadRegistry.set(k, obj[k]);
      }
      this.log.add(`加载下载记录: ${this.downloadRegistry.size} 条`);
    this.registryVersion++;
    } catch (_e) {
      // File doesn't exist yet — registry stays empty
    }
    this.registryLoaded = true;

    // Prune entries whose Gallery files no longer exist (e.g. user deleted from Album)
    await this.validateRegistry();
  }

  /**
   * Validates the persisted download registry against actual filesystem state.
   * Removes entries for files that have been deleted from Gallery.
   */
  private async validateRegistry(): Promise<void> {
    const keys: string[] = [];
    this.downloadRegistry.forEach((_record: DownloadRecord, key: string) => {
      keys.push(key);
    });
    const stale: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const record = this.downloadRegistry.get(key);
      if (!record) continue;
      try {
        const f = await fileIo.open(record.localPath, fileIo.OpenMode.READ_ONLY);
        await fileIo.close(f);
      } catch (_e) {
        stale.push(key);
      }
    }
    if (stale.length > 0) {
      for (let i = 0; i < stale.length; i++) {
        this.downloadRegistry.delete(stale[i]);
      }
      this.log.add(`下载记录清理: 移除 ${stale.length} 条失效记录`);
      await this.saveRegistry();
    }
  }

  private async saveRegistry(): Promise<void> {
    const obj: Record<string, DownloadRecord> = {};
    this.downloadRegistry.forEach((v: DownloadRecord, k: string) => { obj[k] = v; });
    const text = JSON.stringify(obj);
    const path = this.downloadDir + '/download_registry.json';
    try {
      const f = await fileIo.open(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.write(f.fd, text);
      await fileIo.close(f);
    this.registryVersion++;
    } catch (err) {
      this.log.add(`保存下载记录失败: ${JSON.stringify(err)}`);
    }
  }

  async scanForCamera(quickMode: boolean = true): Promise<void> {
    this.scanning = true;
    this.log.clear();
    this.log.add('=== 开始扫描 ===');

    this.statusText = '正在搜索USB相机...';


    try {
      const cameras = PtpSession.findCameras();
      if (cameras.length === 0) {
        this.statusText = '未检测到USB相机';
        this.connected = false;
        this.cameraName = '';
        this.scanning = false;

        return;
      }

      const sameDevice = this.connected &&
        this.session.connectedDeviceName === cameras[0].name;

      if (sameDevice) {
        // Same camera — clear cached data, keep USB session alive
        this.photos = [];
        this.photoCount = 0;
        this.thumbnailPixelMapMap.clear();
        this.thumbnailLoadedSet.clear();
        this.preloadedOrientations.clear();
        this.exifOrigDims.clear();
        this.orientationMap.clear();
        this.orientedDisplaySizes.clear();
        this.clearFullCache();
        this.statusText = '已连接';

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

        this.statusText = `发现相机: ${cameras[0].productName}`;
    

        const ok = await this.session.connect(cameras[0]);
        if (!ok) {
          this.statusText = '连接相机失败';
          this.connected = false;
          this.scanning = false;
      
          return;
        }

        this.cameraName = cameras[0].productName || cameras[0].manufacturerName ||
                          cameras[0].name;
        this.statusText = '已连接';
        this.connected = true;

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

      // If camera is new and caching dialog is required, wait for user
      // choice before scanning. setCachingPreference will trigger scan.
      if (this.cachingDialogRequired) {
        this.statusText = `请选择缓存设置...`;
        this.scanning = false;
        return;
      }

      // Phase 0: deploy cached snapshot (quick mode only, caching enabled, known camera)
      if (quickMode && this.cachingEnabled && this.cameraIdentity &&
          this.cachePrefs.hasCamera(this.cameraIdentity)) {
        this.log.add('[快速扫描] 部署缓存快照...');
        this.statusText = '正在加载缓存...';
        await this.deployCacheSnapshot();
        this.log.add(`[快速扫描] 缓存快照就绪: ${this.photoCount} 张`);
      }

      // scanning stays true for the entire scan (Phase 1 → 2a → 2b)
      this.scanning = true;
      this.statusText = '正在扫描...';

      // Phase 1 + 2a + 2b (replaces old loadPhotosAndThumbnails)
      await this.loadPhotosAndThumbnails(quickMode);

      // Defer registry validation so UI becomes responsive immediately
      this.validateRegistry().catch((_e: Error) => { /* best effort */ });
    } catch (err) {
      hilog.error(DOMAIN, TAG, `scan error: ${JSON.stringify(err)}`);
      this.statusText = '扫描出错';
      this.connected = false;
    } finally {
      this.scanning = false;

    }
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
          const info = await this.session.getObjectInfo(h);
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
   */
  private async loadPhotosAndThumbnails(_quickMode: boolean): Promise<void> {
    this.statusText = '正在获取照片列表...';
    this.photoCount = 0;
    this.scanProgress = 0;
    this.scanTotal = 0;


    try {
      const storageIDs = await this.session.getStorageIDs();
      hilog.info(DOMAIN, TAG, `StorageIDs count: ${storageIDs.length}`);

      if (storageIDs.length === 0) {
        this.photoCount = 0;
        this.photos = [];
        this.statusText = '已连接 (无存储设备)';
    
        return;
      }

      // ---- Phase 1: traverse directories (2 getObjectHandles per level) ----
      this.statusText = '正在遍历目录...';
      this.formatFilterWorks = null; // re-detect for this connection
  

      const allHandles = await this.collectPhotoHandles(storageIDs, 0xFFFFFFFF, 0,
        (count: number) => {
          this.photoCount += count;
      
        });
      const handles = allHandles;
      // TEST: only load first 300 photos
      // const handles = allHandles.slice(0, 300);

      hilog.info(DOMAIN, TAG, `ObjectHandles total: ${allHandles.length}`);

      // ---- Phase 2a: getObjectInfo + sort (metadata only) ----
      this.log.add(`开始加载 ${handles.length} 张照片元数据...`);
      this.scanProgress = 0;
      this.scanTotal = handles.length;
      this.scanPhaseText = '获取元数据';
      this.statusText = '正在获取元数据...';
  

      const photoList: PhotoEntry[] = [];
      const validCacheKeys: Set<string> = new Set();
      let statsInfoOk = 0;

      // Initialize thumbnail cache if enabled
      if (this.cameraIdentity) {
        this.thumbCache.init(this.filesDir, this.cameraIdentity);
        if (this.cachingEnabled) {
          await this.thumbCache.loadManifest();
          this.log.add('缩略图缓存已加载');
        }
        hilog.info(DOMAIN, TAG, '[CACHE] init done en=%{public}s id=%{public}s', this.cachingEnabled.toString(), this.cameraIdentity);
      }

      for (let i = 0; i < handles.length; i++) {
        const h = handles[i];

        const info = await this.session.getObjectInfo(h);
        if (info) {
          statsInfoOk++;
          photoList.push({
            handle: h,
            filename: info.filename,
            size: info.objectCompressedSize,
            objectFormat: info.objectFormat,
            captureDate: info.captureDate || '',
            modificationDate: info.modificationDate || '',
            imagePixWidth: info.imagePixWidth || 0,
            imagePixHeight: info.imagePixHeight || 0,
            storageId: info.storageId || 0
          });
        }

        const cacheKey = info ? `${info.filename}::${info.objectCompressedSize}` : '';
        if (cacheKey) validCacheKeys.add(cacheKey);

        this.scanProgress = i + 1;
      }

      // Sort: captureDate DESC → modificationDate DESC → handle DESC
      photoList.sort((a: PhotoEntry, b: PhotoEntry): number => {
        const da = a.captureDate || '';
        const db = b.captureDate || '';
        if (da !== db) return db.localeCompare(da);
        const ma = a.modificationDate || '';
        const mb = b.modificationDate || '';
        if (ma !== mb) return mb.localeCompare(ma);
        return b.handle - a.handle;
      });

      // cleanupStaleMemoryCache: remove entries for deleted photos
      {
        const validHandles = new Set<number>();
        for (const p of photoList) {
          validHandles.add(p.handle);
        }
        this.cleanupStaleMemoryCache(validHandles);
      }

      // Replace photos (triggers gallery refresh via photosVersion++)
      this.photos = photoList;
      this.photoCount = photoList.length;
      this.photosVersion++;

      // Persist metadata cache for next quick scan
      if (this.cameraIdentity && this.cachingEnabled) {
        this.saveMetadataCache(photoList);
      }

      this.log.add(`元数据获取完成: ${photoList.length} 张`);

      // ---- Phase 2b: load thumbnails, row by row ----
      this.scanPhaseText = '加载缩略图';
      this.statusText = '正在加载缩略图...';
      await this.loadThumbnailsRowByRow(validCacheKeys);

      // Compute scan stats for UI display
      {
        const total = this.photoCount;
        this.scanStatsText = `照片${total} | 扫描完成`;
        this.log.add(this.scanStatsText);
      }

      this.log.add('缩略图加载完成');

      this.statusText = `已连接 - ${this.photoCount} 张照片`;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `loadPhotos error: ${JSON.stringify(err)}`);
      this.statusText = '加载照片失败';
      this.scanStatsText = '';
    } finally {
      this.scanProgress = 0;
      this.scanTotal = 0;
  
    }
  }

  /**
   * Phase 2b: load thumbnails row by row (row width ≈ column count).
   * After each row is fully loaded, bump thumbnailVersion so GalleryPage
   * re-evaluates row completeness and shows the row all at once.
   */
  private async loadThumbnailsRowByRow(
    validCacheKeys: Set<string>
  ): Promise<void> {
    const photos = this.photos;
    if (photos.length === 0) return;

    // Determine row width: use gallery column count (default 4)
    // The caller passes a reasonable default since we can't access display here.
    const rowWidth = 4;

    let totalLoaded = 0;
    const totalToLoad = photos.length;
    this.scanProgress = 0;
    this.scanTotal = totalToLoad;
    this.lastDecodedHandle = -1;

    for (let batchStart = 0; batchStart < totalToLoad; batchStart += rowWidth) {
      const batchEnd = Math.min(batchStart + rowWidth, totalToLoad);
      const rowPromises: Promise<void>[] = [];
      let hasNewLoads = false;

      for (let i = batchStart; i < batchEnd; i++) {
        const photo = photos[i];

        // Already loaded (from Phase 0 deployCacheSnapshot or prior scan)
        if (this.thumbnailLoadedSet.has(photo.handle)) {
          totalLoaded++;
          continue;
        }

        // Check disk cache first
        const key = `${photo.filename}::${photo.size}`;
        const modDate = photo.modificationDate || '';

        if (this.cachingEnabled && key) {
          const cachedEntry = this.thumbCache.findCached(key, modDate);
          if (cachedEntry) {
            rowPromises.push(this.loadCachedThumbnail(photo.handle, cachedEntry.cacheFileName));
            totalLoaded++;
            continue;
          }
        }

        // Need USB: getThumb + EXIF + decode
        hasNewLoads = true;
        rowPromises.push(this.loadSingleThumbnail(photo, key, modDate));
      }

      if (rowPromises.length > 0) {
        await Promise.all(rowPromises);
      }

      // Row complete: bump thumbnailVersion so GalleryPage re-evaluates rowComplete
      if (hasNewLoads) {
        this.thumbnailVersion++;
      }

      // Update lastDecodedHandle for PhotoViewer on-screen refresh
      for (let i = batchStart; i < batchEnd; i++) {
        if (i < totalToLoad && this.thumbnailLoadedSet.has(photos[i].handle)) {
          this.lastDecodedHandle = photos[i].handle;
          break; // Only need one
        }
      }

      this.scanProgress = batchEnd;

      if (!this.connected) break;
    }

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
   */
  private async loadSingleThumbnail(
    photo: PhotoEntry,
    cacheKey: string,
    modDate: string
  ): Promise<void> {
    try {
      const h = photo.handle;
      // Skip GetPartialObject — orientation extraction is done inline here
      const thumbData = await this.session.getThumb(h);
      if (!thumbData || thumbData.length === 0) {
        this.log.add(`[NO_THUMB] handle=0x${h.toString(16)} ${photo.filename}`);
        return;
      }

      // Read EXIF orientation from 16KB header
      const partial = await this.session.getPartialObject(h, 0, 16384);
      if (partial && partial.length > 0) {
        try {
          const orient = await this.getOrientation(h, partial.buffer as ArrayBuffer);
          this.preloadedOrientations.set(h, orient);
          const parsed = CameraService.parseExifDims(partial.buffer as ArrayBuffer);
          if (parsed) {
            this.exifOrigDims.set(h, parsed);
          }
        } catch (_e) { /* best effort */ }
      }

      // Decode and save to cache
      await this.decodeThumbnail(h, thumbData, cacheKey, modDate);

      // Save raw thumb to disk cache
      if (this.cachingEnabled && cacheKey) {
        const dims = this.exifOrigDims.get(h);
        this.scheduleCacheSave(cacheKey, modDate, thumbData, dims?.w, dims?.h);
      }
    } catch (err) {
      this.log.add(`缩略图加载失败: ${photo.filename} ${JSON.stringify(err)}`);
    }
  }

  async loadThumbnail(handle: number): Promise<void> {
    if (this.thumbnailLoadedSet.has(handle)) return;
    try {
      const data = await this.session.getThumb(handle);
      if (data && data.length > 0) {
        await this.decodeThumbnail(handle, data);
        this.thumbnailVersion++;
      }
    } catch (err) {
      this.log.add(`缩略图解码失败: handle=0x${handle.toString(16)}`);
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
        cacheLoads.push(this.loadCachedThumbnail(entry.handle, cached.cacheFileName));
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
    try {
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        fileIo.closeSync(f);
        return null;
      }
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
      const raw: Record<string, Object> = JSON.parse(text);
      const rawEntries = raw['entries'] as PhotoEntry[] | undefined;
      if (rawEntries && rawEntries.length > 0) {
        this.log.add(`元数据缓存加载: ${rawEntries.length} 条`);
        return rawEntries;
      }
    } catch (_e) {
      // File doesn't exist yet
    }
    return null;
  }

  /** Persist PhotoEntry[] to metadata_cache.json */
  private saveMetadataCache(entries: PhotoEntry[]): void {
    if (!this.cameraIdentity) return;
    const path = this.thumbCache.getCacheDir() + '/metadata_cache.json';
    try {
      fileIo.mkdirSync(this.thumbCache.getCacheDir(), true);
    } catch (_e) { /* best effort */ }
    try {
      const text = JSON.stringify({ entries: entries });
      const f = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
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
        const msg = `[TASKPOOL_THUMB] handle=0x${handle.toString(16)} done ${info.size.width}x${info.size.height}`;
        hilog.info(DOMAIN, TAG, '%{public}s', msg);
        this.log.add(msg);

        // Re-encode the cropped PixelMap and overwrite the raw cache entry,
        // so future cache hits load a black-bar-free thumbnail directly.
        if (this.cachingEnabled && cacheKey && modDate) {
          const orient = this.preloadedOrientations.get(handle);
          const dims = this.exifOrigDims.get(handle);
          this.thumbCache.saveEncodedThumbnail(
            cacheKey, modDate, pixelMap, handle,
            orient?.rotate, orient?.flipH, orient?.flipV,
            dims?.w, dims?.h
          ).catch((_e: Error) => { /* best effort */ });
        }
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

  async loadFullPhoto(handle: number): Promise<DecodedPhotoResult | null> {
    try {
      const t0 = Date.now();
      let data: Uint8Array | null = null;
      let hit = false;

      if (this.compressedCache.has(handle)) {
        data = this.compressedCache.get(handle)!;
        hit = true;
      } else if (this.preloadingSet.has(handle)) {
        // Being preloaded, wait up to 5s for cache
        for (let i = 0; i < 25; i++) {
          await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 200); });
          if (this.compressedCache.has(handle)) {
            data = this.compressedCache.get(handle)!;
            hit = true;
            break;
          }
        }
        if (!data) {
          // Timeout — download directly
          this.preloadingSet.add(handle);
          data = await this.session.getObject(handle);
          this.preloadingSet.delete(handle);
          if (!data || data.length === 0) return null;
          const t1 = Date.now();
          const sizeMB = (data.length / 1048576).toFixed(1);
          const usbSec = ((t1 - t0) / 1000).toFixed(1);
          this.log.add(`USB下载(等超时): ${sizeMB}MB ${usbSec}s`);
          this.addToCache(handle, data);
        }
      } else {
        this.preloadingSet.add(handle);
        data = await this.session.getObject(handle);
        this.preloadingSet.delete(handle);
        if (!data || data.length === 0) return null;
        const t1 = Date.now();
        const sizeMB = (data.length / 1048576).toFixed(1);
        const usbSec = ((t1 - t0) / 1000).toFixed(1);
        this.log.add(`USB下载: ${sizeMB}MB ${usbSec}s`);
        this.addToCache(handle, data);
      }

      // 读取 EXIF 方向（主线程读取元数据，很快）
      const orient = await this.getPhotoOrientation(handle, data.buffer as ArrayBuffer);

      // 为 TaskPool 克隆一份 ArrayBuffer，主线程保留原始数据用于缓存
      const decodeBuf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);

      const task = new taskpool.Task(
        decodeFullPhotoTask,
        decodeBuf,
        orient.rotate,
        orient.flipH,
        orient.flipV
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
      this.log.add(`${tag}: ${((t2 - t0) / 1000).toFixed(1)}s`);

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

  /**
   * Read the actual pixelMap dimensions and cache them (post-rotation/flip).
   * For 90°/270° rotation the display aspect ratio is swapped vs PTP ObjectInfo.
   */
  private async cacheOrientedSize(handle: number, pixelMap: image.PixelMap, _orient: OrientationTransform): Promise<void> {
    try {
      const info = await pixelMap.getImageInfo();
      this.orientedDisplaySizes.set(handle, new OrientedSize(info.size.width, info.size.height));
    } catch (_err) {
      // Fallback: skip — ZoomableImage will use PTP ObjectInfo dimensions
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
    let furthestHandle = 0;
    let maxDist = -1;
    this.compressedCache.forEach((_v: Uint8Array, k: number) => {
      const dist = Math.abs(k - this.detailIndex);
      if (dist > maxDist) { maxDist = dist; furthestHandle = k; }
    });
    if (furthestHandle !== 0) {
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
      const photo = this.preloadPhotos[qi];
      if (!photo) continue;
      if (this.compressedCache.has(photo.handle)) continue;
      if (this.preloadingSet.has(photo.handle)) continue;
      this.preloadingSet.add(photo.handle);
      try {
        const data = await this.session.getObject(photo.handle);
        if (data && data.length > 0) {
          this.addToCache(photo.handle, data);
          const sizeMB = (data.length / 1048576).toFixed(1);
          this.log.add(`预加载[${qi}]: ${sizeMB}MB (缓存${this.compressedCache.size}张/${(this.cacheTotalBytes/1048576).toFixed(0)}MB)`);
        }
      } catch (_e) {
        // preload failure is non-critical
      }
      this.preloadingSet.delete(photo.handle);
    }
    this.preloading = false;
  }

  cancelPreload(): void {
    if (this.preloadTimer >= 0) {
      clearTimeout(this.preloadTimer);
      this.preloadTimer = -1;
    }
    this.preloading = false;
    this.preloadingSet.clear();
  }

  clearFullCache(): void {
    this.compressedCache.clear();
    this.preloadingSet.clear();
    this.cacheTotalBytes = 0;
    this.detailIndex = -1;
    this.prevDetailIndex = -1;
    this.preloadPhotos = [];
  }

  async disconnect(): Promise<void> {
    await this.session.closeSessionAndPipe();
    this.connected = false;
    this.cameraName = '';
    this.cameraIdentity = '';
    this.deviceManufacturer = '';
    this.deviceSerialNumber = '';
    this.deviceVersion = '';
    this.usbVidPid = '';
    this.usbSerialNumber = '';
    this.cachingEnabled = false;
    this.cachingDialogRequired = false;
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
    this.clearFullCache();
    if (this.cachingEnabled) {
      this.thumbCache.flush().catch((_e: Error) => {});
    }
    this.thumbCache.close();
    this.statusText = '已断开连接';
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
  private checkCachingState(): void {
    if (!this.cameraIdentity) {
      this.cachingEnabled = false;
      this.cachingDialogRequired = false;
      return;
    }
    const pref = this.cachePrefs.get(this.cameraIdentity);
    if (!pref) {
      // New camera: cache FIRST during scan, prompt AFTER scan completes.
      // This ensures ALL photos are cached regardless of when user taps dialog.
      this.pendingCamIdForDialog = this.cameraIdentity;
      this.pendingCamNameForDialog = this.cameraName;
      this.cachingEnabled = true;
      this.cachingDialogRequired = true;
      this.thumbCache.init(this.filesDir, this.cameraIdentity);
      this.log.add(`新相机 ${this.cameraName}，先缓存后询问`);
      return;
    }
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
   * Called from MainScreen after the user responds to the caching dialog.
   */
  setCachingPreference(cameraId: string, enabled: boolean): void {
    this.cachePrefs.set(cameraId, this.pendingCamNameForDialog, enabled);
    this.cachingDialogRequired = false;
    this.cachingEnabled = enabled;
    this.log.add(enabled ? `用户已启用缓存: ${this.cameraName}` : `用户拒绝缓存: ${this.cameraName}`);
    // Start the delayed scan now that user has decided
    if (this.cameraIdentity === cameraId) {
      this.scanForCamera();
    }
  }

  /**
   * Load a thumbnail from the disk-based ThumbnailCache.
   * Used instead of USB GetThumb when a valid cache entry exists.
   */
  private async loadCachedThumbnail(handle: number, cacheFileName: string): Promise<void> {
    try {
      const filePath = this.thumbCache.getCacheDir() + '/' + cacheFileName;
      const fileBuf: ArrayBuffer | null = await this.thumbCache.readFileToBuffer(filePath);
      if (!fileBuf) return;

      // Cache thumbnails are already rotate+flip+crop corrected.
      // Just decode in TaskPool (no transforms) to keep UI responsive.
      const decodeBuf = fileBuf.slice(0);
      const task = new taskpool.Task(decodeThumbnailTask, decodeBuf, 0, false, false, 0, 0);
      const pixelMap = await taskpool.execute(task) as image.PixelMap;
      const info = await pixelMap.getImageInfo();
      this.orientedDisplaySizes.set(handle, new OrientedSize(info.size.width, info.size.height));
      this.thumbnailPixelMapMap.set(handle, pixelMap);
      this.thumbnailLoadedSet.add(handle);
      this.log.add(`[CACHE_HIT] handle=0x${handle.toString(16)} ${info.size.width}x${info.size.height}`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[CACHE_HIT] FAIL handle=0x%{public}s err=%{public}s',
        handle.toString(16), JSON.stringify(err));
      this.log.add(`缓存加载失败: handle=0x${handle.toString(16)}`);
    }
  }

  /**
   * Asynchronously save raw thumbnail data to the disk cache.
   * Fire-and-forget: does not block the scan loop.
   */
  private scheduleCacheSave(key: string, modDate: string, thumbData: Uint8Array,
    origWidth?: number, origHeight?: number): void {
    this.thumbCache.saveRawThumbnail(key, modDate, thumbData, origWidth, origHeight)
      .catch((_e: Error) => {
        this.log.add(`缓存写入失败: ${key}`);
      });
  }

  formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }
}
