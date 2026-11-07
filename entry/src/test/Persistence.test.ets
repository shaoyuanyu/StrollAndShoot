import { describe, it, expect } from '@ohos/hypium';
import { CameraService } from '../main/ets/services/CameraService';

export default function persistenceTest() {
  describe('Persistence', () => {
    it('下载键包含相机身份，避免跨相机同名文件互相误判', 0, () => {
      const svc = CameraService.getInstance();
      const old = svc.cameraIdentity;
      svc.cameraIdentity = 'camA';
      expect(svc.makeDownloadKey('DSC_0001.JPG', 123)).assertEqual('camA::DSC_0001.JPG::123');
      svc.cameraIdentity = old;
    });
  });
}
