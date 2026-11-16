/**
 * 调试用 Wi-Fi 实时取景假相机（仅调试包）。
 *
 * `WifiRemotePage` 的真实数据全部来自 `NikonWifiLiveView`，模拟器没有 Wi-Fi
 * 相机，页面只会停在「请先连接」。这里实现一个最小的 `PtpTransport`：
 * - 返回一帧 1200×800 的虚拟 JPEG，外面套 1024 字节 Ex 实时取景头；
 * - 暴露白平衡 / 曝光模式 / AF 模式 / AF 区域的可读写属性与 `0x1014` 描述；
 * - `ChangeAfArea` 会真的移动第一块 AF 框，用于验收点画面对焦和多框叠加。
 *
 * 由 `CameraService.connectMockCamera()`（调试开关打开时的 STA）和
 * `CameraStateDemo` 的 `wifi_remote` 预演安装，release 包没有调用入口。
 */
import {
  type DeviceInfo,
  type ObjectInfo,
  type ObjectPropList,
  type PtpEndpoint,
  PtpPriority,
  type PtpRawResult,
  type PtpTransport
} from '../pages/PtpHost';
import { NikonWifiLiveView } from '../services/NikonWifiLiveView';
import { shutterRaw } from '../services/NikonWifiExposure';
import { MockPtpDevice } from './MockPtpDevice';

const PROP_LIVEVIEW_STATUS = 0xD1A2;
const PROP_LIVEVIEW_SELECTOR = 0xD1A6;
const PROP_AF_MODE = 0xD061;
const PROP_AF_AREA = 0xD05D;
const PROP_EXPOSURE_MODE = 0x500E;
const PROP_APERTURE = 0x5007;
const PROP_SHUTTER = 0xD100;
const PROP_ISO = 0xD0B4;
const PROP_EV = 0x5010;
const PROP_ISO_MAX = 0xD183;
const PROP_WHITE_BALANCE = 0x5005;
const PROP_MOVIE_WHITE_BALANCE = 0xD23A;
const PROP_REMOTE_PROHIBITION = 0xD0BD;
const PROP_LIVEVIEW_PROHIBITION = 0xD1A4;

const OPS: number[] = [
  0x90C2, 0x9201, 0x9202, 0x9203, 0x9428, 0x90C8,
  0x9207, 0x90C1, 0x9205, 0x9016, 0x920A, 0x920B
];
const PROPS: number[] = [
  PROP_LIVEVIEW_SELECTOR, PROP_WHITE_BALANCE, PROP_MOVIE_WHITE_BALANCE,
  PROP_AF_MODE, PROP_AF_AREA
];

function u16le(value: number): Uint8Array {
  return new Uint8Array([value & 0xFF, (value >> 8) & 0xFF]);
}

function u32le(value: number): Uint8Array {
  return new Uint8Array([
    value & 0xFF, (value >>> 8) & 0xFF,
    (value >>> 16) & 0xFF, (value >>> 24) & 0xFF
  ]);
}

function enumDescriptor(prop: number, size: number, values: number[]): Uint8Array {
  const data = new Uint8Array(8 + size * 2 + values.length * size);
  const view = new DataView(data.buffer);
  view.setUint16(0, prop, true);
  view.setUint16(2, size === 1 ? 0x0002 : (size === 2 ? 0x0004 : 0x0008), true);
  data[4] = 0x02;
  data[5 + size * 2] = 2;
  view.setUint16(6 + size * 2, values.length, true);
  let offset = 8 + size * 2;
  for (const value of values) {
    if (size === 1) {
      data[offset] = value & 0xFF;
    } else if (size === 2) {
      view.setUint16(offset, value & 0xFFFF, true);
    } else {
      view.setUint32(offset, value >>> 0, true);
    }
    offset += size;
  }
  return data;
}

function writeBox(data: Uint8Array, offset: number,
                   w: number, h: number, cx: number, cy: number): void {
  const view = new DataView(data.buffer);
  view.setUint16(offset, w, false);
  view.setUint16(offset + 2, h, false);
  view.setUint16(offset + 4, cx, false);
  view.setUint16(offset + 6, cy, false);
}

class MockWifiTransport implements PtpTransport {
  private props: Map<number, number> = new Map();
  private descriptors: Map<number, Uint8Array> = new Map();
  private frame: Uint8Array | null = null;
  private boxCx: number = 1800;
  private boxCy: number = 1600;
  private focusState: number = 2;
  private log: (msg: string) => void;

  constructor(log: (msg: string) => void) {
    this.log = log;
    this.props.set(PROP_LIVEVIEW_STATUS, 0);
    this.props.set(PROP_LIVEVIEW_SELECTOR, 0);
    this.props.set(PROP_AF_MODE, 0);
    this.props.set(PROP_AF_AREA, 0x8010);
    this.props.set(PROP_EXPOSURE_MODE, 3); // A（光圈优先）
    this.props.set(PROP_APERTURE, 280);
    this.props.set(PROP_SHUTTER, shutterRaw(1, 250));
    this.props.set(PROP_ISO, 400);
    this.props.set(PROP_EV, 0);
    this.props.set(PROP_ISO_MAX, 51200);
    this.props.set(PROP_WHITE_BALANCE, 4);
    this.props.set(PROP_MOVIE_WHITE_BALANCE, 0x8015);
    this.props.set(PROP_REMOTE_PROHIBITION, 0);
    this.props.set(PROP_LIVEVIEW_PROHIBITION, 0);

    this.descriptors.set(PROP_APERTURE, enumDescriptor(PROP_APERTURE, 2,
      [140, 160, 180, 200, 220, 250, 280, 320, 350, 400, 450, 500,
        560, 630, 710, 800, 900, 1000, 1100, 1300, 1400, 1600]));
    this.descriptors.set(PROP_SHUTTER, enumDescriptor(PROP_SHUTTER, 4,
      [shutterRaw(1, 8000), shutterRaw(1, 4000), shutterRaw(1, 2000),
        shutterRaw(1, 1000), shutterRaw(1, 500), shutterRaw(1, 250),
        shutterRaw(1, 125), shutterRaw(1, 60), shutterRaw(1, 30),
        shutterRaw(1, 15), shutterRaw(1, 8), shutterRaw(1, 4),
        shutterRaw(1, 2), shutterRaw(1, 1), shutterRaw(2, 1)]));
    this.descriptors.set(PROP_ISO, enumDescriptor(PROP_ISO, 4,
      [100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200]));
    this.descriptors.set(PROP_EV, enumDescriptor(PROP_EV, 2,
      [-2000, -1667, -1333, -1000, -667, -333, 0, 333, 667, 1000, 1333, 1667, 2000]));
    this.descriptors.set(PROP_WHITE_BALANCE, enumDescriptor(PROP_WHITE_BALANCE, 2,
      [2, 4, 0x8010, 0x8011, 0x8012, 0x8013, 0x8016]));
    this.descriptors.set(PROP_MOVIE_WHITE_BALANCE, enumDescriptor(PROP_MOVIE_WHITE_BALANCE, 2,
      [0x8015, 2, 4, 0x8010, 0x8011, 0x8012, 0x8013]));
    this.descriptors.set(PROP_AF_MODE, enumDescriptor(PROP_AF_MODE, 1,
      [0, 1, 2, 5, 4]));
    this.descriptors.set(PROP_AF_AREA, enumDescriptor(PROP_AF_AREA, 2,
      [0x8010, 0x8011, 0x8012, 0x8013, 0x8014, 0x8017,
        0x8018, 0x8019, 0x801A, 0x801B, 0x8020, 0x8021]));
  }

  get connectedDeviceName(): string {
    return 'mock-wifi-live';
  }

  async connect(_endpoint: PtpEndpoint, _priority?: PtpPriority): Promise<boolean> {
    return true;
  }

  async getDeviceInfo(_priority?: PtpPriority): Promise<DeviceInfo | null> {
    return null;
  }

  async getDevicePropValue(propertyCode: number,
                           _priority?: PtpPriority): Promise<Uint8Array | null> {
    const value = this.props.get(propertyCode);
    if (value === undefined) return null;
    if (propertyCode === PROP_LIVEVIEW_STATUS || propertyCode === PROP_LIVEVIEW_SELECTOR
      || propertyCode === PROP_AF_MODE) {
      return new Uint8Array([value & 0xFF]);
    }
    if (propertyCode === PROP_SHUTTER || propertyCode === PROP_ISO
      || propertyCode === PROP_ISO_MAX) {
      return u32le(value);
    }
    if (propertyCode === PROP_REMOTE_PROHIBITION || propertyCode === PROP_LIVEVIEW_PROHIBITION) {
      return new Uint8Array([0, 0, 0, 0]);
    }
    return u16le(value);
  }

  async rawCommand(opcode: number, params: number[], _expectData: boolean,
                   dataOut?: Uint8Array, _priority?: PtpPriority): Promise<PtpRawResult | null> {
    if (opcode === 0x1014) {
      const desc = this.descriptors.get(params[0]);
      return { code: 0x2001, params: [], data: desc ?? null };
    }
    if (opcode === 0x1016) {
      if (dataOut !== undefined && dataOut.length > 0) {
        this.setProp(params[0], dataOut);
      }
      return this.ok();
    }
    if (opcode === 0x9201) {
      this.props.set(PROP_LIVEVIEW_STATUS, 1);
      return this.ok();
    }
    if (opcode === 0x9202) {
      this.props.set(PROP_LIVEVIEW_STATUS, 0);
      return this.ok();
    }
    if (opcode === 0x9203 || opcode === 0x9428) {
      return { code: 0x2001, params: [], data: await this.frameData() };
    }
    if (opcode === 0x9205) {
      this.boxCx = params[0];
      this.boxCy = params[1];
      this.focusState = 2;
      this.frame = null;
      this.log(`mock-wifi: ChangeAfArea ${params[0]},${params[1]}`);
      return this.ok();
    }
    if (opcode === 0x90C1) {
      this.focusState = 2;
      this.frame = null;
      return this.ok();
    }
    return this.ok();
  }

  has(_opcode: number): boolean {
    return true;
  }

  async getStorageIDs(_priority?: PtpPriority): Promise<number[]> {
    return [];
  }

  async getObjectHandles(_storageId: number, _parent?: number, _formatCode?: number,
                         _priority?: PtpPriority): Promise<number[]> {
    return [];
  }

  async getObjectInfo(_handle: number, _priority?: PtpPriority): Promise<ObjectInfo | null> {
    return null;
  }

  async getThumb(_handle: number, _priority?: PtpPriority): Promise<Uint8Array | null> {
    return null;
  }

  async getObject(_handle: number, _priority?: PtpPriority): Promise<Uint8Array | null> {
    return null;
  }

  async getPartialObject(_handle: number, _offset: number, _maxBytes: number,
                         _priority?: PtpPriority): Promise<Uint8Array | null> {
    return null;
  }

  async getObjectPropList(_objectHandle: number, _formatCode: number, _propertyCode: number,
                          _groupCode: number, _depth: number,
                          _priority?: PtpPriority): Promise<ObjectPropList> {
    return { objects: [], codes: [], declared: 0, complete: false, bytes: 0, head: '' };
  }

  async closeSessionAndPipe(_priority?: PtpPriority): Promise<void> {
  }

  private ok(): PtpRawResult {
    return { code: 0x2001, params: [], data: null };
  }

  private setProp(prop: number, data: Uint8Array): void {
    let value = 0;
    for (let i = 0; i < data.length; i++) {
      value |= data[i] << (8 * i);
    }
    this.props.set(prop, value >>> 0);
    this.frame = null;
    this.log(`mock-wifi: set 0x${prop.toString(16)} = ${value >>> 0}`);
  }

  private async frameData(): Promise<Uint8Array> {
    if (this.frame !== null) return this.frame;
    let jpeg = await MockPtpDevice.fullJpeg(1001);
    if (jpeg === null) {
      jpeg = new Uint8Array([0xFF, 0xD8, 0xFF, 0xD9]);
    }
    const header = new Uint8Array(1024);
    const view = new DataView(header.buffer);
    view.setUint32(12, jpeg.length, false);
    view.setUint16(16, 5568, false);
    view.setUint16(18, 3712, false);
    header[41] = 0; // FocusDrive = STILL
    header[42] = this.focusState;
    const area = this.props.get(PROP_AF_AREA) ?? -1;
    const autoArea = area === 0x8011 || area === 0x8020 || area === 0x8021;
    header[43] = autoArea ? 2 : 1;
    // 单点 / 针点只返回一块框；自动区域返回两块，用来验收多框叠加。
    header[44] = autoArea ? 2 : 1;
    writeBox(header, 48, 700, 560, this.boxCx, this.boxCy);
    if (autoArea) {
      writeBox(header, 56, 500, 400, 3300, 2400);
    }
    const out = new Uint8Array(header.length + jpeg.length);
    out.set(header, 0);
    out.set(jpeg, header.length);
    this.frame = out;
    return out;
  }
}

/**
 * 造一个会出帧、能读写的假实时取景控制器。
 *
 * 由 `CameraService` 在调试模式下直接挂到 `wifiLiveView`；也从 `CameraStateDemo`
 * 的 `wifi_remote` 预演里使用。这里不接收 `CameraService`，避免服务层和调试模块
 * 互相 import 形成环。
 */
export function createMockWifiLiveView(log: (msg: string) => void): NikonWifiLiveView {
  const transport = new MockWifiTransport(log);
  log('[mock-wifi] 实时取景假相机已安装');
  return new NikonWifiLiveView(transport, OPS, log, PROPS);
}
