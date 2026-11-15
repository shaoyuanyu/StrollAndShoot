import { describe, it, expect } from '@ohos/hypium';
import { DownloadResume } from '../main/ets/services/DownloadResume';

/**
 * 断点续传的纯逻辑：路径、元数据匹配。
 *
 * 文件读写与 PTP 分块在真机上验收；这里只钉住「哪段残片可以续」的判据，
 * 防止换相机/换文件后把别人的半张图拼进来。
 */
export default function downloadResumeTest() {
  describe('DownloadResume', () => {
    it('partPath 带文件名与大小，同名不同大小不共用残片', 0, () => {
      expect(DownloadResume.partPath('/tmp', 'DSC_0001.JPG', 123))
        .assertEqual('/tmp/DSC_0001.JPG.123.part');
      expect(DownloadResume.partPath('/tmp', 'DSC_0001.JPG', 124))
        .assertEqual('/tmp/DSC_0001.JPG.124.part');
    });

    it('metaPath 跟在 part 后面，便于一起清理', 0, () => {
      expect(DownloadResume.metaPath('/tmp/DSC_0001.JPG.123.part'))
        .assertEqual('/tmp/DSC_0001.JPG.123.part.json');
    });

    it('matches 只认同一相机 / handle / 文件名 / 大小', 0, () => {
      const meta = DownloadResume.makeMeta('camA', 7, 'DSC_0001.JPG', 123);
      expect(DownloadResume.matches(meta, 'camA', 7, 'DSC_0001.JPG', 123)).assertTrue();
      expect(DownloadResume.matches(meta, 'camB', 7, 'DSC_0001.JPG', 123)).assertFalse();
      expect(DownloadResume.matches(meta, 'camA', 8, 'DSC_0001.JPG', 123)).assertFalse();
      expect(DownloadResume.matches(meta, 'camA', 7, 'DSC_0002.JPG', 123)).assertFalse();
      expect(DownloadResume.matches(meta, 'camA', 7, 'DSC_0001.JPG', 124)).assertFalse();
    });

    it('没有元数据 / 版本不符时不续传', 0, () => {
      expect(DownloadResume.matches(null, 'camA', 7, 'DSC_0001.JPG', 123)).assertFalse();
      const meta = DownloadResume.makeMeta('camA', 7, 'DSC_0001.JPG', 123);
      meta.version = 99;
      expect(DownloadResume.matches(meta, 'camA', 7, 'DSC_0001.JPG', 123)).assertFalse();
    });
  });
}
