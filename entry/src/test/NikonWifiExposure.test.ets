import { describe, it, expect } from '@ohos/hypium';
import {
  EXPOSURE_PARAM_APERTURE,
  EXPOSURE_PARAM_EV,
  EXPOSURE_PARAM_ISO,
  EXPOSURE_PARAM_SHUTTER,
  formatAperture,
  formatEv,
  formatIso,
  formatShutter,
  parseDescriptorOptions,
  shutterRaw,
  staticOptions
} from '../main/ets/services/NikonWifiExposure';

function makeDescriptor(dataType: number, values: number[]): Uint8Array {
  const size = dataType === 0x0003 || dataType === 0x0004 ? 2 : 4;
  const data = new Uint8Array(8 + size * 2 + values.length * size);
  const view = new DataView(data.buffer);
  view.setUint16(0, 0x5007, true);
  view.setUint16(2, dataType, true);
  data[4] = 0x02;
  data[5 + size * 2] = 2;
  view.setUint16(6 + size * 2, values.length, true);
  let offset = 8 + size * 2;
  for (const value of values) {
    if (size === 2) {
      view.setUint16(offset, value & 0xFFFF, true);
    } else {
      view.setUint32(offset, value >>> 0, true);
    }
    offset += size;
  }
  return data;
}

/** 故意让头里的 dataType 和值的实际宽度不一致，用于验证按属性尝试 2B/4B。 */
function makeMismatchedDescriptor(dataType: number, valueSize: number,
                                  values: number[]): Uint8Array {
  const data = new Uint8Array(8 + valueSize * 2 + values.length * valueSize);
  const view = new DataView(data.buffer);
  view.setUint16(0, 0xD0B4, true);
  view.setUint16(2, dataType, true);
  data[4] = 0x02;
  data[5 + valueSize * 2] = 2;
  view.setUint16(6 + valueSize * 2, values.length, true);
  let offset = 8 + valueSize * 2;
  for (const value of values) {
    if (valueSize === 2) {
      view.setUint16(offset, value, true);
    } else {
      view.setUint32(offset, value, true);
    }
    offset += valueSize;
  }
  return data;
}

export default function nikonWifiExposureTest() {
  describe('NikonWifiExposure', () => {
    it('光圈值按 f 值 ×100 显示', 0, () => {
      expect(formatAperture(280)).assertEqual('f/2.8');
      expect(formatAperture(1000)).assertEqual('f/10');
      expect(formatAperture(95)).assertEqual('f/0.95');
      expect(formatAperture(0)).assertEqual('--');
    });

    it('快门按分子/分母显示，支持整秒和 B 门', 0, () => {
      expect(formatShutter(1, 250)).assertEqual('1/250');
      expect(formatShutter(1, 4000)).assertEqual('1/4000');
      expect(formatShutter(2, 1)).assertEqual('2"');
      expect(formatShutter(5, 2)).assertEqual('2.5"');
      expect(formatShutter(65535, 65535)).assertEqual('Bulb');
    });

    it('ISO 和曝光补偿显示', 0, () => {
      expect(formatIso(400)).assertEqual('400');
      expect(formatIso(0)).assertEqual('--');
      expect(formatEv(333)).assertEqual('+0.3');
      expect(formatEv(-333)).assertEqual('-0.3');
      expect(formatEv(0)).assertEqual('0.0');
    });

    it('解析光圈枚举描述', 0, () => {
      const opts = parseDescriptorOptions(makeDescriptor(0x0004, [280, 320, 400]),
        EXPOSURE_PARAM_APERTURE);
      expect(opts.length).assertEqual(3);
      expect(opts[0].label).assertEqual('f/2.8');
      expect(opts[1].label).assertEqual('f/3.2');
      expect(opts[2].value).assertEqual(400);
    });

    it('PTP FormFlag 1 是 Range、2 是 Enumeration', 0, () => {
      const range = new Uint8Array(16);
      const view = new DataView(range.buffer);
      view.setUint16(0, 0x5007, true);
      view.setUint16(2, 0x0004, true);
      range[4] = 0x02;
      range[9] = 0x01; // FormFlag = Range
      view.setUint16(10, 100, true);
      view.setUint16(12, 300, true);
      view.setUint16(14, 50, true);
      const opts = parseDescriptorOptions(range, EXPOSURE_PARAM_APERTURE);
      expect(opts.length).assertEqual(5);
      expect(opts[0].value).assertEqual(100);
      expect(opts[4].value).assertEqual(300);
    });

    it('实际光圈枚举按 22 项解析，首项 f/1.4', 0, () => {
      const values = [140, 160, 180, 200, 220, 250, 280, 320, 350, 400, 450,
        500, 560, 630, 710, 800, 900, 1000, 1100, 1300, 1400, 1600];
      const opts = parseDescriptorOptions(makeDescriptor(0x0004, values),
        EXPOSURE_PARAM_APERTURE);
      expect(opts.length).assertEqual(22);
      expect(opts[0].value).assertEqual(140);
      expect(opts[0].label).assertEqual('f/1.4');
    });

    it('解析快门 32 位枚举描述', 0, () => {
      const opts = parseDescriptorOptions(
        makeDescriptor(0x0006, [shutterRaw(1, 250), shutterRaw(1, 125)]),
        EXPOSURE_PARAM_SHUTTER);
      expect(opts.length).assertEqual(2);
      expect(opts[0].label).assertEqual('1/250');
      expect(opts[1].label).assertEqual('1/125');
    });

    it('解析曝光补偿有符号枚举描述', 0, () => {
      const opts = parseDescriptorOptions(makeDescriptor(0x0003, [-333, 0, 333]),
        EXPOSURE_PARAM_EV);
      expect(opts.length).assertEqual(3);
      expect(opts[0].label).assertEqual('-0.3');
      expect(opts[1].label).assertEqual('0.0');
      expect(opts[2].label).assertEqual('+0.3');
    });

    it('描述不可用时静态列表非空', 0, () => {
      expect(staticOptions(EXPOSURE_PARAM_APERTURE).length > 0).assertTrue();
      expect(staticOptions(EXPOSURE_PARAM_SHUTTER).length > 0).assertTrue();
      expect(staticOptions(EXPOSURE_PARAM_EV).length > 0).assertTrue();
    });

    it('dataType 写成 UINT32 但值实际是 16 位时按属性回退到 2B', 0, () => {
      const data = makeMismatchedDescriptor(0x0006, 2, [50, 100, 200, 400]);
      const opts = parseDescriptorOptions(data, EXPOSURE_PARAM_ISO);
      expect(opts.length).assertEqual(4);
      expect(opts[1].value).assertEqual(100);
      expect(opts[1].label).assertEqual('100');
    });

    it('只有一个不合理值时返回空，交给静态列表兜底', 0, () => {
      const data = makeMismatchedDescriptor(0x0004, 2, [22]);
      const opts = parseDescriptorOptions(data, EXPOSURE_PARAM_APERTURE);
      expect(opts.length).assertEqual(0);
    });
  });
}
