import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';

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

export class AppLog {
  private entries: LogEntry[] = [];
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

    if (level === LogLevel.ERROR) {
      hilog.error(0x0000, 'AppLog', '%{public}s', msg);
    } else if (level === LogLevel.WARN) {
      hilog.warn(0x0000, 'AppLog', '%{public}s', msg);
    } else {
      hilog.info(0x0000, 'AppLog', '%{public}s', msg);
    }

    if (this.entries.length > 200) {
      this.entries = this.entries.slice(-200);
    }

    this.scheduleFlush();
  }

  // Debounce file writes: flush at most once per second
  private scheduleFlush(): void {
    if (this.flushTimer >= 0) return; // already scheduled
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.flushToFile();
    }, 1000);
  }

  private async flushToFile(): Promise<void> {
    if (!this.filePath) return;
    try {
      const text = this.getText();
      const f = await fileIo.open(this.filePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.write(f.fd, text);
      await fileIo.close(f);
    } catch (_e) {
      // best effort
    }
  }

  getText(): string {
    return this.entries.map((e: LogEntry) =>
      `[${e.timestamp}] ${e.message}`).join('\n');
  }

  getEntries(): LogEntry[] {
    return this.entries;
  }

  clear(): void {
    this.entries = [];
    if (this.filePath) {
      try {
        const f = fileIo.openSync(this.filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, '');
        fileIo.closeSync(f);
      } catch (_e) {}
    }
  }
}
