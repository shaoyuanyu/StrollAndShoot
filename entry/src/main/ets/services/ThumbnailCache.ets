/**
 * ThumbnailCache.ets
 *
 * Persists decoded thumbnails to local filesystem so that repeated scans
 * of the same camera can skip USB GetThumb calls entirely.
 *
 * Directory layout:
 *   {filesDir}/thumb_cache/{cameraIdHash}/
 *     manifest.json    // Map<string, CacheEntry> keyed by "filename::size"
 *     {hash}.jpg       // Encoded thumbnail (JPEG quality 85)
 *
 * Key format:  "filename::size"  (same as download registry)
 * Cache hit:   key exists in manifest AND modificationDate matches
 * Cache miss:  key not found OR modificationDate differs
 */
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'ThumbnailCache';

export interface CacheInfo {
  sizeBytes: number;
  entryCount: number;
}

export interface CacheEntry {
  filename: string;
  size: number;
  modificationDate: string;
  cacheFileName: string;
  cachedAt: number;   // epoch ms
  // PTP object handle (for Phase 0 thumbnail mapping without metadata_cache.json)
  handle?: number;
  // EXIF orientation (saves a GetPartialObject USB call on hit)
  exifRotate?: number;
  exifFlipH?: boolean;
  exifFlipV?: boolean;
  // Original photo dimensions (for crop calculation)
  origWidth?: number;
  origHeight?: number;
}

interface CacheKeyParts {
  filename: string;
  size: number;
}

/**
 * Simple string hash (djb2) for producing cache filenames.
 */
function hashString(str: string): string {
  let hash = 5381;
  for (let i = 0; i < str.length; i++) {
    hash = ((hash << 5) + hash) + str.charCodeAt(i);
    hash = hash & 0xFFFFFFFF;
  }
  return (hash >>> 0).toString(16);
}

/** Parse a "filename::size" key into its parts. */
function parseCacheKey(key: string): CacheKeyParts {
  const sep = key.lastIndexOf('::');
  if (sep < 0) return { filename: key, size: 0 };
  return {
    filename: key.substring(0, sep),
    size: parseInt(key.substring(sep + 2)) || 0
  };
}

export class ThumbnailCache {
  private cacheDir: string = '';
  private manifestPath: string = '';
  private manifest: Map<string, CacheEntry> = new Map();
  private loaded: boolean = false;
  private pendingSaves: Promise<void>[] = [];

  /** Initialize cache for a specific camera. */
  init(filesDir: string, cameraId: string): void {
    const safeId = cameraId.replace(/[\\/:*?"<>|]/g, '_');
    this.cacheDir = filesDir + '/thumb_cache/' + safeId;
    this.manifestPath = this.cacheDir + '/manifest.json';
    this.loaded = false;
    this.manifest.clear();
    this.pendingSaves = [];
  }

  getCacheDir(): string {
    return this.cacheDir;
  }

  /** Ensure the cache directory exists (create recursively if needed). */
  private ensureCacheDir(): void {
    try {
      fileIo.mkdirSync(this.cacheDir, true);
    } catch (_e) { /* best effort — dir may already exist */ }
  }

  /** Load the manifest from disk. */
  async loadManifest(): Promise<void> {
    if (this.loaded) return;
    this.loaded = true;
    this.ensureCacheDir();
    try {
      const f = fileIo.openSync(this.manifestPath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(this.manifestPath);
      if (stat.size > 0) {
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(f.fd, buf);
        const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
        const obj = JSON.parse(text) as Record<string, CacheEntry>;
        for (const k of Object.keys(obj)) {
          this.manifest.set(k, obj[k]);
        }
      }
      fileIo.closeSync(f);
      hilog.info(DOMAIN, TAG, 'loaded manifest with %{public}d entries', this.manifest.size);
    } catch (_e) {
      hilog.info(DOMAIN, TAG, 'no existing manifest, starting fresh');
      this.persistManifestSync();
    }
  }

  /**
   * Check if a photo has a cached thumbnail with matching modificationDate.
   * @param key  "filename::size"
   * @param modDate  PTP ModificationDate (YYYYMMDDThhmmss)
   * @returns the cache entry if valid, null otherwise
   */
  findCached(key: string, modDate: string): CacheEntry | null {
    const entry = this.manifest.get(key);
    if (!entry) return null;
    if (!modDate) return entry;
    if (entry.modificationDate !== modDate) {
      hilog.info(DOMAIN, TAG, 'stale: modDate changed for %{public}s', key);
      return null;
    }
    return entry;
  }

  /**
   * Load a cached thumbnail pixelMap from disk.
   */
  async loadThumbnail(cacheFileName: string): Promise<image.PixelMap | null> {
    try {
      const filePath = this.cacheDir + '/' + cacheFileName;
      const f = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(filePath);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);

      const imgSrc = image.createImageSource(buf);
      const pixelMap = await imgSrc.createPixelMap();
      imgSrc.release();
      return pixelMap;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadThumbnail failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /**
   * Save raw thumbnail bytes to cache (avoids re-encoding).
   * Includes EXIF orientation/dims to skip GetPartialObject on future hits.
   * Tracks the promise so caller can await all pending saves via flush().
   */
  async saveRawThumbnail(
    key: string,
    modDate: string,
    jpegData: Uint8Array,
    handle?: number,
    origWidth?: number,
    origHeight?: number
  ): Promise<void> {
    const promise = this.doSaveRawThumbnail(key, modDate, jpegData, handle, origWidth, origHeight);
    this.pendingSaves.push(promise);
    await promise;
    const idx = this.pendingSaves.indexOf(promise);
    if (idx >= 0) this.pendingSaves.splice(idx, 1);
  }

  private async doSaveRawThumbnail(
    key: string,
    modDate: string,
    jpegData: Uint8Array,
    handle?: number,
    origWidth?: number,
    origHeight?: number
  ): Promise<void> {
    try {
      this.ensureCacheDir();
      const cacheFileName = hashString(key) + '.jpg';
      const filePath = this.cacheDir + '/' + cacheFileName;

      const f = fileIo.openSync(filePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, jpegData.buffer as ArrayBuffer);
      fileIo.closeSync(f);

      const pk = parseCacheKey(key);
      const entry: CacheEntry = {
        filename: pk.filename,
        size: pk.size,
        modificationDate: modDate,
        cacheFileName: cacheFileName,
        cachedAt: Date.now()
      };
      if (handle !== undefined) entry.handle = handle;
      // Save origWidth/Height for future crop calculation, but NOT
      // exifRotate — that flag is set only by saveEncodedThumbnail when
      // the JPEG on disk is actually rotate+flip+crop corrected.
      if (origWidth !== undefined && origHeight !== undefined) {
        entry.origWidth = origWidth;
        entry.origHeight = origHeight;
      }
      this.manifest.set(key, entry);
      hilog.info(DOMAIN, TAG, 'raw %{public}s -> %{public}s (%{public}d bytes)',
        key, cacheFileName, jpegData.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveRawThumbnail failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * Encode a PixelMap as JPEG and save it to the cache (overwrites existing).
   * Used to replace raw (uncropped) thumbnail with cropped version after decode.
   */
  async saveEncodedThumbnail(
    key: string,
    modDate: string,
    pixelMap: image.PixelMap,
    handle?: number,
    exifRotate?: number,
    exifFlipH?: boolean,
    exifFlipV?: boolean,
    origWidth?: number,
    origHeight?: number
  ): Promise<void> {
    try {
      this.ensureCacheDir();
      const cacheFileName = hashString(key) + '.jpg';
      const filePath = this.cacheDir + '/' + cacheFileName;

      // Encode PixelMap to JPEG
      const packer = image.createImagePacker();
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: 85
      };
      const encoded = await packer.packing(pixelMap, packOpts);
      packer.release();

      // Write to file (overwrites raw version)
      const f = fileIo.openSync(filePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, encoded);
      fileIo.closeSync(f);

      // Update manifest entry
      const pk = parseCacheKey(key);
      const entry: CacheEntry = {
        filename: pk.filename,
        size: pk.size,
        modificationDate: modDate,
        cacheFileName: cacheFileName,
        cachedAt: Date.now()
      };
      if (handle !== undefined) entry.handle = handle;
      if (exifRotate !== undefined) { entry.exifRotate = exifRotate; }
      if (exifFlipH !== undefined) { entry.exifFlipH = exifFlipH; }
      if (exifFlipV !== undefined) { entry.exifFlipV = exifFlipV; }
      if (origWidth !== undefined && origHeight !== undefined) {
        entry.origWidth = origWidth;
        entry.origHeight = origHeight;
      }
      // Signal that this entry is cropped by setting origWidth/origHeight
      this.manifest.set(key, entry);
      hilog.info(DOMAIN, TAG, 'encoded %{public}s -> %{public}s (%{public}d bytes)',
        key, cacheFileName, encoded.byteLength);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveEncodedThumbnail failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * Wait for all pending save operations to complete.
   */
  async flush(): Promise<void> {
    while (this.pendingSaves.length > 0) {
      const batch = this.pendingSaves.slice();
      await Promise.all(batch);
    }
  }

  /**
   * Remove cache entries whose keys are not in the valid set.
   */
  async purgeStale(validKeys: Set<string>): Promise<number> {
    const staleKeys: string[] = [];
    const staleFiles: string[] = [];

    this.manifest.forEach((entry, key) => {
      if (!validKeys.has(key)) {
        staleKeys.push(key);
        staleFiles.push(this.cacheDir + '/' + entry.cacheFileName);
      }
    });

    for (const fp of staleFiles) {
      try { fileIo.unlinkSync(fp); } catch (_e) {}
    }

    for (const k of staleKeys) {
      this.manifest.delete(k);
    }

    if (staleKeys.length > 0) {
      hilog.info(DOMAIN, TAG, 'purged %{public}d stale entries', staleKeys.length);
      this.persistManifestSync();
    }

    return staleKeys.length;
  }

  /** Persist manifest to disk (synchronous). */
  persistManifestSync(): void {
    if (!this.manifestPath) return;
    try {
      const obj: Record<string, CacheEntry> = {};
      this.manifest.forEach((v, k) => { obj[k] = v; });
      const text = JSON.stringify(obj, null, 2);
      const f = fileIo.openSync(this.manifestPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'persist manifest failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * Get the total size of cached thumbnail files in bytes.
   */
  async getCacheSizeBytes(): Promise<number> {
    let total = 0;
    this.manifest.forEach((entry) => {
      try {
        const fp = this.cacheDir + '/' + entry.cacheFileName;
        const stat = fileIo.statSync(fp);
        total += stat.size;
      } catch (_e) {}
    });
    return total;
  }

  /**
   * Get the count of cached thumbnails.
   */
  getEntryCount(): number {
    return this.manifest.size;
  }

  /**
   * Get all cache entries (used by Phase 0 fallback to reconstruct PhotoEntry).
   */
  getAllEntries(): CacheEntry[] {
    const result: CacheEntry[] = [];
    this.manifest.forEach((entry: CacheEntry) => {
      result.push(entry);
    });
    return result;
  }

  /**
   * Delete all cached data for the current camera.
   */
  async clearAll(): Promise<void> {
    this.manifest.forEach((entry) => {
      try { fileIo.unlinkSync(this.cacheDir + '/' + entry.cacheFileName); } catch (_e) {}
    });
    this.manifest.clear();
    try { fileIo.unlinkSync(this.manifestPath); } catch (_e) {}
    try { fileIo.rmdirSync(this.cacheDir); } catch (_e) {}
  }

  /** Read a cached file into an ArrayBuffer (fast sync read on main thread). */
  async readFileToBuffer(filePath: string): Promise<ArrayBuffer | null> {
    try {
      const f = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(filePath);
      if (stat.size <= 0) { fileIo.closeSync(f); return null; }
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      return buf;
    } catch (_e) { return null; }
  }

  /** Debug: check whether a key exists in manifest and return saved modDate. */
  debugLookup(key: string): string | null {
    const e = this.manifest.get(key);
    return e ? e.modificationDate : null;
  }

  /** Close cache: persist manifest. */
  close(): void {
    this.persistManifestSync();
  }

  // ---- Static helpers for CacheManagementPage ----

  static async deleteCameraCache(filesDir: string, cameraId: string): Promise<void> {
    const safeId = cameraId.replace(/[\\/:*?"<>|]/g, '_');
    const cacheDir = filesDir + '/thumb_cache/' + safeId;
    const manifestPath = cacheDir + '/manifest.json';

    try {
      const f = fileIo.openSync(manifestPath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(manifestPath);
      if (stat.size > 0) {
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(f.fd, buf);
        const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
        const obj = JSON.parse(text) as Record<string, CacheEntry>;
        for (const k of Object.keys(obj)) {
          try { fileIo.unlinkSync(cacheDir + '/' + obj[k].cacheFileName); } catch (_e) {}
        }
      }
      fileIo.closeSync(f);
    } catch (_e) {}

    try { fileIo.unlinkSync(manifestPath); } catch (_e) {}
    try { fileIo.rmdirSync(cacheDir); } catch (_e) {}
  }

  /**
   * Get cache info (total bytes + entry count) for a specific camera.
   */
  static async getCameraCacheInfo(filesDir: string, cameraId: string): Promise<CacheInfo> {
    const safeId = cameraId.replace(/[\\/:*?"<>|]/g, '_');
    const cacheDir = filesDir + '/thumb_cache/' + safeId;
    const manifestPath = cacheDir + '/manifest.json';
    let sizeBytes = 0;
    let entryCount = 0;

    try {
      const f = fileIo.openSync(manifestPath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(manifestPath);
      if (stat.size > 0) {
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(f.fd, buf);
        const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
        const obj = JSON.parse(text) as Record<string, CacheEntry>;
        entryCount = Object.keys(obj).length;
        for (const k of Object.keys(obj)) {
          try {
            const fp = cacheDir + '/' + obj[k].cacheFileName;
            const s = fileIo.statSync(fp);
            sizeBytes += s.size;
          } catch (_e) { /* file may be missing */ }
        }
      }
      fileIo.closeSync(f);
    } catch (_e) { /* no manifest */ }

    const result: CacheInfo = { sizeBytes: sizeBytes, entryCount: entryCount };
    return result;
  }

  static async getCameraCacheSize(filesDir: string, cameraId: string): Promise<number> {
    const safeId = cameraId.replace(/[\\/:*?"<>|]/g, '_');
    const cacheDir = filesDir + '/thumb_cache/' + safeId;
    const manifestPath = cacheDir + '/manifest.json';
    let total = 0;

    try {
      const f = fileIo.openSync(manifestPath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(manifestPath);
      if (stat.size > 0) {
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(f.fd, buf);
        const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
        const obj = JSON.parse(text) as Record<string, CacheEntry>;
        for (const k of Object.keys(obj)) {
          try {
            const fp = cacheDir + '/' + obj[k].cacheFileName;
            const s = fileIo.statSync(fp);
            total += s.size;
          } catch (_e) {}
        }
      }
      fileIo.closeSync(f);
    } catch (_e) {}

    return total;
  }
}
