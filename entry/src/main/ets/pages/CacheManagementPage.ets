/**
 * CacheManagementPage.ets
 *
 * Settings sub-page showing all cameras that have been connected,
 * their thumbnail cache sizes, and per-camera caching toggles.
 */
import { PageHeader } from '../components/PageHeader';
import { CameraCachePrefs, type CameraCachePref } from '../services/CameraCachePrefs';
import { ThumbnailCache, type CacheInfo } from '../services/ThumbnailCache';
import { L10n } from '../utils/L10n';
import { formatIsoDate } from '../utils/DateTimeText';
import { FontSize, IconSize, Radius } from '../utils/UiTokens';

@Builder
export function CacheManagementPageBuilder() {
  CacheManagementPage();
}

@ComponentV2
export struct CacheManagementPage {
  private pageInfos: NavPathStack = new NavPathStack();
  private cachePrefs: CameraCachePrefs = CameraCachePrefs.getInstance();
  @Local cameras: CacheDisplayItem[] = [];
  @Local totalCacheSize: number = 0;
  @Local refreshing: boolean = false;

  aboutToAppear(): void {
    this.refresh();
  }

  async refresh(): Promise<void> {
    this.refreshing = true;
    const prefs = this.cachePrefs.getAll();
    const items: CacheDisplayItem[] = [];
    let total = 0;
    const fd = this.cachePrefs.filesDir;

    for (const pref of prefs) {
      const info: CacheInfo = await ThumbnailCache.getCameraCacheInfo(fd, pref.cameraId);
      total += info.sizeBytes;
      items.push({
        cameraId: pref.cameraId,
        friendlyName: pref.friendlyName,
        cachingEnabled: pref.cachingEnabled,
        cacheSizeBytes: info.sizeBytes,
        entryCount: info.entryCount,
        lastSeen: pref.lastSeen
      });
    }

    this.cameras = items;
    this.totalCacheSize = total;
    this.refreshing = false;
  }

  toggleCaching(cameraId: string, enabled: boolean): void {
    const pref = this.cachePrefs.get(cameraId);
    if (pref) {
      this.cachePrefs.set(cameraId, pref.friendlyName, enabled);
      this.refresh();
    }
  }

  deleteCameraCache(cameraId: string, friendlyName: string): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.cache_delete_title'),
      message: $r('app.string.cache_delete_message', friendlyName),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: () => {}
      },
      secondaryButton: {
        value: $r('app.string.common_delete'),
        fontColor: $r('app.color.button_danger'),
        action: async () => {
          this.cachePrefs.delete(cameraId);
          await ThumbnailCache.deleteCameraCache(this.cachePrefs.filesDir, cameraId);
          this.refresh();
        }
      }
    });
  }

  clearAllCaches(): void {
    const total = this.cameras.length;
    if (total === 0) return;
    this.getUIContext().showAlertDialog({
      title: $r('app.string.cache_clear_all_title'),
      message: $r('app.string.cache_clear_all_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: () => {}
      },
      secondaryButton: {
        value: $r('app.string.cache_clear_all_button'),
        fontColor: $r('app.color.button_danger'),
        action: async () => {
          const all = this.cachePrefs.getAll();
          for (const c of all) {
            await ThumbnailCache.deleteCameraCache(this.cachePrefs.filesDir, c.cameraId);
          }
          this.cachePrefs.clearAll();
          this.refresh();
        }
      }
    });
  }

  formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }

  formatDate(iso: string): string {
    return formatIsoDate(iso);
  }

  build() {
    NavDestination() {
      Column() {
        PageHeader({
          title: $r('app.string.cache_title'),
          subtitle: $r('app.string.cache_total_size', this.formatSize(this.totalCacheSize)),
          onBack: () => { this.pageInfos.pop(); }
        })

      if (this.cameras.length === 0) {
        Column() {
          Text($r('app.string.cache_empty'))
            .fontSize(FontSize.Body).fontColor($r('app.color.text_secondary'))
            .margin({ top: 80 })
          Text($r('app.string.cache_empty_hint'))
            .fontSize(FontSize.Caption).fontColor($r('app.color.text_secondary'))
            .margin({ top: 6 })
        }
        .width('100%').layoutWeight(1)
      } else {
        List() {
          Repeat<CacheDisplayItem>(this.cameras)
            .each((ri: RepeatItem<CacheDisplayItem>) => {
              ListItem() {
                Column() {
                  Row() {
                    // Camera info
                    Column() {
                      Text(ri.item.friendlyName)
                        .fontSize(FontSize.CardTitle).fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                      Text($r('app.string.cache_item_stats',
                        L10n.plural('photo_count', ri.item.entryCount, ri.item.entryCount),
                        this.formatSize(ri.item.cacheSizeBytes),
                        this.formatDate(ri.item.lastSeen)))
                        .fontSize(FontSize.Caption).fontColor($r('app.color.text_secondary'))
                        .margin({ top: 2 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    // Toggle
                    Toggle({ type: ToggleType.Switch, isOn: ri.item.cachingEnabled })
                      .onChange((on: boolean) => {
                        this.toggleCaching(ri.item.cameraId, on);
                      })
                      .margin({ right: 10 })

                    // Delete
                    Button({ type: ButtonType.Circle }) {
                      SymbolGlyph($r('sys.symbol.trash'))
                        .fontSize(IconSize.Body)
                        .fontColor([$r('app.color.button_danger')])
                    }
                    .width(32).height(32)
                    .backgroundColor($r('app.color.primary_soft'))
                    .onClick(() => {
                      this.deleteCameraCache(ri.item.cameraId, ri.item.friendlyName);
                    })
                  }
                  .width('100%')
                }
                .width('100%').padding(16)
                .backgroundColor($r('app.color.bg_surface'))
                .borderRadius(Radius.Card)
              }
              .margin({ bottom: 8 })
            })
            .key((item: CacheDisplayItem) => item.cameraId)
        }
        .width('100%').layoutWeight(1)
        .padding({ left: 16, right: 16, top: 8 })
        .scrollBar(BarState.Off)
      }

      // Bottom: clear all button
      if (this.cameras.length > 0) {
        Button($r('app.string.cache_clear_all_button'))
          .width('90%').height(44).margin({ bottom: 24, top: 8 })
          .fontSize(FontSize.Body)
          .fontColor($r('app.color.button_danger'))
          .backgroundColor($r('app.color.primary_soft'))
          .onClick(() => { this.clearAllCaches(); })
      }
      }
      .width('100%').height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}

interface CacheDisplayItem {
  cameraId: string;
  friendlyName: string;
  cachingEnabled: boolean;
  cacheSizeBytes: number;
  entryCount: number;
  lastSeen: string;
}
