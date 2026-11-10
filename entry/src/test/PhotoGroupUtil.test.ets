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

    it('内容优先：同一秒的连拍按 basename 降序，整条列表单调', 0, () => {
      // 相机时间戳只到秒，连拍会有多张落在同一秒（Z50_2 实测 1288 个文件只有 360 个时间）。
      // 兜底键必须与整体方向一致（降序），否则会出现 4479 → 4477 → 4478 这种来回跳。
      const photos: PhotoEntry[] = [
        photo(1, 'DSC_4477.JPG', '20260101T100000'),
        photo(2, 'DSC_4478.JPG', '20260101T100000'),
        photo(3, 'DSC_4479.JPG', '20260101T100000'),
        photo(4, 'DSC_4476.JPG', '20260101T095959')
      ];
      const groups: DisplayGroup[] = groupPhotosByBasename(photos);
      expect(groups.length).assertEqual(4);
      expect(groups[0].basename).assertEqual('DSC_4479');
      expect(groups[1].basename).assertEqual('DSC_4478');
      expect(groups[2].basename).assertEqual('DSC_4477');
      expect(groups[3].basename).assertEqual('DSC_4476');
    });

    it('分组按拍摄时间倒序', 0, () => {
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

    it('文件优先：同一秒的 JPG 与 NEF 必须成对相邻，JPG 在前', 0, () => {
      // 模拟相机：JPEG 与 NEF 的 handle 分段分配（JPG 高段、NEF 低段），
      // 两连拍照片的 EXIF 时间戳落在同一秒，只能靠 handle 兜底。
      const photos: PhotoEntry[] = [
        photo(7002, 'DSC_0002.JPG', '20260101T100005'),
        photo(1002, 'DSC_0002.NEF', '20260101T100005'),
        photo(7001, 'DSC_0001.JPG', '20260101T100004'),
        photo(1001, 'DSC_0001.NEF', '20260101T100004')
      ];
      const groups: DisplayGroup[] = buildDisplayGroups(photos, 'file_first');
      expect(groups.length).assertEqual(4);
      expect(groups[0].displayPhoto.filename).assertEqual('DSC_0002.JPG');
      expect(groups[1].displayPhoto.filename).assertEqual('DSC_0002.NEF');
      expect(groups[2].displayPhoto.filename).assertEqual('DSC_0001.JPG');
      expect(groups[3].displayPhoto.filename).assertEqual('DSC_0001.NEF');
      // 文件优先里每个格子只有一个文件
      expect(groups[0].alternates.length).assertEqual(0);
      expect(groups[0].allPhotos.length).assertEqual(1);
      expect(groups[0].basename).assertEqual('DSC_0002');
    });

    it('文件优先：两文件时间相差 1 秒也成对相邻', 0, () => {
      const photos: PhotoEntry[] = [
        photo(11, 'DSC_0010.NEF', '20260101T100010'),
        photo(12, 'DSC_0010.JPG', '20260101T100009'),
        photo(13, 'DSC_0011.JPG', '20260101T100008')
      ];
      const groups: DisplayGroup[] = buildDisplayGroups(photos, 'file_first');
      expect(groups.length).assertEqual(3);
      expect(groups[0].displayPhoto.filename).assertEqual('DSC_0010.JPG');
      expect(groups[1].displayPhoto.filename).assertEqual('DSC_0010.NEF');
      expect(groups[2].displayPhoto.filename).assertEqual('DSC_0011.JPG');
    });

    it('文件优先：不同照片之间仍按拍摄时间倒序', 0, () => {
      const photos: PhotoEntry[] = [
        photo(1, 'DSC_0001.JPG', '20260101T100004'),
        photo(3, 'DSC_0003.JPG', '20260101T100006'),
        photo(2, 'DSC_0002.NEF', '20260101T100005')
      ];
      const groups: DisplayGroup[] = buildDisplayGroups(photos, 'file_first');
      expect(groups[0].displayPhoto.filename).assertEqual('DSC_0003.JPG');
      expect(groups[1].displayPhoto.filename).assertEqual('DSC_0002.NEF');
      expect(groups[2].displayPhoto.filename).assertEqual('DSC_0001.JPG');
    });
  });
}
