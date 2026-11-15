/**
 * NikonWifiLiveView.ets
 *
 * 尼康 Wi-Fi PTP/IP 实时取景与遥控拍摄。
 *
 * 协议来自 SnapBridge 2.14.3 的反编译结果（`ptpclient/actions/liveview` 与
 * `snapbridge.ptpclient.c8/y7`）：
 * - `0x9201 StartLiveView` / `0x9202 EndLiveView`
 * - `0x9203 GetLiveViewImage`（老协议）/ `0x9428 GetLiveViewImageEx`
 * - `0x90C8 DeviceReady`：启动、对焦、拍摄后都要轮询到相机空闲
 * - `0x90C2 ChangeCameraMode`：1 = 交给手机（HOST），0 = 还给相机
 * - `0x9207 InitiateCaptureRecInMedia`：p1 = -1 普通释放，p2 = 0 存卡
 * - `0x90C1 AfDrive`：自动对焦
 * - `0x9205 ChangeAfArea`：p1/p2 = 对焦点坐标
 * - `0x9016 ZoomControlOperation`：p1 = wide 步数，p2 = tele 步数
 * - 属性 `0xD1A2 LiveViewStatus`、`0xD1A4 LiveViewProhibitionCondition`、
 *   `0xD0BD RemoteCaptureProhibitionCondition`
 *
 * 所有请求都走 `PtpTransport.rawCommand`，因此和扫描 / 下载共用同一个
 * `PtpScheduler` 串行队列；实时取景循环自身只保留一笔在途事务。
 *
 * 注意：实时取景画面是「头 + JPEG」的复合数据。不同机型头长度不同，这里
 * 优先按头部声明的 JPEG 长度取末尾，再用 SOI 扫描兜底，不依赖固定偏移。
 */
import { image } from '@kit.ImageKit';
import { L10n } from '../utils/L10n';
import { PtpPriority, type PtpTransport, type PtpRawResult } from '../pages/PtpHost';

/** 尼康 PTP 操作码。 */
export const NIKON_OP_ZOOM = 0x9016;
export const NIKON_OP_DEVICE_READY = 0x90C8;
export const NIKON_OP_AF_DRIVE = 0x90C1;
export const NIKON_OP_CHANGE_CAMERA_MODE = 0x90C2;
export const NIKON_OP_START_LIVEVIEW = 0x9201;
export const NIKON_OP_END_LIVEVIEW = 0x9202;
export const NIKON_OP_GET_LIVEVIEW_IMAGE = 0x9203;
export const NIKON_OP_CHANGE_AF_AREA = 0x9205;
export const NIKON_OP_CAPTURE = 0x9207;
export const NIKON_OP_GET_LIVEVIEW_IMAGE_EX = 0x9428;

/** 尼康设备属性。 */
export const NIKON_PROP_REMOTE_CAPTURE_PROHIBITION = 0xD0BD;
export const NIKON_PROP_LIVEVIEW_STATUS = 0xD1A2;
export const NIKON_PROP_LIVEVIEW_PROHIBITION = 0xD1A4;

const RESPONSE_OK = 0x2001;
const RESPONSE_OPERATION_NOT_SUPPORTED = 0x2005;
const RESPONSE_DEVICE_PROP_NOT_SUPPORTED = 0x200A;
const RESPONSE_DEVICE_BUSY = 0x2019;
/** DeviceReady 在拍摄中 / 释放快门时也会回 busy 类错误，继续轮询。 */
const RESPONSE_BULB_RELEASE = 0xA200;
const RESPONSE_CAPTURE_BUSY_1 = 0xA201;
const RESPONSE_MOVIE_FRAME_RELEASE = 0xA202;
const RESPONSE_CAPTURE_BUSY_2 = 0xA207;

const FRAME_INTERVAL_MS = 80;
const LOOP_FAIL_LIMIT = 5;
const START_RETRY = 10;
const START_RETRY_DELAY_MS = 500;
const DEVICE_READY_TIMEOUT_MS = 10000;

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

function u32le(data: Uint8Array | null): number {
  if (data === null || data.length < 4) return 0;
  return (data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24)) >>> 0;
}

/**
 * 从「头 + JPEG」的数据里取出 JPEG。
 *
 * - `GetLiveViewImage` 的头在偏移 4 处有 JPEG 长度；
 * - `GetLiveViewImageEx` 的头在偏移 12 处有 JPEG 长度。
 *
 * 头版本因机型而异，直接按固定偏移取有风险；先用声明长度取末尾并验证 SOI，
 * 验证失败再从头扫 `FF D8`。两种路径都找不到就返回 null。
 */
export function extractLiveViewJpeg(data: Uint8Array, ex: boolean): Uint8Array | null {
  if (data.length < 2) return null;
  const declaredOffset = ex ? 12 : 4;
  if (data.length >= declaredOffset + 4) {
    const declared = u32le(data.subarray(declaredOffset, declaredOffset + 4));
    if (declared > 2 && declared <= data.length) {
      const candidate = data.subarray(data.length - declared);
      if (candidate[0] === 0xFF && candidate[1] === 0xD8) return candidate;
    }
  }
  let start = -1;
  for (let i = 0; i + 1 < data.length; i++) {
    if (data[i] === 0xFF && data[i + 1] === 0xD8) {
      start = i;
      break;
    }
  }
  if (start < 0) return null;
  let end = data.length;
  for (let i = data.length - 2; i >= start; i--) {
    if (data[i] === 0xFF && data[i + 1] === 0xD9) {
      end = i + 2;
      break;
    }
  }
  return data.subarray(start, end);
}

/**
 * 实时取景 + 遥控控制器。
 *
 * 一个 Wi-Fi 会话对应一个实例；断开 / 换会话时由 `CameraService` 丢弃。
 * 页面只读 `@Trace` 字段，不直接碰 PTP。
 */
@ObservedV2
export class NikonWifiLiveView {
  @Trace starting: boolean = false;
  @Trace active: boolean = false;
  @Trace error: string = '';
  @Trace lastAction: string = '';
  @Trace frameVersion: number = 0;
  @Trace frameWidth: number = 0;
  @Trace frameHeight: number = 0;
  @Trace shooting: boolean = false;
  @Trace focusing: boolean = false;
  @Trace zooming: boolean = false;
  @Trace fps: number = 0;
  /** 最近一次对焦命令是否成功（只代表相机接受了命令，不代表合焦）。 */
  @Trace lastFocusOk: boolean = false;

  readonly supportsLiveView: boolean;
  readonly supportsCapture: boolean;
  readonly supportsAf: boolean;
  readonly supportsAfArea: boolean;
  readonly supportsZoom: boolean;

  private transport: PtpTransport;
  private log: (msg: string) => void;
  private useEx: boolean;
  private frame: image.PixelMap | null = null;
  private loopToken: number = 0;
  private startSeq: number = 0;
  private paused: boolean = false;
  private liveViewStarted: boolean = false;
  private modeChanged: boolean = false;
  private failStreak: number = 0;
  private fpsWindowStart: number = 0;
  private fpsFrames: number = 0;

  constructor(transport: PtpTransport, deviceOps: number[],
              log: (msg: string) => void) {
    this.transport = transport;
    this.log = log;
    // 旧包或虚拟相机可能没有 operationsSupported；空列表时乐观尝试，失败再报错。
    const known = deviceOps.length > 0;
    this.supportsLiveView = !known || (deviceOps.includes(NIKON_OP_START_LIVEVIEW)
      && deviceOps.includes(NIKON_OP_END_LIVEVIEW)
      && (deviceOps.includes(NIKON_OP_GET_LIVEVIEW_IMAGE)
        || deviceOps.includes(NIKON_OP_GET_LIVEVIEW_IMAGE_EX)));
    this.supportsCapture = !known || (deviceOps.includes(NIKON_OP_CAPTURE)
      && deviceOps.includes(NIKON_OP_DEVICE_READY));
    this.supportsAf = !known || deviceOps.includes(NIKON_OP_AF_DRIVE);
    this.supportsAfArea = !known || deviceOps.includes(NIKON_OP_CHANGE_AF_AREA);
    this.supportsZoom = !known || deviceOps.includes(NIKON_OP_ZOOM);
    this.useEx = deviceOps.includes(NIKON_OP_GET_LIVEVIEW_IMAGE_EX);
  }

  /** 当前帧；只读。UI 用 `frameVersion` 触发重建，Map / PixelMap 本身不参与追踪。 */
  getPixelMap(): image.PixelMap | null {
    return this.frame;
  }

  async start(): Promise<boolean> {
    if (this.active) return true;
    if (this.starting) return false;
    if (!this.supportsLiveView) {
      this.error = L10n.tr('camera_wifi_remote_unsupported');
      return false;
    }
    const seq = ++this.startSeq;
    this.starting = true;
    this.error = '';
    this.lastAction = '';
    this.log('实时取景: 开始启动');
    try {
      // 先看相机当前是否允许取景（SnapBridge 的顺序）：拒绝时不要先把
      // 控制权从相机抢过来。
      const blocked = await this.checkProhibitions(seq);
      if (seq !== this.startSeq || blocked !== '') {
        if (blocked !== '') this.error = blocked;
        return false;
      }

      // 再把控制权交给手机；相机在回放/菜单时，StartLiveView 会被拒。
      const mode = await this.raw(NIKON_OP_CHANGE_CAMERA_MODE, [1], false);
      if (seq !== this.startSeq) return false;
      if (mode === null) {
        this.error = L10n.tr('camera_wifi_remote_start_failed');
        return false;
      }
      this.modeChanged = mode.code === RESPONSE_OK;
      if (!this.modeChanged && mode.code !== RESPONSE_OPERATION_NOT_SUPPORTED) {
        this.error = this.errorText(mode.code);
        return false;
      }

      const status = await this.transport.getDevicePropValue(NIKON_PROP_LIVEVIEW_STATUS,
        PtpPriority.FOREGROUND);
      if (seq !== this.startSeq) return false;
      const already = status !== null && status.length > 0 && status[0] === 1;
      if (!already) {
        const ok = await this.startLiveViewWithRetry(seq);
        if (!ok) return false;
      }
      this.liveViewStarted = true;

      const ready = await this.waitDeviceReady(seq, DEVICE_READY_TIMEOUT_MS);
      if (!ready) {
        if (this.error === '') this.error = L10n.tr('camera_wifi_remote_start_failed');
        return false;
      }

      this.active = true;
      this.starting = false;
      this.paused = false;
      this.failStreak = 0;
      this.fpsWindowStart = Date.now();
      this.fpsFrames = 0;
      this.startLoop(++this.loopToken);
      this.log('实时取景: 已启动');
      return true;
    } catch (err) {
      this.error = (err as Error).message;
      this.log(`实时取景: 启动异常 ${this.error}`);
      return false;
    } finally {
      if (!this.active) {
        this.starting = false;
        // 启动中途失败也要把相机从 live view / HOST 模式里放出来。
        await this.stop();
      }
    }
  }

  async stop(): Promise<void> {
    this.startSeq++;
    this.active = false;
    this.starting = false;
    this.paused = false;
    this.loopToken++;
    this.failStreak = 0;
    const wasStarted = this.liveViewStarted;
    this.liveViewStarted = false;
    if (wasStarted) {
      await this.endLiveViewWithRetry();
      this.log('实时取景: 已停止');
    }
    await this.cleanupMode();
    this.releaseFrame();
    this.fps = 0;
    this.shooting = false;
    this.focusing = false;
    this.zooming = false;
  }

  /**
   * 快门：普通释放，存到相机卡。
   *
   * 不发 AF：实时取景页面上的「AF」按钮负责对焦；快门只触发释放。若相机需要
   * 「先对焦再拍」，用户可以点画面或按 AF 后再按快门。
   */
  async capture(): Promise<boolean> {
    if (!this.active) {
      this.error = L10n.tr('camera_wifi_remote_not_live');
      return false;
    }
    if (!this.supportsCapture) {
      this.error = L10n.tr('camera_wifi_remote_unsupported');
      return false;
    }
    if (this.shooting) return false;
    this.shooting = true;
    this.error = '';
    this.lastAction = L10n.tr('camera_wifi_remote_shooting');
    await this.pauseLoop();
    try {
      const r = await this.raw(NIKON_OP_CAPTURE, [0xFFFFFFFF, 0], false);
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = r === null ? L10n.tr('camera_wifi_remote_start_failed')
          : this.errorText(r.code);
        return false;
      }
      const ready = await this.waitDeviceReady(this.startSeq, DEVICE_READY_TIMEOUT_MS);
      if (!ready) return false;
      this.lastAction = L10n.tr('camera_wifi_remote_shot');
      this.log('实时取景: 已拍摄');
      return true;
    } finally {
      this.shooting = false;
      this.resumeLoop();
    }
  }

  /** AF-ON：相机自动对焦，然后等 DeviceReady。 */
  async afDrive(): Promise<boolean> {
    if (!this.active || !this.supportsAf) return false;
    if (this.focusing) return false;
    this.focusing = true;
    this.error = '';
    this.lastFocusOk = false;
    this.lastAction = L10n.tr('camera_wifi_remote_focusing');
    await this.pauseLoop();
    try {
      const r = await this.raw(NIKON_OP_AF_DRIVE, [], false);
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = r === null ? L10n.tr('camera_wifi_remote_af_failed')
          : this.errorText(r.code);
        return false;
      }
      const ready = await this.waitDeviceReady(this.startSeq, DEVICE_READY_TIMEOUT_MS);
      this.lastFocusOk = ready;
      if (ready) {
        this.lastAction = L10n.tr('camera_wifi_remote_af_done');
      } else {
        this.error = L10n.tr('camera_wifi_remote_af_failed');
      }
      return ready;
    } finally {
      this.focusing = false;
      this.resumeLoop();
    }
  }

  /**
   * 点画面对焦：先移动 AF 区域，再驱动一次对焦。
   *
   * `x/y` 是实时取景 JPEG 的像素坐标，不是屏幕 vp；页面负责按 Contain 的
   * 显示矩形换算。相机不支持移动区域时只做中心 AF。
   */
  async focusAt(x: number, y: number): Promise<boolean> {
    if (!this.active) return false;
    if (!this.supportsAf && !this.supportsAfArea) return false;
    if (this.focusing) return false;
    this.focusing = true;
    this.error = '';
    this.lastFocusOk = false;
    this.lastAction = L10n.tr('camera_wifi_remote_focusing');
    await this.pauseLoop();
    try {
      if (this.supportsAfArea) {
        const px = Math.max(0, Math.round(x));
        const py = Math.max(0, Math.round(y));
        const moved = await this.raw(NIKON_OP_CHANGE_AF_AREA, [px, py], false);
        if (moved === null || (moved.code !== RESPONSE_OK
          && moved.code !== RESPONSE_OPERATION_NOT_SUPPORTED)) {
          this.error = moved === null ? L10n.tr('camera_wifi_remote_af_failed')
            : this.errorText(moved.code);
          return false;
        }
      }
      if (!this.supportsAf) return false;
      const r = await this.raw(NIKON_OP_AF_DRIVE, [], false);
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = r === null ? L10n.tr('camera_wifi_remote_af_failed')
          : this.errorText(r.code);
        return false;
      }
      const ready = await this.waitDeviceReady(this.startSeq, DEVICE_READY_TIMEOUT_MS);
      this.lastFocusOk = ready;
      if (ready) {
        this.lastAction = L10n.tr('camera_wifi_remote_af_done');
      } else {
        this.error = L10n.tr('camera_wifi_remote_af_failed');
      }
      return ready;
    } finally {
      this.focusing = false;
      this.resumeLoop();
    }
  }

  /** 变焦：一步 wide / tele；Z 卡口手动变焦镜头不会响应，页面会显示失败。 */
  async zoom(tele: boolean): Promise<boolean> {
    if (!this.active || !this.supportsZoom) return false;
    if (this.zooming) return false;
    this.zooming = true;
    this.error = '';
    try {
      const params = tele ? [0, 1] : [1, 0];
      const r = await this.raw(NIKON_OP_ZOOM, params, false);
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = r === null ? L10n.tr('camera_wifi_remote_zoom_failed')
          : this.errorText(r.code);
        return false;
      }
      return true;
    } finally {
      this.zooming = false;
    }
  }

  /** 清掉一次性提示（页面切走 / 重新操作时用）。 */
  clearAction(): void {
    this.lastAction = '';
    this.error = '';
    this.lastFocusOk = false;
  }

  private async checkProhibitions(seq: number): Promise<string> {
    const remote = await this.transport.getDevicePropValue(
      NIKON_PROP_REMOTE_CAPTURE_PROHIBITION, PtpPriority.FOREGROUND);
    if (seq !== this.startSeq) return '';
    if (remote !== null && remote.length >= 4
      && (u32le(remote) & 0x7FFFFFFF) !== 0) {
      this.log(`实时取景: RemoteCaptureProhibition=0x${u32le(remote).toString(16)}`);
      return L10n.tr('camera_wifi_remote_denied');
    }
    const live = await this.transport.getDevicePropValue(
      NIKON_PROP_LIVEVIEW_PROHIBITION, PtpPriority.FOREGROUND);
    if (seq !== this.startSeq) return '';
    if (live !== null && live.length >= 4
      && (u32le(live) & 0x7FFFFFFF) !== 0) {
      this.log(`实时取景: LiveViewProhibition=0x${u32le(live).toString(16)}`);
      return L10n.tr('camera_wifi_remote_denied');
    }
    return '';
  }

  private async startLiveViewWithRetry(seq: number): Promise<boolean> {
    for (let i = 0; i < START_RETRY; i++) {
      if (seq !== this.startSeq) return false;
      const r = await this.raw(NIKON_OP_START_LIVEVIEW, [], false);
      if (seq !== this.startSeq) return false;
      if (r !== null && r.code === RESPONSE_OK) return true;
      if (r !== null && r.code === RESPONSE_DEVICE_BUSY) {
        this.log(`实时取景: StartLiveView 忙，重试 ${i + 1}/${START_RETRY}`);
        await delay(START_RETRY_DELAY_MS);
        continue;
      }
      this.error = r === null ? L10n.tr('camera_wifi_remote_start_failed')
        : this.errorText(r.code);
      return false;
    }
    this.error = L10n.tr('camera_wifi_remote_busy');
    return false;
  }

  private async endLiveViewWithRetry(): Promise<void> {
    for (let i = 0; i < START_RETRY; i++) {
      const r = await this.raw(NIKON_OP_END_LIVEVIEW, [], false);
      if (r !== null && r.code === RESPONSE_OK) return;
      if (r !== null && r.code === RESPONSE_DEVICE_BUSY) {
        await delay(START_RETRY_DELAY_MS);
        continue;
      }
      return;
    }
  }

  private async waitDeviceReady(seq: number, timeoutMs: number): Promise<boolean> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (seq !== this.startSeq) return false;
      const r = await this.raw(NIKON_OP_DEVICE_READY, [], false);
      if (seq !== this.startSeq) return false;
      if (r !== null && r.code === RESPONSE_OK) return true;
      if (r !== null && r.code === RESPONSE_DEVICE_BUSY) {
        await delay(100);
        continue;
      }
      if (r !== null && (r.code === RESPONSE_BULB_RELEASE
        || r.code === RESPONSE_CAPTURE_BUSY_1
        || r.code === RESPONSE_MOVIE_FRAME_RELEASE
        || r.code === RESPONSE_CAPTURE_BUSY_2)) {
        await delay(100);
        continue;
      }
      if (r !== null) this.error = this.errorText(r.code);
      return false;
    }
    return false;
  }

  private startLoop(token: number): void {
    this.frameLoop(token).catch((err: Error) => {
      this.log(`实时取景: 循环异常 ${err.message}`);
    });
  }

  private async frameLoop(token: number): Promise<void> {
    while (this.active && token === this.loopToken) {
      if (this.paused) {
        await delay(30);
        continue;
      }
      const started = Date.now();
      const op = this.useEx ? NIKON_OP_GET_LIVEVIEW_IMAGE_EX : NIKON_OP_GET_LIVEVIEW_IMAGE;
      const r = await this.raw(op, [], true);
      if (!this.active || token !== this.loopToken) return;

      if (r !== null && this.useEx
        && (r.code === RESPONSE_OPERATION_NOT_SUPPORTED
          || r.code === RESPONSE_DEVICE_PROP_NOT_SUPPORTED)) {
        // 相机没声明 Ex 或声明了却不支持：退回老协议，不让循环停在这里。
        this.useEx = false;
        this.log('实时取景: Ex 不支持，改走 0x9203');
        await delay(30);
        continue;
      }

      if (r === null || r.code !== RESPONSE_OK || r.data === null) {
        this.failStreak++;
        if (this.failStreak >= LOOP_FAIL_LIMIT) {
          this.error = r === null ? L10n.tr('camera_wifi_remote_disconnected')
            : this.errorText(r.code);
          this.log(`实时取景: 连续 ${this.failStreak} 帧失败，停止`);
          await this.stop();
          return;
        }
        await delay(100);
        continue;
      }

      this.failStreak = 0;
      const jpeg = extractLiveViewJpeg(r.data, op === NIKON_OP_GET_LIVEVIEW_IMAGE_EX);
      if (jpeg !== null) {
        await this.pushFrame(jpeg);
      }

      const elapsed = Date.now() - started;
      const wait = Math.max(10, FRAME_INTERVAL_MS - elapsed);
      await delay(wait);
    }
  }

  private async pushFrame(jpeg: Uint8Array): Promise<void> {
    try {
      const buf = jpeg.buffer.slice(jpeg.byteOffset, jpeg.byteOffset + jpeg.byteLength);
      const src = image.createImageSource(buf);
      let pm: image.PixelMap | null = null;
      try {
        pm = await src.createPixelMap();
      } finally {
        try { src.release(); } catch (_e) { /* best effort */ }
      }
      if (pm === null) return;
      if (!this.active) {
        try { pm.release(); } catch (_e) { /* best effort */ }
        return;
      }
      const info = await pm.getImageInfo();
      if (!this.active) {
        try { pm.release(); } catch (_e) { /* best effort */ }
        return;
      }
      const old = this.frame;
      this.frame = pm;
      this.frameWidth = info.size.width;
      this.frameHeight = info.size.height;
      this.frameVersion++;
      this.countFrame();
      if (old !== null) {
        // 给 UI 一帧时间把旧的绘制完；立刻 release 会出现黑闪。
        setTimeout(() => {
          try { old.release(); } catch (_e) { /* best effort */ }
        }, 1000);
      }
    } catch (_e) {
      // 单帧 JPEG 解码失败不打断实时取景。
    }
  }

  private countFrame(): void {
    const now = Date.now();
    this.fpsFrames++;
    if (now - this.fpsWindowStart >= 1000) {
      this.fps = Math.round(this.fpsFrames * 1000 / (now - this.fpsWindowStart));
      this.fpsFrames = 0;
      this.fpsWindowStart = now;
    }
  }

  private async pauseLoop(): Promise<void> {
    this.paused = true;
    // 让已发出的那一帧先走完；实时取景循环自己不会排第二帧。
    await delay(FRAME_INTERVAL_MS + 20);
  }

  private resumeLoop(): void {
    this.paused = false;
  }

  private async raw(opcode: number, params: number[],
                    expectData: boolean): Promise<PtpRawResult | null> {
    return this.transport.rawCommand(opcode, params, expectData, PtpPriority.FOREGROUND);
  }

  private async cleanupMode(): Promise<void> {
    if (this.modeChanged) {
      await this.raw(NIKON_OP_CHANGE_CAMERA_MODE, [0], false);
      this.modeChanged = false;
    }
  }

  private releaseFrame(): void {
    const old = this.frame;
    this.frame = null;
    this.frameWidth = 0;
    this.frameHeight = 0;
    this.frameVersion++;
    if (old !== null) {
      // UI 可能还拿着上一帧；延后释放，避免释放后仍被绘制。
      setTimeout(() => {
        try { old.release(); } catch (_e) { /* best effort */ }
      }, 500);
    }
  }

  private errorText(code: number): string {
    if (code === RESPONSE_DEVICE_BUSY) return L10n.tr('camera_wifi_remote_busy');
    if (code === 0x200F) return L10n.tr('camera_wifi_remote_denied');
    if (code === RESPONSE_OPERATION_NOT_SUPPORTED
      || code === RESPONSE_DEVICE_PROP_NOT_SUPPORTED) {
      return L10n.tr('camera_wifi_remote_unsupported');
    }
    return L10n.tr('camera_wifi_remote_error', `0x${code.toString(16)}`);
  }
}
