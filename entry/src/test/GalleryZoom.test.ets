import { describe, it, expect } from '@ohos/hypium';
import { GalleryZoom } from '../main/ets/utils/GalleryZoom';

export default function galleryZoomTest() {
  describe('GalleryZoom', () => {
    it('scale 为 1 时列数恰好等于默认列数', 0, () => {
      expect(GalleryZoom.columnsForScale(360, -1, 1.0)).assertEqual(3);
      expect(GalleryZoom.columnsForScale(360, 4, 1.0)).assertEqual(4);
      expect(GalleryZoom.columnsForScale(360, 6, 1.0)).assertEqual(6);
      // 不整除的宽度同样不能掉一列
      expect(GalleryZoom.columnsForScale(361.5, 3, 1.0)).assertEqual(3);
      expect(GalleryZoom.columnsForScale(393, 5, 1.0)).assertEqual(5);
    });

    it('倍数越大列数越少，倍数越小列数越多', 0, () => {
      // 360vp、默认 3 列：最小倍数 0.4x 时 7 列，最大 6.0x 时 1 列
      let prev = GalleryZoom.columnsForScale(360, 3, GalleryZoom.MIN_SCALE);
      expect(prev).assertEqual(7);
      for (let s = GalleryZoom.MIN_SCALE; s <= GalleryZoom.MAX_SCALE; s += 0.05) {
        const cols = GalleryZoom.columnsForScale(360, 3, s);
        expect(cols <= prev).assertTrue();
        prev = cols;
      }
      expect(prev).assertEqual(1);
    });

    it('列数被夹在 1..8', 0, () => {
      expect(GalleryZoom.columnsForScale(360, 3, 0.01)).assertEqual(7);
      expect(GalleryZoom.columnsForScale(360, 3, 99)).assertEqual(1);
      // 6 列时捏到最小会撞到 8 列上限
      expect(GalleryZoom.columnsForScale(360, 6, GalleryZoom.MIN_SCALE))
        .assertEqual(GalleryZoom.MAX_COLUMNS);
    });

    it('clampScale 夹在 0.4..6.0', 0, () => {
      expect(GalleryZoom.clampScale(0.1)).assertEqual(0.4);
      expect(GalleryZoom.clampScale(10)).assertEqual(6.0);
      expect(GalleryZoom.clampScale(2.5)).assertEqual(2.5);
      expect(GalleryZoom.clampScale(Number.NaN)).assertEqual(1.0);
      expect(GalleryZoom.clampScale(0)).assertEqual(1.0);
    });

    it('间距按列数取档，默认 3 列仍是 2vp', 0, () => {
      expect(GalleryZoom.gapForColumns(8)).assertEqual(1.5);
      expect(GalleryZoom.gapForColumns(4)).assertEqual(1.5);
      expect(GalleryZoom.gapForColumns(3)).assertEqual(2);
      expect(GalleryZoom.gapForColumns(2)).assertEqual(3);
      expect(GalleryZoom.gapForColumns(1)).assertEqual(4);
    });

    it('列数不变时对应一段连续的倍数区间', 0, () => {
      // 1x → 1.5x 之间只跨一档，说明捏合不会每帧换列
      const colsAt = (s: number): number => GalleryZoom.columnsForScale(360, 3, s);
      let changes = 0;
      let prev = colsAt(1.0);
      for (let s = 1.0; s <= 1.5; s += 0.01) {
        const cols = colsAt(s);
        if (cols !== prev) changes++;
        prev = cols;
      }
      expect(changes <= 2).assertTrue();
    });

    it('baseItemWidth 在默认列数下让一整行刚好铺满', 0, () => {
      const w = 360;
      const gap = GalleryZoom.BASE_GAP;
      const cols = 3;
      const itemW = GalleryZoom.baseItemWidth(w, cols);
      expect(itemW * cols + (cols - 1) * gap).assertEqual(w);
    });
  });
}
