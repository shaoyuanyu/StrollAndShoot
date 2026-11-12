import { describe, expect, it } from '@ohos/hypium';
import { cameraStandeeAspect, cameraStandeeKey, cameraStandeeLabel } from '../main/ets/utils/CameraStandee';

/**
 * 立牌型号匹配。
 *
 * 重点在**两套型号口径**：PTP `DeviceInfo.model` 给的是尼康内部名（实测
 * `Z50_2`），USB iProduct 与界面文案给营销名（`Z 50II`）。归一化后两者都要
 * 命中同一个 key。
 */
export default function cameraStandeeTest() {
  describe('CameraStandee', () => {
    it('Z50_2 命中 z50ii（PTP 内部名）', 0, () => {
      expect(cameraStandeeKey('Z50_2')).assertEqual('z50ii');
    });

    it('Z 50II 命中 z50ii（营销名）', 0, () => {
      expect(cameraStandeeKey('Z 50II')).assertEqual('z50ii');
    });

    it('Z 6_3 与 Z 6III 都命中 z6iii', 0, () => {
      expect(cameraStandeeKey('Z6_3')).assertEqual('z6iii');
      expect(cameraStandeeKey('Z 6III')).assertEqual('z6iii');
    });

    it('Z6III 不会被 Z6II 抢先命中（顺序敏感）', 0, () => {
      expect(cameraStandeeKey('Z6III')).assertEqual('z6iii');
      expect(cameraStandeeKey('Z6II')).assertEqual('z6ii');
    });

    it('Z5IIC 不会被 Z5II 抢先命中', 0, () => {
      expect(cameraStandeeKey('Z5IIC')).assertEqual('z5iic');
      expect(cameraStandeeKey('Z 5II')).assertEqual('z5ii');
    });

    it('Z7II / Z9 / Z8 / Zf / Z30', 0, () => {
      expect(cameraStandeeKey('Z 7II')).assertEqual('z7ii');
      expect(cameraStandeeKey('Z9')).assertEqual('z9');
      expect(cameraStandeeKey('Z 8')).assertEqual('z8');
      expect(cameraStandeeKey('Zf')).assertEqual('zf');
      expect(cameraStandeeKey('Z 30')).assertEqual('z30');
    });

    it('没带立牌的机型返回空串（Z fc、ZR、老 Z6、空串）', 0, () => {
      expect(cameraStandeeKey('Z fc')).assertEqual('');
      expect(cameraStandeeKey('ZR')).assertEqual('');
      expect(cameraStandeeKey('Z 6')).assertEqual('');
      expect(cameraStandeeKey('')).assertEqual('');
    });

    it('厂商串不会被误判成机型', 0, () => {
      expect(cameraStandeeKey('Nikon Corporation')).assertEqual('');
    });

    it('展示名用尼康的官方写法', 0, () => {
      expect(cameraStandeeLabel('z50ii')).assertEqual('Z 50II');
      expect(cameraStandeeLabel('zf')).assertEqual('Z f');
      expect(cameraStandeeLabel('z9')).assertEqual('Z 9');
    });

    /**
     * 立牌盒子按「高度 × 宽高比」算宽度（见 `CameraPage.standeeWidth()`），盒子与
     * 画布比例不一致时，`Contain` 会在上下留透明带，立牌和倒影之间就会露出白缝。
     * 所以这张表必须覆盖所有带立牌的机型，且**兜底分支要和 `cameraStandeeMedia()`
     * 的兜底是同一个型号**（都是 Z 9），否则未知 key 会拿 Z 9 的图配别人的比例。
     */
    it('每个带立牌的机型都有宽高比，兜底与媒体兜底同为 Z 9', 0, () => {
      const keys: string[] = ['z9', 'z8', 'z7ii', 'z6iii', 'z6ii', 'z5ii', 'z5iic', 'zf', 'z50ii', 'z30'];
      for (const key of keys) {
        const aspect = cameraStandeeAspect(key);
        expect(aspect > 1.4 && aspect < 2.6).assertTrue();
      }
      // 未知 key：媒体兜底给 camera_z9，比例兜底也必须是 Z 9 的 703/429
      expect(cameraStandeeAspect('unknown')).assertEqual(cameraStandeeAspect('z9'));
      expect(cameraStandeeAspect('z50ii')).assertEqual(722 / 358);
    });
  });
}
