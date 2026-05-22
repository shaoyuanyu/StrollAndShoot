import { pasteboard } from '@kit.BasicServicesKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { CameraService } from '../services/CameraService';
import { GpsRecorder } from '../services/GpsRecorder';
import { ExifGeotagger } from '../services/ExifGeotagger';
import { GalleryPage } from './GalleryPage';
import { CameraPage } from './CameraPage';
import { SettingsPage } from './SettingsPage';
import type { PhotoEntry, DownloadProgress } from '../model/PhotoEntry';
import { AppLog } from '../services/AppLog';

const DARK_MODE_KEY = 'dark_mode_pref';
const TABS: string[] = ['Gallery', 'Camera', 'Settings'];

function tabLabel(key: string): string {
  if (key === 'Gallery') return '画廊';
  if (key === 'Camera') return '相机';
  return '设置';
}

@Entry
@Component
struct Index {
  private tabsController: TabsController = new TabsController();
  private service: CameraService = CameraService.getInstance();
  private appLog: AppLog = this.service.getLog();
  private uiContext: common.UIAbilityContext | null = null;
  @State currentTab: number = 1;
  @State statusText: string = '就绪';
  @State cameraName: string = '';
  @State photoCount: number = 0;
  @State photos: PhotoEntry[] = [];
  @State scanning: boolean = false;
  @State connected: boolean = false;
  @State logText: string = '';
  @State thumbnailVersion: number = 0;
  @State thumbnailReadyHandles: number[] = [];
  @State downloadProgress: DownloadProgress | null = null;
  @State downloadedKeys: string[] = [];
  @State gpsRunning: boolean = false;
  @State gpsRecordCount: number = 0;
  @State gpsMode: number = 2;
  @State scanProgress: number = 0;
  @State scanTotal: number = 0;
  private gpsRecorder: GpsRecorder = GpsRecorder.getInstance();

  onPageShow(): void {
    // Restore onChange in case another page overwrote it (e.g. GpsManagementPage)
    this.gpsRecorder.onChange = () => { this.syncGpsState(); };
    this.syncGpsState();
    this.syncState();
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.uiContext = ctx;

    // Persist dark mode across restarts
    PersistentStorage.persistProp(DARK_MODE_KEY, ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    const savedMode = AppStorage.get<number>(DARK_MODE_KEY);

    // Persist gallery column count across restarts (-1 = auto)
    PersistentStorage.persistProp('gallery_column_count', -1);
    if (savedMode !== undefined && savedMode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
      this.applyDarkMode(savedMode);
    }

    this.service.initLogPath(ctx.filesDir);
    this.service.initDownloadDir(ctx.filesDir);
    this.service.onChange = () => { this.syncState(); };

    // Init GPS recorder and geotagger; auto-start if it was running last time
    this.gpsRecorder.init(ctx.filesDir, this.appLog, ctx);
    this.gpsRecorder.onChange = () => { this.syncGpsState(); };
    ExifGeotagger.setLog(this.appLog);
    this.syncGpsState();
    this.gpsRecorder.autoStart();

    this.syncState();
  }

  syncState(): void {
    this.statusText = this.service.statusText;
    this.cameraName = this.service.cameraName;
    this.photoCount = this.service.photoCount;
    this.photos = this.service.photos;
    this.scanning = this.service.scanning;
    this.connected = this.service.connected;
    this.logText = this.appLog.getText();
    this.thumbnailVersion++;
    // Build array of handles that have thumbnails ready
    const handles: number[] = [];
    this.service.thumbnailPixelMapMap.forEach((_v: Object, k: number) => { handles.push(k); });
    this.thumbnailReadyHandles = handles;
    this.downloadedKeys = this.service.getDownloadedKeys();
    this.scanProgress = this.service.scanProgress;
    this.scanTotal = this.service.scanTotal;
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
    this.tabsController.changeIndex(idx);
  }

  build() {
    Column() {
      Tabs({ index: 1, controller: this.tabsController }) {
        TabContent() {
          GalleryPage({
            connected: this.connected, cameraName: this.cameraName,
            photoCount: this.photoCount, statusText: this.statusText,
            photos: this.photos,
            thumbnailVersion: this.thumbnailVersion,
            thumbnailReadyHandles: this.thumbnailReadyHandles,
            downloadProgress: this.downloadProgress,
            downloadedKeys: this.downloadedKeys,
            scanProgress: this.scanProgress, scanTotal: this.scanTotal,
            onThumbClick: (photos: PhotoEntry[], index: number) => {
              router.pushUrl({
                url: 'pages/PhotoDetailPage',
                params: { photos: photos, initialIndex: index }
              });
            },
            onDownloadSelected: async (handles: number[]) => {
              if (handles.length === 0) return;
              this.service.cancelPreload();
              this.appLog.add(`选中 ${handles.length} 张照片，开始下载`);
              this.syncState();

              try {
                await this.service.downloadPhotos(
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

                this.downloadedKeys = this.service.getDownloadedKeys();
                this.syncState();

                setTimeout(() => {
                  this.downloadProgress = null;
                  this.syncState();
                }, 2000);
              } catch (err) {
                this.appLog.add(`下载异常: ${JSON.stringify(err)}`);
                this.downloadProgress = null;
                this.syncState();
              }
            },
            onCancelDownload: () => {
              this.service.cancelDownload();
              this.downloadProgress = null;
              this.syncState();
            }
          })
        }

        TabContent() {
          CameraPage({
            connected: this.connected, cameraName: this.cameraName,
            photoCount: this.photoCount, statusText: this.statusText,
            scanning: this.scanning,
            scanProgress: this.scanProgress, scanTotal: this.scanTotal,
            onScan: () => { this.service.scanForCamera(); },
            onDisconnect: () => { this.service.disconnect(); this.syncState(); }
          })
        }

        TabContent() {
          SettingsPage({
            logText: this.logText,
            gpsRunning: this.gpsRunning,
            gpsRecordCount: this.gpsRecordCount,
            gpsMode: this.gpsMode,
            onClear: () => { this.appLog.clear(); this.syncState(); },
            onCopy: () => {
              const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);
              pasteboard.getSystemPasteboard().setData(data);
              this.appLog.add('日志已复制到剪贴板');
              this.syncState();
            },
            onDarkModeChange: (mode: number) => { this.applyDarkMode(mode); },
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
        ForEach(TABS, (key: string, idx: number) => {
          Text(tabLabel(key))
            .fontSize(16)
            .fontWeight(this.currentTab === idx ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.currentTab === idx ? $r('app.color.primary') : $r('app.color.text_secondary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 12, bottom: 12 })
            .onClick(() => { this.switchToTab(idx); })
        })
      }
      .width('100%').height(56)
      .backgroundColor($r('app.color.tab_bar_bg'))
    }
    .width('100%').height('100%')
  }
}
