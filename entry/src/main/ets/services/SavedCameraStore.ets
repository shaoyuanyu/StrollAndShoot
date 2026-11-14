import { PersistenceV2 } from '@kit.ArkUI';
import { CameraModelStore } from '../model/CameraModelStore';
import { SettingsStore } from '../model/SettingsStore';
import { BleIdentityStore } from './BleIdentityStore';
import { cameraSerialFromBleName } from '../utils/CameraStandee';

/**
 * 一台已经配对过的相机。
 *
 * `key` 是稳定标识（优先序列号）；BLE 地址会随相机每轮广播变化，只作为
 * 快速重连的提示，不作为身份。`identityDevice` / `identityNonce` 是相机侧
 * 认的那份配对身份，必须原样保留。
 */
export interface SavedCamera {
  key: string;
  deviceId: string;
  cameraName: string;
  identityDevice: number;
  identityNonce: number;
  /** 展示用序列号（和标题栏角标一致）；旧记录没有这个字段时退回 serial。 */
  serial: string;
  /** BLE stage4 的身份序列号，和展示序列号不是同一个数，不能混用。 */
  identitySerial?: string;
  modelKey: string;
  lastConnectedAt: number;
  /**
   * 调试包的模拟相机（`MockPtpSession`）。
   *
   * 它没有蓝牙身份，也不能被当成真机：切到它时不能写 `BleIdentityStore`，
   * 界面上要显式标出「模拟」。缺省（undefined）就是真机，旧记录照旧读。
   */
  isMock?: boolean;
}

/**
 * 多相机配对仓库。
 *
 * 相机只认同一份 BLE 身份，但手机端可以保存多台相机的身份。当前真正喂给
 * `BleScanner` 的仍是 `BleIdentityStore`（它是「活动身份」，很多底层代码直接
 * 读它）；切换相机时把对应记录载入活动身份即可，不必改动整条 BLE 状态机。
 *
 * 单独一个 PersistenceV2 key，不复用 `ble_identity`：旧对象恢复时不会补上
 * 新增的数组字段，复用会把老用户的配对丢掉。首次启动从 `BleIdentityStore`
 * 迁移一条，之后不再迁移。
 */
@ObservedV2
export class SavedCameraStore {
  static readonly KEY = 'saved_cameras';

  /** 已保存的相机，整体替换数组，V2 才能追踪。 */
  @Trace cameras: SavedCamera[] = [];
  /** 当前查看/操作的相机；空串表示「准备连接新相机」。 */
  @Trace currentKey: string = '';
  /** 上一次真正连接成功的相机：冷启动默认回到它。 */
  @Trace lastConnectedKey: string = '';
  /** 旧 `ble_identity` 是否已经迁移过。 */
  @Trace migrated: boolean = false;

  private static instance_: SavedCameraStore;
  private static bootstrapped: boolean = false;

  static getInstance(): SavedCameraStore {
    if (!SavedCameraStore.instance_) {
      SavedCameraStore.instance_ = PersistenceV2.globalConnect({
        type: SavedCameraStore,
        key: SavedCameraStore.KEY,
        defaultCreator: () => new SavedCameraStore()
      })!;
    }
    if (!SavedCameraStore.bootstrapped) {
      SavedCameraStore.bootstrapped = true;
      SavedCameraStore.instance_.bootstrap();
    }
    return SavedCameraStore.instance_;
  }

  /** 首次迁移，以及每次冷启动把 current 归位到 lastConnected。 */
  private bootstrap(): void {
    if (!this.migrated) {
      const legacy = BleIdentityStore.getInstance();
      if (legacy.hasIdentity()) {
        const model = CameraModelStore.getInstance();
        const fromName = cameraSerialFromBleName(legacy.cameraName);
        const serial = model.serial !== '' ? model.serial
          : (fromName !== '' ? fromName : legacy.serial);
        const key = this.makeKey(legacy.deviceId, legacy.cameraName, legacy.identityDevice, serial);
        // 只有在仓库还是空的时候才迁移；旧键可能因为中断没清掉，不能反过来
        // 把新仓库里已经保存的多相机覆盖成一条。
        if (key !== '' && this.cameras.length === 0) {
          const rec: SavedCamera = {
            key,
            deviceId: legacy.deviceId,
            cameraName: legacy.cameraName,
            identityDevice: legacy.identityDevice,
            identityNonce: legacy.identityNonce,
            serial,
            identitySerial: legacy.serial,
            modelKey: model.key,
            lastConnectedAt: Date.now()
          };
          this.cameras = [rec];
          this.lastConnectedKey = key;
        }
      }
      this.migrated = true;
    }

    // 当前选择不跨进程保留：重新启动时要求默认显示上一次连接的相机。
    // 但**模拟相机的记录不能顶替真机**（1.66.1）：它一个配对身份都没有，选中它
    // 等于把 `BleIdentityStore` 清空，蓝牙页上「已配对」就变成「未连接」。
    // 模拟相机只有在调试开关打开、且没有真机记录时才是默认相机。
    this.normalizeMockRecords();
    const mockOn = SettingsStore.getInstance().mockCameraEnabled;
    const last = this.lastConnectedKey !== '' ? this.find(this.lastConnectedKey) : null;
    const pick = last !== null && (last.isMock !== true || mockOn)
      ? last : this.defaultRecord(mockOn);
    if (pick !== null) {
      this.lastConnectedKey = pick.key;
      this.activate(pick.key);
      return;
    }
    this.lastConnectedKey = '';
    this.currentKey = '';
  }

  /** 冷启动默认相机：真机优先，没有真机且模拟相机开着时才退回模拟记录。 */
  private defaultRecord(mockOn: boolean): SavedCamera | null {
    const real = this.latestReal();
    if (real !== null) return real;
    return mockOn ? this.latestMock() : null;
  }

  /**
   * 1.66.1：把模拟相机的记录从真机的身份空间里摘出来。
   *
   * 1.66.0 及以前 `rememberMock()` 用 `CameraModelStore.serial` 当 key，而那个
   * 值常常是上一台真机留下的（`bleCameraName` 断开时不清，尾段又被优先采用）。
   * 于是模拟相机的记录直接顶掉了真机那条：下次冷启动 `activate()` 看到
   * `isMock` 就清空 `BleIdentityStore`，相机页从「已配对」退回「未连接」，
   * 再连只能重新配对——而相机那边还记着这台手机，首配会被
   * `Remote device has an error` 秒拒。
   *
   * 这里补一次收尾：纯数字序列号的模拟记录不可能有配对身份，直接丢掉；
   * 其余模拟记录改用 `mock:` 前缀的 key，从此不可能和真机序列号撞上。
   */
  private normalizeMockRecords(): void {
    let changed = false;
    let cur = this.currentKey;
    let last = this.lastConnectedKey;
    // 模拟开关关着的时候，模拟记录没有存在的理由：它只会让「已配对相机」里躺着
    // 一台根本连不上的假相机，冷启动还会把活动身份清掉。
    const mockOn = SettingsStore.getInstance().mockCameraEnabled;
    const next: SavedCamera[] = [];
    for (const cam of this.cameras) {
      if (cam.isMock !== true) {
        next.push(cam);
        continue;
      }
      if (!mockOn || /^[0-9]+$/.test(cam.serial)) {
        changed = true;
        if (cur === cam.key) cur = '';
        if (last === cam.key) last = '';
        continue;
      }
      const key = this.mockKey(cam.modelKey, cam.cameraName);
      const normalized: SavedCamera = {
        key,
        deviceId: cam.deviceId,
        cameraName: cam.cameraName,
        identityDevice: cam.identityDevice,
        identityNonce: cam.identityNonce,
        serial: cam.serial,
        identitySerial: cam.identitySerial,
        modelKey: cam.modelKey,
        lastConnectedAt: cam.lastConnectedAt,
        isMock: true
      };
      if (key !== cam.key) {
        changed = true;
        if (cur === cam.key) cur = key;
        if (last === cam.key) last = key;
      }
      // 旧记录可能同一条出现过两种 key（序列号写过、广播名写过），归一之后
      // 会撞到一起：留最近连接的那条。
      let dup = -1;
      for (let i = 0; i < next.length; i++) {
        if (next[i].isMock === true && next[i].key === key) {
          dup = i;
          break;
        }
      }
      if (dup < 0) {
        next.push(normalized);
        continue;
      }
      changed = true;
      if (normalized.lastConnectedAt >= next[dup].lastConnectedAt) next[dup] = normalized;
    }
    if (!changed) return;
    this.cameras = next;
    this.currentKey = cur;
    this.lastConnectedKey = last;
  }

  /** 模拟相机记录的 key：永远带 `mock:` 前缀，不可能和真机序列号撞。 */
  private mockKey(modelKey: string, name: string): string {
    const tail = modelKey !== '' ? modelKey : name;
    return tail !== '' ? `mock:${tail}` : 'mock:unknown';
  }

  private latestMock(): SavedCamera | null {
    const sorted = this.sorted();
    for (const cam of sorted) {
      if (cam.isMock === true) return cam;
    }
    return null;
  }

  /**
   * 最近连接过的一台真机（模拟记录一律跳过）。
   *
   * 蓝牙 / 无线这条线只认真机：模拟相机没有蓝牙身份，也不该出现在
   * 「已配对」的按钮文案里。
   */
  latestReal(): SavedCamera | null {
    const sorted = this.sorted();
    for (const cam of sorted) {
      if (cam.isMock !== true) return cam;
    }
    return null;
  }

  /**
   * 当前可用的真机记录。
   *
   * 当前选中的若是模拟相机（或记录已被删掉），退回最近连接过的那台真机；
   * 用户在「已配对相机」里点了「连接新相机」（`currentKey` 为空）时返回 null，
   * 不要自作主张把旧相机接回来。
   */
  pickReal(): SavedCamera | null {
    if (this.currentKey === '') return null;
    const cur = this.current();
    if (cur !== null && cur.isMock !== true) return cur;
    return this.latestReal();
  }

  /** 按序列号 / 广播名找一台已保存的真机（蓝牙扫描命中时用）。 */
  findReal(serial: string, name: string): SavedCamera | null {
    for (const cam of this.cameras) {
      if (cam.isMock === true) continue;
      if (serial !== '' && cam.serial === serial) return cam;
      if (name !== '' && cam.cameraName === name) return cam;
      if (serial !== '' && cameraSerialFromBleName(cam.cameraName) === serial) return cam;
    }
    return null;
  }

  /** 按上次连接时间倒序，菜单直接用。 */
  sorted(): SavedCamera[] {
    const next = this.cameras.slice();
    next.sort((a: SavedCamera, b: SavedCamera): number => b.lastConnectedAt - a.lastConnectedAt);
    return next;
  }

  find(key: string): SavedCamera | null {
    for (const cam of this.cameras) {
      if (cam.key === key) return cam;
    }
    return null;
  }

  current(): SavedCamera | null {
    return this.currentKey !== '' ? this.find(this.currentKey) : null;
  }

  hasAny(): boolean {
    return this.cameras.length > 0;
  }

  /** 把某台已保存相机切成活动身份；不负责清 Wi-Fi 地址，调用方按场景处理。 */
  activate(key: string): boolean {
    const rec = this.find(key);
    if (rec === null) return false;
    if (rec.isMock === true) {
      // 模拟相机没有蓝牙身份：留着上一台真机的身份，会让相机页把它显示成
      // 「已配对」的蓝牙相机。这里直接把活动身份收干净。
      BleIdentityStore.getInstance().clear();
    } else {
      const active = BleIdentityStore.getInstance();
      const identitySerial = rec.identitySerial !== undefined && rec.identitySerial !== ''
        ? rec.identitySerial : rec.serial;
      active.save(rec.deviceId, rec.cameraName, rec.identityDevice,
        rec.identityNonce, identitySerial);
    }
    this.currentKey = rec.key;
    const model = CameraModelStore.getInstance();
    model.clear();
    if (rec.modelKey !== '') model.set(rec.modelKey);
    if (rec.serial !== '') model.setSerial(rec.serial);
    return true;
  }

  /** 准备连一台新相机：只清活动身份，保留所有已保存记录。 */
  beginNew(): void {
    BleIdentityStore.getInstance().clear();
    this.currentKey = '';
  }

  /**
   * 记下一台**模拟相机**（仅调试包）。
   *
   * 模拟相机走的是 USB/PTP，没有蓝牙配对那一步，所以 `rememberActive()` 永远
   * 不会被它触发——重启之后标题、立牌、当前相机全都退回「相机」，每轮测试都得
   * 重新搜一次，和真机流程对不上。这里给它建一条普通记录（`isMock` 标记），
   * 于是一次配对之后重启也能回到同一台。
   *
   * **key 必须带 `mock:` 前缀，序列号只能用模拟相机自己上报的**（1.66.1）：
   * 以前拿 `CameraModelStore.serial` 当 key，而那个值常是上一台真机的，
   * 模拟相机因此顶掉了真机记录，还顺手清空了蓝牙身份。
   */
  rememberMock(modelKey: string, serial: string, name: string): SavedCamera | null {
    if (modelKey === '' && name === '') return null;
    const key = this.mockKey(modelKey, name);
    const rec: SavedCamera = {
      key,
      deviceId: '',
      cameraName: name,
      identityDevice: 0,
      identityNonce: 0,
      serial,
      modelKey,
      lastConnectedAt: Date.now(),
      isMock: true
    };
    const next = this.cameras.slice();
    let idx = -1;
    for (let i = 0; i < next.length; i++) {
      // 只在模拟记录里找同一条：按序列号去匹配真机记录，正是当初丢身份的原因。
      if (next[i].isMock === true && next[i].key === key) {
        idx = i;
        break;
      }
    }
    if (idx >= 0) {
      next[idx] = rec;
    } else {
      next.push(rec);
    }
    this.cameras = next;
    this.currentKey = key;
    this.lastConnectedKey = key;
    return rec;
  }

  /**
   * 删掉一条配对记录。
   *
   * 删的是当前这台时，活动身份一起收掉，并回退到最近连接过的那台（还有的话）；
   * 相机侧不知道自己被忘了，重新配对即可再用。
   */
  remove(key: string): boolean {
    const idx = this.indexOfKey(key);
    if (idx < 0) return false;
    const next = this.cameras.slice();
    next.splice(idx, 1);
    this.cameras = next;
    if (this.lastConnectedKey === key) this.lastConnectedKey = '';
    if (this.currentKey !== key) return true;
    this.currentKey = '';
    BleIdentityStore.getInstance().clear();
    // 回退目标同样真机优先：删掉一台真机之后不该落到模拟相机上。
    const fallback = this.defaultRecord(SettingsStore.getInstance().mockCameraEnabled);
    if (fallback !== null) {
      this.activate(fallback.key);
    } else {
      // 一台都不剩了：展示缓存也得一起清掉，否则标题栏会继续挂着刚删掉的那台
      // 相机的型号与序列号（1.66.1）。
      CameraModelStore.getInstance().clear();
    }
    return true;
  }

  /** 配对成功后把活动身份写入仓库，并更新「上次连接」。 */
  rememberActive(): SavedCamera | null {
    const active = BleIdentityStore.getInstance();
    if (!active.hasIdentity()) return null;
    const model = CameraModelStore.getInstance();
    const fromName = cameraSerialFromBleName(active.cameraName);
    const serial = model.serial !== '' ? model.serial
      : (fromName !== '' ? fromName : active.serial);
    const key = this.makeKey(active.deviceId, active.cameraName, active.identityDevice, serial);
    if (key === '') return null;
    const rec: SavedCamera = {
      key,
      deviceId: active.deviceId,
      cameraName: active.cameraName,
      identityDevice: active.identityDevice,
      identityNonce: active.identityNonce,
      serial,
      identitySerial: active.serial,
      modelKey: model.key,
      lastConnectedAt: Date.now()
    };
    const next = this.cameras.slice();
    const idx = this.indexOf(rec);
    if (idx >= 0) {
      next[idx] = rec;
    } else {
      next.push(rec);
    }
    this.cameras = next;
    this.currentKey = key;
    this.lastConnectedKey = key;
    return rec;
  }

  /** 机型/序列号后补到当前记录（PTP 连接后才认出来的情况）。 */
  updateCurrentMeta(modelKey: string, serial: string): void {
    if (this.currentKey === '') return;
    const idx = this.indexOfKey(this.currentKey);
    if (idx < 0) return;
    const cur = this.cameras[idx];
    if (modelKey === '' && serial === '') return;
    if ((modelKey === '' || modelKey === cur.modelKey)
      && (serial === '' || serial === cur.serial)) {
      return;
    }
    const next = this.cameras.slice();
    const rec: SavedCamera = {
      key: cur.key,
      deviceId: cur.deviceId,
      cameraName: cur.cameraName,
      identityDevice: cur.identityDevice,
      identityNonce: cur.identityNonce,
      serial: serial !== '' ? serial : cur.serial,
      identitySerial: cur.identitySerial !== undefined ? cur.identitySerial : cur.serial,
      modelKey: modelKey !== '' ? modelKey : cur.modelKey,
      lastConnectedAt: cur.lastConnectedAt
    };
    // 以前这里把 `isMock` 整个漏掉了：模拟相机的记录被「补机型 / 序列号」洗一遍
    // 就变成一条没有配对身份、却当成真机的记录（1.66.1 修）。只在确实是模拟记录
    // 时才写这个字段，真机记录里不该留下一个 `isMock: undefined`。
    if (cur.isMock === true) rec.isMock = true;
    next[idx] = rec;
    this.cameras = next;
  }

  private makeKey(deviceId: string, cameraName: string, identityDevice: number,
                  serial: string): string {
    if (serial !== '') return serial;
    if (cameraName !== '') return cameraName;
    if (deviceId !== '') return deviceId;
    return identityDevice > 0 ? `${identityDevice}` : '';
  }

  private indexOf(rec: SavedCamera): number {
    for (let i = 0; i < this.cameras.length; i++) {
      const cam = this.cameras[i];
      if (rec.serial !== '' && cam.serial === rec.serial) return i;
      if (rec.cameraName !== '' && cam.cameraName === rec.cameraName) return i;
      if (rec.identityDevice !== 0 && cam.identityDevice === rec.identityDevice) return i;
      if (cam.key === rec.key) return i;
    }
    return -1;
  }

  private indexOfKey(key: string): number {
    for (let i = 0; i < this.cameras.length; i++) {
      if (this.cameras[i].key === key) return i;
    }
    return -1;
  }
}
