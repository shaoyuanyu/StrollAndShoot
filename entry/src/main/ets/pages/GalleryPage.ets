import display from '@ohos.display';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry, DownloadProgress, DisplayGroup } from '../model/PhotoEntry';
import { getExt, buildDisplayGroups } from '../utils/PhotoGroupUtil';
import { GalleryZoom } from '../utils/GalleryZoom';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';
import { FontSize, IconSize, Radius, pillRadius } from '../utils/UiTokens';
import { formatDateParts } from '../utils/DateTimeText';

/** 扫描浮卡占用的高度（vp）：列表用 contentStartOffset 让开这么多。 */
const SCAN_CARD_INSET = 64;

class FlatItem {
  kind: 'header' | 'row' | 'tail' = 'tail';
  /** 日期分组键（YYYYMMDD，无拍摄日期为 ''）。标题文案由它换算，见 dateHeaderLabel()。 */
  dateKey: string = '';
  /**
   * 该行的真实照片，**不放 null 占位**。
   *
   * 以前末行不满时补 null，`PhotoCell` 里就得到处写 `cellRi.item!`；扫描期间列表会被
   * 重新分块、元素被复用，判空之后的那次读取可能拿到 null，直接把进程打崩
   * （真机 jscrash：Cannot read property displayPhoto of null）。空白格改由
   * `padIndexes` 单独渲染，行数据里永远只有真照片。
   */
  rowPhotos: DisplayGroup[] = [];
  /** 该行的总列数（照片 + 右侧空白格）。 */
  cols: number = 0;
  /** 右侧空白格的下标，只用于补齐末行。 */
  padIndexes: number[] = [];

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

  static row(photos: DisplayGroup[], cols: number): FlatItem {
    const item = new FlatItem();
    item.kind = 'row';
    item.rowPhotos = photos;
    item.cols = cols > 0 ? cols : photos.length;
    const pads: number[] = [];
    for (let i = photos.length; i < item.cols; i++) {
      pads.push(i);
    }
    item.padIndexes = pads;
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
  // ---- 拖拽多选（REQ-001）----
  /** DOWN 时决定整笔的方向：起手格未选 → 整笔选中；已选 → 整笔取消。 */
  private dragIntent: boolean = false;
  /** 是否正处于一笔拖选里（手指按下且落在可选格子上）。 */
  private dragActive: boolean = false;
  /** 起手格 handle（第一笔 MOVE 时也要补选它）。 */
  private dragStartHandle: number = -1;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private dragLastX: number = 0;
  private dragLastY: number = 0;
  /** 本笔已经真正改动过选择集；用于抑制抬手时单元格自己的 TapGesture。 */
  private dragApplied: boolean = false;
  /** 上一次拖选改动过选择集 → 抬手后的 Tap 不要再去反选。 */
  private suppressNextTap: boolean = false;
  private dragScrollTimerId: number = -1;
  /** List 的可视高度（vp），边缘自动滚动需要它。 */
  private listHeightVp: number = 0;
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
        if (g.displayPhoto.handle === handle) {
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
    this.stopDragSelect();
    this.selectMode = false;
    this.onSelectModeChange(false);
    this.selectedHandles.clear();
    this.syncSelectionStats();
  }

  @Monitor('exitSelectModeVersion')
  onExitSelectModeRequest(): void {
    if (this.selectMode) {
      this.stopDragSelect();
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
    // 顺序（含文件优先模式下的 JPG/NEF 成对）由 buildDisplayGroups 统一负责，
    // 这里**不要**再按 captureDate 排一次：那会把时间相差 1 秒的同名文件重新拆开。
    this._allGroupsCache = buildDisplayGroups(this.svc.photos, this.displayMode);
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
        items.push(FlatItem.row(photos.slice(i, i + safeCols), safeCols));
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

  // ---------------- 拖拽多选（REQ-001） ----------------

  /**
   * 屏幕坐标 → 单元格 handle。
   *
   * 用官方 `Scroller.getItemIndex(x, y)`（API 14）拿到行在 flat 列表里的下标，
   * 再用 `getItemRect(index)` 拿这一行相对 List 的矩形，按列均分反推是第几格。
   * 两条都是官方接口，比按 header 高度/行高累加推算稳得多（那种做法依赖字号缩放）。
   * 坐标口径：`onTouch` 的 `TouchObject.x/y` 与 `getItemIndex` 都是「相对 List」。
   */
  private handleAt(x: number, y: number): number {
    let itemIndex = -1;
    try {
      itemIndex = this.scroller.getItemIndex(x, y);
    } catch (_e) {
      return -1;
    }
    if (itemIndex < 0) return -1;
    const items = this.buildFlatItems();
    if (itemIndex >= items.length) return -1;
    const item = items[itemIndex];
    if (item.kind !== 'row') return -1;
    const count = item.cols > 0 ? item.cols : item.rowPhotos.length;
    if (count <= 0) return -1;
    let rect: RectResult | null = null;
    try {
      rect = this.scroller.getItemRect(itemIndex);
    } catch (_e) {
      return -1;
    }
    if (rect === null || rect.width <= 0) return -1;
    const gap = this.activeGap();
    const cellW = (rect.width - (count - 1) * gap) / count;
    if (cellW <= 0) return -1;
    let col = Math.floor((x - rect.x) / (cellW + gap));
    if (col < 0) col = 0;
    if (col >= count) col = count - 1;
    if (col >= item.rowPhotos.length) return -1;
    return item.rowPhotos[col].displayPhoto.handle;
  }

  private isHandleDownloaded(handle: number): boolean {
    const groups = this.getFilteredDisplayGroups();
    for (const g of groups) {
      if (g.displayPhoto.handle === handle) {
        return this.isDownloaded(g.displayPhoto);
      }
    }
    return false;
  }

  /** 按整笔方向把某个格子设成选中/未选；已下载的照片跳过。 */
  private applyDragHandle(handle: number): void {
    if (handle < 0) return;
    if (this.isHandleDownloaded(handle)) return;
    const has = this.selectedHandles.has(handle);
    if (has === this.dragIntent) return;
    if (this.dragIntent) {
      this.selectedHandles.add(handle);
    } else {
      this.selectedHandles.delete(handle);
    }
    this.selectedHandles = new Set(this.selectedHandles);
    this.syncSelectionStats();
    this.dragApplied = true;
    this.suppressNextTap = true;
  }

  private applyDragAt(x: number, y: number): void {
    this.applyDragHandle(this.handleAt(x, y));
  }

  /** 手指贴住上下边缘时自动滚动；否则长列表里选不到屏幕外的照片。 */
  private startDragScrollTimer(): void {
    if (this.dragScrollTimerId >= 0) return;
    this.dragScrollTimerId = setInterval(() => {
      if (!this.dragActive) {
        this.stopDragSelect();
        return;
      }
      const h = this.listHeightVp;
      if (h <= 0) return;
      const edge = 72;
      let step = 0;
      if (this.dragLastY < edge) {
        step = -Math.max(6, Math.min(24, (edge - this.dragLastY) / 3));
      } else if (this.dragLastY > h - edge) {
        step = Math.max(6, Math.min(24, (this.dragLastY - (h - edge)) / 3));
      }
      if (step === 0) return;
      try {
        this.scroller.scrollBy(0, step);
      } catch (_e) {
        return;
      }
      // 内容滚过手指后，压着的格子可能换了一张，继续按整笔方向处理
      this.applyDragAt(this.dragLastX, this.dragLastY);
    }, 50);
  }

  private stopDragSelect(): void {
    this.dragActive = false;
    this.dragStartHandle = -1;
    if (this.dragScrollTimerId >= 0) {
      clearInterval(this.dragScrollTimerId);
      this.dragScrollTimerId = -1;
    }
  }

  /**
   * 网格上的原始触摸。这里刻意不用 PanGesture：
   * 多选态下 List 的滚动交互已被关掉（`enableScrollInteraction(!selectMode)`），
   * 原始触摸与单元格自己的 Tap/LongPress 不打架，抬手时由 `suppressNextTap`
   * 抑制一次多余的 Tap。
   */
  private onGridTouch(event: TouchEvent): void {
    if (!this.selectMode) {
      this.stopDragSelect();
      return;
    }
    const touches = event.touches;
    if (event.type === TouchType.Down) {
      this.suppressNextTap = false;
      this.stopDragSelect();
      if (touches.length !== 1) return;
      const t = touches[0];
      this.dragStartX = t.x;
      this.dragStartY = t.y;
      this.dragLastX = t.x;
      this.dragLastY = t.y;
      this.dragApplied = false;
      const h = this.handleAt(t.x, t.y);
      this.dragStartHandle = h;
      if (h < 0 || this.isHandleDownloaded(h)) return;
      // 起手格已选 → 整笔取消；未选 → 整笔选中
      this.dragIntent = !this.selectedHandles.has(h);
      this.dragActive = true;
      this.startDragScrollTimer();
      return;
    }
    if (event.type === TouchType.Move) {
      if (touches.length !== 1) {
        this.stopDragSelect();
        return;
      }
      const t = touches[0];
      this.dragLastX = t.x;
      this.dragLastY = t.y;
      if (!this.dragActive) {
        // 长按进入多选时长按那一笔还没结束：继续拖就直接按“选中”方向接着选
        if (this.dragStartHandle < 0) return;
        this.dragIntent = true;
        this.dragActive = true;
        this.startDragScrollTimer();
      }
      if (!this.dragApplied) {
        // 第一笔 MOVE 补上起手格（手指可能一上来就跨过了起手格）
        this.applyDragHandle(this.dragStartHandle);
      }
      this.applyDragAt(t.x, t.y);
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.stopDragSelect();
    }
  }

  /**
   * 渲染一个格子。
   *
   * 参数保持 `RepeatItem`：`@Builder` 的**值参数不会随列表复用刷新**（AGENTS.md 记过这个坑），
   * 之前为了躲空指针改成传值，结果滚动复用后格子停在旧照片上。
   * 现在 `rowPhotos` 里只有真实照片、没有 null 占位，`cellRi.item` 不会再变成 null，
   * 原来那个 jscrash 也不会回来。
   */
  @Builder
  PhotoCell(cellRi: RepeatItem<DisplayGroup>) {
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
                if (this.suppressNextTap) {
                  // 这一笔是拖选，不要在建整笔状态的格子上再反选一次
                  this.suppressNextTap = false;
                  return;
                }
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
      Row()
        .layoutWeight(1)
        .aspectRatio(1)
    }
  }

  /** 末行右侧的空白格：只占位，不画内容。 */
  @Builder
  PadCell() {
    Row()
      .layoutWeight(1)
      .aspectRatio(1)
  }

  private toggleSelectMode(): void {
    this.stopDragSelect();
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

  /**
   * 扫描状态浮卡。
   *
   * 以前是把横幅排在列表上方（同一个 Column），但列表为了「照片能钻到标题栏底下」
   * 设了 `clip(false)`，滚动内容会越过自身的上边界盖住横幅——真机截图里就是
   * 日期标题压在进度条上、进度文字被格子切掉。现在改成 **浮在列表之上的卡片**，
   * 列表用 contentStartOffset 整体让开，谁都不会遮谁。
   */
  @Builder
  ScanCard() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        LoadingProgress()
          .width(18).height(18)
          .color($r('app.color.primary'))
        Column({ space: 2 }) {
          Text($r('app.string.gallery_scanning_title'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
          Text(this.svc.scanPhaseText)
            .fontSize(FontSize.Micro)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(`${this.svc.scanProgress}/${this.svc.scanTotal}`)
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Progress({
        value: this.svc.scanProgress,
        total: this.svc.scanTotal > 0 ? this.svc.scanTotal : 1,
        type: ProgressType.Linear
      })
        .width('100%').height(2)
        .color($r('app.color.primary'))
        .backgroundColor($r('app.color.progress_track'))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 12 })
    .borderRadius(Radius.Inner)
    .backgroundColor($r('app.color.bg_surface'))
    .border({ width: 1, color: $r('app.color.card_border') })
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
    // 扫描卡是浮层（见 build 里的 ScanCard），内容要整体让开它，
    // 否则首个日期标题会被卡片压住。
    return titleBarTotalVp() + (this.topHeaderVisible() ? SCAN_CARD_INSET : 0);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
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
                      Repeat<DisplayGroup>(ri.item.rowPhotos)
                        .each((cellRi: RepeatItem<DisplayGroup>) => {
                          this.PhotoCell(cellRi)
                        })
                        .key((dg: DisplayGroup) => dg.displayPhoto.handle.toString())
                      Repeat<number>(ri.item.padIndexes)
                        .each((_pad: RepeatItem<number>) => {
                          this.PadCell()
                        })
                        .key((_n: number, idx: number) => `pad_${ri.index}_${idx}`)
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
          // 多选态：拖动用来框选，不再滚列表（滚到边缘时自动滚动）。
          .enableScrollInteraction(!this.selectMode)
          .onTouch((event: TouchEvent) => { this.onGridTouch(event); })
          .onAreaChange((_o: Area, n: Area) => {
            const h = n.height as number;
            if (h > 0) { this.listHeightVp = h; }
          })
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

      // 扫描浮卡：放在列表之后绘制，永远盖在内容之上
      if (this.topHeaderVisible()) {
        Column() {
          this.ScanCard()
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
        .position({ top: titleBarTotalVp() + 4, left: 0 })
        .hitTestBehavior(HitTestMode.None)
      }
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
