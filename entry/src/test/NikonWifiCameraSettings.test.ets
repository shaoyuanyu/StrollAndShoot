import { describe, it, expect } from '@ohos/hypium';
import {
  AF_AREA_AUTO_ANIMAL,
  AF_AREA_AUTO_AREA,
  AF_AREA_PIN_POINT,
  AF_AREA_SINGLE_POINT,
  AF_AREA_WIDE_L,
  afAreaLabelKey,
  afAreaOptionsFromDescriptor,
  afAreaStaticOptions,
  afAreaSupportsPoint,
  afModeLabelKey,
  afModeOptionsFromDescriptor,
  afModeStaticOptions,
  exposureParamEnabled,
  parseEnumDescriptor,
  programModeLabel,
  whiteBalanceLabelKey,
  whiteBalanceOptionsFromDescriptor,
  whiteBalanceStaticOptions
} from '../main/ets/services/NikonWifiCameraSettings';
import {
  EXPOSURE_PARAM_APERTURE,
  EXPOSURE_PARAM_EV,
  EXPOSURE_PARAM_ISO,
  EXPOSURE_PARAM_SHUTTER
} from '../main/ets/services/NikonWifiExposure';

function makeDescriptor(prop: number, dataType: number, size: number,
                        values: number[]): Uint8Array {
  const data = new Uint8Array(8 + size * 2 + values.length * size);
  const view = new DataView(data.buffer);
  view.setUint16(0, prop, true);
  view.setUint16(2, dataType, true);
  data[4] = 0x02;
  data[5 + size * 2] = 2; // FormFlag = Enumeration
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

export default function nikonWifiCameraSettingsTest() {
  describe('NikonWifiCameraSettings', () => {
    it('曝光模式显示 P/A/S/M/AUTO', 0, () => {
      expect(programModeLabel(1)).assertEqual('M');
      expect(programModeLabel(2)).assertEqual('P');
      expect(programModeLabel(3)).assertEqual('A');
      expect(programModeLabel(4)).assertEqual('S');
      expect(programModeLabel(0x8000)).assertEqual('AUTO');
      expect(programModeLabel(-1)).assertEqual('--');
    });

    it('按曝光模式决定四个参数是否可调', 0, () => {
      expect(exposureParamEnabled(2, EXPOSURE_PARAM_APERTURE)).assertFalse();
      expect(exposureParamEnabled(2, EXPOSURE_PARAM_SHUTTER)).assertFalse();
      expect(exposureParamEnabled(2, EXPOSURE_PARAM_ISO)).assertTrue();
      expect(exposureParamEnabled(2, EXPOSURE_PARAM_EV)).assertTrue();
      expect(exposureParamEnabled(3, EXPOSURE_PARAM_APERTURE)).assertTrue();
      expect(exposureParamEnabled(3, EXPOSURE_PARAM_SHUTTER)).assertFalse();
      expect(exposureParamEnabled(4, EXPOSURE_PARAM_APERTURE)).assertFalse();
      expect(exposureParamEnabled(4, EXPOSURE_PARAM_SHUTTER)).assertTrue();
      expect(exposureParamEnabled(1, EXPOSURE_PARAM_APERTURE)).assertTrue();
      expect(exposureParamEnabled(0x8000, EXPOSURE_PARAM_APERTURE)).assertFalse();
      expect(exposureParamEnabled(0x8000, EXPOSURE_PARAM_EV)).assertTrue();
      // 模式未知时不锁死控件，交给相机回执。
      expect(exposureParamEnabled(-1, EXPOSURE_PARAM_APERTURE)).assertTrue();
    });

    it('白平衡值映射到资源键，照片/视频区分「与照片相同」', 0, () => {
      expect(whiteBalanceLabelKey(2, false)).assertEqual('camera_wifi_remote_wb_auto');
      expect(whiteBalanceLabelKey(4, false)).assertEqual('camera_wifi_remote_wb_daylight');
      expect(whiteBalanceLabelKey(0x8010, false)).assertEqual('camera_wifi_remote_wb_cloudy');
      expect(whiteBalanceLabelKey(0x8016, false)).assertEqual('camera_wifi_remote_wb_natural');
      expect(whiteBalanceLabelKey(0x8012, false)).assertEqual('camera_wifi_remote_wb_color_temp');
      expect(whiteBalanceLabelKey(0x8015, false)).assertEqual('');
      expect(whiteBalanceLabelKey(0x8015, true))
        .assertEqual('camera_wifi_remote_wb_same_as_still');
    });

    it('白平衡描述枚举解析，失败时退回保守列表', 0, () => {
      const desc = makeDescriptor(0x5005, 0x0004, 2, [2, 4, 0x8010, 0x8012]);
      const opts = whiteBalanceOptionsFromDescriptor(desc, false);
      expect(opts.length).assertEqual(4);
      expect(opts[0].value).assertEqual(2);
      expect(opts[2].value).assertEqual(0x8010);
      expect(whiteBalanceStaticOptions(false).length).assertEqual(10);
      expect(whiteBalanceStaticOptions(true)[0].value).assertEqual(0x8015);
    });

    it('AF 模式值映射，描述里过滤只读的 MF（固定）', 0, () => {
      expect(afModeLabelKey(0)).assertEqual('camera_wifi_remote_af_s');
      expect(afModeLabelKey(1)).assertEqual('camera_wifi_remote_af_c');
      expect(afModeLabelKey(2)).assertEqual('camera_wifi_remote_af_f');
      expect(afModeLabelKey(3)).assertEqual('camera_wifi_remote_mf_fixed');
      expect(afModeLabelKey(4)).assertEqual('camera_wifi_remote_mf');
      expect(afModeLabelKey(5)).assertEqual('camera_wifi_remote_af_a');

      const desc = makeDescriptor(0xD061, 0x0002, 1, [0, 1, 2, 3, 4, 5]);
      const opts = afModeOptionsFromDescriptor(desc);
      expect(opts.length).assertEqual(5);
      let hasFixed = false;
      for (const opt of opts) {
        if (opt.value === 3) hasFixed = true;
      }
      expect(hasFixed).assertFalse();
      expect(afModeStaticOptions().length).assertEqual(4);
    });

    it('AF 区域值映射与点选支持判断', 0, () => {
      expect(afAreaLabelKey(AF_AREA_SINGLE_POINT))
        .assertEqual('camera_wifi_remote_af_area_single');
      expect(afAreaLabelKey(AF_AREA_AUTO_AREA))
        .assertEqual('camera_wifi_remote_af_area_auto');
      expect(afAreaLabelKey(AF_AREA_WIDE_L))
        .assertEqual('camera_wifi_remote_af_area_wide_l');
      expect(afAreaLabelKey(AF_AREA_AUTO_ANIMAL))
        .assertEqual('camera_wifi_remote_af_area_auto_animal');
      expect(afAreaSupportsPoint(AF_AREA_SINGLE_POINT)).assertTrue();
      expect(afAreaSupportsPoint(AF_AREA_PIN_POINT)).assertTrue();
      expect(afAreaSupportsPoint(AF_AREA_AUTO_AREA)).assertFalse();
      expect(afAreaSupportsPoint(AF_AREA_AUTO_ANIMAL)).assertFalse();
      expect(afAreaSupportsPoint(-1)).assertTrue();
    });

    it('AF 区域描述枚举解析，失败时退回全量保守列表', 0, () => {
      const desc = makeDescriptor(0xD05D, 0x0004, 2,
        [AF_AREA_SINGLE_POINT, AF_AREA_AUTO_AREA, AF_AREA_PIN_POINT]);
      const opts = afAreaOptionsFromDescriptor(desc);
      expect(opts.length).assertEqual(3);
      expect(opts[0].value).assertEqual(AF_AREA_SINGLE_POINT);
      expect(afAreaStaticOptions().length).assertEqual(14);
    });

    it('枚举描述按 1B / 2B 解析，FormFlag 1 为 Range', 0, () => {
      const enum2 = makeDescriptor(0x500E, 0x0004, 2, [1, 2, 3, 4, 0x8000]);
      const values2 = parseEnumDescriptor(enum2, 2);
      expect(values2.length).assertEqual(5);
      expect(values2[4]).assertEqual(0x8000);

      const enum1 = makeDescriptor(0xD061, 0x0002, 1, [0, 1, 5, 4]);
      const values1 = parseEnumDescriptor(enum1, 1);
      expect(values1.length).assertEqual(4);

      const range = new Uint8Array(16);
      const view = new DataView(range.buffer);
      view.setUint16(0, 0x500E, true);
      view.setUint16(2, 0x0004, true);
      range[4] = 0x02;
      range[9] = 0x01; // FormFlag = Range
      view.setUint16(10, 2, true);
      view.setUint16(12, 6, true);
      view.setUint16(14, 2, true);
      const rangeValues = parseEnumDescriptor(range, 2);
      expect(rangeValues.length).assertEqual(3);
      expect(rangeValues[0]).assertEqual(2);
      expect(rangeValues[2]).assertEqual(6);
    });
  });
}
