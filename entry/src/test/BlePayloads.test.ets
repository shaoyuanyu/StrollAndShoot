import { describe, it, expect } from '@ohos/hypium';
import { BleTimePayload, BleGeoPayload, type BleGeoFix } from '../main/ets/services/BlePayloads';

/**
 * 尼康 BLE 的两个定长载荷（0x2006 / 0x2007）。
 *
 * 字节布局来自社区逆向（nsg / ZPill），相机那边不会告诉我们「少了一个字节」——
 * 写错了只表现为「相机毫无反应」。所以这里把每个字段钉死在测试里，改布局必须
 * 同步改测试。
 */
export default function blePayloadsTest() {
  describe('BlePayloads', () => {
    it('0x2006 校时：10 字节，UTC 字段 + 时区偏移', 0, () => {
      const utc = new Date(Date.UTC(2026, 10, 14, 11, 20, 22));
      const out = BleTimePayload.build(utc, 480);
      expect(out.length).assertEqual(10);
      // 年 2026 = 0x07EA，小端
      expect(out[0]).assertEqual(0xEA);
      expect(out[1]).assertEqual(0x07);
      expect(out[2]).assertEqual(11);   // 月
      expect(out[3]).assertEqual(14);   // 日
      expect(out[4]).assertEqual(11);   // 时
      expect(out[5]).assertEqual(20);   // 分
      expect(out[6]).assertEqual(22);   // 秒
      expect(out[7]).assertEqual(0);    // 夏令时
      expect(out[8]).assertEqual(8);    // 时区小时（东八区）
      expect(out[9]).assertEqual(0);    // 时区分钟
    });

    it('0x2006 校时：负偏移按截断拆成（负小时, 负分钟），不是 floor', 0, () => {
      const utc = new Date(Date.UTC(2026, 0, 2, 3, 4, 5));
      const out = BleTimePayload.build(utc, -210); // UTC-3:30
      expect(out[8]).assertEqual(0xFD); // -3
      expect(out[9]).assertEqual(0xE2); // -30
    });

    it('0x2006 读回值可解成本机一致的 UTC', 0, () => {
      const utc = new Date(Date.UTC(2026, 10, 14, 11, 20, 22));
      const payload = BleTimePayload.build(utc, 480);
      const cameraView = payload.slice(0, 7);
      const text = BleTimePayload.describe(cameraView);
      expect(text.indexOf('2026-11-14 11:20:22')).assertEqual(0);
    });

    it('0x2007 位置：41 字节、头 0x007F、valid=1、WGS-84', 0, () => {
      const fix: BleGeoFix = {
        latitude: 31.2304,
        longitude: 121.4737,
        altitude: 12,
        satellites: 9,
        utc: new Date(Date.UTC(2026, 10, 14, 11, 20, 22))
      };
      const out = BleGeoPayload.build(fix);
      expect(out.length).assertEqual(41);
      expect(out[0]).assertEqual(0x7F);
      expect(out[1]).assertEqual(0x00);
      expect(out[2]).assertEqual(0x4E); // 'N'
      expect(out[3]).assertEqual(31);   // 度
      // 0.2304° = 13.824 分 → 13 分 / 82 百分位 / 39 余数
      // 最后一位是 double 截断：0.39999…×100 取整得 39，误差约 0.18 m，可忽略
      expect(out[4]).assertEqual(13);
      expect(out[5]).assertEqual(82);
      expect(out[6]).assertEqual(39);
      expect(out[7]).assertEqual(0x45); // 'E'
      expect(out[8]).assertEqual(121);
      expect(out[12]).assertEqual(9);   // 卫星数
      expect(out[13]).assertEqual(0x50); // 'P' = 正海拔
      expect(out[14]).assertEqual(12);
      expect(out[15]).assertEqual(0);
      expect(out[24]).assertEqual(0x01); // valid
      expect(String.fromCharCode(out[25], out[26], out[27], out[28], out[29], out[30]))
        .assertEqual('WGS-84');
      for (let i = 31; i < 41; i++) {
        expect(out[i]).assertEqual(0);
      }
    });

    it('0x2007 位置：南纬西经用 S / W', 0, () => {
      const fix: BleGeoFix = {
        latitude: -33.8688,
        longitude: -70.6693,
        altitude: -5,
        satellites: 4,
        utc: new Date(Date.UTC(2026, 10, 14, 0, 0, 0))
      };
      const out = BleGeoPayload.build(fix);
      expect(out[2]).assertEqual(0x53); // 'S'
      expect(out[7]).assertEqual(0x57); // 'W'
      expect(out[13]).assertEqual(0x4D); // 'M' = 负海拔
      expect(out[14]).assertEqual(5);
    });

    it('0x2007 失效帧：只有头 + valid=0，其余全 0', 0, () => {
      const out = BleGeoPayload.buildInvalid();
      expect(out.length).assertEqual(41);
      expect(out[0]).assertEqual(0x7F);
      expect(out[1]).assertEqual(0x00);
      expect(out[24]).assertEqual(0x00); // valid = 0：让相机丢掉已保存的位置
      for (let i = 2; i < 41; i++) {
        if (i === 24) continue;
        expect(out[i]).assertEqual(0);
      }
    });
  });
}
