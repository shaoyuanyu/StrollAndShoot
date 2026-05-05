import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { PtpSession, setPtpLog } from '../pages/PtpHost';
import { AppLog } from './AppLog';
import type { PhotoEntry } from '../model/PhotoEntry';

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

      // Try each storage ID to find photos
      let handles: number[] = [];
      for (const sid of storageIDs) {
        const h = await this.session.getObjectHandles(sid);
        hilog.info(DOMAIN, TAG, `Storage 0x${sid.toString(16)}: ${h.length} objects`);
        if (h.length > 0) {
          handles = h;
          break;
        }
      }

      // Check for directory objects and traverse up to 6 levels
      let dirParent: number = 0;
      for (const h of handles) {
        const info = await this.session.getObjectInfo(h);
        if (info) {
          hilog.info(DOMAIN, TAG,
            `Handle 0x${h.toString(16)} fmt=0x${info.objectFormat.toString(16)} file=${info.filename}`);
          if (info.objectFormat === 0x3001) {
            dirParent = h;
          }
        }
      }

      if (dirParent !== 0) {
        for (let level = 0; level < 6; level++) {
          let foundDir = false;
          for (const sid of storageIDs) {
            const h = await this.session.getObjectHandles(sid, dirParent);
            hilog.info(DOMAIN, TAG,
              `Level ${level} dir 0x${dirParent.toString(16)}: ${h.length} objects`);
            if (h.length > 0) {
              handles = h;
              let nextDir = 0;
              let validCount = 0;
              for (const childH of h) {
                const info = await this.session.getObjectInfo(childH);
                if (info) {
                  validCount++;
                  if (info.objectFormat === 0x3001) {
                    nextDir = childH;
                  }
                }
              }
              if (nextDir !== 0 && validCount <= 2) {
                dirParent = nextDir;
                foundDir = true;
              } else {
                foundDir = false;
              }
              break;
            }
          }
          if (!foundDir) break;
        }
      }

      hilog.info(DOMAIN, TAG, `ObjectHandles total: ${handles.length}`);
      this.photoCount = handles.length;

      // Get info for each object (limit to first 50)
      const photoList: PhotoEntry[] = [];
      const limit = Math.min(handles.length, 50);
      for (let i = 0; i < limit; i++) {
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
        const imageSource = image.createImageSource(data.buffer as ArrayBuffer);
        const pixelMap = await imageSource.createPixelMap();
        this.thumbnailPixelMapMap.set(handle, pixelMap);
        this.thumbnailLoadedSet.add(handle);
        imageSource.release();
      }
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

  clearFullCache(): void {
    this.compressedCache.clear();
    this.preloadingSet.clear();
    this.cacheTotalBytes = 0;
    this.detailIndex = -1;
    this.prevDetailIndex = -1;
  }

  async loadAllThumbnails(): Promise<void> {
    this.log.add(`开始加载 ${this.photos.length} 张缩略图...`);
    for (const photo of this.photos) {
      await this.loadThumbnail(photo.handle);
    }
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
