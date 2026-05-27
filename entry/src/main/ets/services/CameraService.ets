import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { PtpSession, setPtpLog } from '../pages/PtpHost';
import { AppLog } from './AppLog';
import { GpsRecorder } from './GpsRecorder';
import { ExifGeotagger } from './ExifGeotagger';
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
    if (!isTiff) {
      // Must be JPEG — find APP1/Exif marker
      if (bytes[0] !== 0xFF || bytes[1] !== 0xD8) {
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
      if (off >= bytes.length - 14) return null;
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
    if (r16(off + 2) !== 0x002A) return null;

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
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] no ExifIFD pointer (tag 0x8769) in IFD0');
    }

    if (imgW > 0 && imgH > 0) {
      hilog.info(DOMAIN, TAG, '[EXIF_PARSE] ExifIFD found %{public}dx%{public}d', imgW, imgH);
      return new OrientedSize(imgW, imgH);
    }
    hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] failed IFD0 W=%{public}d H=%{public}d exifOff=%{public}d', imgW, imgH, exifIfdOff);
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
    this.downloadDir = dir;
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

  async scanForCamera(): Promise<void> {
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

      }

      await this.loadPhotosAndThumbnails();

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
  private async loadPhotosAndThumbnails(): Promise<void> {
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
      // TEST: only load first 150 photos
      const handles = allHandles.slice(0, 150);

      hilog.info(DOMAIN, TAG, `ObjectHandles total: ${allHandles.length}, limited to: ${handles.length}`);

      // ---- Phase 2: getObjectInfo + getThumb in a single pass ----
      this.log.add(`开始加载 ${handles.length} 张照片...`);
      this.scanProgress = 0;
      this.scanTotal = handles.length;
      this.statusText = '正在加载照片...';
  

      const decodeJobs: Promise<void>[] = [];
      const photoList: PhotoEntry[] = [];

      for (let i = 0; i < handles.length; i++) {
        const h = handles[i];

        const info = await this.session.getObjectInfo(h);
        if (info) {
          photoList.push({
            handle: h,
            filename: info.filename,
            size: info.objectCompressedSize,
            objectFormat: info.objectFormat,
            captureDate: info.captureDate || '',
            imagePixWidth: info.imagePixWidth || 0,
            imagePixHeight: info.imagePixHeight || 0,
            storageId: info.storageId || 0
          });
        }

        // Fetch thumbnail raw data first
        let thumbData: Uint8Array | null = null;
        if (!this.thumbnailLoadedSet.has(h)) {
          thumbData = await this.session.getThumb(h);
        }

        // Pre-read first 16KB via GetPartialObject to extract EXIF Orientation
        // and original image dimensions (ImageWidth/ImageLength).
        // If the camera doesn't support GetPartialObject, this gracefully fails
        // and the thumbnail will decode without orientation correction.
        const partial = await this.session.getPartialObject(h, 0, 16384);
        if (partial && partial.length > 0) {
          try {
            const orient = await this.getOrientation(h, partial.buffer as ArrayBuffer);
            if (orient.rotate !== 0 || orient.flipH || orient.flipV) {
              this.preloadedOrientations.set(h, orient);
              hilog.info(DOMAIN, TAG, `[PARTIAL_ORIENT] handle=0x%{public}s rotate=%{public}d flipH=%{public}s flipV=%{public}s`,
                h.toString(16), orient.rotate, orient.flipH.toString(), orient.flipV.toString());
            }
            // Use manual EXIF parsing (faster than getImageInfo, works on 16KB)
            const parsed = CameraService.parseExifDims(partial.buffer as ArrayBuffer);
            if (parsed) {
              this.exifOrigDims.set(h, parsed);
              this.log.add(`[EXIF_DIMS] handle=0x${h.toString(16)} parsed=${parsed.w}x${parsed.h}`);
            }
            // Dump IFD0 + NextIFD chain to persistent log for diagnosis (RAW/tiff only)
            if (partial && partial.length > 12) {
              const raw = new Uint8Array(partial.buffer as ArrayBuffer);
              if ((raw[0] === 0x49 && raw[1] === 0x49) || (raw[0] === 0x4D && raw[1] === 0x4D)) {
                const le = (raw[0] === 0x49);
                const r16 = (p: number) => (p + 2 > raw.length) ? 0 : le ? (raw[p] | (raw[p+1] << 8)) : ((raw[p] << 8) | raw[p+1]);
                const r32 = (p: number) => (p + 4 > raw.length) ? 0 : le ? (raw[p] | (raw[p+1] << 8) | (raw[p+2] << 16) | (raw[p+3] << 24)) : ((raw[p] << 24) | (raw[p+1] << 16) | (raw[p+2] << 8) | raw[p+3]);
                if (r16(2) === 0x002A) {
                  const tiffBase = r32(4); // IFD0 offset is absolute from TIFF header start
                  let nextOff = tiffBase;
                  let ifdIdx = 0;
                  while (nextOff > 0 && nextOff + 2 < raw.length && ifdIdx < 5) {
                    const eCnt = r16(nextOff);
                    const nxt = r32(nextOff + 2 + eCnt * 12); // NextIFD offset (absolute)
                    let ifdDump = '';
                    for (let di = 0; di < eCnt && nextOff + 2 + di * 12 + 10 < raw.length; di++) {
                      const b = nextOff + 2 + di * 12;
                      const tag = r16(b);
                      if (di > 0) ifdDump += ';';
                      ifdDump += `t0x${tag.toString(16)}:T${r16(b+2)}:C${r32(b+4)}:V${r32(b+8)}`;
                    }
                    this.log.add(`[IFD_CHAIN] handle=0x${h.toString(16)} IFD#${ifdIdx} off=${nextOff} entries=${eCnt} next=${nxt} ${ifdDump}`);
                    nextOff = nxt;
                    ifdIdx++;
                  }
                  // SubIFD fallback: scan IFD0 for 0x014A, parse offset array,
                  // fetch SubIFD via second GetPartialObject to read 0x0100/0x0101
                  if (!this.exifOrigDims.has(h)) {
                    const ifd0Off = tiffBase;
                    const eCnt = r16(ifd0Off);
                    for (let i = 0; i < eCnt && ifd0Off + 2 + (i+1) * 12 <= raw.length; i++) {
                      const b = ifd0Off + 2 + i * 12;
                      if (r16(b) === 0x014A && r16(b+2) === 4) {
                        const cnt = r32(b+4);
                        const arrOff = r32(b+8);
                        if (cnt > 0 && arrOff > 0 && arrOff + cnt * 4 <= raw.length) {
                          for (let si = 0; si < cnt; si++) {
                            const subOff = r32(arrOff + si * 4);
                            if (subOff < 100) continue;
                            try {
                              const sub = await this.session.getPartialObject(h, subOff, 8192);
                              if (sub && sub.length > 20) {
                                const sr = new Uint8Array(sub.buffer as ArrayBuffer);
                                const scnt = le ? (sr[0] | (sr[1] << 8)) : ((sr[0] << 8) | sr[1]);
                                let sw = 0, sh = 0;
                                for (let j = 0; j < scnt && 2 + (j+1) * 12 <= sr.length; j++) {
                                  const sb = 2 + j * 12;
                                  const stag = le ? (sr[sb] | (sr[sb+1] << 8)) : ((sr[sb] << 8) | sr[sb+1]);
                                  const sv = le ? (sr[sb+8] | (sr[sb+9] << 8) | (sr[sb+10] << 16) | (sr[sb+11] << 24))
                                              : ((sr[sb+8] << 24) | (sr[sb+9] << 16) | (sr[sb+10] << 8) | sr[sb+11]);
                                  if (stag === 0x0100) sw = sv;
                                  if (stag === 0x0101) sh = sv;
                                }
                                if (sw > 100 && sh > 100) {
                                  this.exifOrigDims.set(h, new OrientedSize(sw, sh));
                                  this.log.add(`[SUBIFD_DIMS] handle=0x${h.toString(16)} idx=${si} off=${subOff} ${sw}x${sh}`);
                                  break; // found dimensions, stop iterating SubIFDs
                                }
                              }
                            } catch (_eSub) { /* try next SubIFD */ }
                          }
                        }
                        break; // found 0x014A, stop iterating IFD0
                      }
                    }
                  }
                }
              }
            }
          } catch (_e) {
            // Not supported / data incomplete — skip orientation
          }
        }

        // Decode thumbnail AFTER preloadedOrientations is populated
        if (thumbData && thumbData.length > 0) {
          decodeJobs.push(this.decodeThumbnail(h, thumbData));
        }

        this.scanProgress = i + 1;
      }

      this.photos = photoList;
      this.photosVersion++;

      await Promise.all(decodeJobs);
      this.thumbnailVersion++;
      this.log.add('缩略图加载完成');

      this.statusText = `已连接 - ${this.photoCount} 张照片`;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `loadPhotos error: ${JSON.stringify(err)}`);
      this.statusText = '加载照片失败';
    } finally {
      this.scanProgress = 0;
      this.scanTotal = 0;
  
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

  private async decodeThumbnail(handle: number, data: Uint8Array): Promise<void> {
    try {
      // Check if orientation was pre-loaded via GetPartialObject during scan.
      // If so, apply rotate/flip in one pass so thumbnails display correctly
      // immediately, without waiting for full photo load + re-decode.
      const orient = this.preloadedOrientations.get(handle);
      const needsFlip = orient ? (orient.flipH || orient.flipV) : false;
      const needsRotate = orient ? (orient.rotate !== 0) : false;

      const imageSource = image.createImageSource(data.buffer as ArrayBuffer);
      const pixelMap = await imageSource.createPixelMap({ editable: needsFlip || needsRotate });
      if (needsRotate) {
        await pixelMap.rotate(orient!.rotate);
      }
      if (needsFlip) {
        pixelMap.flip(orient!.flipH, orient!.flipV);
      }

      // Crop to pure content (remove only black bars, keep aspect ratio).
      // Gallery/strip use objectFit(ImageFit.Cover) to fill square cells;
      // the main viewer uses Contain to display the full content naturally.
      const imgInfo = await pixelMap.getImageInfo();
      const tw = imgInfo.size.width;
      const th = imgInfo.size.height;

      let cropW: number;
      let cropH: number;
      const exifDim = this.exifOrigDims.get(handle);
      if (exifDim) {
        let origW = exifDim.w;
        let origH = exifDim.h;
        // Swap EXIF dimensions if orientation involves 90°/270° rotation
        if (orient && (orient.rotate === 90 || orient.rotate === 270)) {
          const tmp = origW;
          origW = origH;
          origH = tmp;
        }
        // Compute natural content size: original photo downscaled to fit
        // within the thumbnail canvas (camera then padded to canvas size).
        const scale = Math.min(tw / origW, th / origH);
        cropW = Math.floor(origW * scale);
        cropH = Math.floor(origH * scale);
        const msg = `[CROP] handle=0x${handle.toString(16)} thumb=${tw}x${th} orig=${origW}x${origH} content=${cropW}x${cropH}`;
        hilog.info(DOMAIN, TAG, '%{public}s', msg);
        this.log.add(msg);
      } else {
        // No dimensions available — passthrough (no crop).
        const msg = `[CROP] handle=0x${handle.toString(16)} no-dims passthrough=${tw}x${th}`;
        hilog.warn(DOMAIN, TAG, '%{public}s', msg);
        this.log.add(msg);
        cropW = tw;
        cropH = th;
      }

      const region: image.Region = {
        x: Math.floor((tw - cropW) / 2),
        y: Math.floor((th - cropH) / 2),
        size: { width: cropW, height: cropH }
      };
      const cropped = await pixelMap.createCroppedAndScaledPixelMap(region, 1.0, 1.0);
      pixelMap.release();
      this.thumbnailPixelMapMap.set(handle, cropped);
      this.orientedDisplaySizes.set(handle, new OrientedSize(cropW, cropH));
      this.thumbnailLoadedSet.add(handle);
      imageSource.release();
    } catch (err) {
      hilog.error(DOMAIN, TAG, `[THUMB_CROP] FAIL handle=0x%{public}s err=%{public}s`,
        handle.toString(16), JSON.stringify(err));
      this.log.add(`缩略图解码失败: handle=0x${handle.toString(16)}`);
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

      // Decode with orientation correction
      const imageSource = image.createImageSource(data.buffer as ArrayBuffer);
      const orient = await this.getPhotoOrientation(handle, data.buffer as ArrayBuffer);
      // pixelMap.rotate() swaps BOTH pixel data AND width/height, so
      // ImageFit.Contain will use the correct post-rotation aspect ratio.
      const needsFlip = orient.flipH || orient.flipV;
      const pixelMap = await imageSource.createPixelMap({ editable: needsFlip || orient.rotate !== 0 });
      if (orient.rotate !== 0) {
        await pixelMap.rotate(orient.rotate);
      }
      if (needsFlip) {
        pixelMap.flip(orient.flipH, orient.flipV);
      }
      imageSource.release();
      const t2 = Date.now();
      const tag = hit ? '缓存命中' : '下载完成';
      this.log.add(`${tag}: ${((t2 - t0) / 1000).toFixed(1)}s`);

      // pixelMap.rotate() swapped width/height — read actual dimensions.
      const info = await pixelMap.getImageInfo();
      const displayW = info.size.width;
      const displayH = info.size.height;
      this.orientedDisplaySizes.set(handle, new OrientedSize(displayW, displayH));

      // Thumbnail already has correct orientation applied during scan-time
      // decode (via preloadedOrientations). No re-decode needed.

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
    this.photoCount = 0;
    this.photos = [];
    this.thumbnailPixelMapMap.clear();
    this.thumbnailLoadedSet.clear();
    this.preloadedOrientations.clear();
    this.exifOrigDims.clear();
    this.orientationMap.clear();
    this.orientedDisplaySizes.clear();
    this.clearFullCache();
    this.statusText = '已断开连接';
    this.log.add('已断开连接');
  }

  formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }
}
