import { fileIo } from '@kit.CoreFileKit';
import { AtomicFile } from '../utils/AtomicFile';

/**
 * 分块下载的断点元数据。
 *
 * 文件的**实际长度**才是续传的 offset，这里存的 `handle / filename / size`
 * 只用来判断“这段残片是不是同一张照片的”。`cameraIdentity` 防止换相机后
 * 同名同大小的照片误续；`handle` 在同一张卡的同一轮会话里稳定。
 */
export interface DownloadPartMeta {
  version: number;
  cameraId: string;
  handle: number;
  filename: string;
  size: number;
  updatedAt: number;
}

/** `.part` 文件与 `.part.json` 的命名、校验和清理。 */
export class DownloadResume {
  static readonly VERSION: number = 1;

  /**
   * 临时分片路径。
   *
   * 文件名里带上 `size`，同名但大小不同的两张照片不会共用一段残片；
   * 调用方传进来的 `safeFilename` 已经过 `sanitizeFilename()`。
   */
  static partPath(tempDir: string, safeFilename: string, size: number): string {
    return `${tempDir}/${safeFilename}.${size}.part`;
  }

  static metaPath(partPath: string): string {
    return partPath + '.json';
  }

  static makeMeta(cameraId: string, handle: number, filename: string, size: number): DownloadPartMeta {
    return {
      version: DownloadResume.VERSION,
      cameraId: cameraId,
      handle: handle,
      filename: filename,
      size: size,
      updatedAt: Date.now()
    };
  }

  static readMeta(partPath: string): DownloadPartMeta | null {
    const text = AtomicFile.readText(DownloadResume.metaPath(partPath));
    if (text === null || text === '') return null;
    try {
      const raw = JSON.parse(text) as DownloadPartMeta;
      if (raw === null || raw.version !== DownloadResume.VERSION) return null;
      return raw;
    } catch (_e) {
      return null;
    }
  }

  static writeMeta(partPath: string, meta: DownloadPartMeta): void {
    AtomicFile.writeText(DownloadResume.metaPath(partPath), JSON.stringify(meta));
  }

  /** 残片必须属于同一台相机、同一个对象、同名同大小。 */
  static matches(meta: DownloadPartMeta | null, cameraId: string, handle: number,
                 filename: string, size: number): boolean {
    return meta !== null && meta.version === DownloadResume.VERSION
      && meta.cameraId === cameraId && meta.handle === handle
      && meta.filename === filename && meta.size === size;
  }

  static exists(path: string): boolean {
    return AtomicFile.exists(path);
  }

  /** 文件长度；不存在或读不到都按 0 处理。 */
  static sizeOf(path: string): number {
    try {
      const stat = fileIo.statSync(path);
      return stat.size;
    } catch (_e) {
      return 0;
    }
  }

  static remove(path: string): void {
    AtomicFile.delete(path);
  }

  static removeMeta(partPath: string): void {
    AtomicFile.delete(DownloadResume.metaPath(partPath));
  }

  static removePart(partPath: string): void {
    DownloadResume.remove(partPath);
    DownloadResume.removeMeta(partPath);
  }
}
