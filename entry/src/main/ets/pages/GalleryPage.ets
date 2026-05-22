import display from '@ohos.display';
import { ConnectionStatusBar } from '../components/ConnectionStatusBar';
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

  static header(label: string): FlatItem {
    const item = new FlatItem();
    item.kind = 'header';
    item.dateLabel = label;
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
struct GalleryContent {
  @Param flatItems: FlatItem[] = [];
  @Param columnCount: number = 3;
  @Param itemGap: number = 2;
  @Param hasThumbFn: (handle: number) => boolean = (_h: number) => false;
  @Param isDownloadedFn: (photo: PhotoEntry) => boolean = (_p: PhotoEntry) => false;
  @Param makeDownloadKeyFn: (filename: string, size: number) => string = (_f: string, _s: number) => '';
  @Param thumbnailMap: Map<number, Object> = new Map();
  @Param downloadedKeys: string[] = [];
  @Param selectMode: boolean = false;
  @Param selectedHandles: Set<number> = new Set();
  @Event onPhotoTap: (dg: DisplayGroup) => void = (_dg: DisplayGroup) => {};
  @Event onSelectionToggle: (handle: number) => void = (_h: number) => {};
  @Event onLongPress: (handle: number) => void = (_h: number) => {};
  @Event onSelectDate: (dateLabel: string) => void = (_d: string) => {};

  private formatTime(dateStr: string): string {
    if (!dateStr || dateStr.length < 14) return '';
    return `${dateStr.substring(9, 11)}:${dateStr.substring(11, 13)}:${dateStr.substring(13, 15)}`;
  }

  @Builder
  PhotoCell(dg: DisplayGroup) {
    Stack() {
      if (this.hasThumbFn(dg.displayPhoto.handle)) {
        Image(this.thumbnailMap.get(dg.displayPhoto.handle) as PixelMap)
          .objectFit(ImageFit.Cover)
          .width('100%').height('100%')
      } else {
        Column() { Text('📷').fontSize(20) }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.thumbnail_placeholder'))
      }
      if (dg.displayPhoto.captureDate) {
        Text(this.formatTime(dg.displayPhoto.captureDate!))
          .fontSize(8).fontColor($r('app.color.text_on_dark'))
          .padding({ left: 3, right: 3, top: 1, bottom: 1 })
          .backgroundColor('rgba(0,0,0,0.5)').borderRadius(3)
          .position({ x: 0, y: '100%' }).markAnchor({ x: 0, y: '100%' })
          .margin({ left: 3, bottom: 3 })
      }
      if (this.selectMode && !this.isDownloadedFn(dg.displayPhoto)) {
        Checkbox()
          .select(this.selectedHandles.has(dg.displayPhoto.handle))
          .width(18).height(18)
          .position({ x: '100%', y: 0 }).markAnchor({ x: '100%', y: 0 })
          .margin({ top: 3, right: 3 })
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.downloadedKeys.indexOf(this.makeDownloadKeyFn(dg.displayPhoto.filename, dg.displayPhoto.size)) >= 0) {
        Circle({ width: 6, height: 6 })
          .fill('#4CAF50')
          .position({ x: '100%', y: 0 }).markAnchor({ x: '100%', y: 0 })
          .margin({ top: 4, right: 4 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .layoutWeight(1)
    .aspectRatio(1)
    .borderRadius(4)
    .border({
      width: this.downloadedKeys.indexOf(this.makeDownloadKeyFn(dg.displayPhoto.filename, dg.displayPhoto.size)) >= 0 ? 2 : 0,
      color: '#4CAF50', radius: 4
    })
    .clip(true)
    .parallelGesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ repeat: false, duration: 500 })
          .onAction(() => {
            if (this.isDownloadedFn(dg.displayPhoto)) return;
            this.onLongPress(dg.displayPhoto.handle);
          }),
        TapGesture()
          .onAction(() => {
            if (this.selectMode) {
              if (this.isDownloadedFn(dg.displayPhoto)) return;
              this.onSelectionToggle(dg.displayPhoto.handle);
            } else {
              this.onPhotoTap(dg);
            }
          })
      )
    )
  }

  build() {
    List({ space: this.itemGap }) {
      Repeat<FlatItem>(this.flatItems)
        .each((ri: RepeatItem<FlatItem>) => {
          if (ri.item.kind === 'header') {
            ListItem() {
              Row({ space: 8 }) {
                Text(ri.item.dateLabel)
                  .fontSize(13).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                if (this.selectMode) {
                  Text('全选当天')
                    .fontSize(11).fontColor($r('app.color.primary'))
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .border({ width: 1, color: $r('app.color.primary'), radius: 10 })
                    .onClick(() => { this.onSelectDate(ri.item.dateLabel); })
                }
              }
              .alignSelf(ItemAlign.Start)
              .width('100%')
              .padding({ left: 4, top: 10, bottom: 4 })
            }
          } else {
            ListItem() {
              Row({ space: this.itemGap }) {
                ForEach(ri.item.rowPhotos, (dg: DisplayGroup | null, idx: number) => {
                  if (dg !== null) {
                    this.PhotoCell(dg)
                  } else {
                    Stack()
                      .layoutWeight(1)
                      .aspectRatio(1)
                      .backgroundColor(Color.Transparent)
                  }
                }, (_dg: DisplayGroup | null, idx: number) => {
                  if (_dg !== null) return _dg.displayPhoto.handle.toString();
                  return `pad_${idx}_${ri.index}`;
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
    .padding({ left: 6, right: 6, bottom: 16 })
  }
}

@Component
export struct GalleryPage {
  @Prop connected: boolean = false;
  @Prop cameraName: string = '';
  @Prop photoCount: number = 0;
  @Prop statusText: string = '就绪';
  @Prop photos: PhotoEntry[] = [];
  @Prop thumbnailVersion: number = 0;
  @Prop thumbnailReadyHandles: number[] = [];
  @State filterValue: string = '';
  @State selectMode: boolean = false;
  @State selectedHandles: Set<number> = new Set();
  @State galleryScale: number = 1.0;
  @Prop downloadProgress: DownloadProgress | null = null;
  @Prop downloadedKeys: string[] = [];
  @Prop scanProgress: number = 0;
  @Prop scanTotal: number = 0;
  @StorageLink('gallery_column_count') galleryColumnCount: number = -1;
  @StorageLink('gallery_display_mode') displayMode: string = 'file_first';
  private service: CameraService = CameraService.getInstance();
  private pinchBaseScale: number = 1.0;
  onThumbClick: (displayGroups: DisplayGroup[], index: number) => void = (_g: DisplayGroup[], _i: number) => {};
  onDownloadSelected: (handles: number[]) => void = (_h: number[]) => {};
  onCancelDownload: () => void = () => {};

  private columnCount(): number {
    const d = display.getDefaultDisplaySync();
    const w = d ? d.width : 360;
    const avail = w - 12;
    const itemW = this.baseItemW() * this.galleryScale;
    const gap = this.itemGapPx();
    const cols = Math.floor((avail + gap) / (itemW + gap));
    if (cols < 1) return 1;
    if (cols > 8) return 8;
    return cols;
  }

  private baseItemW(): number {
    if (this.galleryColumnCount > 0) {
      const d = display.getDefaultDisplaySync();
      const w = d ? d.width : 360;
      const avail = w - 12;
      return (avail - (this.galleryColumnCount - 1) * 2) / this.galleryColumnCount;
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

  private isDownloaded(photo: PhotoEntry): boolean {
    return this.downloadedKeys.indexOf(this.service.makeDownloadKey(photo.filename, photo.size)) >= 0;
  }

  private _allGroupsCache: DisplayGroup[] | null = null;
  private _cachePhotosRef: PhotoEntry[] | null = null;
  private _cacheMode: string = '';

  private allDisplayGroups(): DisplayGroup[] {
    if (this._allGroupsCache !== null &&
        this._cachePhotosRef === this.photos &&
        this._cacheMode === this.displayMode) {
      return this._allGroupsCache;
    }
    this._allGroupsCache = buildDisplayGroups(this.photos, this.displayMode);
    this._cachePhotosRef = this.photos;
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
        for (let j = 0; j < cols; j++) {
          if (i + j < photos.length) row.push(photos[i + j]);
          else row.push(null);
        }
        items.push(FlatItem.row(row));
      }
    }
    return items;
  }

  private buildFilterOptions(): FilterOption[] {
    const opts: FilterOption[] = [{ label: '全部', value: '' }];
    if (this.displayMode === 'content_first') return opts;
    const seen = new Set<string>();
    for (const p of this.photos) {
      const ext = getExt(p.filename);
      if (ext !== '' && !seen.has(ext)) {
        seen.add(ext);
        opts.push({ label: ext, value: ext });
      }
    }
    return opts;
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

  build() {
    Column() {
      ConnectionStatusBar({
        connected: this.connected, cameraName: this.cameraName,
        photoCount: this.photoCount, statusText: this.statusText,
        compact: true, scanProgress: this.scanProgress, scanTotal: this.scanTotal
      }).margin({ top: 12, bottom: 4 })

      if (this.displayMode === 'file_first') {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.buildFilterOptions(), (opt: FilterOption) => {
              Text(opt.label)
                .fontSize(12)
                .fontColor(opt.value === this.filterValue
                  ? $r('app.color.filter_chip_active_text')
                  : $r('app.color.filter_chip_text'))
                .backgroundColor(opt.value === this.filterValue
                  ? $r('app.color.filter_chip_active_bg')
                  : $r('app.color.filter_chip_bg'))
                .borderRadius(14)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .onClick(() => { this.filterValue = opt.value; })
            })
          }
          .padding({ left: 4, right: 4 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }

      if (this.photos.length === 0) {
        Column() {
          Text('📷').fontSize(48).margin({ bottom: 12 })
          Text('连接相机以浏览照片')
            .fontSize(14).fontColor($r('app.color.text_secondary'))
        }
        .width('100%').layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          GalleryContent({
            flatItems: this.buildFlatItems(),
          columnCount: this.columnCount(),
          itemGap: this.itemGapPx(),
          hasThumbFn: (h: number) => this.thumbnailReadyHandles.indexOf(h) >= 0,
          isDownloadedFn: (p: PhotoEntry) => this.isDownloaded(p),
          makeDownloadKeyFn: (f: string, s: number) => this.service.makeDownloadKey(f, s),
          thumbnailMap: this.service.thumbnailPixelMapMap,
          downloadedKeys: this.downloadedKeys,
          selectMode: this.selectMode,
          selectedHandles: this.selectedHandles,
          onPhotoTap: (dg: DisplayGroup) => {
            const filtered = this.getFilteredDisplayGroups();
            let idx = 0;
            for (let i = 0; i < filtered.length; i++) {
              if (filtered[i].displayPhoto.handle === dg.displayPhoto.handle) { idx = i; break; }
            }
            this.onThumbClick(filtered, idx);
          },
          onSelectionToggle: (handle: number) => {
            if (this.selectedHandles.has(handle)) {
              this.selectedHandles.delete(handle);
            } else {
              this.selectedHandles.add(handle);
            }
            this.selectedHandles = new Set(this.selectedHandles);
          },
          onLongPress: (handle: number) => {
            if (!this.selectMode) {
              this.selectMode = true;
              this.selectedHandles.add(handle);
              this.selectedHandles = new Set(this.selectedHandles);
            }
          },
          onSelectDate: (dateLabel: string) => { this.toggleSelectDate(dateLabel); }
          })
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
            this.selectedHandles.clear();
          },
          onDownload: () => {
            const handles: number[] = [];
            this.selectedHandles.forEach((key: number) => { handles.push(key); });
            this.onDownloadSelected(handles);
            this.selectMode = false;
            this.selectedHandles.clear();
          },
          onSelectAll: () => { this.toggleSelectAll(); }
        })
      }
    }
    .width('100%').height('100%')
  }
}
