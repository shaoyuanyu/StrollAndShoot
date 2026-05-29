/**
 * CameraCachePrefs.ets
 *
 * Manages per-camera caching preferences persisted to a JSON file.
 * Records whether the user has enabled/disabled thumbnail caching
 * for each camera they've connected, and when they were first asked.
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'CameraCachePrefs';

export interface CameraCachePref {
  cameraId: string;         // unique camera identity hash
  friendlyName: string;     // human-readable (e.g. "NIKON D850")
  cachingEnabled: boolean;  // user has opted in?
  firstAsked: string;       // ISO timestamp of first prompt
  lastSeen: string;         // ISO timestamp of last connection
}

export class CameraCachePrefs {
  private static instance: CameraCachePrefs;
  private filePath: string = '';
  private prefs: Map<string, CameraCachePref> = new Map();
  private _filesDir: string = '';

  static getInstance(): CameraCachePrefs {
    if (!CameraCachePrefs.instance) {
      CameraCachePrefs.instance = new CameraCachePrefs();
    }
    return CameraCachePrefs.instance;
  }

  /** The application filesDir, needed by ThumbnailCache for path construction. */
  get filesDir(): string {
    return this._filesDir;
  }

  init(filesDir: string): void {
    this._filesDir = filesDir;
    this.filePath = filesDir + '/camera_cache_prefs.json';
    this.load();
  }

  /** Load prefs from disk. */
  load(): void {
    this.prefs.clear();
    try {
      const f = fileIo.openSync(this.filePath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(this.filePath);
      if (stat.size > 0) {
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(f.fd, buf);
        const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
        const obj = JSON.parse(text) as Record<string, CameraCachePref>;
        for (const k of Object.keys(obj)) {
          this.prefs.set(k, obj[k]);
        }
      }
      fileIo.closeSync(f);
      hilog.info(DOMAIN, TAG, 'Loaded %{public}d camera cache prefs', this.prefs.size);
    } catch (_e) {
      // File doesn't exist yet
    }
  }

  /** Persist prefs to disk. */
  save(): void {
    if (!this.filePath) return;
    try {
      const obj: Record<string, CameraCachePref> = {};
      this.prefs.forEach((v, k) => { obj[k] = v; });
      const text = JSON.stringify(obj, null, 2);
      const f = fileIo.openSync(this.filePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save prefs failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Get a camera's preference entry, or null if never seen. */
  get(cameraId: string): CameraCachePref | null {
    return this.prefs.get(cameraId) ?? null;
  }

  /** Get all known camera preferences. */
  getAll(): CameraCachePref[] {
    const result: CameraCachePref[] = [];
    this.prefs.forEach((v) => result.push(v));
    // Sort: most recently seen first
    result.sort((a, b) => b.lastSeen.localeCompare(a.lastSeen));
    return result;
  }

  /** Set or update a camera's preference. */
  set(cameraId: string, friendlyName: string, cachingEnabled: boolean): void {
    const now = new Date().toISOString();
    const existing = this.prefs.get(cameraId);
    if (existing) {
      existing.friendlyName = friendlyName;
      existing.cachingEnabled = cachingEnabled;
      existing.lastSeen = now;
    } else {
      this.prefs.set(cameraId, {
        cameraId,
        friendlyName,
        cachingEnabled,
        firstAsked: now,
        lastSeen: now,
      });
    }
    this.save();
  }

  /** Remove a camera's preference entry. */
  delete(cameraId: string): void {
    this.prefs.delete(cameraId);
    this.save();
  }

  /** Check if this camera has been asked before (regardless of answer). */
  hasCamera(cameraId: string): boolean {
    return this.prefs.has(cameraId);
  }

  /** Check if caching is enabled for this camera (default: true if never asked). */
  isCachingEnabled(cameraId: string): boolean {
    const entry = this.prefs.get(cameraId);
    if (!entry) return true; // never asked → default to true (cache will be used)
    return entry.cachingEnabled;
  }

  /** Delete all preferences. */
  clearAll(): void {
    this.prefs.clear();
    this.save();
  }
}
