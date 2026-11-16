import { describe, it, expect } from '@ohos/hypium';
import { extractLiveViewJpeg, parseLiveViewWholeSize } from '../main/ets/services/NikonWifiLiveView';

function makePayload(headerLength: number, declaredOffset: number,
                     jpeg: number[]): Uint8Array {
  const data = new Uint8Array(headerLength + jpeg.length);
  const view = new DataView(data.buffer);
  if (declaredOffset >= 0) {
    view.setUint32(declaredOffset, jpeg.length, true);
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
      view.setUint16(12, 640, true);
      view.setUint16(14, 424, true);
      const size = parseLiveViewWholeSize(data, false);
      expect(size[0]).assertEqual(640);
      expect(size[1]).assertEqual(424);
    });

    it('Ex 头读取 wholeSize', 0, () => {
      const data = new Uint8Array(32);
      const view = new DataView(data.buffer);
      view.setUint16(16, 1280, true);
      view.setUint16(18, 848, true);
      const size = parseLiveViewWholeSize(data, true);
      expect(size[0]).assertEqual(1280);
      expect(size[1]).assertEqual(848);
    });
  });
}
