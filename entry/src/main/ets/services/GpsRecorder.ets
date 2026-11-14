import geoLocationManager from '@ohos.geoLocationManager';
import { abilityAccessCtrl, common, Permissions, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { AppLog } from './AppLog';
import { GpsTrack } from '../utils/GpsTrack';
import { GpsMockTrack } from '../utils/GpsMockTrack';
import { AtomicFile } from '../utils/AtomicFile';
import { L10n } from '../utils/L10n';
import type { GpsRecord, GpsDailyGroup } from '../model/PhotoEntry';

const LOCATION_PERMS: Permissions[] = [
  'ohos.permission.LOCATION',
  'ohos.permission.APPROXIMATELY_LOCATION'
];

/**
 * 记录总量上限。精确档 11 秒一条，连续移动约 12 天；日常/省电档会更久。
 * 超出后按“整天”丢弃最旧的一天，而不是一次砍掉 10% 的零散记录。
 */
const MAX_RECORDS = 100000;
/** 最长保留天数；超过后也按整天清理。 */
const MAX_RETENTION_DAYS = 365;
/**
 * 内存里的数组最多每 5 分钟压缩重写一次；每个点本身已经追加到 JSONL，
 * 所以即使进程被杀，也不会丢定位（最多留一些待压缩的追加行）。
 * 压缩仍然是一次全量同步写，10 万条时不要把它设得太频繁。
 */
const COMPACT_INTERVAL_MS = 5 * 60 * 1000;

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
  /** 0=精确(11s), 1=日常(61s), 2=省电(121s), 3=出行(31s)。 */
  @Trace gpsMode: number = 2;
  /** 最近一次定位结果，null 表示启动后还没拿到定位。 */
  @Trace lastFix: GpsRecord | null = null;
  /** 最近一次启动失败的原因，空串表示没有错误。 */
  @Trace lastError: string = '';
  /** 记录集变化计数。页面读它建立 V2 依赖（records 本身是普通数组）。 */
  @Trace recordsVersion: number = 0;
  /** 因保留策略被清理的历史条数，设置页用来提示用户。 */
  @Trace trimmedRecords: number = 0;

  private records: GpsRecord[] = [];
  /** 调试包模拟轨迹：只在内存里覆盖当天的显示，不写 gps_records.jsonl。 */
  private mockDay: string = '';
  private mockRecords: GpsRecord[] = [];
  /** 按天聚合的缓存。recordsVersion 不变时直接复用，页面每帧取分组不再遍历全部记录。 */
  private dailyCacheVersion: number = -1;
  private dailyGroups: GpsDailyGroup[] = [];
  private dailyGroupMap: Map<string, GpsDailyGroup> = new Map();
  /** 与 dailyGroups 同步构建的按天记录，getDayRecords 直接复用，避免每次筛选+排序。 */
  private dailyRecordsMap: Map<string, GpsRecord[]> = new Map();
  private dailyDisplayCount: number = 0;
  private log: AppLog = new AppLog();
  private storageDir: string = '';
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private context: common.UIAbilityContext | null = null;
  private permissionsChecked: boolean = false;
  /** 正在启动中的启动流程，避免连点时重复订阅回调。 */
  private startPromise: Promise<boolean> | null = null;
  /** 大记录集延迟压缩：定时器与脏标记。 */
  private saveTimerId: number = -1;
  private savePending: boolean = false;

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
  async ensureLocationPermission(): Promise<string> {
    if (this.permissionsChecked) return '';
    if (!this.context) return L10n.tr('error_no_context');

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
      return L10n.tr('error_location_permission_denied');
    } catch (err) {
      return L10n.tr('error_location_permission_failed', JSON.stringify(err));
    }
  }

  getRecords(): GpsRecord[] {
    return this.records;
  }

  /** 切换记录频率。正在记录时会按新频率重启，返回是否最终在运行。 */
  async setGpsMode(mode: number): Promise<boolean> {
    if (mode < 0 || mode > 3) mode = 2;
    if (mode === this.gpsMode) return this.running;
    this.gpsMode = mode;
    this.saveMode();
    if (!this.running) return false;
    await this.stop();
    return this.start();
  }

  getGpsModeLabel(): string {
    switch (this.gpsMode) {
      case 0: return L10n.tr('settings_gps_precise');
      case 1: return L10n.tr('settings_gps_daily');
      case 3: return L10n.tr('settings_gps_travel');
      default: return L10n.tr('settings_gps_power');
    }
  }

  /** 按页面上的开关意图启停。返回是否成功，失败原因写在 lastError。 */
  async toggle(on: boolean): Promise<boolean> {
    if (on) return this.start();
    // 启动过程中用户把开关拨回去：先等启动流程落定再停。否则 stop 会因为
    // running 还是 false 直接返回，随后 start 又把 running 置回 true，开关弹回去。
    const pending = this.startPromise;
    if (pending !== null) {
      try {
        await Promise.resolve(pending);
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
      return this.fail(L10n.tr('error_location_unsupported'));
    }

    const permError = await this.ensureLocationPermission();
    if (permError !== '') return this.fail(permError);

    let locationEnabled = false;
    try {
      // @SuppressWarnings syscap
      locationEnabled = geoLocationManager.isLocationEnabled();
    } catch (err) {
      return this.fail(L10n.tr('error_location_check_failed', JSON.stringify(err)));
    }
    if (!locationEnabled) {
      return this.fail(L10n.tr('error_location_service_off'));
    }

    let scenario: geoLocationManager.UserActivityScenario;
    let interval: number;
    if (this.gpsMode === 0) {
      // @SuppressWarnings syscap
      scenario = geoLocationManager.UserActivityScenario.TRANSPORT;
      interval = 11;
    } else if (this.gpsMode === 3) {
      // @SuppressWarnings syscap
      scenario = geoLocationManager.UserActivityScenario.TRANSPORT;
      interval = 31;
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
      return this.fail(L10n.tr('error_location_start_failed', JSON.stringify(err)));
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

    const lastBefore = this.records.length > 0
      ? this.records[this.records.length - 1].timestamp
      : 0;
    const merged = GpsTrack.append(this.records, record);
    if (!merged && lastBefore > 0 && record.timestamp < lastBefore) {
      // 系统时间被回拨时保持按时间有序，findClosest 的二分查找才不会失效。
      // 只有一条旧记录时同样要排序，不能因为 length < 2 就跳过。
      this.records.sort((a: GpsRecord, b: GpsRecord) => a.timestamp - b.timestamp);
    }
    this.lastFix = merged ? this.records[this.records.length - 1] : record;
    const trimmed = this.pruneIfNeeded();
    this.recordCount = this.records.length;
    this.recordsVersion++;
    // 每个点先追加到 JSONL：即使 30 秒压缩窗口内进程被杀，记录也已经落盘。
    this.appendRecordToDisk(record);
    this.scheduleSaveRecords();
    if (trimmed) {
      this.saveRecords();
    }
    const tag = merged ? '更新末点' : '新增';
    this.log.add(`GPS定位${tag}: ${record.latitude.toFixed(4)},${record.longitude.toFixed(4)} (共${this.records.length}条)`);
  }

  /** 超出条数/天数上限时按整天丢弃；返回是否真的清理了。 */
  private pruneIfNeeded(): boolean {
    if (this.records.length === 0) return false;
    const cutoffDayStart = GpsTrack.startOfDay(Date.now() - MAX_RETENTION_DAYS * 86400000);
    let drop = 0;
    while (drop < this.records.length) {
      const dayStart = GpsTrack.startOfDay(this.records[drop].timestamp);
      const overCap = this.records.length - drop > MAX_RECORDS;
      const tooOld = dayStart < cutoffDayStart;
      if (!overCap && !tooOld) break;
      // 整天一起丢，避免把某一天切成半截；用当天 0 点做边界，不在循环里反复 new Date。
      const nextDay = dayStart + 86400000;
      while (drop < this.records.length &&
             this.records[drop].timestamp < nextDay) {
        drop++;
      }
    }
    // 一天本身超过上限时，宁可保留当天也不要清空。
    if (drop >= this.records.length) {
      drop = 0;
      const lastDayStart = GpsTrack.startOfDay(
        this.records[this.records.length - 1].timestamp);
      for (let i = this.records.length - 1; i >= 0; i--) {
        if (this.records[i].timestamp < lastDayStart) {
          drop = i + 1;
          break;
        }
      }
    }
    if (drop <= 0) return false;
    const removed = drop;
    this.records = this.records.slice(drop);
    this.recordCount = this.records.length;
    this.trimmedRecords += removed;
    this.log.add(`GPS记录保留策略: 已清理 ${removed} 条旧记录` +
      `（上限 ${MAX_RECORDS} 条 / ${MAX_RETENTION_DAYS} 天）`);
    return true;
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
    // 停止时强制压缩一次，把待压缩的追加行收进快照。
    this.saveRecords();
    // 即使本来就没在跑也要落盘：启动失败后用户把开关拨回去时，
    // 不写 wasRunning=false 的话下次启动还会自动重试。
    this.saveMode();
    if (wasRunning) {
      this.log.add(`GPS记录已停止 (共${this.records.length}条)`);
    }
  }

  /** 应用进入后台 / 退出前调用；只有存在待压缩记录时才重写快照。 */
  flush(): void {
    this.flushRecords();
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
    this.ensureDailyCache();
    return this.dailyGroups;
  }

  /** 单日分组，找不到返回 null。按天卡片用它刷新，不必每次遍历全部记录。 */
  getGroupForDay(day: string): GpsDailyGroup | null {
    if (this.recordsVersion < 0) return null;
    this.ensureDailyCache();
    const group = this.dailyGroupMap.get(day);
    return group !== undefined ? group : null;
  }

  /** 页面上应该显示的总条数：模拟轨迹开启时，用模拟点替换当天真实记录。 */
  displayRecordCount(): number {
    if (this.recordsVersion < 0) return 0;
    this.ensureDailyCache();
    return this.dailyDisplayCount;
  }

  hasMockTrack(): boolean {
    if (this.recordsVersion < 0) return false;
    return this.mockRecords.length > 0;
  }

  mockCount(): number {
    if (this.recordsVersion < 0) return 0;
    return this.mockRecords.length;
  }

  isMockDay(day: string): boolean {
    if (this.recordsVersion < 0) return false;
    return this.mockRecords.length > 0 && this.mockDay === day;
  }

  private ensureDailyCache(): void {
    if (this.dailyCacheVersion === this.recordsVersion) return;

    const map = new Map<string, GpsRecord[]>();
    const d = new Date();
    for (const r of this.records) {
      d.setTime(r.timestamp);
      const key = GpsRecorder.dayKeyOf(d);
      let arr = map.get(key);
      if (!arr) { arr = []; map.set(key, arr); }
      arr.push(r);
    }

    let displayCount = this.records.length;
    if (this.mockRecords.length > 0) {
      const realMockDay = map.get(this.mockDay);
      displayCount = this.records.length -
        (realMockDay !== undefined ? realMockDay.length : 0) + this.mockRecords.length;
      // 当天只显示模拟轨迹；真实记录仍留在 records 里，关掉开关立刻恢复
      map.delete(this.mockDay);
      map.set(this.mockDay, this.mockRecords);
    }

    const result: GpsDailyGroup[] = [];
    const groupMap = new Map<string, GpsDailyGroup>();
    map.forEach((recs: GpsRecord[], day: string) => {
      const group: GpsDailyGroup = {
        day: day,
        count: recs.length,
        // 第一条用 runStart：静止心跳点的 timestamp 是这一轮的最后一个点，
        // 直接拿它当「当天开始时间」会平白晚最多 10 分钟。runStart 落到
        // 前一天时（跨午夜的一轮静止）按当天 0 点裁剪，避免显示 23:55–00:05。
        first: Math.max(
          GpsTrack.runStartOf(recs[0]),
          GpsTrack.startOfDay(recs[0].timestamp)
        ),
        last: recs[recs.length - 1].timestamp,
        mock: this.mockRecords.length > 0 && day === this.mockDay
      };
      result.push(group);
      groupMap.set(day, group);
    });
    result.sort((a: GpsDailyGroup, b: GpsDailyGroup) => b.day.localeCompare(a.day));

    this.dailyGroups = result;
    this.dailyGroupMap = groupMap;
    this.dailyRecordsMap = map;
    this.dailyDisplayCount = displayCount;
    this.dailyCacheVersion = this.recordsVersion;
  }

  /** Returns all records for a specific day (YYYY-MM-DD), sorted by time ascending. */
  getDayRecords(dateKey: string): GpsRecord[] {
    // 同 getDailyStats：读版本号建立 V2 依赖（见 thumbForRender 的同样做法）
    if (this.recordsVersion < 0) return [];
    this.ensureDailyCache();
    const records = this.dailyRecordsMap.get(dateKey);
    return records !== undefined ? records : [];
  }

  private static dayKeyOf(d: Date): string {
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${d.getFullYear()}-${m}-${day}`;
  }

  private static dayKey(timestamp: number): string {
    return GpsRecorder.dayKeyOf(new Date(timestamp));
  }

  /** UI 用的当天键（YYYY-MM-DD）。 */
  static dayKeyFor(timestamp: number): string {
    return GpsRecorder.dayKeyOf(new Date(timestamp));
  }

  /**
   * 调试包：以当前位置为起点生成相机图案，覆盖当天的显示。
   * 真实记录不动，关掉后立即恢复；模拟点也不写盘、不参与 findClosest。
   */
  async createMockTrack(): Promise<boolean> {
    this.lastError = '';
    if (!canIUse('SystemCapability.Location.Location.Core')) {
      this.lastError = L10n.tr('error_location_unsupported');
      return false;
    }

    const permError = await this.ensureLocationPermission();
    if (permError !== '') {
      this.lastError = permError;
      return false;
    }

    const now = Date.now();
    // 始终优先取一次当前定位；失败时用 5 分钟内的最后一次真实定位兜底
    let origin: GpsRecord | null = null;
    try {
      const request: geoLocationManager.CurrentLocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.ACCURACY,
        scenario: geoLocationManager.LocationRequestScenario.TRAJECTORY_TRACKING,
        timeoutMs: 10000
      };
      // @SuppressWarnings syscap
      const loc = await geoLocationManager.getCurrentLocation(request);
      origin = {
        timestamp: loc.timeStamp,
        latitude: loc.latitude,
        longitude: loc.longitude,
        altitude: loc.altitude ?? 0
      };
    } catch (err) {
      if (this.lastFix !== null && now - this.lastFix.timestamp <= 5 * 60 * 1000) {
        origin = this.lastFix;
      } else {
        this.lastError = L10n.tr('error_location_current_failed', JSON.stringify(err));
        this.log.add(`模拟GPS轨迹: ${this.lastError}`);
        return false;
      }
    }

    if (origin === null) {
      this.lastError = L10n.tr('error_mock_no_location');
      return false;
    }

    const records = GpsMockTrack.buildCameraTrack(origin, now);
    if (records.length === 0) {
      this.lastError = L10n.tr('error_mock_generation_failed');
      return false;
    }

    const day = GpsRecorder.dayKeyFor(now);
    this.mockDay = day;
    this.mockRecords = records.slice().sort((a: GpsRecord, b: GpsRecord) => a.timestamp - b.timestamp);
    this.recordsVersion++;
    this.log.add(`已注入模拟GPS轨迹: ${records.length} 点 (${day})`);
    return true;
  }

  /** 清掉模拟轨迹，当天真实记录重新出现。 */
  clearMockTrack(): void {
    if (this.mockRecords.length === 0 && this.mockDay === '') return;
    this.mockRecords = [];
    this.mockDay = '';
    this.recordsVersion++;
    this.log.add('模拟GPS轨迹已清除');
  }

  /** Delete all records for a given day. Returns the new total count. */
  deleteDay(dateKey: string): number {
    // 模拟轨迹只是当天的显示覆盖；删这一天的卡片时先撤掉模拟层
    if (this.isMockDay(dateKey)) {
      this.clearMockTrack();
      return this.records.length;
    }
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
    const text = AtomicFile.readText(this.settingsPath());
    if (text === null || text === '') return;
    try {
      const obj = JSON.parse(text) as Record<string, Object>;
      if (typeof obj.gpsMode === 'number') {
        // 新格式（带 version）与旧格式都兼容
        const mode = obj.gpsMode as number;
        this.gpsMode = mode >= 0 && mode <= 3 ? mode : 2;
      } else if (typeof obj.precisionMode === 'boolean') {
        this.gpsMode = (obj.precisionMode as boolean) ? 0 : 2;
      }
    } catch (_e) {
      // keep default
    }
  }

  private cancelSaveTimer(): void {
    if (this.saveTimerId >= 0) {
      clearTimeout(this.saveTimerId);
      this.saveTimerId = -1;
    }
  }

  private scheduleSaveRecords(): void {
    this.savePending = true;
    if (this.saveTimerId >= 0) return;
    this.saveTimerId = setTimeout(() => {
      this.saveTimerId = -1;
      this.flushRecords();
    }, COMPACT_INTERVAL_MS);
  }

  private flushRecords(): void {
    if (!this.savePending) return;
    this.savePending = false;
    this.saveRecords();
  }

  private saveMode(): void {
    if (!this.storageDir) return;
    try {
      AtomicFile.writeText(this.settingsPath(), JSON.stringify({
        version: 1,
        gpsMode: this.gpsMode,
        wasRunning: this.running
      }));
    } catch (_e) {
      // best effort
    }
  }

  /** Resume GPS recording if it was active in the previous session. */
  async autoStart(): Promise<void> {
    let wasRunning = false;
    const text = AtomicFile.readText(this.settingsPath());
    if (text !== null && text !== '') {
      try {
        const obj = JSON.parse(text) as Record<string, Object>;
        wasRunning = obj.wasRunning === true;
      } catch (_e) {
        // ignore
      }
    }
    if (wasRunning) {
      await this.start();
    }
  }

  /** 新格式：每行一条记录的 JSONL，追加即可保证单点落盘。 */
  private recordsPath(): string {
    return this.storageDir + '/gps_records.jsonl';
  }

  /** 旧版单文件 JSON 数组，仅在首次启动时迁移。 */
  private legacyRecordsPath(): string {
    return this.storageDir + '/gps_records.json';
  }

  private loadRecords(): void {
    // 模拟轨迹只在本次进程内有效，启动时不要带出上次的假数据
    this.mockRecords = [];
    this.mockDay = '';
    this.records = [];
    let needsSave = false;

    const text = AtomicFile.readText(this.recordsPath());
    if (text !== null) {
      const lines = text.split('\n');
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed === '') continue;
        try {
          this.records.push(JSON.parse(trimmed) as GpsRecord);
        } catch (_e) {
          // 崩溃可能留下半行，忽略并触发一次重写
          needsSave = true;
        }
      }
    } else {
      // 迁移旧版 gps_records.json
      const legacy = AtomicFile.readText(this.legacyRecordsPath());
      if (legacy !== null && legacy !== '') {
        try {
          const parsed = JSON.parse(legacy) as Object;
          this.records = Array.isArray(parsed) ? parsed as GpsRecord[] : [];
          needsSave = true;
        } catch (_e) {
          this.records = [];
        }
      }
    }

    // 旧版本是「每隔几十秒堆一条」，同一位置会重复很多次，且时间顺序未必可靠。
    // 读入时先排序（findClosest 的二分查找依赖升序），再按新规则折叠历史重复点。
    this.records.sort((a: GpsRecord, b: GpsRecord) => a.timestamp - b.timestamp);
    const before = this.records.length;
    let needsRunStart = false;
    for (let i = 0; i < this.records.length; i++) {
      if (this.records[i].runStart === undefined) {
        needsRunStart = true;
        break;
      }
    }
    const compacted = GpsTrack.compact(this.records);
    if (compacted.length !== before) {
      this.records = compacted;
      needsSave = true;
      this.log.add(`GPS历史记录已整理: ${before} 条 -> ${compacted.length} 条`);
    } else if (needsRunStart) {
      // 只是补齐 runStart，不改变条数
      this.records = compacted;
      needsSave = true;
    }
    if (this.pruneIfNeeded()) {
      needsSave = true;
    }
    if (needsSave) {
      // 只有新 JSONL 写成功才删除旧文件，避免磁盘异常时两头都没了。
      if (this.saveRecords()) {
        AtomicFile.delete(this.legacyRecordsPath());
      }
    }
    this.recordCount = this.records.length;
    this.recordsVersion++;
  }

  /** 把内存中的记录压缩成 JSONL 快照（不是普通 JSON 数组）。返回是否写成功。 */
  private saveRecords(): boolean {
    if (!this.storageDir) return false;
    this.cancelSaveTimer();
    try {
      const lines: string[] = [];
      for (const record of this.records) {
        lines.push(JSON.stringify(record));
      }
      const text = lines.length > 0 ? lines.join('\n') + '\n' : '';
      AtomicFile.writeText(this.recordsPath(), text);
      this.savePending = false;
      return true;
    } catch (err) {
      this.log.add(`GPS记录保存失败: ${JSON.stringify(err)}`);
      return false;
    }
  }

  /** 每个定位点立即追加一行，避免等待 30 秒压缩窗口。 */
  private appendRecordToDisk(record: GpsRecord): void {
    if (!this.storageDir) return;
    try {
      AtomicFile.appendText(this.recordsPath(), JSON.stringify(record) + '\n');
    } catch (err) {
      this.log.add(`GPS记录追加失败: ${JSON.stringify(err)}`);
    }
  }
}
