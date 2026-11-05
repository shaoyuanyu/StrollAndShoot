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

  @Monitor('svc.cachingDialogRequired')
  onCachingDialogRequired(): void {
    if (!this.svc.cachingDialogRequired) return;
    const camId = this.svc.pendingCamIdForDialog;
    const camName = this.svc.pendingCamNameForDialog;
    if (!camId) return;
    this.getUIContext().showAlertDialog({
      title: '发现新相机',
      message: `检测到新相机「${camName}」，是否启用缩略图缓存？\n\n启用后下次连接时将直接从本地加载缩略图，大幅提升加载速度。`,
      autoCancel: false,
      primaryButton: {
        value: '不缓存',
        action: () => {
          this.svc.setCachingPreference(camId, false);
        }
      },
      secondaryButton: {
        value: '启用缓存',
        fontColor: $r('app.color.primary'),
        action: () => {
          this.svc.setCachingPreference(camId, true);
        }
      }
    });
  }

  aboutToAppear(): void {
    // Initialize the global BuilderNode for shared element transitions
    createMyNode(this.getUIContext());

    // Subscribe to GPS state changes
    this.gpsRecorder.onChange = () => { this.syncGpsState(); };
    this.syncGpsState();
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

  @Builder
  TabItem(label: string, icon: Resource, index: number) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([this.currentTab === index
          ? $r('app.color.primary') : $r('app.color.text_tertiary')])
      Text(label)
        .fontSize(10)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.currentTab === index
          ? $r('app.color.primary') : $r('app.color.text_tertiary'))
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    NavDestination() {
      Tabs({ index: this.currentTab, controller: this.tabsController, barPosition: BarPosition.End }) {
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
              const thumbRect = ComponentAttrUtils.getRectInfoById(
                this.getUIContext(), `thumb_${handle}`);
              if (thumbRect) {
                cardItemInfoStr = JSON.stringify(thumbRect);
                this.svc.getLog().add(`thumbPos handle=${handle} rect=${cardItemInfoStr}`);
              } else {
                this.svc.getLog().add(`thumbPos MISS handle=${handle}`);
              }

              // 2. Populate the global BuilderNode with this thumbnail
              const pm = this.svc.thumbnailPixelMapMap.get(handle);
              if (pm) {
                const node = getMyNode();
                if (node) {
                  node.setPixelMap(this.getUIContext(), pm);
                }
              }

              // 3. Cache positions around the tapped item so the pop animation can
              //    restore the shared element from a known rect. Only a window is
              //    cached — any handle outside it falls back to a live query below,
              //    so correctness is kept without an O(n) scan on every tap.
              const posCache: Record<string, string> = {};
              const winStart = Math.max(0, index - 40);
              const winEnd = Math.min(_displayGroups.length, index + 41);
              for (let i = winStart; i < winEnd; i++) {
                const h = _displayGroups[i].displayPhoto.handle;
                const r = ComponentAttrUtils.getRectInfoById(
                  this.getUIContext(), `thumb_${h}`);
                if (r) {
                  posCache[String(h)] = JSON.stringify(r);
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
                const r = ComponentAttrUtils.getRectInfoById(
                  this.getUIContext(), `thumb_${targetHandle}`);
                if (r) {
                  const s = JSON.stringify(r);
                  this.svc.getLog().add(`posLookup handle=${targetHandle} rect=${s}`);
                  return s;
                }
                this.svc.getLog().add(`posLookup MISS handle=${targetHandle}`);
                return '';
              };
              this.pageInfos.pushPath({ name: 'PhotoViewerScreen', param: pushParam });
            },
            onDownloadSelected: async (handles: number[]) => {
              if (handles.length === 0) return;
              if (this.svc.scanning) {
                this.svc.getLog().add('扫描中，跳过下载');
                return;
              }
              this.svc.cancelPreload();
              this.svc.getLog().add(`选中 ${handles.length} 张照片，开始下载`);
              this.syncDownloadedKeys();

              try {
                const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
                if (!ctx) {
                  this.svc.getLog().add('下载失败: 无法获取应用上下文');
                  this.downloadProgress = null;
                  return;
                }
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
        .tabBar(this.TabItem('画廊', $r('sys.symbol.square_grid_2x2'), 0))

        TabContent() {
          CameraPage({
            onScan: (quick: boolean) => { this.svc.scanForCamera(quick); },
            onDisconnect: () => { this.svc.disconnect(); this.syncDownloadedKeys(); }
          })
        }
        .tabBar(this.TabItem('相机', $r('sys.symbol.camera'), 1))

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
            onGpsClear: () => { this.clearGpsRecords(); },
            onOpenGpsManagement: () => { this.pageInfos.pushPath({ name: 'GpsManagementPage' }); },
            onOpenCacheManagement: () => { this.pageInfos.pushPath({ name: 'CacheManagementPage' }); }
          })
        }
        .tabBar(this.TabItem('设置', $r('sys.symbol.gearshape'), 2))
      }
      .barHeight(64)
      .barMode(BarMode.Fixed)
      .barBackgroundColor($r('app.color.tab_bar_bg'))
      .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .animationDuration(220)
      .scrollable(false)
      .onChange((idx: number) => {
        this.currentTab = idx;
        if (idx === 2) { this.logText = this.svc.getLog().getText(); }
      })
      .width('100%').height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
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
