import { describe, it, expect } from '@ohos/hypium';
import { isPaddedPrintable, securityLabel } from '../main/ets/services/NikonWifiCredentials';
import { prefixOf } from '../main/ets/services/LocalNetworks';

/**
 * 0x2004 凭据解密的纯逻辑部分 + 网络前缀。
 *
 * 加解密本身依赖 CryptoFramework，本地单测环境没有该系统能力，所以这里只
 * 覆盖「唯一的对错判据」——可打印性 oracle，以及布局相关的安全模式标签。
 * 真实解密在真机上用日志验证（解出来会打 `相机热点「Z50_2_xxxx」`）。
 */
export default function nikonWifiCredentialsTest() {
  describe('NikonWifiCredentials', () => {
    it('isPaddedPrintable 接受 NUL 尾填充的 ASCII', 0, () => {
      const bytes = new Uint8Array(32);
      'Z50_2_8079350'.split('').forEach((c: string, i: number) => {
        bytes[i] = c.charCodeAt(0);
      });
      expect(isPaddedPrintable(bytes, false)).assertTrue();
    });

    it('isPaddedPrintable 拒绝控制字符', 0, () => {
      const bytes = new Uint8Array(32);
      bytes[0] = 0x5A;
      bytes[1] = 0x01;
      expect(isPaddedPrintable(bytes, false)).assertFalse();
    });

    it('isPaddedPrintable 拒绝 NUL 之后再出现可打印字符', 0, () => {
      const bytes = new Uint8Array(8);
      bytes[0] = 0x41;
      bytes[1] = 0x00;
      bytes[2] = 0x42;
      expect(isPaddedPrintable(bytes, false)).assertFalse();
    });

    it('isPaddedPrintable 全零只在 allowEmpty 时通过（开放网络空密码）', 0, () => {
      const bytes = new Uint8Array(64);
      expect(isPaddedPrintable(bytes, false)).assertFalse();
      expect(isPaddedPrintable(bytes, true)).assertTrue();
    });

    it('securityLabel 覆盖 LSS 口径的四个值', 0, () => {
      expect(securityLabel(0x00)).assertEqual('开放');
      expect(securityLabel(0x01)).assertEqual('WPA2');
      expect(securityLabel(0x02)).assertEqual('WPA3');
      expect(securityLabel(0x03)).assertEqual('WPA2+WPA3');
      expect(securityLabel(0xFF)).assertEqual('未定义');
      expect(securityLabel(0x09)).assertEqual('未知(9)');
    });
  });

  describe('LocalNetworks', () => {
    it('prefixOf 取前三段', 0, () => {
      expect(prefixOf('192.168.43.5')).assertEqual('192.168.43');
      expect(prefixOf('10.15.98.124')).assertEqual('10.15.98');
    });

    it('prefixOf 对非 IPv4 返回空串', 0, () => {
      expect(prefixOf('192.168.43')).assertEqual('');
      expect(prefixOf('a.b.c.d')).assertEqual('a.b.c');
    });
  });
}
