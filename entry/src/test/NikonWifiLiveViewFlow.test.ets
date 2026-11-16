import { describe, it, expect } from '@ohos/hypium';
import { PtpPriority, type DeviceInfo, type ObjectInfo, type ObjectPropList,
  type PtpEndpoint, type PtpRawResult, type PtpTransport } from '../main/ets/pages/PtpHost';
import { NikonWifiLiveView, NIKON_OP_AF_DRIVE, NIKON_OP_CAPTURE,
  NIKON_OP_CHANGE_AF_AREA, NIKON_OP_CHANGE_CAMERA_MODE, NIKON_OP_DEVICE_READY,
  NIKON_OP_END_LIVEVIEW, NIKON_OP_GET_LIVEVIEW_IMAGE, NIKON_OP_GET_LIVEVIEW_IMAGE_EX,
  NIKON_OP_SET_DEVICE_PROP_VALUE, NIKON_OP_START_LIVEVIEW, NIKON_OP_START_MOVIE,
  NIKON_OP_END_MOVIE, NIKON_OP_ZOOM, NIKON_PROP_LIVEVIEW_SELECTOR }
  from '../main/ets/services/NikonWifiLiveView';
import { EXPOSURE_PARAM_APERTURE } from '../main/ets/services/NikonWifiExposure';

const OPS: number[] = [
  NIKON_OP_CHANGE_CAMERA_MODE, NIKON_OP_START_LIVEVIEW, NIKON_OP_END_LIVEVIEW,
  NIKON_OP_GET_LIVEVIEW_IMAGE, NIKON_OP_GET_LIVEVIEW_IMAGE_EX, NIKON_OP_DEVICE_READY,
  NIKON_OP_CAPTURE, NIKON_OP_AF_DRIVE, NIKON_OP_CHANGE_AF_AREA, NIKON_OP_ZOOM,
  NIKON_OP_SET_DEVICE_PROP_VALUE, NIKON_OP_START_MOVIE, NIKON_OP_END_MOVIE
];
const PROPS: number[] = [NIKON_PROP_LIVEVIEW_SELECTOR];

interface RecordedOp {
  opcode: number;
  params: number[];
  data: Uint8Array | null;
}

class FakeLiveTransport implements PtpTransport {
  ops: RecordedOp[] = [];
  afModeValue: number = -1;

  get connectedDeviceName(): string {
    return 'fake-live';
  }

  async connect(_endpoint: PtpEndpoint, _priority?: PtpPriority): Promise<boolean> {
    return true;
  }

  async getDeviceInfo(_priority?: PtpPriority): Promise<DeviceInfo | null> {
    return null;
  }

  async getDevicePropValue(propertyCode: number,
    _priority?: PtpPriority): Promise<Uint8Array | null> {
    if (propertyCode === 0xD0BD || propertyCode === 0xD1A4) {
      return new Uint8Array([0, 0, 0, 0]);
    }
    if (propertyCode === 0xD1A2) {
      return new Uint8Array([0]);
    }
    if (propertyCode === 0xD061) {
      return this.afModeValue >= 0 ? new Uint8Array([this.afModeValue]) : null;
    }
    return null;
  }

  async rawCommand(opcode: number, params: number[], _expectData: boolean,
    dataOut?: Uint8Array, _priority?: PtpPriority): Promise<PtpRawResult | null> {
    this.ops.push({ opcode: opcode, params: params, data: dataOut ?? null });
    if (opcode === NIKON_OP_GET_LIVEVIEW_IMAGE_EX || opcode === NIKON_OP_GET_LIVEVIEW_IMAGE) {
      // 给取景循环一个“成功”的假帧，避免 5 次失败后自动 stop 干扰后续断言。
      return { code: 0x2001, params: [], data: new Uint8Array([0xFF, 0xD8, 0xFF, 0xD9]) };
    }
    return { code: 0x2001, params: [], data: null };
  }

  has(opcode: number): boolean {
    return this.ops.some((x: RecordedOp) => x.opcode === opcode);
  }

  find(opcode: number): RecordedOp | null {
    for (const op of this.ops) {
      if (op.opcode === opcode) return op;
    }
    return null;
  }

  findAll(opcode: number): RecordedOp[] {
    return this.ops.filter((x: RecordedOp) => x.opcode === opcode);
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
    _groupCode: number, _depth: number, _priority?: PtpPriority): Promise<ObjectPropList> {
    return { objects: [], codes: [], declared: 0, complete: false, bytes: 0, head: '' };
  }

  async closeSessionAndPipe(_priority?: PtpPriority): Promise<void> {
  }
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => { setTimeout(resolve, ms); });
}

export default function nikonWifiLiveViewFlowTest() {
  describe('NikonWifiLiveView flow', () => {
    it('启动 / 拍摄 / 对焦 / 变焦 / 停止走正确的 PTP 操作码', 0, async () => {
      const fake = new FakeLiveTransport();
      const live = new NikonWifiLiveView(fake, OPS, (_m: string) => {}, PROPS);
      const started = await live.start();
      expect(started).assertTrue();
      expect(fake.has(NIKON_OP_CHANGE_CAMERA_MODE)).assertTrue();
      expect(fake.has(NIKON_OP_START_LIVEVIEW)).assertTrue();
      expect(fake.has(NIKON_OP_DEVICE_READY)).assertTrue();

      const shot = await live.capture();
      expect(shot).assertTrue();
      const capture = fake.find(NIKON_OP_CAPTURE);
      expect(capture !== null).assertTrue();
      expect(capture?.params[0]).assertEqual(0xFFFFFFFF);
      expect(capture?.params[1]).assertEqual(0);

      const focused = await live.afDrive();
      expect(focused).assertTrue();
      expect(fake.has(NIKON_OP_AF_DRIVE)).assertTrue();

      const focusPoint = await live.focusAt(120, 80);
      expect(focusPoint).assertTrue();
      const area = fake.find(NIKON_OP_CHANGE_AF_AREA);
      expect(area !== null).assertTrue();
      expect(area?.params[0]).assertEqual(120);
      expect(area?.params[1]).assertEqual(80);

      const zoomed = await live.zoom(true);
      expect(zoomed).assertTrue();
      const zoom = fake.find(NIKON_OP_ZOOM);
      expect(zoom !== null).assertTrue();
      expect(zoom?.params[0]).assertEqual(0);
      expect(zoom?.params[1]).assertEqual(1);

      const movie = await live.setMovieMode(true);
      expect(movie).assertTrue();
      expect(live.movieMode).assertTrue();
      const selectorSet = fake.findAll(NIKON_OP_SET_DEVICE_PROP_VALUE);
      expect(selectorSet.length >= 1).assertTrue();
      expect(selectorSet[selectorSet.length - 1].params[0]).assertEqual(NIKON_PROP_LIVEVIEW_SELECTOR);
      expect(selectorSet[selectorSet.length - 1].data?.[0]).assertEqual(1);
      const rec = await live.startMovie();
      expect(rec).assertTrue();
      expect(live.movieRecording).assertTrue();
      const stoppedRec = await live.stopMovie();
      expect(stoppedRec).assertTrue();
      expect(live.movieRecording).assertFalse();
      const back = await live.setMovieMode(false);
      expect(back).assertTrue();
      expect(live.movieMode).assertFalse();
      const selectorBack = fake.findAll(NIKON_OP_SET_DEVICE_PROP_VALUE);
      expect(selectorBack[selectorBack.length - 1].data?.[0]).assertEqual(0);

      await live.stop();
      expect(live.active).assertFalse();
      expect(fake.has(NIKON_OP_END_LIVEVIEW)).assertTrue();
      await delay(10);
    });

    it('AF-F 连续对焦只移动对焦点，不再发 AfDrive', 0, async () => {
      const fake = new FakeLiveTransport();
      fake.afModeValue = 2;
      const live = new NikonWifiLiveView(fake, OPS, (_m: string) => {}, PROPS);
      expect(await live.start()).assertTrue();
      expect(live.afMode).assertEqual(2);

      const ok = await live.focusAt(120, 80);
      expect(ok).assertTrue();
      expect(fake.has(NIKON_OP_CHANGE_AF_AREA)).assertTrue();
      expect(fake.has(NIKON_OP_AF_DRIVE)).assertFalse();

      await live.stop();
      await delay(10);
    });

    it('曝光参数写入光圈属性并回读', 0, async () => {
      const fake = new FakeLiveTransport();
      const live = new NikonWifiLiveView(fake, OPS, (_m: string) => {}, PROPS);
      expect(await live.start()).assertTrue();
      for (let i = 0; i < 30 && !live.exposureReady; i++) {
        await delay(10);
      }
      expect(live.exposureReady).assertTrue();

      const ok = await live.setExposure(EXPOSURE_PARAM_APERTURE, 280);
      expect(ok).assertTrue();
      const sets = fake.findAll(NIKON_OP_SET_DEVICE_PROP_VALUE);
      expect(sets.length >= 1).assertTrue();
      const last = sets[sets.length - 1];
      expect(last.params[0]).assertEqual(0x5007);
      expect(last.data?.[0]).assertEqual(0x18);
      expect(last.data?.[1]).assertEqual(0x01);

      await live.stop();
      await delay(10);
    });
  });
}
