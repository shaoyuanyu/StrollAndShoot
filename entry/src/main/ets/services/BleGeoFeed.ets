import geoLocationManager from '@ohos.geoLocationManager';
import { AppLog } from './AppLog';
import { GpsRecorder } from './GpsRecorder';
import { BleGeoFix } from './BlePayloads';

/**
 * 蓝牙相机「位置注入」的轻量定位源（1.66.17）。
 *
 * 为什么要单独一个源：注入只需要**最近一次定位**，不需要轨迹记录。
 * 1.66.16 及以前注入直接读 `GpsRecorder.lastFix`，而定位记录默认是关的——
 * 于是 `lastFix` 恒为 null，0x2007 一次都没发出去，相机侧当然没有任何反应
 * （真机日志 2026-11-14 的证据：9 千行 AppLog 里没有一条定位启动记录）。
 *
 * 分工：
 * - 定位记录开着 → 直接借它的 `lastFix`，这里不重复订阅 GNSS；
 * - 定位记录关着 → 这里自己订阅（31 秒一拍），只保留最后一个点，不落盘。
 * - 卫星数只有这里订阅 `satelliteStatusChange` 才拿得到，相机那边要显示。
 */
export class BleGeoFeed {
  private static instance_: BleGeoFeed;

  private log: AppLog = new AppLog();
  private running: boolean = false;
  private starting: boolean = false;
  private fix: BleGeoFix | null = null;
  /** 最近一次上报的卫星颗数；0 表示还没拿到过。 */
  private satellites: number = 0;
  private locationCallback?: (location: geoLocationManager.Location) => void;
  private satelliteCallback?: (info: geoLocationManager.SatelliteStatusInfo) => void;

  static getInstance(): BleGeoFeed {
    if (!BleGeoFeed.instance_) {
      BleGeoFeed.instance_ = new BleGeoFeed();
    }
    return BleGeoFeed.instance_;
  }

  initLog(log: AppLog): void {
    this.log = log;
  }

  isRunning(): boolean {
    return this.running;
  }

  /**
   * 开始供位置。定位记录已经在跑时只补一个卫星状态订阅。
   *
   * 返回 false 表示这次拿不到位置（没权限 / 系统定位关着 / 订阅失败），
   * 原因已经写进日志。
   */
  async start(): Promise<boolean> {
    if (this.starting) return this.running;
    const recorder = GpsRecorder.getInstance();
    const needOwn = !recorder.running;
    if (this.running) {
      // 已经在供位置：记录刚被用户打开的话，把自己那份订阅撤掉（不重复跑 GNSS）。
      if (!needOwn) this.stopLocationOnly();
      return true;
    }
    this.starting = true;
    try {
      const permError = await recorder.ensureLocationPermission();
      if (permError !== '') {
        this.log.add(`位置注入未启动: ${permError}`);
        return false;
      }
      let enabled = false;
      try {
        // @SuppressWarnings syscap
        enabled = geoLocationManager.isLocationEnabled();
      } catch (_e) {
        enabled = false;
      }
      if (!enabled) {
        this.log.add('位置注入未启动: 系统定位开关未打开');
        return false;
      }
      if (!this.subscribeSatellites()) return false;
      if (needOwn && !this.subscribeLocation()) return false;
      this.running = true;
      // 连续订阅的第一拍最多要等 31 秒；蓝牙链路在相机半睡时常常撑不到那么久，
      // 首帧位置就永远发不出去。这里补一次单次定位，让第一帧尽快有数据。
      if (needOwn) this.requestOneShot();
      this.log.add(needOwn
        ? '位置注入已启动（独立定位，31 秒一拍）'
        : '位置注入已启动（借用定位记录的定位）');
      return true;
    } finally {
      this.starting = false;
    }
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    this.fix = null;
    this.stopLocationOnly();
    this.unsubscribeSatellites();
    this.log.add('位置注入已停止');
  }

  /**
   * 当前可用的位置。
   *
   * 定位记录开着时以它为准：注入和「照片匹配轨迹」用同一个点，不会出现
   * 相机照片带的位置和 App 里显示的位置对不上。
   */
  lastFix(): BleGeoFix | null {
    const recorder = GpsRecorder.getInstance();
    if (recorder.running && recorder.lastFix !== null) {
      const r = recorder.lastFix;
      return {
        latitude: r.latitude,
        longitude: r.longitude,
        altitude: r.altitude,
        satellites: this.satellites,
        utc: new Date()
      };
    }
    return this.fix;
  }

  private subscribeLocation(): boolean {
    if (this.locationCallback !== undefined) return true;
    try {
      this.locationCallback = (location: geoLocationManager.Location): void => {
        this.fix = {
          latitude: location.latitude,
          longitude: location.longitude,
          altitude: location.altitude ?? 0,
          satellites: this.satellites,
          utc: new Date()
        };
      };
      const requestCfg: geoLocationManager.ContinuousLocationRequest = {
        interval: GEO_INTERVAL_S,
        locationScenario: geoLocationManager.UserActivityScenario.TRANSPORT
      };
      // @SuppressWarnings syscap
      geoLocationManager.on('locationChange', requestCfg, this.locationCallback);
      return true;
    } catch (err) {
      this.log.add(`位置注入订阅定位失败: ${(err as Error).message}`);
      this.locationCallback = undefined;
      return false;
    }
  }

  /** 单次定位：只用来尽快拿到第一帧，失败无所谓（连续订阅还在跑）。 */
  private requestOneShot(): void {
    try {
      // @SuppressWarnings syscap
      geoLocationManager.getCurrentLocation().then((location: geoLocationManager.Location) => {
        if (!this.running || this.fix !== null) return;
        this.fix = {
          latitude: location.latitude,
          longitude: location.longitude,
          altitude: location.altitude ?? 0,
          satellites: this.satellites,
          utc: new Date()
        };
        this.log.add(`位置注入：单次定位已拿到 ${location.latitude.toFixed(5)},`
          + `${location.longitude.toFixed(5)}`);
      }).catch((err: Error) => {
        this.log.add(`位置注入：单次定位失败（${err.message}），等连续订阅`);
      });
    } catch (err) {
      this.log.add(`位置注入：单次定位调用失败（${(err as Error).message}）`);
    }
  }

  private stopLocationOnly(): void {
    const cb = this.locationCallback;
    if (cb === undefined) return;
    this.locationCallback = undefined;
    try {
      // @SuppressWarnings syscap
      geoLocationManager.off('locationChange', cb);
    } catch (_e) {
      // 已经停了
    }
  }

  private subscribeSatellites(): boolean {
    if (this.satelliteCallback !== undefined) return true;
    try {
      this.satelliteCallback = (info: geoLocationManager.SatelliteStatusInfo): void => {
        const n = info === null || info === undefined ? 0 : info.satellitesNumber;
        if (n > 0) this.satellites = n;
      };
      // @SuppressWarnings syscap
      geoLocationManager.on('satelliteStatusChange', this.satelliteCallback);
      return true;
    } catch (_e) {
      // 部分设备不支持卫星状态（syscap 声明 GNSS）：没有就发 0，不影响定位本身。
      this.satelliteCallback = undefined;
      return true;
    }
  }

  private unsubscribeSatellites(): void {
    const cb = this.satelliteCallback;
    if (cb === undefined) return;
    this.satelliteCallback = undefined;
    try {
      // @SuppressWarnings syscap
      geoLocationManager.off('satelliteStatusChange', cb);
    } catch (_e) {
      // 已经停了
    }
  }
}

/** 注入用的定位间隔。相机那边 45 秒写一次，这里比它快，保证每次都是新点。 */
const GEO_INTERVAL_S: number = 31;
