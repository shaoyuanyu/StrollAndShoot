import display from '@ohos.display';
import { ConnectionStatusBar } from '../components/ConnectionStatusBar';
import { SelectionActionBar } from '../components/SelectionActionBar';
import { CameraService } from '../services/CameraService';
import type { PhotoEntry } from '../model/PhotoEntry';

interface DateGroup {
  dateLabel: string;
  photos: PhotoEntry[];
}

interface FilterOption {
  label: string;
  value: string;
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
  @State dateGroups: DateGroup[] = [];
  @State galleryScale: number = 1.0;
  private service: CameraService = CameraService.getInstance();
  private pinchBaseScale: number = 1.0;
  onThumbClick: (photo: PhotoEntry, index: number) => void = (_p: PhotoEntry, _i: number) => {};
  onDownloadSelected: (handles: number[]) => void = (_h: number[]) => {};

  private columnCount(): number {
    const d = display.getDefaultDisplaySync();
    const w = d ? d.width : 360;
    const avail = w - 12;
    const itemW = 80 * this.galleryScale;
    const gap = this.itemGapPx();
    const cols = Math.floor((avail + gap) / (itemW + gap));
    if (cols < 1) return 1;
    if (cols > 8) return 8;
    return cols;
  }

  private itemGapPx(): number {
    const s = this.galleryScale;
    if (s <= 0.7) return 1.5;
    if (s <= 1.2) return 2;
    if (s <= 1.8) return 3;
    return 4;
  }

  private itemWidth(): string {
    const c = this.columnCount();
    const g = this.itemGapPx();
    const totalGap = (c - 1) * g;
    const d = display.getDefaultDisplaySync();
    const avail = (d ? d.width : 360) - 12;
    const itemPx = (avail - totalGap) / c;
    const pct = (itemPx / (d ? d.width : 360)) * 100;
    return `${pct.toFixed(1)}%`;
  }

  private itemMargin(): string {
    const g = this.itemGapPx();
    const d = display.getDefaultDisplaySync();
    const pct = (g / (d ? d.width : 360)) * 100;
    return `${pct.toFixed(1)}%`;
  }

  private hasThumb(handle: number): boolean {
    return this.thumbnailReadyHandles.indexOf(handle) >= 0;
  }

  private getExt(filename: string): string {
    const dot = filename.lastIndexOf('.');
    if (dot < 0) return '';
    return filename.substring(dot + 1).toUpperCase();
  }

  private formatDate(dateStr: string): string {
    if (!dateStr || dateStr.length < 8) return '';
    return `${dateStr.substring(0, 4)}-${dateStr.substring(4, 6)}-${dateStr.substring(6, 8)}`;
  }

  private formatTime(dateStr: string): string {
    if (!dateStr || dateStr.length < 14) return '';
    return `${dateStr.substring(9, 11)}:${dateStr.substring(11, 13)}:${dateStr.substring(13, 15)}`;
  }

  private getFilterExt(): string {
    return this.filterValue;
  }

  private getFilteredPhotos(): PhotoEntry[] {
    const ext = this.getFilterExt();
    if (ext === '') return this.photos;
    const result: PhotoEntry[] = [];
    for (const p of this.photos) {
      if (this.getExt(p.filename) === ext) result.push(p);
    }
    return result;
  }

  private getFilteredGroups(): DateGroup[] {
    const filtered = this.getFilteredPhotos();
    const map = new Map<string, PhotoEntry[]>();
    let noDate: PhotoEntry[] = [];
    for (const p of filtered) {
      const d = this.formatDate(p.captureDate ?? '');
      if (d) {
        const arr = map.get(d);
        if (arr) arr.push(p);
        else map.set(d, [p]);
      } else {
        noDate.push(p);
      }
    }
    const sortFn = (a: PhotoEntry, b: PhotoEntry) =>
      (b.captureDate ?? '').localeCompare(a.captureDate ?? '');
    const keys: string[] = [];
    map.forEach((_v: PhotoEntry[], k: string) => {
      const arr = map.get(k)!;
      arr.sort(sortFn);
      keys.push(k);
    });
    keys.sort((a: string, b: string) => b.localeCompare(a));
    const groups: DateGroup[] = [];
    for (const k of keys) {
      groups.push({ dateLabel: k, photos: map.get(k)! });
    }
    if (noDate.length > 0) {
      noDate.sort(sortFn);
      groups.push({ dateLabel: '未知日期', photos: noDate });
    }
    return groups;
  }

  private buildFilterOptions(): FilterOption[] {
    const opts: FilterOption[] = [{ label: '全部', value: '' }];
    const seen = new Set<string>();
    for (const p of this.photos) {
      const ext = this.getExt(p.filename);
      if (ext !== '' && !seen.has(ext)) {
        seen.add(ext);
        opts.push({ label: ext, value: ext });
      }
    }
    return opts;
  }

build() {
    Column() {
      ConnectionStatusBar({
        connected: this.connected, cameraName: this.cameraName,
        photoCount: this.photoCount, statusText: this.statusText,
        compact: true
      }).margin({ top: 12, bottom: 4 })

      // Filter bar
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
              .onClick(() => {
                this.filterValue = opt.value;
              })
          })
        }
        .padding({ left: 4, right: 4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })

      if (this.photos.length === 0) {
        Column() {
          Text('📷').fontSize(48).margin({ bottom: 12 })
          Text('连接相机以浏览照片')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%').layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.getFilteredGroups(), (group: DateGroup, gi: number) => {
              Column() {
                Text(group.dateLabel)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .alignSelf(ItemAlign.Start)
                  .padding({ left: 4, bottom: 4 })

                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                  ForEach(group.photos, (photo: PhotoEntry) => {
                    Column() {
                      Stack() {
                        if (this.hasThumb(photo.handle)) {
                          Image(this.service.thumbnailPixelMapMap.get(photo.handle)!)
                            .objectFit(ImageFit.Cover)
                            .width('100%').height('100%')
                        } else {
                          Column() {
                            Text('📷').fontSize(20)
                          }
                          .width('100%').height('100%')
                          .justifyContent(FlexAlign.Center)
                          .backgroundColor($r('app.color.thumbnail_placeholder'))
                        }

                        if (photo.captureDate) {
                          Text(this.formatTime(photo.captureDate!))
                            .fontSize(8)
                            .fontColor($r('app.color.text_on_dark'))
                            .padding({ left: 3, right: 3, top: 1, bottom: 1 })
                            .backgroundColor('rgba(0,0,0,0.5)')
                            .borderRadius(3)
                            .position({ x: 0, y: '100%' })
                            .markAnchor({ x: 0, y: '100%' })
                            .margin({ left: 3, bottom: 3 })
                        }

                        if (this.selectMode) {
                          Checkbox()
                            .select(this.selectedHandles.has(photo.handle))
                            .width(18).height(18)
                            .position({ x: '100%', y: 0 })
                            .markAnchor({ x: '100%', y: 0 })
                            .margin({ top: 3, right: 3 })
                            .hitTestBehavior(HitTestMode.None)
                        }
                      }
                      .width('100%')
                      .aspectRatio(1)
                      .borderRadius(4)
                      .clip(true)
                      .onClick(() => {
                        if (this.selectMode) {
                          if (this.selectedHandles.has(photo.handle)) {
                            this.selectedHandles.delete(photo.handle);
                          } else {
                            this.selectedHandles.add(photo.handle);
                          }
                          this.selectedHandles = new Set(this.selectedHandles);
                        } else {
                          // Find by handle, not reference (ArkTS @Prop copies objects)
                          let idx = 0;
                          for (let i = 0; i < this.photos.length; i++) {
                            if (this.photos[i].handle === photo.handle) { idx = i; break; }
                          }
                          this.onThumbClick(photo, idx);
                        }
                      })
                      .gesture(
                        LongPressGesture({ repeat: false, duration: 500 })
                          .onAction(() => {
                            if (!this.selectMode) {
                              this.selectMode = true;
                              this.selectedHandles.add(photo.handle);
                              this.selectedHandles = new Set(this.selectedHandles);
                            }
                          })
                      )
                    }
                    .width(this.itemWidth())
                    .margin({ right: this.itemMargin(), bottom: 4 })
                  }, (photo: PhotoEntry) => photo.handle.toString())
                }
                .width('100%')
              }
              .width('100%')
              .margin({ bottom: 10 })
            }, (group: DateGroup, gi: number) => `${gi}_${group.dateLabel}_${group.photos.length}`)
          }
          .width('100%').padding({ left: 6, right: 6, bottom: 16 })
        }
        .width('100%').layoutWeight(1)
        .parallelGesture(
          GestureGroup(GestureMode.Parallel,
            TapGesture({ count: 2 }).onAction(() => {
              this.galleryScale = 1.0;
            }),
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.pinchBaseScale = this.galleryScale;
              })
              .onActionUpdate((event: GestureEvent) => {
                const s = this.pinchBaseScale * event.scale;
                this.galleryScale = Math.max(0.4, Math.min(6.0, s));
              })
          )
        )
      }

      if (this.selectMode) {
        SelectionActionBar({
          selectedCount: this.selectedHandles.size,
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
          }
        })
      }
    }
    .width('100%').height('100%')
  }
}
