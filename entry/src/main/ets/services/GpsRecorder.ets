import geoLocationManager from '@ohos.geoLocationManager';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { abilityAccessCtrl, common, Permissions, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { AppLog } from './AppLog';
import { GpsTrack } from '../utils/GpsTrack';
import type { GpsRecord, GpsDailyGroup } from '../model/PhotoEntry';

const LOCATION_PERMS: Permissions[] = [
  'ohos.permission.LOCATION',
  'ohos.permission.APPROXIMATELY_LOCATION'
];

/** 记录总量上限，超出后丢弃最旧的 10%。 */
const MAX_RECORDS = 20000;

/**
 * 连续定位服务。状态直接暴露成 @Trace 字段，页面绑定后自动刷新，
 * 不再由页面之间手工同步副本（之前 UI 显示的状态和真实状态会对不上）。
 */
@ObservedV2
export class GpsRecorder {
  private static instance: GpsRecorder;

  /** 是否正在记录。真值来源只有这里，页面只读。 */
  @Trace running: boolean = false;
  /** 已记录的位置点数量。 */
  @Trace recordCount: number = 0;
  /** 0=精确(11s), 1=日常(61s), 2=省电(121s)。 */
  @Trace gpsMode: number = 2;
  /** 最近一次定位结果，null 表示启动后还没拿到定位。 */
  @Trace lastFix: GpsRecord | null = null;
  /** 最近一次启动失败的原因，空串表示没有错误。 */
  @Trace lastError: string = '';
  /** 记录集变化计数。页面读它建立 V2 依赖（records 本身是普通数组）。 */
  @Trace recordsVersion: number = 0;

  private records: GpsRecord[] = [];
  private log: AppLog = new AppLog();
  private storageDir: string = '';
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private context: common.UIAbilityContext | null = null;
  private permissionsChecked: boolean = false;
  /** 正在启动中的启动流程，避免连点时重复订阅回调。 */
  private startPromise: Promise<boolean> | null = null;

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
    this.loadMode();
    this.loadRecords();
  }

  /** 申请位置权限。返回空串表示已授权，否则返回给用户看的原因。 */
  private async ensurePermissions(): Promise<string> {
    if (this.permissionsChecked) return '';
    if (!this.context) return '无法获取应用上下文';

    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const result = await atManager.requestPermissionsFromUser(
        this.context, LOCATION_PERMS
      );
      const granted = result.authResults.every((r: number) => r === 0);
      if (granted) {
        this.permissionsChecked = true;
        return '';
      }
      return '未授予位置权限，请在系统设置中允许「走走拍拍」获取位置';
    } catch (err) {
      return `位置权限申请失败: ${JSON.stringify(err)}`;
    }
  }

  getRecords(): GpsRecord[] {
    return this.records;
  }

  /** 切换记录频率。正在记录时会按新频率重启，返回是否最终在运行。 */
  async setGpsMode(mode: number): Promise<boolean> {
    if (mode === this.gpsMode) return this.running;
    this.gpsMode = mode;
    this.saveMode();
    if (!this.running) return false;
    await this.stop();
    return this.start();
  }

  getGpsModeLabel(): string {
    switch (this.gpsMode) {
      case 0: return '精确';
      case 1: return '日常';
      default: return '省电';
    }
  }

  /** 按页面上的开关意图启停。返回是否成功，失败原因写在 lastError。 */
  async toggle(on: boolean): Promise<boolean> {
    if (on) return this.start();
    // 启动过程中用户把开关拨回去：先等启动流程落定再停。否则 stop 会因为
    // running 还是 false 直接返回，随后 start 又把 running 置回 true，开关弹回去。
    if (this.startPromise !== null) {
      try {
        await this.startPromise;
      } catch (_e) {
        // 启动失败也要继续走停止流程，把落盘状态清成 false
      }
    }
    await this.stop();
    this.lastError = '';
    return true;
  }

  async start(): Promise<boolean> {
    if (this.running) return true;
    // 连点时复用同一次启动流程：重复订阅会把每个定位写成两条记录
    if (this.startPromise !== null) return this.startPromise;
    const promise = this.doStart();
    this.startPromise = promise;
    try {
      return await promise;
    } finally {
      this.startPromise = null;
    }
  }

  private fail(message: string): boolean {
    this.lastError = message;
    this.log.add(`GPS记录启动失败: ${message}`);
    return false;
  }

  private async doStart(): Promise<boolean> {
    this.lastError = '';

    if (!canIUse('SystemCapability.Location.Location.Core')) {
      return this.fail('当前设备不支持定位能力');
    }

    const permError = await this.ensurePermissions();
    if (permError !== '') return this.fail(permError);

    let locationEnabled = false;
    try {
      // @SuppressWarnings syscap
      locationEnabled = geoLocationManager.isLocationEnabled();
    } catch (err) {
      return this.fail(`定位状态检查失败: ${JSON.stringify(err)}`);
    }
    if (!locationEnabled) {
      return this.fail('系统位置服务未开启，请在控制中心打开「位置」后重试');
    }

    let scenario: geoLocationManager.UserActivityScenario;
    let interval: number;
    if (this.gpsMode === 0) {
      // @SuppressWarnings syscap
      scenario = geoLocationManager.UserActivityScenario.TRANSPORT;
      interval = 11;
    } else if (this.gpsMode === 1) {
      // @SuppressWarnings syscap
      scenario = geoLocationManager.UserActivityScenario.TRANSPORT;
      interval = 61;
    } else {
      // @SuppressWarnings syscap
      scenario = geoLocationManager.UserActivityScenario.DAILY_LIFE_SERVICE;
      interval = 121;
    }

    try {
      this.locationCallback = (location: geoLocationManager.Location): void => {
        this.handleLocation(location);
      };

      const requestCfg: geoLocationManager.ContinuousLocationRequest = {
        interval: interval,
        locationScenario: scenario
      };

      // @SuppressWarnings syscap
      geoLocationManager.on('locationChange', requestCfg, this.locationCallback);
      this.running = true;
      this.lastFix = null;
      this.saveMode();

      // Request continuous task for background GPS
      await this.requestContinuousTask();

      this.log.add(`GPS记录已启动 (${this.getGpsModeLabel()}模式, interval=${interval}s, 已有${this.records.length}条)`);
      return true;
    } catch (err) {
      // 订阅失败要把半成品清掉，否则界面显示在记录、实际没有回调
      if (this.locationCallback !== undefined) {
        try {
          // @SuppressWarnings syscap
          geoLocationManager.off('locationChange', this.locationCallback);
        } catch (_e) {
          // ignore
        }
      }
      this.locationCallback = undefined;
      this.running = false;
      this.saveMode();
      return this.fail(`启动定位失败: ${JSON.stringify(err)}`);
    }
  }

  private handleLocation(location: geoLocationManager.Location): void {
    const record: GpsRecord = {
      timestamp: location.timeStamp,
      latitude: location.latitude,
      longitude: location.longitude,
      altitude: location.altitude ?? 0
    };

    // 定位源切换/丢星恢复时可能一下甩到几十公里外。丢弃这一次，但把它当作
    // 下一次判断的参考点，真到了新城市后第二个点仍能正常入库。
    const prev = this.lastFix;
    if (prev !== null && GpsTrack.isImplausibleJump(prev, record)) {
      const seconds = Math.max(1, Math.round((record.timestamp - prev.timestamp) / 1000));
      const km = GpsTrack.distanceMeters(
        prev.latitude, prev.longitude, record.latitude, record.longitude
      ) / 1000;
      this.log.add(`GPS跳点已忽略: ${record.latitude.toFixed(4)},${record.longitude.toFixed(4)} (${seconds}s 内 ${km.toFixed(1)}km)`);
      this.lastFix = record;
      return;
    }

    const merged = GpsTrack.append(this.records, record);
    if (!merged && this.records.length >= 2 &&
      record.timestamp <= this.records[this.records.length - 2].timestamp) {
      // 系统时间被回拨时保持按时间有序，findClosest 的二分查找才不会失效
      this.records.sort((a: GpsRecord, b: GpsRecord) => a.timestamp - b.timestamp);
    }
    this.lastFix = merged ? this.records[this.records.length - 1] : record;
    this.pruneIfNeeded();
    this.recordCount = this.records.length;
    this.recordsVersion++;
    this.saveRecords();
    const tag = merged ? '更新末点' : '新增';
    this.log.add(`GPS定位${tag}: ${record.latitude.toFixed(4)},${record.longitude.toFixed(4)} (共${this.records.length}条)`);
  }

  private pruneIfNeeded(): void {
    if (this.records.length <= MAX_RECORDS) return;
    const drop = Math.floor(MAX_RECORDS / 10);
    this.records.splice(0, drop);
    this.recordCount = this.records.length;
    this.log.add(`GPS记录超过 ${MAX_RECORDS} 条，已清理最旧的 ${drop} 条`);
  }

  async stop(): Promise<void> {
    const wasRunning = this.running;
    if (wasRunning || this.locationCallback !== undefined) {
      await this.cancelContinuousTask();

      if (canIUse('SystemCapability.Location.Location.Core') && this.locationCallback !== undefined) {
        try {
          // @SuppressWarnings syscap
          geoLocationManager.off('locationChange', this.locationCallback);
        } catch (err) {
          this.log.add(`GPS记录停止失败: ${JSON.stringify(err)}`);
        }
      }
    }
    this.running = false;
    this.lastFix = null;
    this.locationCallback = undefined;
    // 即使本来就没在跑也要落盘：启动失败后用户把开关拨回去时，
    // 不写 wasRunning=false 的话下次启动还会自动重试。
    this.saveMode();
    if (wasRunning) {
      this.log.add(`GPS记录已停止 (共${this.records.length}条)`);
    }
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
    // 先读一次 recordsVersion 建立 V2 依赖：records 是普通数组，不读版本号页面不会刷新
    if (this.recordsVersion < 0) return [];
    const map = new Map<string, GpsRecord[]>();
    const d = new Date();
    for (const r of this.records) {
      d.setTime(r.timestamp);
      const key = GpsRecorder.dayKeyOf(d);
      let arr = map.get(key);
      if (!arr) { arr = []; map.set(key, arr); }
      arr.push(r);
    }
    const result: GpsDailyGroup[] = [];
    map.forEach((recs: GpsRecord[], day: string) => {
      result.push({
        day: day,
        count: recs.length,
        // 第一条用 runStart：静止心跳点的 timestamp 是这一轮的最后一个点，
        // 直接拿它当「当天开始时间」会平白晚最多 10 分钟。runStart 落到
        // 前一天时（跨午夜的一轮静止）按当天 0 点裁剪，避免显示 23:55–00:05。
        first: Math.max(
          GpsTrack.runStartOf(recs[0]),
          GpsRecorder.startOfDay(recs[0].timestamp)
        ),
        last: recs[recs.length - 1].timestamp
      });
    });
    result.sort((a: GpsDailyGroup, b: GpsDailyGroup) => b.day.localeCompare(a.day));
    return result;
  }

  /** Returns all records for a specific day (YYYY-MM-DD), sorted by time ascending. */
  getDayRecords(dateKey: string): GpsRecord[] {
    // 同 getDailyStats：读版本号建立 V2 依赖（见 thumbForRender 的同样做法）
    if (this.recordsVersion < 0) return [];
    const d = new Date();
    return this.records
      .filter((r: GpsRecord) => {
        d.setTime(r.timestamp);
        return GpsRecorder.dayKeyOf(d) === dateKey;
      })
      .sort((a: GpsRecord, b: GpsRecord) => a.timestamp - b.timestamp);
  }

  private static dayKeyOf(d: Date): string {
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${d.getFullYear()}-${m}-${day}`;
  }

  private static dayKey(timestamp: number): string {
    return GpsRecorder.dayKeyOf(new Date(timestamp));
  }

  private static startOfDay(timestamp: number): number {
    const d = new Date(timestamp);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  /** Delete all records for a given day. Returns the new total count. */
  deleteDay(dateKey: string): number {
    const before = this.records.length;
    const d = new Date();
    this.records = this.records.filter((r: GpsRecord) => {
      d.setTime(r.timestamp);
      return GpsRecorder.dayKeyOf(d) !== dateKey;
    });
    const removed = before - this.records.length;
    if (removed > 0) {
      // 被删掉的最后一条可能正是跳点判断的参考点，清掉避免下一次定位被误判
      if (this.lastFix !== null && GpsRecorder.dayKey(this.lastFix.timestamp) === dateKey) {
        this.lastFix = null;
      }
      this.recordCount = this.records.length;
      this.recordsVersion++;
      this.saveRecords();
      this.log.add(`已删除 ${dateKey} 的 ${removed} 条GPS记录`);
    }
    return this.records.length;
  }

  clearRecords(): void {
    this.records = [];
    this.recordCount = 0;
    this.recordsVersion++;
    this.lastFix = null;
    this.saveRecords();
    this.log.add('GPS记录已清除');
  }

  private async requestContinuousTask(): Promise<void> {
    if (!this.context) return;
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'io.github.shaoyuanyu.strollandshoot',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
      };
      const wa: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.LOCATION,
        wa
      );
      this.log.add('后台定位长时任务已申请');
    } catch (err) {
      this.log.add(`后台长时任务申请失败: ${JSON.stringify(err)}`);
    }
  }

  private async cancelContinuousTask(): Promise<void> {
    if (!this.context) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.log.add('后台定位长时任务已取消');
    } catch (err) {
      this.log.add(`后台长时任务取消失败: ${JSON.stringify(err)}`);
    }
  }

  private settingsPath(): string {
    return this.storageDir + '/gps_settings.json';
  }

  private loadMode(): void {
    try {
      const f = fileIo.openSync(this.settingsPath(), fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(this.settingsPath());
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
      const obj = JSON.parse(text) as Record<string, Object>;
      if (typeof obj.gpsMode === 'number') {
        // Also migrate from old boolean precisionMode
        this.gpsMode = obj.gpsMode as number;
      } else if (typeof obj.precisionMode === 'boolean') {
        this.gpsMode = (obj.precisionMode as boolean) ? 0 : 2;
      }
    } catch (_e) {
      // keep default
    }
  }

  private saveMode(): void {
    if (!this.storageDir) return;
    try {
      const text = JSON.stringify({
        gpsMode: this.gpsMode,
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
    // 旧版本是「每隔几十秒堆一条」，同一位置会重复很多次，且时间顺序未必可靠。
    // 读入时先排序（findClosest 的二分查找依赖升序），再按新规则折叠历史重复点。
    this.records.sort((a: GpsRecord, b: GpsRecord) => a.timestamp - b.timestamp);
    const before = this.records.length;
    let needsSave = false;
    for (let i = 0; i < this.records.length; i++) {
      if (this.records[i].runStart === undefined) {
        needsSave = true;
        break;
      }
    }
    const compacted = GpsTrack.compact(this.records);
    if (compacted.length !== before) {
      this.records = compacted;
      needsSave = true;
      this.log.add(`GPS历史记录已整理: ${before} 条 -> ${compacted.length} 条`);
    } else if (needsSave) {
      // 只是补齐 runStart，不改变条数
      this.records = compacted;
    }
    if (needsSave) {
      this.saveRecords();
    }
    this.recordCount = this.records.length;
    this.recordsVersion++;
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
