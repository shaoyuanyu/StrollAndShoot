/**
 * Photo entry model — extracted from PtpHost for shared use across pages.
 */
export interface PhotoEntry {
  handle: number;
  filename: string;
  size: number;
  // Extended fields from NAPI PtpObjectInfo (populated when available)
  captureDate?: string;
  objectFormat?: number;
  imagePixWidth?: number;
  imagePixHeight?: number;
  storageId?: number;
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
