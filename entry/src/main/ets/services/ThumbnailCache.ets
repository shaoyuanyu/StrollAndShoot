/**
 * ThumbnailCache.ets
 *
 * Persists decoded thumbnails to local filesystem so that repeated scans
 * of the same camera can skip USB GetThumb calls entirely.
 *
 * Directory layout:
 *   {filesDir}/thumb_cache/{cameraIdHash}/
 *     manifest.json    // Map<string, CacheEntry> keyed by "filename::size"
 *     metadata_cache.json // Last PhotoEntry[] snapshot (owned by CameraService)
 *     {hash}.jpg       // Encoded thumbnail (JPEG quality 85)
 *
 * Key format:  "filename::size"  (same as download registry)
 * Cache hit:   key exists in manifest AND modificationDate matches
 * Cache miss:  key not found OR modificationDate differs
 */
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AtomicFile } from '../utils/AtomicFile';

const DOMAIN = 0x0000;
const TAG = 'ThumbnailCache';

/** 清单最多每 2 秒落一次盘，避免每张缩略图都重写整份 JSON。 */
const PERSIST_INTERVAL_MS = 2000;
/** 单相机磁盘缓存上限，超出后按 cachedAt 淘汰最旧条目。 */
const MAX_CACHE_BYTES = 512 * 1024 * 1024;

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
  /** 磁盘上这张 JPEG 的字节数，用于容量淘汰。 */
  sizeBytes?: number;
  // PTP object handle (for Phase 0 thumbnail mapping without metadata_cache.json)
  handle?: number;
  // EXIF orientation of the source photo.
  //   corrected === true  → the JPEG on disk is already rotate/flip/crop corrected,
  //                         these fields are informational only.
  //   corrected !== true  → the JPEG on disk is the raw camera thumbnail and these
  //                         fields MUST be applied when decoding.
  exifRotate?: number;
  exifFlipH?: boolean;
  exifFlipV?: boolean;
  // Original photo dimensions (used to crop black bars from raw thumbnails)
  origWidth?: number;
  origHeight?: number;
  // True only after a decode+re-encode pass has baked the transform into the JPEG.
  corrected?: boolean;
}

/** On-disk manifest envelope. Bumped whenever the meaning of CacheEntry changes. */
interface ManifestFile {
  version: number;
  entries: Record<string, CacheEntry>;
}

/**
 * v2 加了 `corrected`；v1 条目无法判断方向是否已烘焙。
 * v3（ISSUE-012 / ISSUE-007）：不再写“纠正后重新编码”的缩略图，磁盘上只保留
 * 原始 JPEG + manifest 里的 rotate/flip/origWidth/origHeight，解码时再裁剪。
 * v2 的 NEF 缩略图是按“无原始尺寸 → 不裁剪”存下的纠正版，带黑边且无法补救，
 * 所以版本不匹配时整库重建。
 */
const MANIFEST_VERSION = 3;

/** Parse a manifest, returning an empty set for unknown/legacy schemas. */
function readManifestEntries(text: string): Record<string, CacheEntry> {
  try {
    const parsed = JSON.parse(text) as ManifestFile;
    if (parsed && parsed.version === MANIFEST_VERSION && parsed.entries) {
      return parsed.entries;
    }
  } catch (_e) {
    // corrupt manifest — treat as empty
  }
  return {};
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
  private totalBytes: number = 0;
  private dirty: boolean = false;
  private lastPersistAt: number = 0;

  /** Initialize cache for a specific camera. Idempotent for the same camera. */
  init(filesDir: string, cameraId: string): void {
    const safeId = cameraId.replace(/[\\/:*?"<>|]/g, '_');
    const dir = filesDir + '/thumb_cache/' + safeId;
    if (this.cacheDir === dir) {
      // Same camera — keep the loaded manifest and pending writes intact.
      return;
    }
    this.cacheDir = dir;
    this.manifestPath = this.cacheDir + '/manifest.json';
    this.loaded = false;
    this.manifest.clear();
    this.pendingSaves = [];
    this.totalBytes = 0;
    this.dirty = false;
    this.lastPersistAt = 0;
  }

  /** Drop in-memory state after the directory has been deleted externally. */
  reset(): void {
    this.cacheDir = '';
    this.manifestPath = '';
    this.manifest.clear();
    this.loaded = false;
    this.pendingSaves = [];
    this.totalBytes = 0;
    this.dirty = false;
    this.lastPersistAt = 0;
  }

  getCacheDir(): string {
    return this.cacheDir;
  }

  /** manifest 文件是否还在（目录被外部删除时返回 false）。 */
  private manifestFileExists(): boolean {
    if (this.manifestPath === '') return false;
    try {
      return fileIo.accessSync(this.manifestPath);
    } catch (_e) {
      return false;
    }
  }

  /**
   * 丢弃一条已失效的缓存记录（文件被删/读不出来时由上层调用）。
   * 不删文件、只改 manifest，避免下次扫描继续“命中”同一条坏记录。
   */
  invalidate(key: string): void {
    const entry = this.manifest.get(key);
    if (!entry) return;
    if (entry.sizeBytes !== undefined) {
      this.totalBytes -= entry.sizeBytes;
    }
    this.manifest.delete(key);
    this.dirty = true;
  }

  /** Ensure the cache directory exists (create recursively if needed). */
  private ensureCacheDir(): void {
    try {
      fileIo.mkdirSync(this.cacheDir, true);
    } catch (_e) {
      // best effort — dir may already exist
    }
  }

  /** Load the manifest from disk, repair missing entries and remove orphan JPEGs. */
  async loadManifest(): Promise<void> {
    if (this.loaded) {
      // 「缓存管理」里的“清除缓存”只删目录，删不到这个单例的内存状态。
      // 不校验就会保留一整份指向已删文件的 manifest：之后每次 findCached 都命中、
      // 每次读文件都失败，画廊从头到尾只有占位符（2026-11-09 真机）。
      if (this.manifestFileExists()) return;
      this.manifest.clear();
      this.totalBytes = 0;
      this.dirty = false;
      this.loaded = false;
      hilog.info(DOMAIN, TAG, 'manifest disappeared, cache state reset');
    }
    this.loaded = true;
    this.ensureCacheDir();

    const text = AtomicFile.readText(this.manifestPath);
    if (text !== null && text !== '') {
      const entries = readManifestEntries(text);
      for (const k of Object.keys(entries)) {
        this.manifest.set(k, entries[k]);
      }
      if (Object.keys(entries).length === 0) {
        hilog.info(DOMAIN, TAG, 'legacy or empty manifest, cache will be rebuilt');
      }
    } else {
      hilog.info(DOMAIN, TAG, 'no existing manifest, starting fresh');
    }

    const changed = this.recalculateAndCleanup();
    this.evictIfNeeded();
    if (changed || this.dirty) {
      this.persistManifestSync();
    }
    hilog.info(DOMAIN, TAG, 'loaded manifest with %{public}d entries, %{public}d bytes',
      this.manifest.size, this.totalBytes);
  }

  /**
   * Stat every entry, drop missing files, compute total size, and delete
   * JPEGs that the manifest does not reference (crash / legacy v1 leftovers).
   */
  private recalculateAndCleanup(): boolean {
    let changed = false;
    const validFiles = new Set<string>();
    const missing: string[] = [];
    this.totalBytes = 0;

    this.manifest.forEach((entry, key) => {
      const fp = this.cacheDir + '/' + entry.cacheFileName;
      try {
        const stat = fileIo.statSync(fp);
        if (stat.size <= 0) {
          missing.push(key);
          return;
        }
        if (entry.sizeBytes !== stat.size) {
          entry.sizeBytes = stat.size;
          changed = true;
        }
        this.totalBytes += stat.size;
        validFiles.add(entry.cacheFileName);
      } catch (_e) {
        missing.push(key);
      }
    });

    for (const key of missing) {
      this.manifest.delete(key);
      changed = true;
    }

    try {
      const names = fileIo.listFileSync(this.cacheDir);
      for (const name of names) {
        const base = name.substring(name.lastIndexOf('/') + 1);
        if (base.endsWith('.tmp')) {
          try {
            fileIo.unlinkSync(this.cacheDir + '/' + base);
            changed = true;
          } catch (_e) {
            // best effort
          }
          continue;
        }
        if (!base.endsWith('.jpg')) continue;
        if (!validFiles.has(base)) {
          try {
            fileIo.unlinkSync(this.cacheDir + '/' + base);
            changed = true;
          } catch (_e) {
            // best effort
          }
        }
      }
    } catch (_e) {
      // directory missing — nothing to clean
    }

    if (changed) {
      this.dirty = true;
    }
    return changed;
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
   * Save raw thumbnail bytes to cache (avoids re-encoding).
   * Includes EXIF orientation/dims to skip GetPartialObject on future hits.
   * Tracks the promise so caller can await all pending saves via flush().
   */
  async saveRawThumbnail(
    key: string,
    modDate: string,
    jpegData: Uint8Array,
    handle?: number,
    exifRotate?: number,
    exifFlipH?: boolean,
    exifFlipV?: boolean,
    origWidth?: number,
    origHeight?: number
  ): Promise<void> {
    const promise = this.doSaveRawThumbnail(key, modDate, jpegData, handle,
      exifRotate, exifFlipH, exifFlipV, origWidth, origHeight);
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
        cachedAt: Date.now(),
        sizeBytes: jpegData.length
      };
      if (handle !== undefined) entry.handle = handle;
      // Raw JPEG: transform has NOT been applied yet, record what is needed
      // to reproduce it on a later cache hit.
      entry.corrected = false;
      if (exifRotate !== undefined) { entry.exifRotate = exifRotate; }
      if (exifFlipH !== undefined) { entry.exifFlipH = exifFlipH; }
      if (exifFlipV !== undefined) { entry.exifFlipV = exifFlipV; }
      if (origWidth !== undefined && origHeight !== undefined) {
        entry.origWidth = origWidth;
        entry.origHeight = origHeight;
      }
      this.putEntry(key, entry);
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
    const promise = this.doSaveEncodedThumbnail(key, modDate, pixelMap, handle,
      exifRotate, exifFlipH, exifFlipV, origWidth, origHeight);
    this.pendingSaves.push(promise);
    await promise;
    const idx = this.pendingSaves.indexOf(promise);
    if (idx >= 0) this.pendingSaves.splice(idx, 1);
  }

  private async doSaveEncodedThumbnail(
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
      const encoded = await packer.packToData(pixelMap, packOpts);
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
        cachedAt: Date.now(),
        sizeBytes: encoded.byteLength
      };
      if (handle !== undefined) entry.handle = handle;
      if (exifRotate !== undefined) { entry.exifRotate = exifRotate; }
      if (exifFlipH !== undefined) { entry.exifFlipH = exifFlipH; }
      if (exifFlipV !== undefined) { entry.exifFlipV = exifFlipV; }
      if (origWidth !== undefined && origHeight !== undefined) {
        entry.origWidth = origWidth;
        entry.origHeight = origHeight;
      }
      // The JPEG on disk now has rotate/flip/crop baked in — a later cache hit
      // must decode it as-is instead of applying the transform twice.
      entry.corrected = true;
      this.putEntry(key, entry);
      hilog.info(DOMAIN, TAG, 'encoded %{public}s -> %{public}s (%{public}d bytes)',
        key, cacheFileName, encoded.byteLength);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveEncodedThumbnail failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 更新条目与总字节数，按容量淘汰，并按节流策略落盘。 */
  private putEntry(key: string, entry: CacheEntry): void {
    const old = this.manifest.get(key);
    if (old !== undefined && old.sizeBytes !== undefined) {
      this.totalBytes -= old.sizeBytes;
    }
    this.manifest.set(key, entry);
    this.totalBytes += entry.sizeBytes ?? 0;
    this.dirty = true;
    this.evictIfNeeded();
    this.maybePersist();
  }

  /** 超过单相机容量上限时，按 cachedAt 从旧到新淘汰。 */
  private evictIfNeeded(): void {
    if (this.totalBytes <= MAX_CACHE_BYTES) return;
    const keys: string[] = [];
    this.manifest.forEach((_e, k) => keys.push(k));
    keys.sort((a, b) => {
      const ea = this.manifest.get(a);
      const eb = this.manifest.get(b);
      return (ea?.cachedAt ?? 0) - (eb?.cachedAt ?? 0);
    });
    for (const k of keys) {
      if (this.totalBytes <= MAX_CACHE_BYTES || this.manifest.size <= 1) break;
      const e = this.manifest.get(k);
      if (e === undefined) continue;
      try {
        fileIo.unlinkSync(this.cacheDir + '/' + e.cacheFileName);
      } catch (_e) {
        // best effort
      }
      if (e.sizeBytes !== undefined) {
        this.totalBytes -= e.sizeBytes;
      }
      this.manifest.delete(k);
      this.dirty = true;
    }
    if (this.dirty) {
      hilog.info(DOMAIN, TAG, 'cache trimmed to %{public}d bytes', this.totalBytes);
    }
  }

  /** 按节流间隔持久化清单；force=true 时立即写。 */
  maybePersist(force: boolean = false): void {
    if (!this.dirty) return;
    const now = Date.now();
    if (!force && now - this.lastPersistAt < PERSIST_INTERVAL_MS) return;
    this.persistManifestSync();
  }

  /**
   * Wait for all pending save operations to complete.
   */
  async flush(): Promise<void> {
    while (this.pendingSaves.length > 0) {
      const batch = this.pendingSaves.slice();
      await Promise.all(batch);
    }
    this.maybePersist(true);
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
        if (entry.sizeBytes !== undefined) {
          this.totalBytes -= entry.sizeBytes;
        }
      }
    });

    for (const fp of staleFiles) {
      try { fileIo.unlinkSync(fp); } catch (_e) { /* best effort */ }
    }

    for (const k of staleKeys) {
      this.manifest.delete(k);
    }

    if (staleKeys.length > 0) {
      this.dirty = true;
      hilog.info(DOMAIN, TAG, 'purged %{public}d stale entries', staleKeys.length);
      this.persistManifestSync();
    }

    return staleKeys.length;
  }

  /** Persist manifest to disk atomically. */
  persistManifestSync(): void {
    if (!this.manifestPath) return;
    try {
      const entries: Record<string, CacheEntry> = {};
      this.manifest.forEach((v, k) => {
        entries[k] = v;
      });
      const envelope: ManifestFile = { version: MANIFEST_VERSION, entries: entries };
      AtomicFile.writeText(this.manifestPath, JSON.stringify(envelope, null, 2));
      this.dirty = false;
      this.lastPersistAt = Date.now();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'persist manifest failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * Delete all cached data for the current camera, including metadata_cache.json.
   */
  async clearAll(): Promise<void> {
    this.manifest.clear();
    this.totalBytes = 0;
    this.dirty = false;
    if (this.cacheDir !== '') {
      AtomicFile.deleteDirRecursive(this.cacheDir);
    }
  }

  /** Read a cached file into an ArrayBuffer (fast sync read on main thread). */
  async readFileToBuffer(filePath: string): Promise<ArrayBuffer | null> {
    try {
      const f = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(filePath);
      if (stat.size <= 0) {
        fileIo.closeSync(f);
        return null;
      }
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      return buf;
    } catch (_e) {
      return null;
    }
  }

  /** Close cache: persist manifest. */
  close(): void {
    this.maybePersist(true);
  }

  // ---- Static helpers for CacheManagementPage ----

  /** 删除整个相机缓存目录（缩略图 + manifest + metadata_cache.json）。 */
  static async deleteCameraCache(filesDir: string, cameraId: string): Promise<void> {
    const safeId = cameraId.replace(/[\\/:*?"<>|]/g, '_');
    AtomicFile.deleteDirRecursive(filesDir + '/thumb_cache/' + safeId);
  }

  /**
   * Get cache info (total bytes + entry count) for a specific camera.
   * 按目录里的实际 .jpg 统计，孤儿文件也会计入。
   */
  static async getCameraCacheInfo(filesDir: string, cameraId: string): Promise<CacheInfo> {
    const safeId = cameraId.replace(/[\\/:*?"<>|]/g, '_');
    const cacheDir = filesDir + '/thumb_cache/' + safeId;
    let sizeBytes = 0;
    let entryCount = 0;

    try {
      const names = fileIo.listFileSync(cacheDir);
      for (const name of names) {
        const base = name.substring(name.lastIndexOf('/') + 1);
        if (!base.endsWith('.jpg')) continue;
        try {
          const stat = fileIo.statSync(cacheDir + '/' + base);
          sizeBytes += stat.size;
          entryCount++;
        } catch (_e) {
          // best effort
        }
      }
    } catch (_e) {
      // directory does not exist
    }

    return { sizeBytes, entryCount };
  }
}
