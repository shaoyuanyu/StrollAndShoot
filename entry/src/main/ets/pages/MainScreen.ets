import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { CameraService } from '../services/CameraService';
import { GpsRecorder } from '../services/GpsRecorder';
import { ExifGeotagger } from '../services/ExifGeotagger';
import { GalleryPage } from './GalleryPage';
import { CameraPage } from './CameraPage';
import { SettingsPage } from './SettingsPage';
import type { DownloadProgress, DisplayGroup } from '../model/PhotoEntry';
import { SettingsStore } from '../model/SettingsStore';
import { CustomTransition } from '../CustomTransition/CustomNavigationUtils';
import { ComponentAttrUtils } from '../utils/ComponentAttrUtils';
import { createMyNode, getMyNode } from '../NodeContainer/CustomComponent';
import type { MyNodeController } from '../NodeContainer/CustomComponent';

const TABS: string[] = ['Gallery', 'Camera', 'Settings'];

function tabLabel(key: string): string {
  if (key === 'Gallery') return '画廊';
  if (key === 'Camera') return '相机';
  return '设置';
}

@Builder
export function MainScreenBuilder() {
  MainScreen();
}

@ComponentV2
export struct MainScreen {
  private pageInfos: NavPathStack = new NavPathStack();
  private pageId: number = -1;
  private tabsController: TabsController = new TabsController();
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
  @Local gallerySelectMode: boolean = false;
  @Local exitSelectModeVersion: number = 0;

  @Monitor('svc.photosVersion')
  onPhotosChanged(): void {
    this.syncDownloadedKeys();
  }

  aboutToAppear(): void {
    // Initialize the global BuilderNode for shared element transitions
    createMyNode(this.getUIContext());

    // Subscribe to GPS state changes
    this.gpsRecorder.onChange = () => { this.syncGpsState(); };
    this.syncGpsState();
    this.syncDownloadedKeys();

    // Subscribe to download state
    this.syncDownloadedKeys();
  }

  onPageShow(): void {
    this.gpsRecorder.onChange = () => { this.syncGpsState(); };
    this.syncGpsState();
    this.syncDownloadedKeys();
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

  switchToTab(idx: number): void {
    this.currentTab = idx;
    if (idx === 2) { this.logText = this.svc.getLog().getText(); }
    this.tabsController.changeIndex(idx);
  }

  build() {
    NavDestination() {
      Tabs({ index: 1, controller: this.tabsController }) {
        TabContent() {
          GalleryPage({
            downloadProgress: this.downloadProgress,
            downloadedKeys: this.downloadedKeys,
            galleryColumnCount: this.settings.galleryColumnCount,
            displayMode: this.settings.displayMode,
            onSelectModeChange: (v: boolean) => { this.gallerySelectMode = v; },
            exitSelectModeVersion: this.exitSelectModeVersion,
            onThumbClick: (_displayGroups: DisplayGroup[], index: number) => {
              const handle = _displayGroups[index].displayPhoto.handle;
              // Build handles array from visual order
              const handles: number[] = [];
              for (const g of _displayGroups) {
                handles.push(g.displayPhoto.handle);
              }

              // 1. Capture thumbnail position for shared-element animation
              let cardItemInfoStr: string = '';
              try {
                const rect = ComponentAttrUtils.getRectInfoById(
                  this.getUIContext(), `thumb_${handle}`);
                cardItemInfoStr = JSON.stringify(rect);
                this.svc.getLog().add(`thumbPos handle=${handle} rect=${JSON.stringify(rect)}`);
              } catch (_err) {
                this.svc.getLog().add(`thumbPos FAIL handle=${handle} err=${_err}`);
                // Fallback: empty rect → no animation
              }

              // 2. Populate the global BuilderNode with this thumbnail
              const pm = this.svc.thumbnailPixelMapMap.get(handle);
              if (pm) {
                const node = getMyNode();
                if (node) {
                  node.setPixelMap(this.getUIContext(), pm);
                }
              }

              // 3. Cache positions for all handles in the current viewport
              //    (so PhotoViewerScreen can look them up at pop time without
              //     relying on getRectInfoById on a possibly-stale layout).
              const posCache: Record<string, string> = {};
              for (const g of _displayGroups) {
                const h = g.displayPhoto.handle;
                try {
                  const r = ComponentAttrUtils.getRectInfoById(
                    this.getUIContext(), `thumb_${h}`);
                  posCache[String(h)] = JSON.stringify(r);
                } catch (_e) {
                  // skip — not in viewport
                }
              }

              // 4. Push PhotoViewer via Navigation (not router)
              const pushParam: Record<string, Object> = {};
              pushParam['handle'] = handle;
              pushParam['handles'] = handles;
              pushParam['startIndex'] = index;
              pushParam['cardItemInfo'] = cardItemInfoStr;
              pushParam['posCache'] = JSON.stringify(posCache);
              pushParam['doDefaultTransition'] = (_controller: MyNodeController) => {
                // Gallery uses regular Image components — nothing to restore
              };
              pushParam['positionLookup'] = (targetHandle: number): string => {
                // Fallback: use cached position if available
                const cached = posCache[String(targetHandle)];
                if (cached) return cached;
                try {
                  const r = ComponentAttrUtils.getRectInfoById(
                    this.getUIContext(), `thumb_${targetHandle}`);
                  const s = JSON.stringify(r);
                  this.svc.getLog().add(`posLookup handle=${targetHandle} rect=${s}`);
                  return s;
                } catch (_err) {
                  this.svc.getLog().add(`posLookup FAIL handle=${targetHandle} err=${_err}`);
                  return '';
                }
              };
              this.pageInfos.pushPath({ name: 'PhotoViewerScreen', param: pushParam });
            },
            onDownloadSelected: async (handles: number[]) => {
              if (handles.length === 0) return;
              this.svc.cancelPreload();
              this.svc.getLog().add(`选中 ${handles.length} 张照片，开始下载`);
              this.syncDownloadedKeys();

              try {
                const ctx = getContext(this) as common.UIAbilityContext;
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
                  ctx
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
    .onBackPressed(() => {
      if (this.currentTab === 0 && this.gallerySelectMode) {
        this.exitSelectModeVersion++;
        this.gallerySelectMode = false;
        return true;
      }
      return false;
    })
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
      this.pageId = this.pageInfos.getAllPathName().length - 1;
      // Register empty callback to enable custom transitions from this page
      CustomTransition.getInstance().registerNavParam(this.pageId,
        (_isPush: boolean, _isExit: boolean, _proxy: NavigationTransitionProxy) => {}, 500);
    })
    .onDisAppear(() => {
      CustomTransition.getInstance().unRegisterNavParam(this.pageId);
    })
  }
}
