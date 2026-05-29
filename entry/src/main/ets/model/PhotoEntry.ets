/**
 * Photo entry model — extracted from PtpHost for shared use across pages.
 */
export interface PhotoEntry {
  handle: number;
  filename: string;
  size: number;
  // Extended fields from NAPI PtpObjectInfo (populated when available)
  captureDate?: string;
  modificationDate?: string;
  objectFormat?: number;
  imagePixWidth?: number;
  imagePixHeight?: number;
  storageId?: number;
}

/**
 * Unified display group for both content-first and file-first modes.
 * In file-first mode, each PhotoEntry maps to one group (alternates empty).
 * In content-first mode, photos with the same basename are merged into one group.
 */
export interface DisplayGroup {
  basename: string;
  displayPhoto: PhotoEntry;
  alternates: PhotoEntry[];
  allPhotos: PhotoEntry[];
}

/**
 * Persistent record of a downloaded photo.
 * Keyed by `${filename}::${size}` since PTP handles are not stable across sessions.
 */
export interface DownloadRecord {
  key: string;
  filename: string;
  size: number;
  localPath: string;
  downloadDate: string;
}

/**
 * Progress snapshot emitted during batch download.
 * USB bulkTransfer is opaque — progress granularity is per-file, not per-byte.
 */
export interface DownloadProgress {
  phase: 'idle' | 'downloading' | 'saving' | 'complete' | 'error';
  currentIndex: number;
  totalCount: number;
  currentFilename: string;
  currentSizeBytes: number;
  downloadedCount: number;
  totalBytes: number;
  downloadedBytes: number;
  errors: string[];
}

export interface DownloadResult {
  handle: number;
  key: string;
  success: boolean;
  localPath: string;
  error?: string;
}

export interface GpsRecord {
  timestamp: number;   // epoch ms
  latitude: number;
  longitude: number;
  altitude: number;     // meters, 0 if unavailable
}

export interface GpsDailyGroup {
  day: string;    // "YYYY-MM-DD"
  count: number;
}
