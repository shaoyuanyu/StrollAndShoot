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

export class CameraService {
  private static instance: CameraService;
  private session: PtpSession = new PtpSession();
  private log: AppLog = new AppLog();

  // State
  statusText: string = '就绪';
  cameraName: string = '';
  photoCount: number = 0;
  photos: PhotoEntry[] = [];
  scanning: boolean = false;
  connected: boolean = false;

  // Thumbnail cache
  thumbnailPixelMapMap: Map<number, image.PixelMap> = new Map();
  thumbnailLoadedSet: Set<number> = new Set();

  // Full-resolution compressed cache for preloading
  private compressedCache: Map<number, Uint8Array> = new Map();
  private preloadingSet: Set<number> = new Set();
  private cacheTotalBytes: number = 0;
  private cacheMaxBytes: number = 200 * 1048576;
  private detailIndex: number = -1;
  private prevDetailIndex: number = -1;
  private preloadRadius: number = 5;
  private preloading: boolean = false;

  // Download registry — persisted across sessions
  private downloadRegistry: Map<string, DownloadRecord> = new Map();
  private downloadDir: string = '';
  private downloadAborted: boolean = false;
  private registryLoaded: boolean = false;

  // Change callback
  onChange: () => void = () => {};

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

  getDownloadedKeys(): string[] {
    const keys: string[] = [];
    for (const p of this.photos) {
      const k = this.makeDownloadKey(p.filename, p.size);
      if (this.downloadRegistry.has(k)) {
        keys.push(k);
      }
    }
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

      try {
        await this.moveToGallery(sandboxSuccesses, context);
      } catch (err) {
        this.log.add(`保存到相册失败: ${JSON.stringify(err)}`);
      }

      // Persist registry for successfully saved photos
      for (const r of sandboxSuccesses) {
        if (this.downloadRegistry.has(r.key)) {
          continue;
        }
        const photo = batch.find((p: PhotoEntry) => p.handle === r.handle);
        if (!photo) continue;
        const record: DownloadRecord = {
          key: r.key,
          filename: photo.filename,
          size: photo.size,
          localPath: r.localPath,
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
   */
  private async moveToGallery(
    sandboxResults: DownloadResult[],
    context: common.UIAbilityContext
  ): Promise<void> {
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
      return;
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
    } catch (_e) {
      // File doesn't exist yet — registry stays empty
    }
    this.registryLoaded = true;
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
    } catch (err) {
      this.log.add(`保存下载记录失败: ${JSON.stringify(err)}`);
    }
  }

  private notify(): void {
    if (this.onChange) {
      this.onChange();
    }
  }

  async scanForCamera(): Promise<void> {
    if (this.connected) {
      await this.disconnect();
    }
    this.scanning = true;
    this.log.clear();
    this.log.add('=== 开始扫描 ===');
    this.notify();

    this.statusText = '正在搜索USB相机...';
    this.notify();

    try {
      const cameras = PtpSession.findCameras();
      if (cameras.length === 0) {
        this.statusText = '未检测到USB相机';
        this.connected = false;
        this.cameraName = '';
        this.scanning = false;
        this.notify();
        return;
      }

      this.statusText = `发现相机: ${cameras[0].productName}`;
      this.notify();

      const ok = await this.session.connect(cameras[0]);
      if (!ok) {
        this.statusText = '连接相机失败';
        this.connected = false;
        this.scanning = false;
        this.notify();
        return;
      }

      // Use USB descriptor for camera name
      this.cameraName = cameras[0].productName || cameras[0].manufacturerName ||
                        cameras[0].name;
      this.statusText = '已连接';
      this.connected = true;
      this.notify();

      // Attempt DeviceInfo parsing for diagnosis
      const devInfo = await this.session.getDeviceInfo();
      if (devInfo) {
        hilog.info(DOMAIN, TAG,
          `DeviceInfo vendorExtId=0x${devInfo.vendorExtensionID.toString(16)} ` +
          `manu=${devInfo.manufacturer} model=${devInfo.model} ` +
          `ver=${devInfo.deviceVersion} serial=${devInfo.serialNumber}`);
      }

      await this.loadPhotoList();
      await this.loadAllThumbnails();
    } catch (err) {
      hilog.error(DOMAIN, TAG, `scan error: ${JSON.stringify(err)}`);
      this.statusText = '扫描出错';
      this.connected = false;
    } finally {
      this.scanning = false;
      this.notify();
    }
  }

  /**
   * Recursively collect all photo handles by traversing the directory tree.
   * Returns handles of non-directory objects (photos/videos).
   */
  private async collectPhotoHandles(
    storageIDs: number[], parent: number, depth: number
  ): Promise<number[]> {
    if (depth > 10) return [];

    const result: number[] = [];
    for (const sid of storageIDs) {
      const handles = await this.session.getObjectHandles(sid, parent);
      if (handles.length === 0) continue;

      const dirs: number[] = [];
      for (const h of handles) {
        const info = await this.session.getObjectInfo(h);
        if (!info) continue;
        if (info.objectFormat === 0x3001) {
          dirs.push(h);
          hilog.info(DOMAIN, TAG,
            `Dir 0x${h.toString(16)}: ${info.filename}`);
        } else {
          result.push(h);
        }
      }

      // Recurse into all subdirectories
      for (const dh of dirs) {
        const sub = await this.collectPhotoHandles(storageIDs, dh, depth + 1);
        result.push(...sub);
      }

      break; // only use the first storage with results
    }
    return result;
  }

  private async loadPhotoList(): Promise<void> {
    this.statusText = '正在获取照片列表...';
    this.notify();

    try {
      const storageIDs = await this.session.getStorageIDs();
      hilog.info(DOMAIN, TAG, `StorageIDs count: ${storageIDs.length}`);

      if (storageIDs.length === 0) {
        this.photoCount = 0;
        this.photos = [];
        this.statusText = '已连接 (无存储设备)';
        this.notify();
        return;
      }

      const handles = await this.collectPhotoHandles(storageIDs, 0xFFFFFFFF, 0);

      hilog.info(DOMAIN, TAG, `ObjectHandles total: ${handles.length}`);
      this.photoCount = handles.length;

      const photoList: PhotoEntry[] = [];
      for (let i = 0; i < handles.length; i++) {
        const info = await this.session.getObjectInfo(handles[i]);
        if (info) {
          photoList.push({
            handle: handles[i],
            filename: info.filename,
            size: info.objectCompressedSize,
            objectFormat: info.objectFormat,
            captureDate: info.captureDate || '',
            imagePixWidth: info.imagePixWidth || 0,
            imagePixHeight: info.imagePixHeight || 0,
            storageId: info.storageId || 0
          });
        }
      }
      this.photos = photoList;
      this.statusText = `已连接 - ${this.photoCount} 张照片`;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `loadPhotoList error: ${JSON.stringify(err)}`);
      this.statusText = '获取照片列表失败';
    } finally {
      this.notify();
    }
  }

  async loadThumbnail(handle: number): Promise<void> {
    if (this.thumbnailLoadedSet.has(handle)) return;
    try {
      const data = await this.session.getThumb(handle);
      if (data && data.length > 0) {
        await this.decodeThumbnail(handle, data);
      }
    } catch (err) {
      this.log.add(`缩略图解码失败: handle=0x${handle.toString(16)}`);
    }
  }

  private async decodeThumbnail(handle: number, data: Uint8Array): Promise<void> {
    try {
      const imageSource = image.createImageSource(data.buffer as ArrayBuffer);
      const pixelMap = await imageSource.createPixelMap();
      this.thumbnailPixelMapMap.set(handle, pixelMap);
      this.thumbnailLoadedSet.add(handle);
      imageSource.release();
    } catch (err) {
      this.log.add(`缩略图解码失败: handle=0x${handle.toString(16)}`);
    }
  }

  async loadFullPhoto(handle: number): Promise<image.PixelMap | null> {
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

      const imageSource = image.createImageSource(data.buffer as ArrayBuffer);
      const pixelMap = await imageSource.createPixelMap();
      imageSource.release();
      const t2 = Date.now();
      const tag = hit ? '缓存命中' : '下载完成';
      this.log.add(`${tag}: ${((t2 - t0) / 1000).toFixed(1)}s`);
      return pixelMap;
    } catch (err) {
      this.log.add(`全尺寸加载失败: handle=0x${handle.toString(16)}`);
      return null;
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

  setDetailIndex(idx: number, total: number): void {
    if (this.detailIndex === idx) return;
    this.prevDetailIndex = this.detailIndex;
    this.detailIndex = idx;
    // Trigger preload after a short delay
    this.schedulePreload(total);
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
      const photo = this.photos[qi];
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
  }

  async loadAllThumbnails(): Promise<void> {
    this.log.add(`开始加载 ${this.photos.length} 张缩略图...`);
    const decodeJobs: Promise<void>[] = [];

    for (const photo of this.photos) {
      if (this.thumbnailLoadedSet.has(photo.handle)) continue;
      const data = await this.session.getThumb(photo.handle); // USB 串行读取
      if (data && data.length > 0) {
        // 立即启动异步解码，不等待；USB 继续读下一张，重叠隐藏解码延迟
        decodeJobs.push(this.decodeThumbnail(photo.handle, data));
      }
    }

    await Promise.all(decodeJobs);
    this.log.add('缩略图加载完成');
    this.notify();
  }

  async disconnect(): Promise<void> {
    await this.session.closeSessionAndPipe();
    this.connected = false;
    this.cameraName = '';
    this.photoCount = 0;
    this.photos = [];
    this.thumbnailPixelMapMap.clear();
    this.thumbnailLoadedSet.clear();
    this.clearFullCache();
    this.statusText = '已断开连接';
    this.log.add('已断开连接');
    this.notify();
  }

  formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }
}
