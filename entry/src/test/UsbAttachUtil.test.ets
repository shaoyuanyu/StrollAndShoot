import { describe, it, expect } from '@ohos/hypium';
import { cameraAttachKey, shouldHandleAttach } from '../main/ets/utils/UsbAttachUtil';

export default function usbAttachUtilTest() {
  describe('UsbAttachUtil', () => {
    it('cameraAttachKey 用 VID/PID/产品名标识同一台相机', 0, () => {
      expect(cameraAttachKey(1200, 1109, 'NIKON DSC Z50_2'))
        .assertEqual('1200:1109:NIKON DSC Z50_2');
    });

    it('同一台相机在冷却窗口内只处理一次', 0, () => {
      const key = cameraAttachKey(1200, 1109, 'NIKON DSC Z50_2');
      expect(shouldHandleAttach(key, key, 1000, 2000, 15000)).assertFalse();
      expect(shouldHandleAttach(key, key, 16000, 31000, 15000)).assertTrue();
    });

    it('不同相机立即处理，空键忽略', 0, () => {
      expect(shouldHandleAttach('b', 'a', 1000, 2000, 15000)).assertTrue();
      expect(shouldHandleAttach('', 'a', 1000, 2000, 15000)).assertFalse();
    });
  });
}
