import display from '@ohos.display';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry, DownloadProgress, DisplayGroup } from '../model/PhotoEntry';
import { getExt, buildDisplayGroups } from '../utils/PhotoGroupUtil';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';

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
  @Local galleryScale: number = 1.0;
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
  private pinchBaseScale: number = 1.0;

  @Monitor('toggleSelectVersion')
  onToggleSelectRequest(): void {
    this.toggleSelectMode();
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
  private _flatCacheThumbVer: number = -1;
  private _flatCacheMode: string = '';
  private _flatCacheFilter: string = '';
  private _flatCacheScale: number = -1;
  private _flatCacheColumns: number = -1;
  private _flatCacheWidth: number = -1;

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

  private columnCount(): number {
    // 网格贴边（与官方图库一致，没有左右页边距）
    const avail = this.getDisplayWidthVp();
    const itemW = this.baseItemW() * this.galleryScale;
    const gap = this.itemGapPx();
    const cols = Math.floor((avail + gap) / (itemW + gap));
    if (cols < 1) return 1;
    if (cols > 8) return 8;
    return cols;
  }

  private baseItemW(): number {
    const w = this.getDisplayWidthVp();
    const gap = this.itemGapPx();
    if (this.galleryColumnCount > 0) {
      return (w - (this.galleryColumnCount - 1) * gap) / this.galleryColumnCount;
    }
    // 官方图库在手机上是 3 列
    return (w - 2 * gap) / 3;
  }

  private itemGapPx(): number {
    const s = this.galleryScale;
    if (s <= 0.7) return 1.5;
    if (s <= 1.2) return 2;
    if (s <= 1.8) return 3;
    return 4;
  }

  /** 日期分组键：YYYYMMDD；没有拍摄日期时为空串。 */
  private dateKeyOf(captureDate: string): string {
    if (!captureDate || captureDate.length < 8) return '';
    return captureDate.substring(0, 8);
  }

  /** 对齐官方图库的日期标题：今天 / 昨天 / 11月6日 / 2025年11月6日。 */
  private dateHeaderLabel(key: string): string {
    if (!key) return '未知日期';
    const y = Number(key.substring(0, 4));
    const m = Number(key.substring(4, 6));
    const d = Number(key.substring(6, 8));
    const now = new Date();
    const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const target = new Date(y, m - 1, d);
    const diffDays = Math.round((todayStart.getTime() - target.getTime()) / 86400000);
    if (diffDays === 0) return '今天';
    if (diffDays === 1) return '昨天';
    if (y === now.getFullYear()) return `${m}月${d}日`;
    return `${y}年${m}月${d}日`;
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
    const all = this.allDisplayGroups();
    if (this.displayMode === 'content_first' || this.filterValue === '') return all;
    const result: DisplayGroup[] = [];
    for (const g of all) {
      if (getExt(g.displayPhoto.filename) === this.filterValue) result.push(g);
    }
    return result;
  }

  private buildFlatItems(): FlatItem[] {
    if (this._flatItemsCache !== null &&
        this._flatCachePhotosVer === this.svc.photosVersion &&
        this._flatCacheThumbVer === this.svc.thumbnailVersion &&
        this._flatCacheMode === this.displayMode &&
        this._flatCacheFilter === this.filterValue &&
        this._flatCacheScale === this.galleryScale &&
        this._flatCacheColumns === this.galleryColumnCount &&
        this._flatCacheWidth === this.getDisplayWidthVp()) {
      return this._flatItemsCache;
    }
    const t0 = Date.now();
    this.svc.getLog().add('PERF buildFlatItems cache MISS, rebuilding...');
    const filtered = this.getFilteredDisplayGroups();
    const map = new Map<string, DisplayGroup[]>();
    let noDate: DisplayGroup[] = [];
    for (const g of filtered) {
      const d = this.dateKeyOf(g.displayPhoto.captureDate ?? '');
      if (d) {
        const arr = map.get(d);
        if (arr) arr.push(g);
        else map.set(d, [g]);
      } else {
        noDate.push(g);
      }
    }
    const sortFn = (a: DisplayGroup, b: DisplayGroup) =>
      (b.displayPhoto.captureDate ?? '').localeCompare(a.displayPhoto.captureDate ?? '');
    const keys: string[] = [];
    map.forEach((_v: DisplayGroup[], k: string) => {
      map.get(k)!.sort(sortFn);
      keys.push(k);
    });
    keys.sort((a: string, b: string) => b.localeCompare(a));
    if (noDate.length > 0) {
      noDate.sort(sortFn);
      keys.push('');
      map.set('', noDate);
    }

    const cols = this.columnCount();
    const items: FlatItem[] = [];
    for (const k of keys) {
      items.push(FlatItem.header(k));
      const photos = map.get(k)!;
      for (let i = 0; i < photos.length; i += cols) {
        const row: (DisplayGroup | null)[] = [];
        for (let j = 0; j < cols; j++) {
          row.push(i + j < photos.length ? photos[i + j] : null);
        }
        items.push(FlatItem.row(row));
      }
    }
    items.push(FlatItem.tail());
    this._flatItemsCache = items;
    this._flatCachePhotosVer = this.svc.photosVersion;
    this._flatCacheThumbVer = this.svc.thumbnailVersion;
    this._flatCacheMode = this.displayMode;
    this._flatCacheFilter = this.filterValue;
    this._flatCacheScale = this.galleryScale;
    this._flatCacheColumns = this.galleryColumnCount;
    this._flatCacheWidth = this.getDisplayWidthVp();
    this.svc.getLog().add(`PERF buildFlatItems done in ${Date.now() - t0}ms (${items.length} items)`);
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
                .fontSize(12)
                .fontColor([$r('app.color.text_on_primary')])
            }
          }
          .width(20).height(20)
          .borderRadius(10)
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
            .width(10).height(10).borderRadius(5)
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
          Text(this.svc.scanPhaseText || '正在扫描')
            .fontSize(11).fontColor($r('app.color.text_secondary'))
          Blank()
          Text(`${this.svc.scanProgress}/${this.svc.scanTotal}`)
            .fontSize(11).fontColor($r('app.color.text_secondary'))
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
            .fontSize(48)
            .fontColor([$r('app.color.text_tertiary')])
          if (this.svc.scanning) {
            LoadingProgress().width(28).height(28).color($r('app.color.primary'))
            Text('正在扫描相机…')
              .fontSize(14).fontColor($r('app.color.text_secondary'))
          } else {
            Text('连接相机以浏览照片')
              .fontSize(14).fontColor($r('app.color.text_secondary'))
            Text('在「相机」页搜索并连接 PTP 设备')
              .fontSize(12).fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%').layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          List({ scroller: this.scroller, space: this.itemGapPx() }) {
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
                        .fontSize(16)
                        .fontWeight(FontWeight.Bold)
                        .fontColor($r('app.color.text_primary'))
                        .layoutWeight(1)
                      if (this.selectMode) {
                        Stack() {
                          if (this.dateSelectState(ri.item.dateKey) === 2) {
                            SymbolGlyph($r('sys.symbol.checkmark'))
                              .fontSize(12)
                              .fontColor([$r('app.color.text_on_primary')])
                          } else if (this.dateSelectState(ri.item.dateKey) === 1) {
                            Row()
                              .width(9).height(1.6)
                              .borderRadius(1)
                              .backgroundColor($r('app.color.text_on_primary'))
                          }
                        }
                        .width(20).height(20)
                        .borderRadius(10)
                        .backgroundColor(this.dateSelectState(ri.item.dateKey) > 0
                          ? $r('app.color.primary') : Color.Transparent)
                        .border({
                          width: this.dateSelectState(ri.item.dateKey) > 0 ? 0 : 1.5,
                          color: $r('app.color.text_tertiary')
                        })
                        // 视觉 20vp，热区扩到 44vp
                        .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
                        .accessibilityText(`全选 ${this.dateHeaderLabel(ri.item.dateKey)}`)
                        .onClick(() => { this.toggleSelectDate(ri.item.dateKey); })
                      }
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)
                    .padding({ left: 16, right: 16, top: 24, bottom: 24 })
                  }
                } else {
                  ListItem() {
                    Row({ space: this.itemGapPx() }) {
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
          .cachedCount(5)
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
          PinchGesture({ fingers: 2 })
            .onActionStart(() => { this.pinchBaseScale = this.galleryScale; })
            .onActionUpdate((event: GestureEvent) => {
              const s = this.pinchBaseScale * event.scale;
              this.galleryScale = Math.max(0.4, Math.min(6.0, s));
            })
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
            .fontSize(20)
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
