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
 * Keyed by `${cameraId}::${filename}::${size}`: PTP handles are not stable
 * across sessions, and the same filename/size can appear on two cameras.
 */
export interface DownloadRecord {
  key: string;
  /** 相机身份；旧版记录没有该字段，读取时按无相机记录兼容。 */
  cameraId?: string;
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
  timestamp: number;   // epoch ms，最后一次定位的时间
  latitude: number;
  longitude: number;
  altitude: number;     // meters, 0 if unavailable
  /**
   * 这一轮「原地不动」的起点时间（epoch ms）。合并心跳按它计算：
   * 从起点起满 10 分钟就补一条新记录，否则静止一整天只剩最后一个点，
   * 当天早些时候拍的照片会匹配不到 GPS。旧数据没有该字段时视为 timestamp。
   */
  runStart?: number;
  /** 调试包「模拟 GPS 轨迹」注入的点；只影响显示，不写入 gps_records.jsonl。 */
  mock?: boolean;
}

export interface GpsDailyGroup {
  day: string;    // "YYYY-MM-DD"
  count: number;
  first: number;  // 当天第一条记录的时间戳（epoch ms）
  last: number;   // 当天最后一条记录的时间戳
  /** 这一天当前显示的是否为模拟轨迹（仅调试包）。 */
  mock?: boolean;
}
