import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { CameraService } from '../services/CameraService';
import { GalleryPage } from './GalleryPage';
import { CameraPage } from './CameraPage';
import { SettingsPage } from './SettingsPage';
import type { PhotoEntry } from '../model/PhotoEntry';
import { AppLog } from '../services/AppLog';

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

  aboutToAppear(): void {
    // Init log file path for persistence
    const ctx = getContext(this) as common.UIAbilityContext;
    this.service.initLogPath(ctx.filesDir);
    this.service.onChange = () => { this.syncState(); };
    this.syncState();
    // DDK availability test
    try {
      const devices = deviceManager.queryDevices(1); // BusType.USB = 1
      this.appLog.add(`DDK OK: ${devices.length}`);
    } catch (e) {
      this.appLog.add('DDK crashed: ' + e);
    }
    try {
      const devices2 = deviceManager.queryDevices();
      this.appLog.add(`DDK noarg: ${devices2.length}`);
    } catch (e) {
      this.appLog.add('DDK noarg crashed: ' + e);
    }
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
            onThumbClick: (photo: PhotoEntry, index: number) => {
              router.pushUrl({
                url: 'pages/PhotoDetailPage',
                params: { photos: this.photos, initialIndex: index }
              });
            },
            onDownloadSelected: (handles: number[]) => {
              this.appLog.add(`选中 ${handles.length} 张照片准备下载`);
              this.syncState();
            }
          })
        }

        TabContent() {
          CameraPage({
            connected: this.connected, cameraName: this.cameraName,
            photoCount: this.photoCount, statusText: this.statusText,
            scanning: this.scanning,
            onScan: () => { this.service.scanForCamera(); },
            onDisconnect: () => { this.service.disconnect(); this.syncState(); }
          })
        }

        TabContent() {
          SettingsPage({
            logText: this.logText,
            onClear: () => { this.appLog.clear(); this.syncState(); },
            onCopy: () => {
              const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);
              pasteboard.getSystemPasteboard().setData(data);
              this.appLog.add('日志已复制到剪贴板');
              this.syncState();
            },
            onDarkModeChange: (mode: number) => { this.applyDarkMode(mode); }
          })
        }
      }
      .barHeight(0)
      .scrollable(true)
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
