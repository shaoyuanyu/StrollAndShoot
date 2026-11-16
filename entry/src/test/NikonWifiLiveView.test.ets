import { describe, it, expect } from '@ohos/hypium';
import { extractLiveViewJpeg, parseJpegSize, parseLiveViewWholeSize }
  from '../main/ets/services/NikonWifiLiveView';

function makeJpeg(width: number, height: number): Uint8Array {
  // SOI + SOF0（长度 17：2B 长度 + 1B 精度 + 2B 高 + 2B 宽 + 1B 分量数 + 9B 分量）
  const data = new Uint8Array(23);
  data.set([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08], 0);
  data[7] = (height >> 8) & 0xFF;
  data[8] = height & 0xFF;
  data[9] = (width >> 8) & 0xFF;
  data[10] = width & 0xFF;
  data[11] = 0x03;
  data[21] = 0xFF;
  data[22] = 0xD9;
  return data;
}

function makePayload(headerLength: number, declaredOffset: number,
                     jpeg: number[]): Uint8Array {
  const data = new Uint8Array(headerLength + jpeg.length);
  const view = new DataView(data.buffer);
  if (declaredOffset >= 0) {
    view.setUint32(declaredOffset, jpeg.length, false);
  }
  data.set(jpeg, headerLength);
  return data;
}

export default function nikonWifiLiveViewTest() {
  describe('NikonWifiLiveView', () => {
    it('标准 LiveView 头按偏移 4 的长度取 JPEG', 0, () => {
      const jpeg = [0xFF, 0xD8, 0x11, 0x22, 0xFF, 0xD9];
      const data = makePayload(384, 4, jpeg);
      const out = extractLiveViewJpeg(data, false);
      expect(out !== null).assertTrue();
      expect(out?.length).assertEqual(jpeg.length);
      expect(out?.[0]).assertEqual(0xFF);
      expect(out?.[1]).assertEqual(0xD8);
      expect(out?.[out.length - 1]).assertEqual(0xD9);
    });

    it('Ex LiveView 头按偏移 12 的长度取 JPEG', 0, () => {
      const jpeg = [0xFF, 0xD8, 0x33, 0x44, 0x55, 0xFF, 0xD9];
      const data = makePayload(1024, 12, jpeg);
      const out = extractLiveViewJpeg(data, true);
      expect(out !== null).assertTrue();
      expect(out?.length).assertEqual(jpeg.length);
      expect(out?.[2]).assertEqual(0x33);
    });

    it('声明长度不可信时退到 SOI/EOI 扫描', 0, () => {
      const jpeg = [0xFF, 0xD8, 0xAA, 0xBB, 0xFF, 0xD9];
      const data = makePayload(64, -1, jpeg);
      const out = extractLiveViewJpeg(data, false);
      expect(out !== null).assertTrue();
      expect(out?.length).assertEqual(jpeg.length);
      expect(out?.[2]).assertEqual(0xAA);
    });

    it('没有 JPEG 数据时返回 null', 0, () => {
      const data = new Uint8Array(32);
      expect(extractLiveViewJpeg(data, false)).assertNull();
    });

    it('标准头读取 wholeSize', 0, () => {
      const data = new Uint8Array(32);
      const view = new DataView(data.buffer);
      view.setUint16(12, 640, false);
      view.setUint16(14, 424, false);
      const size = parseLiveViewWholeSize(data, false);
      expect(size[0]).assertEqual(640);
      expect(size[1]).assertEqual(424);
    });

    it('Ex 头读取 wholeSize', 0, () => {
      const data = new Uint8Array(32);
      const view = new DataView(data.buffer);
      view.setUint16(16, 1280, false);
      view.setUint16(18, 848, false);
      const size = parseLiveViewWholeSize(data, true);
      expect(size[0]).assertEqual(1280);
      expect(size[1]).assertEqual(848);
    });

    it('Z50II 实际 wholeSize 字节按大端解析为 5568x3712', 0, () => {
      // 真机数据是 15 C0 0E 80；按小端会读成 49173x32782。
      const data = new Uint8Array(32);
      data.set([0x15, 0xC0, 0x0E, 0x80], 16);
      const size = parseLiveViewWholeSize(data, true);
      expect(size[0]).assertEqual(5568);
      expect(size[1]).assertEqual(3712);
    });

    it('从 JPEG SOF0 读取尺寸', 0, () => {
      const size = parseJpegSize(makeJpeg(640, 424));
      expect(size[0]).assertEqual(640);
      expect(size[1]).assertEqual(424);
    });

    it('JPEG 头前有 APP 段时也能读尺寸', 0, () => {
      const raw = makeJpeg(1024, 682);
      const data = new Uint8Array(raw.length + 6);
      data.set([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00], 0);
      data.set(raw.subarray(2), 8);
      const size = parseJpegSize(data);
      expect(size[0]).assertEqual(1024);
      expect(size[1]).assertEqual(682);
    });

    it('不是 JPEG 时返回 0', 0, () => {
      const size = parseJpegSize(new Uint8Array([0x00, 0x01, 0x02, 0x03]));
      expect(size[0]).assertEqual(0);
      expect(size[1]).assertEqual(0);
    });
  });
}
