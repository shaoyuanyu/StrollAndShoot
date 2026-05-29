/**
 * CacheManagementPage.ets
 *
 * Settings sub-page showing all cameras that have been connected,
 * their thumbnail cache sizes, and per-camera caching toggles.
 */
import { router } from '@kit.ArkUI';
import { CameraCachePrefs, type CameraCachePref } from '../services/CameraCachePrefs';
import { ThumbnailCache, type CacheInfo } from '../services/ThumbnailCache';

@Entry
@ComponentV2
struct CacheManagementPage {
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
    AlertDialog.show({
      title: '删除缓存',
      message: `删除「${friendlyName}」的所有缓存缩略图？此操作不可恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E84026',
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
    AlertDialog.show({
      title: '清除所有缓存',
      message: `删除全部 ${total} 个相机的缩略图缓存？此操作不可恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '全部清除',
        fontColor: '#E84026',
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
    if (!iso) return '';
    try {
      const d = new Date(iso);
      return `${d.getFullYear()}-${(d.getMonth() + 1).toString().padStart(2, '0')}-${d.getDate().toString().padStart(2, '0')}`;
    } catch (_e) {
      return iso.substring(0, 10);
    }
  }

  build() {
    Column() {
      // Header
      Row() {
        Button({ type: ButtonType.Circle }) {
          Text('←').fontSize(18)
        }
        .width(36).height(36)
        .backgroundColor($r('app.color.bg_surface'))
        .onClick(() => { router.back(); })

        Text('缓存管理')
          .fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 10 })

        Blank()

        Text(`共 ${this.formatSize(this.totalCacheSize)}`)
          .fontSize(13).fontColor($r('app.color.text_secondary'))
      }
      .width('100%').padding({ left: 12, right: 12, top: 12, bottom: 8 })

      if (this.cameras.length === 0) {
        Column() {
          Text('暂无缓存记录')
            .fontSize(14).fontColor($r('app.color.text_secondary'))
            .margin({ top: 80 })
          Text('连接相机并启用缓存后将在此显示')
            .fontSize(12).fontColor($r('app.color.text_secondary'))
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
                        .fontSize(15).fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                      Text(`${ri.item.entryCount} 张 | ${this.formatSize(ri.item.cacheSizeBytes)} | 上次连接: ${this.formatDate(ri.item.lastSeen)}`)
                        .fontSize(12).fontColor($r('app.color.text_secondary'))
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
                      Text('🗑').fontSize(16)
                    }
                    .width(32).height(32)
                    .backgroundColor($r('app.color.bg_page'))
                    .onClick(() => {
                      this.deleteCameraCache(ri.item.cameraId, ri.item.friendlyName);
                    })
                  }
                  .width('100%')
                }
                .width('100%').padding(14)
              }
            })
            .key((item: CacheDisplayItem) => item.cameraId)
        }
        .width('100%').layoutWeight(1)
      }

      // Bottom: clear all button
      if (this.cameras.length > 0) {
        Button('清除所有缓存')
          .width('90%').margin({ bottom: 20, top: 8 })
          .fontColor('#E84026')
          .backgroundColor($r('app.color.bg_surface'))
          .onClick(() => { this.clearAllCaches(); })
      }
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.bg_page'))
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
