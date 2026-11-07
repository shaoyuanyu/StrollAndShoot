import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { AtomicFile } from '../utils/AtomicFile';

export enum LogLevel {
  INFO = 0,
  WARN = 1,
  ERROR = 2
}

export interface LogEntry {
  timestamp: string;
  message: string;
  level: LogLevel;
}

/** 内存里保留的日志条数（设置页只读这里）。 */
const MAX_ENTRIES = 500;
/** 单个日志文件超过 512KB 时轮转到 .1，避免无限增长。 */
const MAX_FILE_BYTES = 512 * 1024;
const FLUSH_DELAY_MS = 1000;

export class AppLog {
  private entries: LogEntry[] = [];
  private pendingLines: string[] = [];
  private filePath: string = '';
  private flushTimer: number = -1;

  setFilePath(path: string): void {
    this.filePath = path;
  }

  add(msg: string): void {
    this.addWithLevel(msg, LogLevel.INFO);
  }

  addWithLevel(msg: string, level: LogLevel): void {
    const ts = new Date().toLocaleTimeString();
    const entry: LogEntry = { timestamp: ts, message: msg, level: level };
    this.entries.push(entry);
    this.pendingLines.push(`[${ts}] ${msg}`);

    if (level === LogLevel.ERROR) {
      hilog.error(0x0000, 'AppLog', '%{public}s', msg);
    } else if (level === LogLevel.WARN) {
      hilog.warn(0x0000, 'AppLog', '%{public}s', msg);
    } else {
      hilog.info(0x0000, 'AppLog', '%{public}s', msg);
    }

    if (this.entries.length > MAX_ENTRIES) {
      this.entries = this.entries.slice(-MAX_ENTRIES);
    }
    if (this.pendingLines.length > MAX_ENTRIES) {
      this.pendingLines = this.pendingLines.slice(-MAX_ENTRIES);
    }

    this.scheduleFlush();
  }

  // Debounce file writes: flush at most once per second
  private scheduleFlush(): void {
    if (this.flushTimer >= 0) return; // already scheduled
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.flushNow();
    }, FLUSH_DELAY_MS);
  }

  /** 立即把待写日志追加到文件。进入后台/退出前调用。 */
  flushNow(): void {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    if (!this.filePath || this.pendingLines.length === 0) return;
    const lines = this.pendingLines;
    this.pendingLines = [];
    try {
      this.rotateIfNeeded();
      AtomicFile.appendText(this.filePath, lines.join('\n') + '\n');
    } catch (_e) {
      // 写失败时放回待写队列，下次再试；同时限制长度避免无限增长。
      const merged = lines.concat(this.pendingLines);
      this.pendingLines = merged.length > MAX_ENTRIES
        ? merged.slice(-MAX_ENTRIES) : merged;
    }
  }

  /** 文件超过上限时把当前日志改名为 .1，下一行从空文件开始。 */
  private rotateIfNeeded(): void {
    if (!this.filePath) return;
    try {
      const stat = fileIo.statSync(this.filePath);
      if (stat.size <= MAX_FILE_BYTES) return;
      const old = this.filePath + '.1';
      try {
        fileIo.unlinkSync(old);
      } catch (_e) {
        // best effort
      }
      fileIo.renameSync(this.filePath, old);
    } catch (_e) {
      // 文件还不存在
    }
  }

  getText(): string {
    return this.entries.map((e: LogEntry) =>
      `[${e.timestamp}] ${e.message}`).join('\n');
  }

  clear(): void {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.entries = [];
    this.pendingLines = [];
    if (this.filePath) {
      try {
        const f = fileIo.openSync(this.filePath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.closeSync(f);
      } catch (_e) {
        // best effort
      }
      AtomicFile.delete(this.filePath + '.1');
    }
  }
}
