import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/**
 * 小文件持久化工具。
 *
 * 所有 JSON / 文本快照都走这里：
 * - 写入先落到 `.tmp`，再 rename 覆盖，避免崩溃时留下半截文件；
 * - rename 失败时退回 copy + unlink（部分文件系统不支持覆盖 rename）；
 * - 读取失败返回 null，由调用方决定是“首次使用”还是“损坏”。
 */
export class AtomicFile {
  /** 原子写文本。失败会抛异常，调用方负责记录日志。 */
  static writeText(path: string, text: string): void {
    const tmp = path + '.tmp';
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(tmp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_e) {
          // best effort
        }
      }
    }
    try {
      fileIo.renameSync(tmp, path);
    } catch (_e) {
      try {
        fileIo.copyFileSync(tmp, path, 0);
      } finally {
        try {
          fileIo.unlinkSync(tmp);
        } catch (_e2) {
          // best effort
        }
      }
    }
  }

  /** 读文本。文件不存在或读取失败返回 null；空文件返回 ''。 */
  static readText(path: string): string | null {
    let file: fileIo.File | null = null;
    try {
      const stat = fileIo.statSync(path);
      if (stat.size <= 0) return '';
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      return new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
    } catch (_e) {
      return null;
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_e2) {
          // best effort
        }
      }
    }
  }

  /** 文件或目录是否存在。权限异常按不存在处理。 */
  static exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_e) {
      return false;
    }
  }

  /** 删除单个文件，失败忽略。 */
  static delete(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (_e) {
      // best effort
    }
  }

  /** 递归删除目录（含子目录与文件）。 */
  static deleteDirRecursive(path: string): void {
    try {
      fileIo.rmdirSync(path);
    } catch (_e) {
      // best effort
    }
  }

  /** 追加文本。失败会抛异常，调用方负责记录日志。 */
  static appendText(path: string, text: string): void {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, text);
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_e) {
          // best effort
        }
      }
    }
  }
}
