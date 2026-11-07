/**
 * CameraCachePrefs.ets
 *
 * Manages per-camera caching preferences persisted to a JSON file.
 * Records whether the user has enabled/disabled thumbnail caching
 * for each camera they've connected, and when they were first asked.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AtomicFile } from '../utils/AtomicFile';

const DOMAIN = 0x0000;
const TAG = 'CameraCachePrefs';
const SCHEMA_VERSION = 1;

export interface CameraCachePref {
  cameraId: string;         // unique camera identity hash
  friendlyName: string;     // human-readable (e.g. "NIKON D850")
  cachingEnabled: boolean;  // user has opted in?
  firstAsked: string;       // ISO timestamp of first prompt
  lastSeen: string;         // ISO timestamp of last connection
}

/** 带 schema 版本的文件信封，便于以后迁移。 */
interface CameraCachePrefsFile {
  version: number;
  prefs: Record<string, CameraCachePref>;
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

  /** Load prefs from disk. Supports the legacy plain-map format. */
  load(): void {
    this.prefs.clear();
    if (!this.filePath) return;
    const text = AtomicFile.readText(this.filePath);
    if (text === null || text === '') {
      hilog.info(DOMAIN, TAG, 'no cached camera prefs yet');
      return;
    }
    try {
      const obj = JSON.parse(text) as Record<string, Object>;
      const version = obj['version'];
      const raw = version !== undefined ? obj['prefs'] : obj;
      if (raw !== undefined && raw !== null) {
        const map = raw as Record<string, CameraCachePref>;
        for (const k of Object.keys(map)) {
          const p = map[k];
          if (p && typeof p.cameraId === 'string' && p.cameraId !== '') {
            this.prefs.set(k, p);
          }
        }
      }
      hilog.info(DOMAIN, TAG, 'Loaded %{public}d camera cache prefs', this.prefs.size);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load prefs failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Persist prefs to disk with a schema envelope. */
  save(): void {
    if (!this.filePath) return;
    try {
      const obj: Record<string, CameraCachePref> = {};
      this.prefs.forEach((v, k) => {
        obj[k] = v;
      });
      const envelope: CameraCachePrefsFile = {
        version: SCHEMA_VERSION,
        prefs: obj
      };
      AtomicFile.writeText(this.filePath, JSON.stringify(envelope, null, 2));
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
        lastSeen: now
      });
    }
    this.save();
  }

  /**
   * 每次连接相机时刷新 lastSeen / friendlyName。
   * 不改变 cachingEnabled，也不会为“尚未回答弹窗”的新相机凭空建条目。
   */
  touch(cameraId: string, friendlyName: string): void {
    const existing = this.prefs.get(cameraId);
    if (!existing) return;
    if (friendlyName !== '') {
      existing.friendlyName = friendlyName;
    }
    existing.lastSeen = new Date().toISOString();
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
