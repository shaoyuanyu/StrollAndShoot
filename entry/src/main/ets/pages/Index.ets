import { pasteboard } from '@kit.BasicServicesKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { CameraService } from '../services/CameraService';
import { GpsRecorder } from '../services/GpsRecorder';
import { ExifGeotagger } from '../services/ExifGeotagger';
import { GalleryPage } from './GalleryPage';
import { CameraPage } from './CameraPage';
import { SettingsPage } from './SettingsPage';
import type { DownloadProgress, DisplayGroup } from '../model/PhotoEntry';
import { SettingsStore } from '../model/SettingsStore';


const TABS: string[] = ['Gallery', 'Camera', 'Settings'];

function tabLabel(key: string): string {
  if (key === 'Gallery') return '画廊';
  if (key === 'Camera') return '相机';
  return '设置';
}

@Entry
@ComponentV2
struct Index {
  private tabsController: TabsController = new TabsController();
  private uiContext: common.UIAbilityContext | null = null;
  private gpsRecorder: GpsRecorder = GpsRecorder.getInstance();
  @Local svc: CameraService = CameraService.getInstance();
  @Local currentTab: number = 1;
  @Local logText: string = '';
  @Local downloadProgress: DownloadProgress | null = null;
  @Local downloadedKeys: string[] = [];
  @Local gpsRunning: boolean = false;
  @Local gpsRecordCount: number = 0;
  @Local gpsMode: number = 2;
  @Local settings: SettingsStore = SettingsStore.getInstance();

  onPageShow(): void {
    this.svc.getLog().add('PERF onPageShow START');
    this.gpsRecorder.onChange = () => { this.syncGpsState(); };
    this.syncGpsState();
    this.syncDownloadedKeys();
    this.svc.getLog().add('PERF onPageShow END');
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.uiContext = ctx;

    if (this.settings.darkMode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
      this.applyDarkMode(this.settings.darkMode);
    }

    this.svc.initLogPath(ctx.filesDir);
    this.svc.initDownloadDir(ctx.filesDir);

    this.gpsRecorder.init(ctx.filesDir, this.svc.getLog(), ctx);
    this.gpsRecorder.onChange = () => { this.syncGpsState(); };
    ExifGeotagger.setLog(this.svc.getLog());
    this.syncGpsState();
    this.gpsRecorder.autoStart();

    this.syncDownloadedKeys();
  }

  @Monitor('settings.darkMode')
  onDarkModeChange(mon: IMonitor) {
    const mode = mon.value()?.now as number;
    if (mode !== undefined) {
      this.applyDarkMode(mode);
    }
  }

  syncDownloadedKeys(): void {
    this.downloadedKeys = this.svc.getDownloadedKeys();
  }

  syncGpsState(): void {
    this.gpsRunning = this.gpsRecorder.isRunning();
    this.gpsRecordCount = this.gpsRecorder.recordCount();
    this.gpsMode = this.gpsRecorder.getGpsMode();
  }

  async toggleGps(): Promise<void> {
    if (this.gpsRecorder.isRunning()) {
      this.gpsRecorder.stop();
    } else {
      await this.gpsRecorder.start();
    }
    this.syncGpsState();
  }

  async changeGpsMode(mode: number): Promise<void> {
    await this.gpsRecorder.setGpsMode(mode);
    this.syncGpsState();
  }

  clearGpsRecords(): void {
    this.gpsRecorder.clearRecords();
    this.syncGpsState();
  }

  applyDarkMode(mode: number): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      ctx.getApplicationContext().setColorMode(mode);
    } catch (_e) { /* ignore */ }
  }

  switchToTab(idx: number): void {
    this.currentTab = idx;
    if (idx === 2) { this.logText = this.svc.getLog().getText(); }
    this.tabsController.changeIndex(idx);
  }

  build() {
    Column() {
      // ---- TEMP: Swiper sync test entry ----
      Row() {
        Blank()
        Button('[TEST] Swiper Sync')
          .fontSize(11).height(28)
          .backgroundColor('#FF6B6B')
          .borderRadius(4)
          .onClick(() => { router.pushUrl({ url: 'pages/SwiperSyncTestPage' }); })
      }
      .width('100%').padding({ right: 8, top: 4 })
      .backgroundColor('#222')
      // ---- END TEMP ----

      Tabs({ index: 1, controller: this.tabsController }) {
        TabContent() {
          GalleryPage({
            downloadProgress: this.downloadProgress,
            downloadedKeys: this.downloadedKeys,
            galleryColumnCount: this.settings.galleryColumnCount,
            displayMode: this.settings.displayMode,
            onThumbClick: (_displayGroups: DisplayGroup[], index: number) => {
              const handle = _displayGroups[index].displayPhoto.handle;
              // _displayGroups is already in gallery visual order (sorted by captureDate DESC
              // in allDisplayGroups()), so handles/index match the visual position directly.
              const handles: number[] = [];
              for (const g of _displayGroups) {
                handles.push(g.displayPhoto.handle);
              }
              router.pushUrl({
                url: 'pages/PhotoViewer',
                params: { handle: handle, handles: handles, startIndex: index }
              });
            },
            onDownloadSelected: async (handles: number[]) => {
              if (handles.length === 0) return;
              this.svc.cancelPreload();
              this.svc.getLog().add(`选中 ${handles.length} 张照片，开始下载`);
              this.syncDownloadedKeys();

              try {
                await this.svc.downloadPhotos(
                  handles,
                  (progress: DownloadProgress) => {
                    this.downloadProgress = {
                      phase: progress.phase,
                      currentIndex: progress.currentIndex,
                      totalCount: progress.totalCount,
                      currentFilename: progress.currentFilename,
                      currentSizeBytes: progress.currentSizeBytes,
                      downloadedCount: progress.downloadedCount,
                      totalBytes: progress.totalBytes,
                      downloadedBytes: progress.downloadedBytes,
                      errors: progress.errors
                    };
                  },
                  this.uiContext!
                );

                this.downloadedKeys = this.svc.getDownloadedKeys();
                this.syncDownloadedKeys();

                setTimeout(() => {
                  this.downloadProgress = null;
                  this.syncDownloadedKeys();
                }, 2000);
              } catch (err) {
                this.svc.getLog().add(`下载异常: ${JSON.stringify(err)}`);
                this.downloadProgress = null;
                this.syncDownloadedKeys();
              }
            },
            onCancelDownload: () => {
              this.svc.cancelDownload();
              this.downloadProgress = null;
              this.syncDownloadedKeys();
            }
          })
        }

        TabContent() {
          CameraPage({
            onScan: () => { this.svc.scanForCamera(); },
            onDisconnect: () => { this.svc.disconnect(); this.syncDownloadedKeys(); }
          })
        }

        TabContent() {
          SettingsPage({
            logText: this.logText,
            gpsRunning: this.gpsRunning,
            gpsRecordCount: this.gpsRecordCount,
            gpsMode: this.gpsMode,
            onClear: () => { this.svc.getLog().clear(); this.syncDownloadedKeys(); },
            onCopy: () => {
              const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);
              pasteboard.getSystemPasteboard().setData(data);
              this.svc.getLog().add('日志已复制到剪贴板');
              this.syncDownloadedKeys();
            },
            onGpsToggle: () => { this.toggleGps(); },
            onGpsModeChange: (mode: number) => { this.changeGpsMode(mode); },
            onGpsClear: () => { this.clearGpsRecords(); }
          })
        }
      }
      .barHeight(0)
      .scrollable(false)
      .onChange((idx: number) => { this.currentTab = idx; })
      .layoutWeight(1)

      Row() {
        Repeat<string>(TABS)
          .each((ri: RepeatItem<string>) => {
            Text(tabLabel(ri.item))
              .fontSize(16)
              .fontWeight(this.currentTab === ri.index ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.currentTab === ri.index ? $r('app.color.primary') : $r('app.color.text_secondary'))
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .padding({ top: 12, bottom: 12 })
              .onClick(() => { this.switchToTab(ri.index); })
          })
          .key((item: string) => item)
      }
      .width('100%').height(56)
      .backgroundColor($r('app.color.tab_bar_bg'))
    }
    .width('100%').height('100%')
  }
}
