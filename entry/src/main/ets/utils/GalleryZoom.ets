/**
 * 画廊捏合缩放的纯数学部分。
 *
 * 关键约定（性能约束）：网格的视觉尺寸只由「列数 + 间距」决定——单元格是
 * `layoutWeight(1)` + `aspectRatio(1)`，宽度永远是行宽按列数均分。捏合过程中
 * 连续变化的倍数本身不参与布局，只能用来推导列数。因此调用方应当：
 *
 * 1. 逐帧把倍数换算成列数（本类只做 O(1) 计算）；
 * 2. **只在列数跨档时**更新响应式状态，否则捏合会逐帧重建整个行模型
 *    （见 pages/GalleryPage.ets 的 appliedColumns）。
 *
 * 本类不依赖 ArkUI，可在 Local Test 里直接用。
 */
export class GalleryZoom {
  static readonly MIN_SCALE: number = 0.4;
  static readonly MAX_SCALE: number = 6.0;
  static readonly MIN_COLUMNS: number = 1;
  static readonly MAX_COLUMNS: number = 8;
  /** 设置里没有指定列数时对标官方图库的 3 列。 */
  static readonly DEFAULT_COLUMNS: number = 3;
  /**
   * 推导列数时使用的间距基准（vp）。它只影响倍数 → 列数的换算，
   * 真正渲染的间距由 gapForColumns() 按列数决定。
   */
  static readonly BASE_GAP: number = 2;
  /** 浮点误差容忍：保证 scale = 1 时算出来的列数恰好等于设置值。 */
  private static readonly EPS: number = 1e-6;

  static clampScale(scale: number): number {
    if (!(scale > 0)) return 1.0;
    if (scale < GalleryZoom.MIN_SCALE) return GalleryZoom.MIN_SCALE;
    if (scale > GalleryZoom.MAX_SCALE) return GalleryZoom.MAX_SCALE;
    return scale;
  }

  /** 默认列数：设置值 > 0 时用它，否则 3 列。 */
  static baseColumns(settingColumns: number): number {
    return settingColumns > 0 ? settingColumns : GalleryZoom.DEFAULT_COLUMNS;
  }

  /** 默认列数下单个单元格的宽度（vp）。 */
  static baseItemWidth(contextWidthVp: number, settingColumns: number): number {
    const w = contextWidthVp > 0 ? contextWidthVp : 1;
    const cols = GalleryZoom.baseColumns(settingColumns);
    const gap = GalleryZoom.BASE_GAP;
    return (w - (cols - 1) * gap) / cols;
  }

  /** 把捏合倍数换算成列数。倍数越大照片越大，列数越少。 */
  static columnsForScale(contextWidthVp: number, settingColumns: number, scale: number): number {
    const w = contextWidthVp > 0 ? contextWidthVp : 1;
    const gap = GalleryZoom.BASE_GAP;
    const itemW = GalleryZoom.baseItemWidth(w, settingColumns) * GalleryZoom.clampScale(scale);
    // + EPS 抵消浮点误差：scale = 1 时 (w + gap) / (baseW + gap) 可能算成 2.9999995。
    const cols = Math.floor((w + gap) / (itemW + gap) + GalleryZoom.EPS);
    if (cols < GalleryZoom.MIN_COLUMNS) return GalleryZoom.MIN_COLUMNS;
    if (cols > GalleryZoom.MAX_COLUMNS) return GalleryZoom.MAX_COLUMNS;
    return cols;
  }

  /** 网格间距（vp）：列数越多越密，与官方图库的观感一致。 */
  static gapForColumns(columns: number): number {
    if (columns >= 4) return 1.5;
    if (columns === 3) return 2;
    if (columns === 2) return 3;
    return 4;
  }
}
