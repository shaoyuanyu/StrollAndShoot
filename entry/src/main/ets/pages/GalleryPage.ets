import display from '@ohos.display';
import { SelectionActionBar } from '../components/SelectionActionBar';
import { DownloadProgressBar } from '../components/DownloadProgressBar';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry, DownloadProgress, DisplayGroup } from '../model/PhotoEntry';
import { getExt, buildDisplayGroups } from '../utils/PhotoGroupUtil';

interface FilterOption {
  label: string;
  value: string;
}

class FlatItem {
  kind: 'header' | 'row' = 'row';
  dateLabel: string = '';
  rowPhotos: (DisplayGroup | null)[] = [];
  /** true when all photos in this row have decoded thumbnails. */
  rowComplete: boolean = true;

  static header(label: string): FlatItem {
    const item = new FlatItem();
    item.kind = 'header';
    item.dateLabel = label;
    return item;
  }

  static row(photos: (DisplayGroup | null)[], complete: boolean): FlatItem {
    const item = new FlatItem();
    item.kind = 'row';
    item.rowPhotos = photos;
    item.rowComplete = complete;
    return item;
  }
}



@ComponentV2
export struct GalleryPage {
  @Param downloadProgress: DownloadProgress | null = null;
  @Param downloadedKeys: string[] = [];
  @Param galleryColumnCount: number = -1;
  @Param displayMode: string = 'file_first';
  @Local svc: CameraService = CameraService.getInstance();
  @Local filterValue: string = '';
  @Local selectMode: boolean = false;
  @Local selectedHandles: Set<number> = new Set();
  @Local galleryScale: number = 1.0;
  @Event onThumbClick: (displayGroups: DisplayGroup[], index: number) => void = (_g: DisplayGroup[], _i: number) => {};
  @Event onDownloadSelected: (handles: number[]) => void = (_h: number[]) => {};
  @Event onCancelDownload: () => void = () => {};
  @Event onSelectModeChange: (v: boolean) => void = (_v: boolean) => {};
  @Param exitSelectModeVersion: number = 0;
  private pinchBaseScale: number = 1.0;

  @Monitor('exitSelectModeVersion')
  onExitSelectModeRequest(): void {
    if (this.selectMode) {
      this.selectMode = false;
      this.selectedHandles.clear();
      this.onSelectModeChange(false);
    }
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
    const w = this.getDisplayWidthVp();
    const avail = w - 20;
    const itemW = this.baseItemW() * this.galleryScale;
    const gap = this.itemGapPx();
    const cols = Math.floor((avail + gap) / (itemW + gap));
    if (cols < 1) return 1;
    if (cols > 8) return 8;
    return cols;
  }

  private baseItemW(): number {
    const w = this.getDisplayWidthVp();
    const avail = w - 20;
    if (this.galleryColumnCount > 0) {
      const gap = this.itemGapPx();
      return (avail - (this.galleryColumnCount - 1) * gap) / this.galleryColumnCount;
    }
    return 80;
  }

  private itemGapPx(): number {
    const s = this.galleryScale;
    if (s <= 0.7) return 1.5;
    if (s <= 1.2) return 2;
    if (s <= 1.8) return 3;
    return 4;
  }

  private formatDate(dateStr: string): string {
    if (!dateStr || dateStr.length < 8) return '';
    return `${dateStr.substring(0, 4)}-${dateStr.substring(4, 6)}-${dateStr.substring(6, 8)}`;
  }

  private formatTime(dateStr: string): string {
    if (!dateStr || dateStr.length < 14) return '';
    return `${dateStr.substring(9, 11)}:${dateStr.substring(11, 13)}:${dateStr.substring(13, 15)}`;
  }

  private hasThumb(handle: number): boolean {
    return this.svc.thumbnailPixelMapMap.has(handle);
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
      const d = this.formatDate(g.displayPhoto.captureDate ?? '');
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
      keys.push('未知日期');
      map.set('未知日期', noDate);
    }

    const cols = this.columnCount();
    const items: FlatItem[] = [];
    for (const k of keys) {
      items.push(FlatItem.header(k));
      const photos = map.get(k)!;
      for (let i = 0; i < photos.length; i += cols) {
        const row: (DisplayGroup | null)[] = [];
        let allComplete = true;
        for (let j = 0; j < cols; j++) {
          if (i + j < photos.length) {
            row.push(photos[i + j]);
            if (!this.hasThumb(photos[i + j].displayPhoto.handle)) {
              allComplete = false;
            }
          } else {
            row.push(null);
          }
        }
        items.push(FlatItem.row(row, allComplete));
      }
    }
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

  private _filterOptsCache: FilterOption[] | null = null;
  private _filterOptsCachePhotosVer: number = -1;
  private _filterOptsCacheMode: string = '';

  private buildFilterOptions(): FilterOption[] {
    if (this._filterOptsCache !== null &&
        this._filterOptsCachePhotosVer === this.svc.photosVersion &&
        this._filterOptsCacheMode === this.displayMode) {
      return this._filterOptsCache;
    }
    const opts: FilterOption[] = [{ label: '全部', value: '' }];
    if (this.displayMode === 'content_first') {
      this._filterOptsCache = opts;
      this._filterOptsCachePhotosVer = this.svc.photosVersion;
      this._filterOptsCacheMode = this.displayMode;
      return opts;
    }
    const seen = new Set<string>();
    for (const p of this.svc.photos) {
      const ext = getExt(p.filename);
      if (ext !== '' && !seen.has(ext)) {
        seen.add(ext);
        opts.push({ label: ext, value: ext });
      }
    }
    this._filterOptsCache = opts;
    this._filterOptsCachePhotosVer = this.svc.photosVersion;
    this._filterOptsCacheMode = this.displayMode;
    return opts;
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
  }

  private toggleSelectDate(dateLabel: string): void {
    if (!this.selectMode) return;
    const all = this.getFilteredDisplayGroups();
    const selectable: DisplayGroup[] = [];
    for (const g of all) {
      if (this.formatDate(g.displayPhoto.captureDate ?? '') === dateLabel ||
          (dateLabel === '未知日期' && !g.displayPhoto.captureDate)) {
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
  }

  @Builder
  PhotoCell(cellRi: RepeatItem<DisplayGroup | null>, rowComplete: boolean) {
    if (cellRi.item !== null) {
      Stack() {
        if (rowComplete && this.hasThumb(cellRi.item!.displayPhoto.handle)) {
          Image(this.svc.thumbnailPixelMapMap.get(cellRi.item!.displayPhoto.handle)!)
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .id('thumb_' + cellRi.item!.displayPhoto.handle)
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
        if (this.formatTime(cellRi.item!.displayPhoto.captureDate ?? '')) {
          Text(this.formatTime(cellRi.item!.displayPhoto.captureDate ?? ''))
            .fontSize(9).fontColor($r('app.color.text_on_dark'))
            .padding({ left: 3, right: 3, top: 1.5, bottom: 1.5 })
            .backgroundColor($r('app.color.scrim')).borderRadius(3)
            .position({ bottom: 3, left: 3 })
        }
        // 边框覆盖层始终在最上层（文本/指示器之后渲染），有边框时自然盖住日期文本底部2px
        Stack()
          .width('100%').height('100%')
          .border({
            width: 2,
            color: this.isDownloaded(cellRi.item!.displayPhoto) ? $r('app.color.status_connected')
              : this.selectedHandles.has(cellRi.item!.displayPhoto.handle) ? $r('app.color.primary')
              : Color.Transparent,
            radius: 8
          })
          .hitTestBehavior(HitTestMode.None)
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
          .position({ top: 5, right: 5 })
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
      .borderRadius(8)
      .clip(true)
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

  private subtitleText(): string {
    if (this.svc.connected) {
      return `${this.svc.photoCount} 张照片 · ${this.svc.cameraName}`;
    }
    return this.svc.statusText || '未连接相机';
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
  }

  @Builder
  Header() {
    Column({ space: 8 }) {
      Row() {
        Text('画廊')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        if (this.svc.photos.length > 0) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(this.selectMode ? $r('sys.symbol.xmark') : $r('sys.symbol.checkmark'))
              .fontSize(18)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40).height(40)
          .backgroundColor($r('app.color.primary_soft'))
          .accessibilityText(this.selectMode ? '退出选择' : '选择照片')
          .onClick(() => { this.toggleSelectMode(); })
        }
      }
      .width('100%')

      Row({ space: 6 }) {
        Row()
          .width(6).height(6).borderRadius(3)
          .backgroundColor(this.svc.connected
            ? $r('app.color.status_connected') : $r('app.color.text_tertiary'))
        Text(this.subtitleText())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

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
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 6 })
  }

  build() {
    Column() {
      this.Header()

      if (this.displayMode === 'file_first') {
        Scroll() {
          Row({ space: 8 }) {
            Repeat<FilterOption>(this.buildFilterOptions())
              .each((ri: RepeatItem<FilterOption>) => {
                Text(ri.item.label)
                  .fontSize(13)
                  .fontColor(ri.item.value === this.filterValue
                    ? $r('app.color.filter_chip_active_text')
                    : $r('app.color.filter_chip_text'))
                  .backgroundColor(ri.item.value === this.filterValue
                    ? $r('app.color.filter_chip_active_bg')
                    : $r('app.color.filter_chip_bg'))
                  .borderRadius(16)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .onClick(() => { this.filterValue = ri.item.value; })
              })
              .key((opt: FilterOption) => opt.value)
          }
          .padding({ left: 4, right: 4 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
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
          List({ space: this.itemGapPx() }) {
            Repeat<FlatItem>(this.buildFlatItems())
              .each((ri: RepeatItem<FlatItem>) => {
                if (ri.item.kind === 'header') {
                  ListItem() {
                    Row({ space: 8 }) {
                      Text(ri.item.dateLabel)
                        .fontSize(15).fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                      if (this.selectMode) {
                        Text('全选当天')
                          .fontSize(12).fontColor($r('app.color.primary'))
                          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                          .backgroundColor($r('app.color.primary_soft'))
                          .borderRadius(12)
                          .onClick(() => { this.toggleSelectDate(ri.item.dateLabel); })
                      }
                    }
                    .alignSelf(ItemAlign.Start)
                    .width('100%')
                    .padding({ left: 4, top: 10, bottom: 4 })
                  }
                } else {
                  ListItem() {
                    Row({ space: this.itemGapPx() }) {
                      Repeat<DisplayGroup | null>(ri.item.rowPhotos)
                        .each((cellRi: RepeatItem<DisplayGroup | null>) => {
                          this.PhotoCell(cellRi, ri.item.rowComplete)
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
                if (item.kind === 'header') return `h_${item.dateLabel}`;
                const first = item.rowPhotos[0];
                return first !== null ? `r_${first.displayPhoto.handle}` : `r_pad`;
              })
              .virtualScroll()
          }
          .cachedCount(5)
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 10, right: 10, bottom: 20 })
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

      if (this.downloadProgress !== null && this.downloadProgress.phase !== 'idle') {
        DownloadProgressBar({
          progress: this.downloadProgress,
          onCancel: () => { this.onCancelDownload(); }
        })
      } else if (this.selectMode) {
        SelectionActionBar({
          selectedCount: this.selectedHandles.size,
          totalVisible: this.getSelectableGroups().length,
          onCancel: () => {
            this.selectMode = false;
            this.onSelectModeChange(false);
            this.selectedHandles.clear();
          },
          onDownload: () => {
            const handles: number[] = [];
            this.selectedHandles.forEach((key: number) => { handles.push(key); });
            this.onDownloadSelected(handles);
            this.selectMode = false;
            this.onSelectModeChange(false);
            this.selectedHandles.clear();
          },
          onSelectAll: () => { this.toggleSelectAll(); }
        })
      }
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
