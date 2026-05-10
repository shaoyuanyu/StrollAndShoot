import { geoLocationManager } from '@kit.LocationKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { AppLog } from './AppLog';
import type { GpsRecord, GpsDailyGroup } from '../model/PhotoEntry';

const LOCATION_PERMS: Permissions[] = [
  'ohos.permission.LOCATION',
  'ohos.permission.APPROXIMATELY_LOCATION'
];

export class GpsRecorder {
  private static instance: GpsRecorder;

  private records: GpsRecord[] = [];
  private log: AppLog = new AppLog();
  private running: boolean = false;
  private storageDir: string = '';
  private intervalSeconds: number = 60;
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private context: common.UIAbilityContext | null = null;
  private permissionsChecked: boolean = false;
  onChange: () => void = () => {};

  static getInstance(): GpsRecorder {
    if (!GpsRecorder.instance) {
      GpsRecorder.instance = new GpsRecorder();
    }
    return GpsRecorder.instance;
  }

  private constructor() {}

  init(dir: string, log: AppLog, ctx: common.UIAbilityContext): void {
    this.storageDir = dir;
    this.log = log;
    this.context = ctx;
    this.loadInterval();
    this.loadRecords();
  }

  private async ensurePermissions(): Promise<boolean> {
    if (this.permissionsChecked) return true;
    if (!this.context) return false;

    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const result = await atManager.requestPermissionsFromUser(
        this.context, LOCATION_PERMS
      );
      const granted = result.authResults.every((r: number) => r === 0);
      if (granted) {
        this.permissionsChecked = true;
      }
      return granted;
    } catch (_e) {
      return false;
    }
  }

  getRecords(): GpsRecord[] {
    return this.records;
  }

  recordCount(): number {
    return this.records.length;
  }

  async setInterval(seconds: number): Promise<void> {
    this.intervalSeconds = seconds;
    this.saveInterval();
    if (this.running) {
      this.stop();
      await this.start();
    }
  }

  getInterval(): number {
    return this.intervalSeconds;
  }

  async start(): Promise<void> {
    if (this.running) return;

    // Request runtime permissions first
    const permitted = await this.ensurePermissions();
    if (!permitted) {
      this.log.add('GPS记录: 位置权限未授权');
      return;
    }

    if (!geoLocationManager.isLocationEnabled()) {
      this.log.add('GPS记录: 位置服务未开启');
      return;
    }

    try {
      let callbackCount = 0;
      this.locationCallback = (location: geoLocationManager.Location): void => {
        callbackCount++;
        const record: GpsRecord = {
          timestamp: location.timeStamp,
          latitude: location.latitude,
          longitude: location.longitude,
          altitude: location.altitude ?? 0
        };
        this.records.push(record);
        this.saveRecords();
        this.onChange();
        this.log.add(`GPS定位 #${callbackCount}: ${record.latitude.toFixed(4)},${record.longitude.toFixed(4)} (共${this.records.length}条)`);
      };

      const requestCfg: geoLocationManager.ContinuousLocationRequest = {
        interval: this.intervalSeconds,
        locationScenario: geoLocationManager.UserActivityScenario.DAILY_LIFE_SERVICE
      };

      geoLocationManager.on('locationChange', requestCfg, this.locationCallback);
      this.running = true;
      this.saveInterval();
      this.log.add(`GPS记录已启动 (间隔${this.intervalSeconds}秒, 已有${this.records.length}条)`);
    } catch (err) {
      this.log.add(`GPS记录启动失败: ${JSON.stringify(err)}`);
    }
  }

  stop(): void {
    if (!this.running) return;

    try {
      if (this.locationCallback) {
        geoLocationManager.off('locationChange', this.locationCallback);
      }
    } catch (err) {
      this.log.add(`GPS记录停止失败: ${JSON.stringify(err)}`);
    }
    this.running = false;
    this.locationCallback = undefined;
    this.saveInterval();
    this.log.add(`GPS记录已停止 (共${this.records.length}条)`);
  }

  isRunning(): boolean {
    return this.running;
  }

  /**
   * Find the GPS record with timestamp closest to the given capture date.
   * Returns null if no records exist or the closest record exceeds `maxDiffMs`.
   */
  findClosest(captureDate: string, maxDiffMs: number = 30 * 60 * 1000): GpsRecord | null {
    if (this.records.length === 0) return null;

    const photoTime = GpsRecorder.parseCaptureDate(captureDate);
    if (photoTime <= 1000) return null;

    // Binary search for closest
    let lo = 0;
    let hi = this.records.length - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.records[mid].timestamp < photoTime) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    // Check neighbors around the insertion point
    let bestIdx = lo;
    let bestDiff = Math.abs(this.records[lo].timestamp - photoTime);

    if (lo > 0) {
      const diff = Math.abs(this.records[lo - 1].timestamp - photoTime);
      if (diff < bestDiff) { bestDiff = diff; bestIdx = lo - 1; }
    }
    if (lo + 1 < this.records.length) {
      const diff = Math.abs(this.records[lo + 1].timestamp - photoTime);
      if (diff < bestDiff) { bestDiff = diff; bestIdx = lo + 1; }
    }

    if (bestDiff > maxDiffMs) return null;
    return this.records[bestIdx];
  }

  static parseCaptureDate(raw: string): number {
    if (!raw || raw.length < 14) return 0;

    try {
      // PTP format: "YYYYMMDDThhmmss" or "YYYYMMDDThhmmss.s"
      const t = raw.indexOf('T');
      const datePart = t >= 0 ? raw.substring(0, t) : raw.substring(0, 8);
      const timePart = t >= 0 ? raw.substring(t + 1).replace('.', '') : raw.substring(8, 14);

      const year = parseInt(datePart.substring(0, 4));
      const month = parseInt(datePart.substring(4, 6)) - 1;
      const day = parseInt(datePart.substring(6, 8));
      const hour = parseInt(timePart.substring(0, 2));
      const min = parseInt(timePart.substring(2, 4));
      const sec = parseInt(timePart.substring(4, 6));

      // Camera captureDate is in local time; GPS timeStamp is UTC epoch ms.
      // Use Date (local time) constructor to align with GPS UTC time.
      const localDate = new Date(year, month, day, hour, min, sec);
      return localDate.getTime();
    } catch (_e) {
      return 0;
    }
  }

  /** Returns records grouped by day, sorted newest first. */
  getDailyStats(): GpsDailyGroup[] {
    const map = new Map<string, GpsRecord[]>();
    for (const r of this.records) {
      const d = new Date(r.timestamp);
      const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      let arr = map.get(key);
      if (!arr) { arr = []; map.set(key, arr); }
      arr.push(r);
    }
    const result: GpsDailyGroup[] = [];
    map.forEach((recs: GpsRecord[], day: string) => {
      result.push({ day, count: recs.length });
    });
    result.sort((a: GpsDailyGroup, b: GpsDailyGroup) => b.day.localeCompare(a.day));
    return result;
  }

  /** Delete all records for a given day. Returns the new total count. */
  deleteDay(dateKey: string): number {
    const before = this.records.length;
    this.records = this.records.filter((r: GpsRecord) => {
      const d = new Date(r.timestamp);
      const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      return key !== dateKey;
    });
    const removed = before - this.records.length;
    if (removed > 0) {
      this.saveRecords();
      this.onChange();
      this.log.add(`已删除 ${dateKey} 的 ${removed} 条GPS记录`);
    }
    return this.records.length;
  }

  clearRecords(): void {
    this.records = [];
    this.saveRecords();
    this.log.add('GPS记录已清除');
  }

  private settingsPath(): string {
    return this.storageDir + '/gps_settings.json';
  }

  private loadInterval(): void {
    try {
      const f = fileIo.openSync(this.settingsPath(), fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(this.settingsPath());
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
      const obj = JSON.parse(text) as Record<string, number>;
      if (typeof obj.interval === 'number' && obj.interval > 0) {
        this.intervalSeconds = obj.interval;
      }
    } catch (_e) {
      // keep default
    }
  }

  private saveInterval(): void {
    if (!this.storageDir) return;
    try {
      const text = JSON.stringify({
        interval: this.intervalSeconds,
        wasRunning: this.running
      });
      const f = fileIo.openSync(this.settingsPath(),
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
    } catch (_e) { /* ignore */ }
  }

  /** Resume GPS recording if it was active in the previous session. */
  async autoStart(): Promise<void> {
    let wasRunning = false;
    try {
      const f = fileIo.openSync(this.settingsPath(), fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(this.settingsPath());
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
      const obj = JSON.parse(text) as Record<string, Object>;
      wasRunning = obj.wasRunning === true;
    } catch (_e) { /* ignore */ }
    if (wasRunning) {
      await this.start();
      this.onChange();
    }
  }

  private recordsPath(): string {
    return this.storageDir + '/gps_records.json';
  }

  private loadRecords(): void {
    try {
      const f = fileIo.openSync(this.recordsPath(), fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(this.recordsPath());
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
      this.records = JSON.parse(text) as GpsRecord[];
    } catch (_e) {
      this.records = [];
    }
  }

  private saveRecords(): void {
    if (!this.storageDir) return;
    try {
      const text = JSON.stringify(this.records);
      const f = fileIo.openSync(this.recordsPath(),
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
    } catch (err) {
      this.log.add(`GPS记录保存失败: ${JSON.stringify(err)}`);
    }
  }
}
