import { describe, it, expect } from '@ohos/hypium';
import {
  getExt,
  getBasename,
  getFormatPriority,
  groupPhotosByBasename,
  buildDisplayGroups
} from '../main/ets/utils/PhotoGroupUtil';
import type { PhotoEntry, DisplayGroup } from '../main/ets/model/PhotoEntry';

function photo(handle: number, filename: string, captureDate: string): PhotoEntry {
  const p: PhotoEntry = {
    handle: handle,
    filename: filename,
    size: 1024 * handle,
    captureDate: captureDate,
    modificationDate: captureDate,
    objectFormat: 0x3801,
    storageId: 1
  };
  return p;
}

export default function photoGroupUtilTest() {
  describe('PhotoGroupUtil', () => {
    it('getExt 取最后一个点之后的部分并转大写', 0, () => {
      expect(getExt('DSC_0001.JPG')).assertEqual('JPG');
      expect(getExt('a.b.cr2')).assertEqual('CR2');
      expect(getExt('noext')).assertEqual('');
      expect(getExt('trailing.')).assertEqual('');
    });

    it('getBasename 去掉扩展名', 0, () => {
      expect(getBasename('DSC_0001.JPG')).assertEqual('DSC_0001');
      expect(getBasename('DSC_0001')).assertEqual('DSC_0001');
      expect(getBasename('a.b.cr2')).assertEqual('a.b');
    });

    it('getFormatPriority 按可显示性排序，未知格式为 0', 0, () => {
      expect(getFormatPriority('JPG')).assertLarger(getFormatPriority('NEF'));
      expect(getFormatPriority('JPEG')).assertLarger(getFormatPriority('JPG'));
      expect(getFormatPriority('nef')).assertEqual(30);
      expect(getFormatPriority('XYZ')).assertEqual(0);
    });

    it('同名的 JPEG 与 RAW 合成一组，展示项取优先级高的', 0, () => {
      const photos: PhotoEntry[] = [
        photo(1, 'IMG_0001.NEF', '20260101T100000'),
        photo(2, 'IMG_0001.JPG', '20260101T100000')
      ];
      const groups: DisplayGroup[] = groupPhotosByBasename(photos);
      expect(groups.length).assertEqual(1);
      expect(groups[0].basename).assertEqual('IMG_0001');
      expect(groups[0].displayPhoto.filename).assertEqual('IMG_0001.JPG');
      expect(groups[0].alternates.length).assertEqual(1);
      expect(groups[0].alternates[0].filename).assertEqual('IMG_0001.NEF');
      expect(groups[0].allPhotos.length).assertEqual(2);
    });

    it('分组按拍摄时间倒序，时间相同按 basename 排序', 0, () => {
      const photos: PhotoEntry[] = [
        photo(1, 'A.JPG', '20260101T100000'),
        photo(2, 'C.JPG', '20260103T100000'),
        photo(3, 'B.JPG', '20260102T100000')
      ];
      const groups: DisplayGroup[] = groupPhotosByBasename(photos);
      expect(groups.length).assertEqual(3);
      expect(groups[0].basename).assertEqual('C');
      expect(groups[1].basename).assertEqual('B');
      expect(groups[2].basename).assertEqual('A');
    });

    it('buildDisplayGroups 在文件优先模式下不做合组', 0, () => {
      const photos: PhotoEntry[] = [
        photo(1, 'IMG_0001.NEF', '20260101T100000'),
        photo(2, 'IMG_0001.JPG', '20260101T100000')
      ];
      const fileFirst: DisplayGroup[] = buildDisplayGroups(photos, 'file_first');
      expect(fileFirst.length).assertEqual(2);
      const contentFirst: DisplayGroup[] = buildDisplayGroups(photos, 'content_first');
      expect(contentFirst.length).assertEqual(1);
    });
  });
}
