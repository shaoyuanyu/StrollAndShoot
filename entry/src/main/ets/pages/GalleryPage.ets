import display from '@ohos.display';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry, DownloadProgress, DisplayGroup } from '../model/PhotoEntry';
import { getExt, buildDisplayGroups } from '../utils/PhotoGroupUtil';
import { GalleryZoom } from '../utils/GalleryZoom';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';
import { FontSize, IconSize, Radius, pillRadius } from '../utils/UiTokens';
import { formatDateParts } from '../utils/DateTimeText';

class FlatItem {
  kind: 'header' | 'row' | 'tail' = 'tail';
  /** 日期分组键（YYYYMMDD，无拍摄日期为 ''）。标题文案由它换算，见 dateHeaderLabel()。 */
  dateKey: string = '';
  rowPhotos: (DisplayGroup | null)[] = [];

  static tail(): FlatItem {
    const item = new FlatItem();
    item.kind = 'tail';
    return item;
  }

  static header(key: string): FlatItem {
    const item = new FlatItem();
    item.kind = 'header';
    item.dateKey = key;
    return item;
  }

  static row(photos: (DisplayGroup | null)[]): FlatItem {
    const item = new FlatItem();
    item.kind = 'row';
    item.rowPhotos = photos;
    return item;
  }
}



@ComponentV2
export struct GalleryPage {
  @Param downloadProgress: DownloadProgress | null = null;
  @Param downloadedKeys: string[] = [];
  @Param galleryColumnCount: number = -1;
  @Param displayMode: string = 'file_first';
  /** 当前格式筛选，'' 表示全部。控件在标题栏，这里只负责过滤。 */
  @Param scroller: Scroller = new Scroller();
  @Param filterValue: string = '';
  @Local svc: CameraService = CameraService.getInstance();
  @Local selectMode: boolean = false;
  @Local selectedHandles: Set<number> = new Set();
  /**
   * 捏合累计倍数（1.0 = 默认列数）。**故意不做响应式**：它在捏合过程中逐帧变化，
   * 若写成 @Local 会触发整页重建，见下面的 appliedColumns。
   */
  private pinchScale: number = 1.0;
  /**
   * 当前实际生效的列数，0 表示还没捏合过、用默认列数。
   * 这是缩放里唯一会触发重建的状态：网格的视觉尺寸只取决于列数（单元格是
   * layoutWeight(1) + aspectRatio(1)），倍数在一段区间内的连续变化不产生任何
   * 视觉差异，所以只在列数跨档时才更新，否则捏合会逐帧重建整个行模型。
   */
  @Local appliedColumns: number = 0;
  @Event onThumbClick: (displayGroups: DisplayGroup[], index: number) => void = (_g: DisplayGroup[], _i: number) => {};
  @Event onDownloadSelected: (handles: number[]) => void = (_h: number[]) => {};
  @Event onCancelDownload: () => void = () => {};
  @Event onSelectModeChange: (v: boolean) => void = (_v: boolean) => {};
  /** 把「已选数量 / 可选项总数」上报给标题栏，标题与全选按钮都依赖它。 */
  @Event onSelectionStats: (selected: number, selectable: number) => void =
    (_s: number, _t: number) => {};
  @Param exitSelectModeVersion: number = 0;
  @Param toggleSelectVersion: number = 0;
  /** 标题栏「全选 / 取消全选」的触发计数。 */
  @Param selectAllVersion: number = 0;
  /** 标题栏底部操作栏「下载」的触发计数（浮岛已搬到标题栏，入口也在那里）。 */
  @Param downloadVersion: number = 0;
  /** 预览器返回转场要求把列表滚到某张照片（计数 + handle 的既有约定）。 */
  @Param galleryScrollVersion: number = 0;
  @Param galleryScrollHandle: number = -1;
  private pinchBaseScale: number = 1.0;
  /** 一次捏合里的事件数 / 换列次数，捏合结束后打一行日志用于核性能。 */
  private pinchUpdateCount: number = 0;
  private pinchColumnChanges: number = 0;

  @Monitor('galleryColumnCount')
  onColumnSettingChanged(): void {
    // 设置里改了默认列数：作废捏合结果，回到新的默认列数。
    this.pinchScale = 1.0;
    this.appliedColumns = 0;
  }

  @Monitor('toggleSelectVersion')
  onToggleSelectRequest(): void {
    this.toggleSelectMode();
  }

  @Monitor('galleryScrollVersion')
  onGalleryScrollRequest(): void {
    if (this.galleryScrollHandle >= 0) {
      this.scrollToHandle(this.galleryScrollHandle);
    }
  }

  /**
   * 把列表滚到某张照片所在的行（立即跳转，不带动画）。
   *
   * 从预览器返回时，目标格子可能①根本没被列表渲染（虚拟化在视口外）；
   * ②渲染了但落在屏幕外（`cachedCount` 缓存窗口）。两种情况都拿不到可用的
   * 屏幕矩形，收回动画会收进看不见的地方。官方图库的做法是先把网格对齐到
   * 当前张，这里同样处理：滚过去 → 预览器下一帧再查矩形 → 再开始收回。
   */
  private scrollToHandle(handle: number): void {
    const items = this.buildFlatItems();
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (it.kind !== 'row') continue;
      for (const g of it.rowPhotos) {
        if (g !== null && g.displayPhoto.handle === handle) {
          // CENTER：让目标行落在舒适区，不要贴着底部悬浮页签
          this.scroller.scrollToIndex(i, false, ScrollAlign.CENTER);
          this.svc.getLog().add(`viewer pop: scrollToIndex ${i} handle=${handle}`);
          return;
        }
      }
    }
    this.svc.getLog().add(`viewer pop: handle=${handle} 不在列表里`);
  }

  @Monitor('selectAllVersion')
  onSelectAllRequest(): void {
    this.toggleSelectAll();
  }

  @Monitor('downloadVersion')
  onDownloadRequest(): void {
    if (this.selectedHandles.size === 0) return;
    const handles: number[] = [];
    this.selectedHandles.forEach((key: number) => { handles.push(key); });
    this.onDownloadSelected(handles);
    this.selectMode = false;
    this.onSelectModeChange(false);
    this.selectedHandles.clear();
    this.syncSelectionStats();
  }

  @Monitor('exitSelectModeVersion')
  onExitSelectModeRequest(): void {
    if (this.selectMode) {
      this.selectMode = false;
      this.selectedHandles.clear();
      this.onSelectModeChange(false);
      this.syncSelectionStats();
    }
  }

  /** 选择集变化后统一上报，标题栏据此刷新数量与全选态。 */
  private syncSelectionStats(): void {
    this.onSelectionStats(this.selectedHandles.size, this.getSelectableGroups().length);
  }

  // O(1) filtered index map
  private _filteredIndexMap: Map<number, number> = new Map();
  private _filteredIndexMapRef: DisplayGroup[] | null = null;
  // O(1) downloaded Set cache
  private _downloadedSet: Set<string> = new Set();
  private _downloadedSetRef: string[] | null = null;
  // buildFlatItems cache (version-based, avoids V2 @Local reference instability)
  private _flatItemsCache: FlatItem[] | null = null;
  private _flatCachePhotosVer: number = -1;
  private _flatCacheMode: string = '';
  private _flatCacheFilter: string = '';
  private _flatCacheColumns: number = -1;
  private _flatCacheWidth: number = -1;
  // 按日期分组后的结果缓存：换列只需要重新分行，不必再扫一遍全部照片。
  private _groupKeys: string[] = [];
  private _groupMap: Map<string, DisplayGroup[]> = new Map();
  private _groupPhotosVer: number = -1;
  private _groupMode: string = '';
  private _groupFilter: string = '';
  // 格式筛选后的数组缓存：dateSelectState 等每帧都会遍历它。
  private _filteredGroupsCache: DisplayGroup[] | null = null;
  private _filteredPhotosVer: number = -1;
  private _filteredMode: string = '';
  private _filteredFilter: string = '';

  /** Width of the gallery content area in vp (0 before first layout). */
  @Local _viewWidthVp: number = 0;
  private _displayWidthVp: number = -1;

  private getDisplayWidthVp(): number {
    if (this._viewWidthVp > 0) return this._viewWidthVp;
    if (this._displayWidthVp > 0) return this._displayWidthVp;
    try {
      const d = display.getDefaultDisplaySync();
      this._displayWidthVp = d ? this.getUIContext().px2vp(d.width) : 360;
    } catch (_e) {
      this._displayWidthVp = 360;
    }
    return this._displayWidthVp;
  }

  /** 当前生效的列数（捏合跨档后由 appliedColumns 接管）。 */
  private activeColumns(): number {
    if (this.appliedColumns > 0) return this.appliedColumns;
    return GalleryZoom.columnsForScale(this.getDisplayWidthVp(), this.galleryColumnCount, 1.0);
  }

  /** 当前生效的网格间距（vp）。只随列数变化，捏合过程中不会单独变动。 */
  private activeGap(): number {
    return GalleryZoom.gapForColumns(this.activeColumns());
  }

  /**
   * 一次捏合结束后打一行日志：事件数远大于换列次数才正常。
   * 如果换列次数接近事件数，说明列数在边界上来回跳，需要加迟滞。
   */
  private logPinchSummary(): void {
    if (this.pinchUpdateCount === 0) return;
    this.svc.getLog().add(
      `PERF pinch: updates=${this.pinchUpdateCount}, columnChanges=${this.pinchColumnChanges}, ` +
      `scale=${this.pinchScale.toFixed(2)}, cols=${this.activeColumns()}`);
  }

  /** 日期分组键：YYYYMMDD；没有拍摄日期时为空串。 */
  private dateKeyOf(captureDate: string): string {
    if (!captureDate || captureDate.length < 8) return '';
    return captureDate.substring(0, 8);
  }

  /** 对齐官方图库的日期标题：今天 / 昨天 / 11月6日 / 2025年11月6日。 */
  private dateHeaderLabel(key: string): ResourceStr {
    if (!key) return $r('app.string.gallery_unknown_date');
    const y = Number(key.substring(0, 4));
    const m = Number(key.substring(4, 6));
    const d = Number(key.substring(6, 8));
    const now = new Date();
    const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const target = new Date(y, m - 1, d);
    const diffDays = Math.round((todayStart.getTime() - target.getTime()) / 86400000);
    if (diffDays === 0) return $r('app.string.date_today');
    if (diffDays === 1) return $r('app.string.date_yesterday');
    const text = formatDateParts(y, m, d, y !== now.getFullYear());
    return text !== '' ? text : $r('app.string.gallery_unknown_date');
  }

  private getDownloadedSet(): Set<string> {
    if (this._downloadedSetRef !== this.downloadedKeys) {
      this._downloadedSet = new Set(this.downloadedKeys);
      this._downloadedSetRef = this.downloadedKeys;
    }
    return this._downloadedSet;
  }

  private isDownloaded(photo: PhotoEntry): boolean {
    return this.getDownloadedSet().has(this.svc.makeDownloadKey(photo.filename, photo.size));
  }

  private _allGroupsCache: DisplayGroup[] | null = null;
  private _cachePhotosVer: number = -1;
  private _cacheMode: string = '';

  private allDisplayGroups(): DisplayGroup[] {
    if (this._allGroupsCache !== null &&
        this._cachePhotosVer === this.svc.photosVersion &&
        this._cacheMode === this.displayMode) {
      return this._allGroupsCache;
    }
    this._allGroupsCache = buildDisplayGroups(this.svc.photos, this.displayMode);
    // Sort by captureDate DESC so getFilteredDisplayGroups() matches gallery visual order.
    // This ensures handles/index are in visual order — eliminating extra sorting in Index.ets
    // and keeping PhotoViewer's thumbnail strip consistent with gallery positions.
    this._allGroupsCache.sort((a: DisplayGroup, b: DisplayGroup): number =>
      (b.displayPhoto.captureDate ?? '').localeCompare(a.displayPhoto.captureDate ?? ''));
    this._cachePhotosVer = this.svc.photosVersion;
    this._cacheMode = this.displayMode;
    return this._allGroupsCache;
  }

  private getFilteredDisplayGroups(): DisplayGroup[] {
    if (this._filteredGroupsCache !== null &&
        this._filteredPhotosVer === this.svc.photosVersion &&
        this._filteredMode === this.displayMode &&
        this._filteredFilter === this.filterValue) {
      return this._filteredGroupsCache;
    }
    const all = this.allDisplayGroups();
    let result: DisplayGroup[] = all;
    if (this.displayMode !== 'content_first' && this.filterValue !== '') {
      result = [];
      for (const g of all) {
        if (getExt(g.displayPhoto.filename) === this.filterValue) result.push(g);
      }
    }
    this._filteredGroupsCache = result;
    this._filteredPhotosVer = this.svc.photosVersion;
    this._filteredMode = this.displayMode;
    this._filteredFilter = this.filterValue;
    return result;
  }

  /**
   * 按拍摄日期分组（只依赖照片与筛选，与列数无关）。
   * 捏合换列时列的只是重新分行，不必再扫全量照片；分组内顺序沿用
   * getFilteredDisplayGroups() 的输出（已按 captureDate 降序），不要再逐组排序。
   */
  private ensureGrouping(): void {
    if (this._groupPhotosVer === this.svc.photosVersion &&
        this._groupMode === this.displayMode &&
        this._groupFilter === this.filterValue) {
      return;
    }
    const filtered = this.getFilteredDisplayGroups();
    const map = new Map<string, DisplayGroup[]>();
    const noDate: DisplayGroup[] = [];
    for (const g of filtered) {
      const d = this.dateKeyOf(g.displayPhoto.captureDate ?? '');
      if (!d) {
        noDate.push(g);
        continue;
      }
      const arr = map.get(d);
      if (arr) arr.push(g);
      else map.set(d, [g]);
    }
    const keys: string[] = [];
    map.forEach((_v: DisplayGroup[], k: string) => { keys.push(k); });
    keys.sort((a: string, b: string) => b.localeCompare(a));
    if (noDate.length > 0) {
      keys.push('');
      map.set('', noDate);
    }
    this._groupKeys = keys;
    this._groupMap = map;
    this._groupPhotosVer = this.svc.photosVersion;
    this._groupMode = this.displayMode;
    this._groupFilter = this.filterValue;
  }

  /** 把日期标题与行拍平成 Repeat 的数据源。 */
  private chunkRows(cols: number): FlatItem[] {
    const safeCols = cols > 0 ? cols : 1;
    const items: FlatItem[] = [];
    for (const k of this._groupKeys) {
      items.push(FlatItem.header(k));
      const photos = this._groupMap.get(k)!;
      for (let i = 0; i < photos.length; i += safeCols) {
        const row: (DisplayGroup | null)[] = [];
        for (let j = 0; j < safeCols; j++) {
          row.push(i + j < photos.length ? photos[i + j] : null);
        }
        items.push(FlatItem.row(row));
      }
    }
    items.push(FlatItem.tail());
    return items;
  }

  private buildFlatItems(): FlatItem[] {
    const cols = this.activeColumns();
    if (this._flatItemsCache !== null &&
        this._flatCachePhotosVer === this.svc.photosVersion &&
        this._flatCacheMode === this.displayMode &&
        this._flatCacheFilter === this.filterValue &&
        this._flatCacheColumns === cols &&
        this._flatCacheWidth === this.getDisplayWidthVp()) {
      return this._flatItemsCache;
    }
    const t0 = Date.now();
    this.ensureGrouping();
    const items = this.chunkRows(cols);
    this._flatItemsCache = items;
    this._flatCachePhotosVer = this.svc.photosVersion;
    this._flatCacheMode = this.displayMode;
    this._flatCacheFilter = this.filterValue;
    this._flatCacheColumns = cols;
    this._flatCacheWidth = this.getDisplayWidthVp();
    // 现在只在照片/筛选/列数真正变化时才会重建，日志不会落在捏合热路径上。
    // 缩略图到达不再重建行模型：每个单元格由 ThumbImage 自己订阅 thumbnailVersion。
    this.svc.getLog().add(
      `PERF buildFlatItems ${Date.now() - t0}ms, ${items.length} items, cols=${cols}`);
    return items;
  }

  private getFilteredIndex(handle: number): number {
    const filtered = this.getFilteredDisplayGroups();
    if (this._filteredIndexMapRef !== filtered) {
      this._filteredIndexMap.clear();
      for (let i = 0; i < filtered.length; i++) {
        this._filteredIndexMap.set(filtered[i].displayPhoto.handle, i);
      }
      this._filteredIndexMapRef = filtered;
    }
    return this._filteredIndexMap.get(handle) ?? 0;
  }

  private getSelectableGroups(): DisplayGroup[] {
    const filtered = this.getFilteredDisplayGroups();
    const result: DisplayGroup[] = [];
    for (const g of filtered) {
      if (!this.isDownloaded(g.displayPhoto)) result.push(g);
    }
    return result;
  }

  private toggleSelectAll(): void {
    const selectable = this.getSelectableGroups();
    if (selectable.length === 0) return;
    const allSelected = selectable.every((g: DisplayGroup) => this.selectedHandles.has(g.displayPhoto.handle));
    if (allSelected) {
      for (const g of selectable) { this.selectedHandles.delete(g.displayPhoto.handle); }
    } else {
      for (const g of selectable) { this.selectedHandles.add(g.displayPhoto.handle); }
    }
    this.selectedHandles = new Set(this.selectedHandles);
    this.syncSelectionStats();
  }

  private toggleSelectDate(dateKey: string): void {
    if (!this.selectMode) return;
    const all = this.getFilteredDisplayGroups();
    const selectable: DisplayGroup[] = [];
    for (const g of all) {
      if (this.dateKeyOf(g.displayPhoto.captureDate ?? '') === dateKey) {
        if (!this.isDownloaded(g.displayPhoto)) selectable.push(g);
      }
    }
    if (selectable.length === 0) return;
    const allSelected = selectable.every((g: DisplayGroup) => this.selectedHandles.has(g.displayPhoto.handle));
    if (allSelected) {
      for (const g of selectable) { this.selectedHandles.delete(g.displayPhoto.handle); }
    } else {
      for (const g of selectable) { this.selectedHandles.add(g.displayPhoto.handle); }
    }
    this.selectedHandles = new Set(this.selectedHandles);
    this.syncSelectionStats();
  }

  /**
   * 日期分组的多选状态：0 = 未选，1 = 部分选中，2 = 全选。
   * 官方图库在多选态的每个日期标题右侧放一个圆形勾选，点一下整组选中/取消。
   */
  private dateSelectState(dateKey: string): number {
    const all = this.getFilteredDisplayGroups();
    let total = 0;
    let selected = 0;
    for (const g of all) {
      if (this.dateKeyOf(g.displayPhoto.captureDate ?? '') !== dateKey) continue;
      if (this.isDownloaded(g.displayPhoto)) continue;
      total++;
      if (this.selectedHandles.has(g.displayPhoto.handle)) selected++;
    }
    if (total === 0 || selected === 0) return 0;
    return selected === total ? 2 : 1;
  }

  @Builder
  PhotoCell(cellRi: RepeatItem<DisplayGroup | null>) {
    if (cellRi.item !== null) {
      Stack() {
        ThumbImage({ handle: cellRi.item!.displayPhoto.handle })
        // 选中态与官方图库一致：不加遮罩/描边，只在右下角显示圆形勾选。
        if (this.selectMode && !this.isDownloaded(cellRi.item!.displayPhoto)) {
          Stack() {
            if (this.selectedHandles.has(cellRi.item!.displayPhoto.handle)) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(IconSize.Small)
                .fontColor([$r('app.color.text_on_primary')])
            }
          }
          .width(20).height(20)
          .borderRadius(pillRadius(20))
          .backgroundColor(this.selectedHandles.has(cellRi.item!.displayPhoto.handle)
            ? $r('app.color.primary') : $r('app.color.scrim'))
          .border({
            width: this.selectedHandles.has(cellRi.item!.displayPhoto.handle) ? 0 : 1.5,
            color: $r('app.color.text_on_dark')
          })
          .position({ bottom: 4, right: 4 })
          .hitTestBehavior(HitTestMode.None)
        }
        if (this.isDownloaded(cellRi.item!.displayPhoto)) {
          Stack()
            .width(10).height(10).borderRadius(pillRadius(10))
            .backgroundColor($r('app.color.status_connected'))
            .border({ width: 1.5, color: $r('app.color.text_on_dark') })
            .position({ top: 5, right: 5 })
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .layoutWeight(1)
      .aspectRatio(1)
      .parallelGesture(
        GestureGroup(GestureMode.Exclusive,
          LongPressGesture({ repeat: false, duration: 500 })
            .onAction(() => {
              if (this.isDownloaded(cellRi.item!.displayPhoto)) return;
              if (!this.selectMode) {
                this.selectMode = true;
                this.onSelectModeChange(true);
                this.selectedHandles.add(cellRi.item!.displayPhoto.handle);
                this.selectedHandles = new Set(this.selectedHandles);
                this.syncSelectionStats();
              }
            }),
          TapGesture()
            .onAction(() => {
              if (this.selectMode) {
                if (this.isDownloaded(cellRi.item!.displayPhoto)) return;
                if (this.selectedHandles.has(cellRi.item!.displayPhoto.handle)) {
                  this.selectedHandles.delete(cellRi.item!.displayPhoto.handle);
                } else {
                  this.selectedHandles.add(cellRi.item!.displayPhoto.handle);
                }
                this.selectedHandles = new Set(this.selectedHandles);
                this.syncSelectionStats();
              } else {
                const filtered = this.getFilteredDisplayGroups();
                this.onThumbClick(filtered, this.getFilteredIndex(cellRi.item!.displayPhoto.handle));
              }
            })
        )
      )
    } else {
      Stack()
        .layoutWeight(1)
        .aspectRatio(1)
        .backgroundColor(Color.Transparent)
    }
  }

  private toggleSelectMode(): void {
    if (this.selectMode) {
      this.selectMode = false;
      this.selectedHandles.clear();
      this.selectedHandles = new Set(this.selectedHandles);
      this.onSelectModeChange(false);
    } else {
      this.selectMode = true;
      this.onSelectModeChange(true);
    }
    this.syncSelectionStats();
  }

  @Builder
  ScanBanner() {
    if (this.svc.scanning && this.svc.scanTotal > 0) {
      Column({ space: 4 }) {
        Progress({
          value: this.svc.scanProgress,
          total: this.svc.scanTotal,
          type: ProgressType.Linear
        })
          .width('100%').height(3)
          .color($r('app.color.primary'))
          .backgroundColor($r('app.color.divider'))
        Row() {
          Text(this.svc.scanPhaseText || $r('app.string.gallery_scanning'))
            .fontSize(FontSize.Caption).fontColor($r('app.color.text_secondary'))
          Blank()
          Text(`${this.svc.scanProgress}/${this.svc.scanTotal}`)
            .fontSize(FontSize.Caption).fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
      }
      .width('100%')
      // 标题栏是 STACK 布局，内容区延伸到它下方，横幅自己避让
      .padding({ left: 16, right: 16, top: 8, bottom: 4 })
    }
  }

  /** 顶部固定区（扫描横幅）是否显示。 */
  private topHeaderVisible(): boolean {
    return this.svc.scanning && this.svc.scanTotal > 0;
  }

  /**
   * 列表的顶部内缩量。
   *
   * 扫描横幅已经在标题栏下方时，List 不再需要偏移，否则会出现双倍空隙；
   * 无固定元素时，List 顶到页面最上方，需要由 contentStartOffset 让首行避开
   * 标题栏，滚动的照片才能从标题栏底下透出。
   */
  private listTopInset(): number {
    return this.topHeaderVisible() ? 0 : titleBarTotalVp();
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
      // 扫描横幅紧凑地放在（已被标题栏安全区下移的）内容顶部
      if (this.topHeaderVisible()) {
        Column() {
          this.ScanBanner()
        }
        .width('100%')
      }

      if (this.svc.photos.length === 0) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(IconSize.Empty)
            .fontColor([$r('app.color.text_tertiary')])
          if (this.svc.scanning) {
            LoadingProgress().width(28).height(28).color($r('app.color.primary'))
            Text($r('app.string.gallery_scanning'))
              .fontSize(FontSize.Body).fontColor($r('app.color.text_secondary'))
          } else {
            Text($r('app.string.gallery_empty_hint'))
              .fontSize(FontSize.Body).fontColor($r('app.color.text_secondary'))
            Text($r('app.string.gallery_empty_hint_sub'))
              .fontSize(FontSize.Caption).fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%').layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          List({ scroller: this.scroller, space: this.activeGap() }) {
            Repeat<FlatItem>(this.buildFlatItems())
              .each((ri: RepeatItem<FlatItem>) => {
                if (ri.item.kind === 'tail') {
                  ListItem() {
                    Row().width('100%').height(104)
                  }
                } else if (ri.item.kind === 'header') {
                  ListItem() {
                    // 官方图库的日期标题：左对齐 16fp 粗体日期，多选态右侧一个圆形整组勾选。
                    // 上下各 24vp 留白，照片贴边后组与组之间才有呼吸感。
                    Row() {
                      Text(this.dateHeaderLabel(ri.item.dateKey))
                        .fontSize(FontSize.CardTitle)
                        .fontWeight(FontWeight.Bold)
                        .fontColor($r('app.color.text_primary'))
                        .layoutWeight(1)
                      if (this.selectMode) {
                        Stack() {
                          if (this.dateSelectState(ri.item.dateKey) === 2) {
                            SymbolGlyph($r('sys.symbol.checkmark'))
                              .fontSize(IconSize.Small)
                              .fontColor([$r('app.color.text_on_primary')])
                          } else if (this.dateSelectState(ri.item.dateKey) === 1) {
                            Row()
                              .width(9).height(1.6)
                              .borderRadius(Radius.Line)
                              .backgroundColor($r('app.color.text_on_primary'))
                          }
                        }
                        .width(20).height(20)
                        .borderRadius(pillRadius(20))
                        .backgroundColor(this.dateSelectState(ri.item.dateKey) > 0
                          ? $r('app.color.primary') : Color.Transparent)
                        .border({
                          width: this.dateSelectState(ri.item.dateKey) > 0 ? 0 : 1.5,
                          color: $r('app.color.text_tertiary')
                        })
                        // 视觉 20vp，热区扩到 44vp
                        .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
                        .onClick(() => { this.toggleSelectDate(ri.item.dateKey); })
                      }
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)
                    .padding({ left: 16, right: 16, top: 24, bottom: 24 })
                  }
                } else {
                  ListItem() {
                    Row({ space: this.activeGap() }) {
                      Repeat<DisplayGroup | null>(ri.item.rowPhotos)
                        .each((cellRi: RepeatItem<DisplayGroup | null>) => {
                          this.PhotoCell(cellRi)
                        })
                        .key((dg: DisplayGroup | null, idx: number) => {
                          if (dg !== null) return dg.displayPhoto.handle.toString();
                          return `pad_${ri.index}_${idx}`;
                        })
                    }
                    .width('100%')
                  }
                }
              })
              .key((item: FlatItem): string => {
                if (item.kind === 'tail') return 'tail';
                if (item.kind === 'header') return `h_${item.dateKey}`;
                const first = item.rowPhotos[0];
                // key 必须保持稳定：把行完成状态编进 key 会让 virtualScroll 的
                // 复用项失效，滚动后整行渲染成空白。缩略图刷新交给 ThumbImage。
                return first !== null ? `r_${first.displayPhoto.handle}` : `r_pad`;
              })
              .virtualScroll()
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          // 官方《设置动态模糊样式》：不裁剪超出范围的子组件，内容才能穿透到标题栏下方；
          // 同时用 cachedCount 预加载，穿过标题栏时不会消失。
          .clip(false)
          .cachedCount(6, true)
          // 注意：不能给 List 加 padding(bottom)，那会收缩可视区域、
          // 内容在悬浮页签上方被裁掉。底部留白用末尾的占位项实现。
          // 也不加左右 padding：官方图库网格贴边。
          // 标题栏 STACK 后，首行内容按标题栏高度内缩；滚动时照片会钻到标题栏底下
          .contentStartOffset(this.listTopInset())
        }
        .layoutWeight(1)
        .parallelGesture(
          // 捏合只更新普通字段 pinchScale，不碰任何响应式状态：
          // 网格尺寸只由列数决定，列数没跨档时这一帧不需要重绘。
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.pinchBaseScale = this.pinchScale;
              this.pinchUpdateCount = 0;
              this.pinchColumnChanges = 0;
            })
            .onActionUpdate((event: GestureEvent) => {
              this.pinchUpdateCount++;
              this.pinchScale = GalleryZoom.clampScale(this.pinchBaseScale * event.scale);
              const cols = GalleryZoom.columnsForScale(
                this.getDisplayWidthVp(), this.galleryColumnCount, this.pinchScale);
              if (cols !== this.activeColumns()) {
                this.appliedColumns = cols;
                this.pinchColumnChanges++;
              }
            })
            .onActionEnd(() => { this.logPinchSummary(); })
            .onActionCancel(() => { this.logPinchSummary(); })
        )
      }

      }
      .width('100%').height('100%')

    }
    .width('100%').height('100%')
    .onAreaChange((_o: Area, n: Area) => {
      const w = n.width as number;
      if (w > 0 && w !== this._viewWidthVp) {
        this._viewWidthVp = w;
        // 宽度变了（分屏 / 折叠展开），捏合结果失效，按新宽度重新算默认列数
        this.pinchScale = 1.0;
        this.appliedColumns = 0;
      }
    })
  }
}

/**
 * 缩略图单元格内容。
 * 必须是独立组件：Repeat 命中相同 key 时不会重跑 each，若把 Image 直接写在
 * @Builder 里，缩略图解码完成后单元格不会重建，会一直停在占位图。
 * 这里通过 svc.thumbForRender() 读一次 thumbnailVersion，建立 V2 依赖。
 */
@ComponentV2
struct ThumbImage {
  @Param handle: number = 0;
  @Local svc: CameraService = CameraService.getInstance();

  build() {
    Stack() {
      if (this.svc.thumbForRender(this.handle) !== undefined) {
        Image(this.svc.thumbForRender(this.handle)!)
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
          .id('thumb_' + this.handle)
          .draggable(false)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(IconSize.Nav)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.thumbnail_placeholder'))
      }
    }
    .width('100%').height('100%')
  }
}
