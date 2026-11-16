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
import {
  EXPOSURE_OP_GET_DEVICE_PROP_DESC,
  EXPOSURE_OP_SET_DEVICE_PROP_VALUE,
  EXPOSURE_PARAM_APERTURE,
  EXPOSURE_PARAM_EV,
  EXPOSURE_PARAM_ISO,
  EXPOSURE_PARAM_SHUTTER,
  EXPOSURE_PROP_APERTURE,
  EXPOSURE_PROP_EV,
  EXPOSURE_PROP_ISO,
  EXPOSURE_PROP_ISO_FALLBACK,
  EXPOSURE_PROP_SHUTTER,
  type ExposureOption,
  formatAperture,
  formatEv,
  formatIso,
  formatShutter,
  parseDescriptorOptions,
  signed16,
  staticOptions,
  shutterDenominator,
  shutterNumerator,
  shutterRaw,
  u16le as exposureU16le,
  u16leBytes,
  u32le as exposureU32le,
  u32leBytes
} from './NikonWifiExposure';

/** 尼康 PTP 操作码。 */
export const NIKON_OP_SET_DEVICE_PROP_VALUE = 0x1016;
export const NIKON_OP_ZOOM = 0x9016;
export const NIKON_OP_DEVICE_READY = 0x90C8;
export const NIKON_OP_AF_DRIVE = 0x90C1;
export const NIKON_OP_CHANGE_CAMERA_MODE = 0x90C2;
export const NIKON_OP_START_LIVEVIEW = 0x9201;
export const NIKON_OP_END_LIVEVIEW = 0x9202;
export const NIKON_OP_GET_LIVEVIEW_IMAGE = 0x9203;
export const NIKON_OP_CHANGE_AF_AREA = 0x9205;
export const NIKON_OP_CAPTURE = 0x9207;
export const NIKON_OP_START_MOVIE = 0x920A;
export const NIKON_OP_END_MOVIE = 0x920B;
export const NIKON_OP_GET_LIVEVIEW_IMAGE_EX = 0x9428;

/** 尼康设备属性。 */
export const NIKON_PROP_REMOTE_CAPTURE_PROHIBITION = 0xD0BD;
export const NIKON_PROP_AF_MODE_AT_LIVEVIEW = 0xD061;
export const NIKON_PROP_LIVEVIEW_STATUS = 0xD1A2;
export const NIKON_PROP_LIVEVIEW_PROHIBITION = 0xD1A4;
export const NIKON_PROP_LIVEVIEW_SELECTOR = 0xD1A6;
export const NIKON_PROP_AF_AREA_MODE = 0xD05D;

/** `0xD061` 的取值：0=AF-S、1=AF-C、2=AF-F、3=MF（固定）、4=MF（可选）、5=AF-A。 */
const AF_MODE_AF_F = 2;
const AF_AREA_SINGLE_POINT = 0x8010;
const AF_AREA_AUTO_AREA = 0x8011;
const AF_AREA_AUTO_AREA_L_CHARACTER = 0x8020;
const AF_AREA_AUTO_AREA_L_ANIMAL = 0x8021;

const RESPONSE_OK = 0x2001;
const RESPONSE_OPERATION_NOT_SUPPORTED = 0x2005;
const RESPONSE_DEVICE_PROP_NOT_SUPPORTED = 0x200A;
const RESPONSE_DEVICE_BUSY = 0x2019;
/** DeviceReady 在拍摄中 / 释放快门时也会回 busy 类错误，继续轮询。 */
const RESPONSE_BULB_RELEASE = 0xA200;
const RESPONSE_CAPTURE_BUSY_1 = 0xA201;
const RESPONSE_MOVIE_FRAME_RELEASE = 0xA202;
const RESPONSE_CAPTURE_BUSY_2 = 0xA207;

/**
 * 取帧节拍：相机本身约 10fps 出帧，这里只保留一个很短的间隔，
 * 避免取到同一帧后空转把 PTP 管道塞满。真正的上限由相机决定。
 */
const FRAME_INTERVAL_MS = 40;
/** 旧帧延后释放：至少让 UI 画完当前这一帧，避免换帧瞬间黑闪。 */
const FRAME_RELEASE_DELAY_MS = 250;
const FRAME_FINAL_RELEASE_DELAY_MS = 500;
const LOOP_FAIL_LIMIT = 5;
const START_RETRY = 10;
const START_RETRY_DELAY_MS = 500;
const DEVICE_READY_TIMEOUT_MS = 10000;

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/**
 * 实时取景头的多字节字段是**大端**（SnapBridge 用 `ByteBuffer.wrap` 默认序读），
 * 和 PTP 属性值的小端不同。以前这里按小端读，Z50II 的 wholeSize
 * `15 C0 0E 80` 被读成 49173×32782，实际是 5568×3712，AF 坐标整体放大约 8.8 倍。
 */
function u16be(data: Uint8Array, offset: number): number {
  if (offset + 2 > data.length) return 0;
  return (data[offset] << 8) | data[offset + 1];
}

function u32be(data: Uint8Array, offset: number): number {
  if (offset + 4 > data.length) return 0;
  return ((data[offset] << 24) | (data[offset + 1] << 16)
    | (data[offset + 2] << 8) | data[offset + 3]) >>> 0;
}

function u32le(data: Uint8Array | null): number {
  if (data === null || data.length < 4) return 0;
  return (data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24)) >>> 0;
}

/**
 * 从实时取景头里读「整幅画面」尺寸（AF 坐标的坐标系）。
 *
 * - 老协议 `GetLiveViewImage`：头偏移 12/14；
 * - `GetLiveViewImageEx`：头偏移 16/18；
 * - 头字段是大端；PTP 属性值才是小端。
 *
 * JPEG 尺寸通常比 wholeSize 小（相机可能按显示比例缩放），
 * `ChangeAfArea` 用的是 wholeSize，因此不能直接拿 JPEG 尺寸算坐标。
 */
export function parseLiveViewWholeSize(data: Uint8Array, ex: boolean): number[] {
  const offset = ex ? 16 : 12;
  if (data.length < offset + 4) return [0, 0];
  const w = u16be(data, offset);
  const h = u16be(data, offset + 2);
  return w > 0 && h > 0 ? [w, h] : [0, 0];
}

/**
 * 从「头 + JPEG」的数据里取出 JPEG。
 *
 * - `GetLiveViewImage` 的头在偏移 4 处有 JPEG 长度；
 * - `GetLiveViewImageEx` 的头在偏移 12 处有 JPEG 长度；
 * - 长度是大端（与头里其它字段一致）。
 *
 * 头版本因机型而异，直接按固定偏移取有风险；先用声明长度取末尾并验证 SOI，
 * 验证失败再从头扫 `FF D8`。两种路径都找不到就返回 null。
 */
export function extractLiveViewJpeg(data: Uint8Array, ex: boolean): Uint8Array | null {
  if (data.length < 2) return null;
  const declaredOffset = ex ? 12 : 4;
  if (data.length >= declaredOffset + 4) {
    const declared = u32be(data, declaredOffset);
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
 * 从 JPEG 的 SOF 段读显示尺寸。
 *
 * 以前每帧都 `await pixelMap.getImageInfo()`，那一趟 native 调用虽然不长，
 * 但和取帧串在一起会直接加到每帧延迟里。JPEG 头里本来就有宽高，直接扫
 * SOF0/1/2 即可。
 */
export function parseJpegSize(data: Uint8Array): number[] {
  if (data.length < 4 || data[0] !== 0xFF || data[1] !== 0xD8) return [0, 0];
  let i = 2;
  while (i + 9 < data.length) {
    if (data[i] !== 0xFF) {
      i++;
      continue;
    }
    const marker = data[i + 1];
    // 填充字节 / 无长度的标记。
    if (marker === 0xFF) {
      i++;
      continue;
    }
    if (marker === 0xD8 || marker === 0xD9 || marker === 0x01
      || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    const segLen = (data[i + 2] << 8) | data[i + 3];
    if (segLen < 2) return [0, 0];
    const isSof = marker >= 0xC0 && marker <= 0xCF
      && marker !== 0xC4 && marker !== 0xC8 && marker !== 0xCC;
    if (isSof) {
      // SOF: 精度(1) + 高(2) + 宽(2)
      const h = (data[i + 5] << 8) | data[i + 6];
      const w = (data[i + 7] << 8) | data[i + 8];
      return w > 0 && h > 0 ? [w, h] : [0, 0];
    }
    i += 2 + segLen;
  }
  return [0, 0];
}

/** 相机实时取景头里的一块 AF 区域（wholeSize 坐标系，单位与 wholeSize 相同）。 */
export interface AfBox {
  cx: number;
  cy: number;
  w: number;
  h: number;
}

export interface LiveViewFocus {
  /** 0 = 未知，1 = 未合焦（DEVIATED），2 = 合焦（MATCH）。 */
  state: number;
  /** 0 = 静止，1 = 正在驱动。 */
  drive: number;
  /** 头里的 AF 模式：0=OTHER、1=FACIAL、2=AUTO_AREA（与 AFAreaMode 不同）。 */
  mode: number;
  boxes: AfBox[];
}

/**
 * 解析实时取景头里的焦点状态与相机实际 AF 框。
 *
 * Ex 头（`GetLiveViewImageEx`）的布局来自 SnapBridge `b8` + `z7`：
 * - 偏移 41：FocusDrive（0=STILL，1=DRIVING）；
 * - 偏移 42：FocusState（0=UNKNOWN，1=DEVIATED，2=MATCH）；
 * - 偏移 44：AF 框数量；
 * - 偏移 48 起：每块 4 个大端 short（宽、高、中心 x、中心 y）。
 *
 * 老协议没有这套字段，返回 null，页面只显示本地点击反馈。
 */
export function parseLiveViewFocus(data: Uint8Array, ex: boolean): LiveViewFocus | null {
  if (!ex || data.length < 48) return null;
  const count = data[44] & 0xFF;
  const boxes: AfBox[] = [];
  let offset = 48;
  const limit = Math.min(count, 96);
  for (let i = 0; i < limit && offset + 8 <= data.length; i++) {
    const w = u16be(data, offset);
    const h = u16be(data, offset + 2);
    if (w > 0 && h > 0) {
      boxes.push({
        w: w,
        h: h,
        cx: u16be(data, offset + 4),
        cy: u16be(data, offset + 6)
      });
    }
    offset += 8;
  }
  return { state: data[42], drive: data[41], mode: data[43], boxes: boxes };
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
  /** AF 坐标系（实时取景头里的 wholeSize）；0 表示还没读到。 */
  @Trace afWidth: number = 0;
  @Trace afHeight: number = 0;
  @Trace shooting: boolean = false;
  @Trace focusing: boolean = false;
  @Trace zooming: boolean = false;
  @Trace fps: number = 0;
  /** 实时取景选择器：false = 照片，true = 视频。 */
  @Trace movieMode: boolean = false;
  @Trace movieRecording: boolean = false;
  @Trace movieSwitching: boolean = false;
  /** 相机当前实时取景对焦模式（0xD061）；-1 = 没读到。 */
  @Trace afMode: number = -1;
  /** 相机实时取景头里的焦点状态与 AF 框。 */
  @Trace focusState: number = 0;
  @Trace focusDrive: number = 0;
  @Trace afBoxes: AfBox[] = [];

  /** 曝光参数（原始值，格式见 NikonWifiExposure）。 */
  @Trace aperture: number = 0;
  @Trace shutterNum: number = 0;
  @Trace shutterDen: number = 0;
  @Trace iso: number = 0;
  @Trace ev: number = 0;
  @Trace apertureOptions: ExposureOption[] = [];
  @Trace shutterOptions: ExposureOption[] = [];
  @Trace isoOptions: ExposureOption[] = [];
  @Trace evOptions: ExposureOption[] = [];
  @Trace exposureLoading: boolean = false;
  @Trace exposureReady: boolean = false;
  /** 正在写入的参数名；空串表示空闲。 */
  @Trace exposureWriting: string = '';
  /** 最近一次对焦命令是否成功（只代表相机接受了命令，不代表合焦）。 */
  @Trace lastFocusOk: boolean = false;

  readonly supportsLiveView: boolean;
  readonly supportsMovie: boolean;
  readonly supportsCapture: boolean;
  readonly supportsAf: boolean;
  readonly supportsAfArea: boolean;
  readonly supportsZoom: boolean;

  private transport: PtpTransport;
  private log: (msg: string) => void;
  private useEx: boolean;
  private isoProperty: number = EXPOSURE_PROP_ISO;
  private afAreaModeOriginal: number = -1;
  private afAreaModeChanged: boolean = false;
  @Trace private frame: image.PixelMap | null = null;
  private loopToken: number = 0;
  private startSeq: number = 0;
  private paused: boolean = false;
  private liveViewStarted: boolean = false;
  private modeChanged: boolean = false;
  private failStreak: number = 0;
  private fpsWindowStart: number = 0;
  private fpsFrames: number = 0;
  private frameIndex: number = 0;
  private extractFailures: number = 0;
  private focusLogCount: number = 0;
  private lastAfKey: string = '';

  /**
   * 解码泵：取帧和 JPEG 解码重叠。
   *
   * PTP 一帧的往返约 80–100ms，JPEG 解码另算；以前两者串行，等于把解码
   * 时间直接加在每一帧上。现在取帧循环只把最新的 JPEG 放进 `pendingJpeg`
   * （解码慢时丢掉中间帧），解码自己在旁边排空，相机下一帧可以立刻开始取。
   */
  private pendingJpeg: Uint8Array | null = null;
  private pendingToken: number = 0;
  private decodeBusy: boolean = false;
  private droppedFrames: number = 0;

  /** 诊断：每 30 帧打印取帧 / 解码平均耗时。 */
  private timingFrames: number = 0;
  private timingFetchMs: number = 0;
  private timingDecodeFrames: number = 0;
  private timingDecodeMs: number = 0;

  constructor(transport: PtpTransport, deviceOps: number[],
              log: (msg: string) => void, deviceProps: number[] = []) {
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
    this.supportsMovie = (!known || (deviceOps.includes(NIKON_OP_START_MOVIE)
      && deviceOps.includes(NIKON_OP_END_MOVIE)))
      && (deviceProps.length === 0 || deviceProps.includes(NIKON_PROP_LIVEVIEW_SELECTOR));
    this.useEx = deviceOps.includes(NIKON_OP_GET_LIVEVIEW_IMAGE_EX);
  }

  /** 当前帧；只读。UI 用 `frameVersion` 触发重建，Map / PixelMap 本身不参与追踪。 */
  getPixelMap(): image.PixelMap | null {
    return this.frame;
  }

  /** 参数当前显示值；0 / 未读到时是 `--`。 */
  getExposureLabel(param: string): string {
    if (param === EXPOSURE_PARAM_APERTURE) return formatAperture(this.aperture);
    if (param === EXPOSURE_PARAM_SHUTTER) {
      return formatShutter(this.shutterNum, this.shutterDen);
    }
    if (param === EXPOSURE_PARAM_ISO) return formatIso(this.iso);
    if (param === EXPOSURE_PARAM_EV) return formatEv(this.ev);
    return '--';
  }

  getExposureOptions(param: string): ExposureOption[] {
    if (param === EXPOSURE_PARAM_APERTURE) return this.apertureOptions;
    if (param === EXPOSURE_PARAM_SHUTTER) return this.shutterOptions;
    if (param === EXPOSURE_PARAM_ISO) return this.isoOptions;
    if (param === EXPOSURE_PARAM_EV) return this.evOptions;
    return [];
  }

  getExposureRaw(param: string): number {
    if (param === EXPOSURE_PARAM_APERTURE) return this.aperture;
    if (param === EXPOSURE_PARAM_SHUTTER) {
      return shutterRaw(this.shutterNum, this.shutterDen);
    }
    if (param === EXPOSURE_PARAM_ISO) return this.iso;
    if (param === EXPOSURE_PARAM_EV) return this.ev;
    return 0;
  }

  /** 页面打开参数面板时兜底触发读取；正常在 start() 后已经自动开始。 */
  ensureExposure(): void {
    if (!this.active || this.exposureReady || this.exposureLoading) return;
    this.loadExposureState().catch((_e: Error) => { /* 已写日志 */ });
  }

  /**
   * 写一个曝光参数。
   *
   * 写之前先暂停取景循环，避免参数事务排在连续帧后面；写完回读相机实际值，
   * 不假设相机一定接受请求值（光圈/快门范围会随镜头与曝光模式变化）。
   */
  async setExposure(param: string, value: number): Promise<boolean> {
    if (!this.active || !this.exposureReady || this.exposureWriting !== '') {
      return false;
    }
    const seq = this.startSeq;
    let prop = 0;
    let data: Uint8Array | null = null;
    if (param === EXPOSURE_PARAM_APERTURE) {
      prop = EXPOSURE_PROP_APERTURE;
      data = u16leBytes(value);
    } else if (param === EXPOSURE_PARAM_SHUTTER) {
      prop = EXPOSURE_PROP_SHUTTER;
      data = u32leBytes(value);
    } else if (param === EXPOSURE_PARAM_ISO) {
      prop = this.isoProperty;
      data = prop === EXPOSURE_PROP_ISO ? u32leBytes(value) : u16leBytes(value);
    } else if (param === EXPOSURE_PARAM_EV) {
      prop = EXPOSURE_PROP_EV;
      data = u16leBytes(value & 0xFFFF);
    } else {
      return false;
    }
    this.exposureWriting = param;
    this.error = '';
    await this.pauseLoop();
    try {
      let r = await this.raw(EXPOSURE_OP_SET_DEVICE_PROP_VALUE, [prop], false, data);
      for (let i = 0; i < 2 && r !== null && r.code === RESPONSE_DEVICE_BUSY; i++) {
        await delay(100);
        r = await this.raw(EXPOSURE_OP_SET_DEVICE_PROP_VALUE, [prop], false, data);
      }
      if (seq !== this.startSeq || !this.active) return false;
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = L10n.tr('camera_wifi_remote_exposure_failed');
        this.log(`曝光: ${param} 写入失败 ${r === null ? 'null' : '0x' + r.code.toString(16)}`);
        return false;
      }
      await delay(40);
      await this.readExposureValues(seq);
      this.log(`曝光: ${param} → ${this.getExposureLabel(param)}`);
      return true;
    } finally {
      this.exposureWriting = '';
      this.resumeLoop();
    }
  }

  /**
   * 实时取景下点画面要能移动对焦点，前提是相机处于支持点选的 AF 区域模式。
   * Z50II 默认可能在「自动区域 AF」，此时 `0x9205 ChangeAfArea` 虽返回成功，
   * 但取景头里 AF 数量为 0、画面没有真实对焦框。这里只在自动区域模式时切到
   * 单点 AF，并在停止取景时恢复用户原来的模式。
   */
  private async prepareAfAreaMode(seq: number): Promise<void> {
    const data = await this.transport.getDevicePropValue(
      NIKON_PROP_AF_AREA_MODE, PtpPriority.FOREGROUND);
    if (seq !== this.startSeq || !this.active) return;
    if (data === null || data.length < 2) return;
    const mode = exposureU16le(data, 0);
    this.log(`实时取景: AF 区域模式=0x${mode.toString(16)}`);
    if (mode !== AF_AREA_AUTO_AREA
      && mode !== AF_AREA_AUTO_AREA_L_CHARACTER
      && mode !== AF_AREA_AUTO_AREA_L_ANIMAL) {
      return;
    }
    const r = await this.raw(NIKON_OP_SET_DEVICE_PROP_VALUE,
      [NIKON_PROP_AF_AREA_MODE], false, u16leBytes(AF_AREA_SINGLE_POINT));
    if (seq !== this.startSeq || !this.active) return;
    if (r !== null && r.code === RESPONSE_OK) {
      this.afAreaModeOriginal = mode;
      this.afAreaModeChanged = true;
      this.log('实时取景: AF 区域模式 → 单点');
    } else {
      this.log(`实时取景: 切换单点 AF 失败 ${r === null ? 'null' : '0x' + r.code.toString(16)}`);
    }
  }

  private async loadExposureState(): Promise<void> {
    if (this.exposureLoading) return;
    const seq = this.startSeq;
    this.exposureLoading = true;
    try {
      await this.readExposureValues(seq);
      if (seq !== this.startSeq || !this.active) return;
      await this.loadExposureOptions(seq);
      if (seq !== this.startSeq || !this.active) return;
      this.exposureReady = true;
      this.log(`曝光: ${this.getExposureLabel(EXPOSURE_PARAM_APERTURE)}`
        + ` ${this.getExposureLabel(EXPOSURE_PARAM_SHUTTER)}`
        + ` ${this.getExposureLabel(EXPOSURE_PARAM_ISO)}`
        + ` EV ${this.getExposureLabel(EXPOSURE_PARAM_EV)}`);
    } catch (err) {
      this.log(`曝光: 读取参数异常 ${(err as Error).message}`);
      if (this.active) {
        // 至少让用户能打开面板、看到相机当前值；写入失败会单独提示。
        if (this.apertureOptions.length === 0) {
          this.apertureOptions = staticOptions(EXPOSURE_PARAM_APERTURE);
        }
        if (this.shutterOptions.length === 0) {
          this.shutterOptions = staticOptions(EXPOSURE_PARAM_SHUTTER);
        }
        if (this.isoOptions.length === 0) {
          this.isoOptions = staticOptions(EXPOSURE_PARAM_ISO);
        }
        if (this.evOptions.length === 0) {
          this.evOptions = staticOptions(EXPOSURE_PARAM_EV);
        }
        this.exposureReady = true;
      }
    } finally {
      if (seq === this.startSeq) this.exposureLoading = false;
    }
  }

  private async readExposureValues(seq: number): Promise<void> {
    const ap = await this.transport.getDevicePropValue(
      EXPOSURE_PROP_APERTURE, PtpPriority.FOREGROUND);
    if (seq !== this.startSeq || !this.active) return;
    if (ap !== null && ap.length >= 2) this.aperture = exposureU16le(ap, 0);

    const sh = await this.transport.getDevicePropValue(
      EXPOSURE_PROP_SHUTTER, PtpPriority.FOREGROUND);
    if (seq !== this.startSeq || !this.active) return;
    if (sh !== null && sh.length >= 4) {
      const raw = exposureU32le(sh, 0);
      this.shutterNum = shutterNumerator(raw);
      this.shutterDen = shutterDenominator(raw);
    }

    let isoData = await this.transport.getDevicePropValue(
      this.isoProperty, PtpPriority.FOREGROUND);
    if (seq !== this.startSeq || !this.active) return;
    if (isoData === null && this.isoProperty === EXPOSURE_PROP_ISO) {
      this.isoProperty = EXPOSURE_PROP_ISO_FALLBACK;
      isoData = await this.transport.getDevicePropValue(
        this.isoProperty, PtpPriority.FOREGROUND);
      if (seq !== this.startSeq || !this.active) return;
    }
    if (isoData !== null) {
      this.iso = this.isoProperty === EXPOSURE_PROP_ISO && isoData.length >= 4
        ? exposureU32le(isoData, 0) : exposureU16le(isoData, 0);
    }

    const evData = await this.transport.getDevicePropValue(
      EXPOSURE_PROP_EV, PtpPriority.FOREGROUND);
    if (seq !== this.startSeq || !this.active) return;
    if (evData !== null && evData.length >= 2) {
      this.ev = signed16(exposureU16le(evData, 0));
    }
  }

  private async loadExposureOptions(seq: number): Promise<void> {
    const apData = await this.readExposureDescriptor(EXPOSURE_PROP_APERTURE);
    if (seq !== this.startSeq || !this.active) return;
    const ap = apData !== null
      ? parseDescriptorOptions(apData, EXPOSURE_PARAM_APERTURE) : [];
    this.apertureOptions = ap.length > 0
      ? ap : staticOptions(EXPOSURE_PARAM_APERTURE);
    this.log(`曝光: 光圈选项 ${this.apertureOptions.length} ${this.optionPreview(this.apertureOptions)}`);

    const shData = await this.readExposureDescriptor(EXPOSURE_PROP_SHUTTER);
    if (seq !== this.startSeq || !this.active) return;
    const sh = shData !== null
      ? parseDescriptorOptions(shData, EXPOSURE_PARAM_SHUTTER) : [];
    this.shutterOptions = sh.length > 0
      ? sh : staticOptions(EXPOSURE_PARAM_SHUTTER);
    this.log(`曝光: 快门选项 ${this.shutterOptions.length} ${this.optionPreview(this.shutterOptions)}`);

    const isoData = await this.readExposureDescriptor(this.isoProperty);
    if (seq !== this.startSeq || !this.active) return;
    const iso = isoData !== null
      ? parseDescriptorOptions(isoData, EXPOSURE_PARAM_ISO) : [];
    this.isoOptions = iso.length > 0
      ? iso : staticOptions(EXPOSURE_PARAM_ISO);
    this.log(`曝光: ISO选项 ${this.isoOptions.length} ${this.optionPreview(this.isoOptions)}`);
    if (this.isoProperty === EXPOSURE_PROP_ISO_FALLBACK) {
      // 旧属性是 UINT16，超过 65535 的 ISO 写不进去。
      this.isoOptions = this.isoOptions.filter((opt: ExposureOption) => opt.value <= 0xFFFF);
    }

    const evData = await this.readExposureDescriptor(EXPOSURE_PROP_EV);
    if (seq !== this.startSeq || !this.active) return;
    const ev = evData !== null
      ? parseDescriptorOptions(evData, EXPOSURE_PARAM_EV) : [];
    this.evOptions = ev.length > 0
      ? ev : staticOptions(EXPOSURE_PARAM_EV);
    this.log(`曝光: EV选项 ${this.evOptions.length} ${this.optionPreview(this.evOptions)}`);
  }

  private optionPreview(options: ExposureOption[]): string {
    const labels: string[] = [];
    for (let i = 0; i < options.length && i < 4; i++) {
      labels.push(options[i].label);
    }
    return labels.join('/');
  }

  private async readExposureDescriptor(prop: number): Promise<Uint8Array | null> {
    const r = await this.raw(EXPOSURE_OP_GET_DEVICE_PROP_DESC, [prop], true);
    if (r === null || r.code !== RESPONSE_OK || r.data === null) {
      this.log(`曝光: 属性 0x${prop.toString(16)} 无描述`
        + ` ${r === null ? 'null' : '0x' + r.code.toString(16)}`);
      return null;
    }
    const head = Array.from(r.data.subarray(0, Math.min(48, r.data.length)))
      .map((b: number) => b.toString(16).padStart(2, '0')).join('');
    this.log(`曝光: 描述 0x${prop.toString(16)} len=${r.data.length} head=${head}`);
    return r.data;
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
      // 相机可能停在上次的照片/视频选择器上；读回来让页面按钮与相机一致。
      const selector = await this.transport.getDevicePropValue(NIKON_PROP_LIVEVIEW_SELECTOR,
        PtpPriority.FOREGROUND);
      if (seq !== this.startSeq) return false;
      if (selector !== null && selector.length > 0) {
        this.movieMode = selector[0] === 1;
      }
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

      // 取景已经起来后再读；AF-F 是连续伺服，SnapBridge 只移动对焦点，不补 AfDrive。
      const afMode = await this.transport.getDevicePropValue(
        NIKON_PROP_AF_MODE_AT_LIVEVIEW, PtpPriority.FOREGROUND);
      if (seq !== this.startSeq) return false;
      if (afMode !== null && afMode.length > 0) {
        this.afMode = afMode[0];
        this.log(`实时取景: AF 模式=${this.afModeName()}`);
      } else {
        this.afMode = -1;
      }

      this.active = true;
      this.starting = false;
      this.paused = false;
      this.failStreak = 0;
      this.pendingJpeg = null;
      this.droppedFrames = 0;
      this.timingFrames = 0;
      this.timingFetchMs = 0;
      this.timingDecodeFrames = 0;
      this.timingDecodeMs = 0;
      this.fpsWindowStart = Date.now();
      this.fpsFrames = 0;
      this.focusState = 0;
      this.focusDrive = 0;
      this.afBoxes = [];
      this.focusLogCount = 0;
      this.lastAfKey = '';
      this.isoProperty = EXPOSURE_PROP_ISO;
      this.exposureReady = false;
      this.exposureLoading = false;
      this.afAreaModeOriginal = -1;
      this.afAreaModeChanged = false;
      this.apertureOptions = [];
      this.shutterOptions = [];
      this.isoOptions = [];
      this.evOptions = [];
      this.prepareAfAreaMode(seq).catch((_e: Error) => { /* 已写日志 */ });
      this.startLoop(++this.loopToken);
      this.log('实时取景: 已启动');
      this.loadExposureState().catch((_e: Error) => { /* 已写日志 */ });
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
    this.pendingJpeg = null;
    if (this.movieRecording) {
      await this.raw(NIKON_OP_END_MOVIE, [], false);
      this.movieRecording = false;
    }
    if (this.afAreaModeChanged) {
      const restored = await this.raw(NIKON_OP_SET_DEVICE_PROP_VALUE,
        [NIKON_PROP_AF_AREA_MODE], false, u16leBytes(this.afAreaModeOriginal));
      this.log(`实时取景: AF 区域模式恢复 0x${this.afAreaModeOriginal.toString(16)}`
        + ` ${restored === null ? 'null' : '0x' + restored.code.toString(16)}`);
      this.afAreaModeChanged = false;
      this.afAreaModeOriginal = -1;
    }
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
    this.focusState = 0;
    this.focusDrive = 0;
    this.afBoxes = [];
    this.exposureReady = false;
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
      this.log(`实时取景: AfDrive → ${r === null ? 'null' : '0x' + r.code.toString(16)}`);
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = r === null ? L10n.tr('camera_wifi_remote_af_failed')
          : this.errorText(r.code);
        return false;
      }
      const ready = await this.waitDeviceReady(this.startSeq, DEVICE_READY_TIMEOUT_MS);
      this.lastFocusOk = ready;
      if (ready) {
        // 合焦与否以实时取景头的 FocusState 为准，不把 DeviceReady 当合焦。
        this.lastAction = '';
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
      let areaCode = -1;
      if (this.supportsAfArea) {
        let px = Math.max(0, Math.round(x));
        let py = Math.max(0, Math.round(y));
        if (this.afWidth > 0) px = Math.min(px, this.afWidth - 1);
        if (this.afHeight > 0) py = Math.min(py, this.afHeight - 1);
        const moved = await this.raw(NIKON_OP_CHANGE_AF_AREA, [px, py], false);
        areaCode = moved === null ? -1 : moved.code;
        this.log(`实时取景: ChangeAfArea(${px},${py}) → `
          + `${moved === null ? 'null' : '0x' + moved.code.toString(16)}`);
        if (moved === null || (moved.code !== RESPONSE_OK
          && moved.code !== RESPONSE_OPERATION_NOT_SUPPORTED)) {
          this.error = moved === null ? L10n.tr('camera_wifi_remote_af_failed')
            : this.errorText(moved.code);
          return false;
        }
      }
      if (this.afMode === AF_MODE_AF_F) {
        // 连续伺服：移动对焦点后相机会自己追焦，SnapBridge 也不会再发 AfDrive。
        const ok = areaCode === RESPONSE_OK;
        this.lastFocusOk = ok;
        if (ok) {
          this.lastAction = '';
        } else {
          this.error = L10n.tr('camera_wifi_remote_af_failed');
        }
        this.log(`实时取景: AF-F 连续对焦，只移动对焦点（${ok ? '成功' : '失败'}）`);
        return ok;
      }
      if (!this.supportsAf) return false;
      const r = await this.raw(NIKON_OP_AF_DRIVE, [], false);
      this.log(`实时取景: AfDrive → ${r === null ? 'null' : '0x' + r.code.toString(16)}`);
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = r === null ? L10n.tr('camera_wifi_remote_af_failed')
          : this.errorText(r.code);
        return false;
      }
      const ready = await this.waitDeviceReady(this.startSeq, DEVICE_READY_TIMEOUT_MS);
      this.lastFocusOk = ready;
      if (ready) {
        // 合焦与否以实时取景头的 FocusState 为准，不把 DeviceReady 当合焦。
        this.lastAction = '';
      } else {
        this.error = L10n.tr('camera_wifi_remote_af_failed');
      }
      setTimeout(() => {
        if (!this.active) return;
        const box = this.afBoxes.length > 0 ? this.afBoxes[0] : null;
        this.log(`实时取景: 对焦后 请求=${Math.round(x)},${Math.round(y)}`
          + ` 框=${box === null ? '无' : `${box.cx},${box.cy}`}`
          + ` state=${this.focusState} mode=${this.afMode}`);
      }, 250);
      return ready;
    } finally {
      this.focusing = false;
      this.resumeLoop();
    }
  }

  /**
   * 切换实时取景选择器（照片 / 视频）。
   *
   * 相机侧的 `0xD1A6` 决定取景与快门语义；切换时先把当前实时取景停掉，
   * 写 0x1016（数据段 1 字节），再按需重新 start。这样不会在取景中途
   * 把相机切到另一套模式，导致 StartMovieRec 被拒。
   */
  async setMovieMode(on: boolean): Promise<boolean> {
    if (!this.supportsMovie) {
      this.error = L10n.tr('camera_wifi_remote_movie_unsupported');
      return false;
    }
    if (this.movieMode === on) return true;
    if (this.movieSwitching) return false;
    this.movieSwitching = true;
    const wasActive = this.active;
    try {
      if (wasActive) await this.stop();
      this.error = '';
      this.lastAction = '';
      const r = await this.raw(NIKON_OP_SET_DEVICE_PROP_VALUE,
        [NIKON_PROP_LIVEVIEW_SELECTOR], false, new Uint8Array([on ? 1 : 0]));
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = r === null ? L10n.tr('camera_wifi_remote_movie_switch_failed')
          : this.errorText(r.code);
        return false;
      }
      this.movieMode = on;
      this.log(`实时取景: 选择器 → ${on ? '视频' : '照片'}`);
      if (wasActive) return await this.start();
      return true;
    } finally {
      this.movieSwitching = false;
    }
  }

  /** 开始录像（相机侧 0x920A）。 */
  async startMovie(): Promise<boolean> {
    if (!this.active || !this.movieMode || this.movieRecording) return false;
    this.error = '';
    await this.pauseLoop();
    try {
      const r = await this.raw(NIKON_OP_START_MOVIE, [], false);
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = r === null ? L10n.tr('camera_wifi_remote_movie_failed')
          : this.errorText(r.code);
        return false;
      }
      this.movieRecording = true;
      this.lastAction = L10n.tr('camera_wifi_remote_recording');
      this.log('实时取景: 开始录像');
      return true;
    } finally {
      this.resumeLoop();
    }
  }

  /** 停止录像（相机侧 0x920B）。 */
  async stopMovie(): Promise<boolean> {
    if (!this.movieRecording) return true;
    await this.pauseLoop();
    try {
      const r = await this.raw(NIKON_OP_END_MOVIE, [], false);
      this.movieRecording = false;
      if (r === null || r.code !== RESPONSE_OK) {
        this.error = r === null ? L10n.tr('camera_wifi_remote_movie_failed')
          : this.errorText(r.code);
        return false;
      }
      this.lastAction = L10n.tr('camera_wifi_remote_movie_stopped');
      this.log('实时取景: 录像结束');
      return true;
    } finally {
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

      if (r !== null && r.code === RESPONSE_DEVICE_BUSY) {
        // 读曝光描述/属性时相机会短暂忙；不算取景失败，避免连续几次后误停。
        await delay(20);
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
      const ex = op === NIKON_OP_GET_LIVEVIEW_IMAGE_EX;
      const whole = parseLiveViewWholeSize(r.data, ex);
      if (whole[0] > 0 && whole[1] > 0) {
        this.afWidth = whole[0];
        this.afHeight = whole[1];
      }
      const focus = parseLiveViewFocus(r.data, ex);
      if (focus !== null) {
        this.focusState = focus.state;
        this.focusDrive = focus.drive;
        this.afBoxes = focus.boxes;
      }
      const jpeg = extractLiveViewJpeg(r.data, ex);
      const elapsed = Date.now() - started;
      if (jpeg === null) {
        this.extractFailures++;
        if (this.extractFailures <= 3) {
          this.log(`实时取景: 帧无 JPEG data=${r.data.length} head=`
            + `${Array.from(r.data.subarray(0, Math.min(16, r.data.length)))
              .map((b: number) => b.toString(16).padStart(2, '0')).join('')}`);
        }
      } else {
        this.frameIndex++;
        if (this.frameIndex === 1) {
          const head = Array.from(r.data.subarray(0, Math.min(64, r.data.length)))
            .map((b: number) => b.toString(16).padStart(2, '0')).join('');
          this.log(`实时取景: 取景头 len=${r.data.length} head=${head}`);
        }
        if (focus !== null) {
          const first = focus.boxes.length > 0 ? focus.boxes[0] : null;
          const key = `${focus.state}_${focus.drive}_${focus.mode}_${focus.boxes.length}`
            + `${first === null ? '' : `_${first.w}_${first.h}_${first.cx}_${first.cy}`}`;
          if (key !== this.lastAfKey && this.focusLogCount < 30) {
            this.lastAfKey = key;
            this.focusLogCount++;
            this.log(`实时取景: AF框 n=${focus.boxes.length} state=${focus.state}`
              + ` drive=${focus.drive} lvMode=${focus.mode}`
              + `${first === null ? ' 无框' : ` first=${first.w}x${first.h}@${first.cx},${first.cy}`}`
              + ` whole=${this.afWidth}x${this.afHeight}`);
          }
        }
        this.timingFrames++;
        this.timingFetchMs += elapsed;
        // 不 await 解码：把下一帧的取帧立刻发出去，解码由泵在旁边做。
        this.queueFrame(jpeg, token);
        if (this.frameIndex === 1 || this.frameIndex % 30 === 0) {
          const avgFetch = Math.round(this.timingFetchMs / Math.max(1, this.timingFrames));
          const avgDecode = this.timingDecodeFrames > 0
            ? Math.round(this.timingDecodeMs / this.timingDecodeFrames) : 0;
          this.log(`实时取景: 帧 ${this.frameIndex} jpeg=${jpeg.length}`
            + ` fetch=${avgFetch}ms decode=${avgDecode}ms drop=${this.droppedFrames}`
            + ` fps=${this.fps}`
            + ` af=${this.afWidth}x${this.afHeight} frame=${this.frameWidth}x${this.frameHeight}`);
          this.timingFrames = 0;
          this.timingFetchMs = 0;
          this.timingDecodeFrames = 0;
          this.timingDecodeMs = 0;
        }
      }

      const wait = Math.max(10, FRAME_INTERVAL_MS - elapsed);
      await delay(wait);
    }
  }

  /** 把最新一帧交给解码泵；解码跟不上时丢掉中间帧，只保留最新。 */
  private queueFrame(jpeg: Uint8Array, token: number): void {
    if (!this.active || token !== this.loopToken) return;
    if (this.pendingJpeg !== null) this.droppedFrames++;
    this.pendingJpeg = jpeg;
    this.pendingToken = token;
    this.scheduleDecode();
  }

  private scheduleDecode(): void {
    if (this.decodeBusy || this.pendingJpeg === null) return;
    const jpeg = this.pendingJpeg;
    const token = this.pendingToken;
    this.pendingJpeg = null;
    this.decodeBusy = true;
    this.pushFrame(jpeg, token)
      .catch((err: Error) => {
        this.log(`实时取景: 解码异常 ${err.message}`);
      })
      .then(() => {
        this.decodeBusy = false;
        this.scheduleDecode();
      });
  }

  private async pushFrame(jpeg: Uint8Array, token: number): Promise<void> {
    const started = Date.now();
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
      if (!this.active || token !== this.loopToken) {
        try { pm.release(); } catch (_e) { /* best effort */ }
        return;
      }
      const size = parseJpegSize(jpeg);
      let fw = size[0];
      let fh = size[1];
      if (fw <= 0 || fh <= 0) {
        // 理论上不会走到这里；JPEG 头异常时再退回 native 查询。
        const info = await pm.getImageInfo();
        fw = info.size.width;
        fh = info.size.height;
        if (!this.active || token !== this.loopToken) {
          try { pm.release(); } catch (_e) { /* best effort */ }
          return;
        }
      }
      const old = this.frame;
      this.frame = pm;
      this.frameWidth = fw;
      this.frameHeight = fh;
      if (this.afWidth === 0 || this.afHeight === 0) {
        this.afWidth = this.frameWidth;
        this.afHeight = this.frameHeight;
      }
      this.frameVersion++;
      this.countFrame();
      this.timingDecodeFrames++;
      this.timingDecodeMs += Date.now() - started;
      if (old !== null) {
        // 给 UI 一两帧时间把旧的绘制完；立刻 release 会出现黑闪。
        setTimeout(() => {
          try { old.release(); } catch (_e) { /* best effort */ }
        }, FRAME_RELEASE_DELAY_MS);
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
                    expectData: boolean, dataOut?: Uint8Array): Promise<PtpRawResult | null> {
    return this.transport.rawCommand(opcode, params, expectData, dataOut, PtpPriority.FOREGROUND);
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
      }, FRAME_FINAL_RELEASE_DELAY_MS);
    }
  }

  private afModeName(): string {
    switch (this.afMode) {
      case 0: return 'AF-S';
      case 1: return 'AF-C';
      case 2: return 'AF-F';
      case 3: return 'MF(固定)';
      case 4: return 'MF(可选)';
      case 5: return 'AF-A';
      default: return '未知';
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
