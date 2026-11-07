import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';

import { CameraService } from '../services/CameraService';
import { ExifGeotagger } from '../services/ExifGeotagger';
import { HandednessService } from '../services/HandednessService';
import { GalleryPage } from './GalleryPage';
import { CameraPage } from './CameraPage';
import { SettingsPage } from './SettingsPage';
import { DownloadProgressBar } from '../components/DownloadProgressBar';
import { SelectionActionBar } from '../components/SelectionActionBar';
import type { DownloadProgress, DisplayGroup } from '../model/PhotoEntry';
import { SettingsStore } from '../model/SettingsStore';
import { CustomTransition } from '../CustomTransition/CustomNavigationUtils';
import { ComponentAttrUtils } from '../utils/ComponentAttrUtils';
import { TITLE_BAR_HEIGHT, titleBarInsetVp, titleBarTotalVp } from '../utils/TitleBarMetrics';
import { WindowUtils } from '../utils/WindowUtils';
import { getExt } from '../utils/PhotoGroupUtil';
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
  @Local svc: CameraService = CameraService.getInstance();
  @Local currentTab: number = 1;
  @Local logText: string = '';
  @Local downloadProgress: DownloadProgress | null = null;
  @Local downloadedKeys: string[] = [];
  @Local settings: SettingsStore = SettingsStore.getInstance();
  @Local gallerySelectMode: boolean = false;
  @Local galleryFilter: string = '';
  @Local exitSelectModeVersion: number = 0;
  @Local toggleSelectVersion: number = 0;
  /** 多选态：已选数量与可选项总数，由 GalleryPage 上报。 */
  @Local gallerySelectedCount: number = 0;
  @Local gallerySelectableCount: number = 0;
  /** 点标题栏「全选 / 取消全选」时递增，GalleryPage 监听后执行。 */
  @Local selectAllVersion: number = 0;
  /** 点底部操作栏「下载」时递增，GalleryPage 监听后执行。 */
  @Local downloadVersion: number = 0;
  @Local handedness: HandednessService = HandednessService.getInstance();

  /**
   * 浮岛材质。真·沉浸光感只能用在 Navigation 标题栏里，所以浮岛虽然画在
   * 屏幕中部 / 底部，本体必须挂在 TitleBar 的 builder 下（见 TitleBar 的浮岛层）。
   */
  private readonly floatMaterial: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      interactive: true
    });

  /** 三个标签页的滚动容器，绑给 NavDestination 驱动标题栏动态显隐。 */
  private galleryScroller: Scroller = new Scroller();
  private cameraScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 智感握姿：订阅握持手，下载浮岛贴到拇指易触及的一侧。
    // 机型不支持时服务内部会静默降级为固定右侧。
    HandednessService.getInstance().start();
  }

  aboutToDisappear(): void {
    HandednessService.getInstance().stop();
  }

  private tabTitle(): string {
    if (this.currentTab === 0) return '画廊';
    if (this.currentTab === 1) return '相机';
    return '设置';
  }

  /** 多选态标题文字：官方图库是「已选择 N 项」，左对齐跟在关闭钮后面。 */
  private selectTitleText(): string {
    return `已选择 ${this.gallerySelectedCount} 项`;
  }

  private allSelected(): boolean {
    return this.gallerySelectableCount > 0 &&
      this.gallerySelectedCount >= this.gallerySelectableCount;
  }

  /** 退出多选：通知画廊页清空选中集。 */
  private exitSelectMode(): void {
    this.exitSelectModeVersion++;
    this.gallerySelectMode = false;
  }

  private screenHeightVp(): number {
    const px = WindowUtils.windowHeightPx;
    return px > 0 ? px2vp(px) : 800;
  }

  private screenWidthVp(): number {
    const px = WindowUtils.windowWidthPx;
    return px > 0 ? px2vp(px) : 392;
  }

  private navIndicatorVp(): number {
    const px = WindowUtils.navigationIndicatorHeightPx;
    return px > 0 ? px2vp(px) : 0;
  }

  /** 照片里出现过的格式，'' 表示“全部”。 */
  private formatList(): string[] {
    const out: string[] = [''];
    const seen = new Set<string>();
    for (const p of this.svc.photos) {
      const ext = getExt(p.filename);
      if (ext !== '' && !seen.has(ext)) {
        seen.add(ext);
        out.push(ext);
      }
    }
    // 当前筛选值必须留在列表里：重新扫描后如果这种格式消失了，
    // 下拉的选中态和按钮文字才不会对不上（还能手动切回「全部」）。
    if (this.galleryFilter !== '' && !seen.has(this.galleryFilter)) {
      out.push(this.galleryFilter);
    }
    return out;
  }

  private filterLabel(): string {
    return this.galleryFilter === '' ? '全部' : this.galleryFilter;
  }

  /** 下拉筛选项：第 0 项永远是「全部」，后面按照片里出现过的格式排列。 */
  private filterOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    const list = this.formatList();
    for (const ext of list) {
      out.push({ value: ext === '' ? '全部' : ext });
    }
    return out;
  }

  private filterSelectedIndex(): number {
    const idx = this.formatList().indexOf(this.galleryFilter);
    return idx < 0 ? 0 : idx;
  }

  private applyFilterIndex(index: number): void {
    const list = this.formatList();
    if (index >= 0 && index < list.length) {
      this.galleryFilter = list[index];
    }
  }

  /**
   * 标题栏。
   *
   * 官方《沉浸光感》：「Navigation 标题栏支持通过 NavigationTitleOptions 中的
   * systemMaterial 字段设置沉浸光感效果」，且「组件开启沉浸光感的生效范围为
   * Navigation/NavDestination 标题栏」。因此背板材质必须由标题栏内的容器自己
   * 承载 —— 这里给整条 Row 设 systemMaterial，材质才会铺满整条标题栏（含状态栏）。
   */
  @Builder
  TitleBar() {
    Stack({ alignContent: Alignment.Top }) {
      // 压色：铺满整条标题栏（含标题下方 TITLE_FADE_EXTRA 的余量），平滑衰减到 0。
      // 磨砂不在这里做——backdropBlur 的边界是硬的，会留下一条泾渭分明的线；
      // 改用内容区的 linearGradientBlur（见下面的 Tabs）。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.nav_bg'), 0.0],
            [$r('app.color.nav_bg'), 0.20],
            [$r('app.color.nav_bg_mid'), 0.50],
            [$r('app.color.nav_bg_weak'), 0.78],
            [$r('app.color.bg_page_fade'), 1.0]
          ]
        })

      Column() {
        // 标题停在状态栏下方（渐隐区顶部），衰减在标题下方继续
        Blank().height(titleBarInsetVp() - TITLE_BAR_HEIGHT)

        if (this.currentTab === 0 && this.gallerySelectMode) {
          this.SelectTitleRow()
        } else {
          this.NormalTitleRow()
        }
      }
      .width('100%')

      // 浮岛层。
      //
      // 真·沉浸光感只在 Navigation/NavDestination 标题栏（或底部 TabBar）里生效，
      // 弹层虽然也能拿到材质，但会铺一层遮罩把整页点击吞掉（实测过，行不通）。
      // 折中的办法是把浮岛挂在这个标题栏 builder 里，再用 position 画到屏幕中部 /
      // 底部 —— 组件树的归属还在标题栏内，材质就还是真的。
      // position 的原点是标题栏顶部（也是屏幕顶部，因为 windowLayoutFullScreen），
      // 所以这里可以直接用屏幕绝对坐标。
      if (this.currentTab === 0) {
        if (this.downloadProgress !== null && this.downloadProgress.phase !== 'idle') {
          // 自定义组件不能直接链式挂通用属性，包一层 Column 承载 position / 材质
          Column() {
            DownloadProgressBar({
              progress: this.downloadProgress,
              onCancel: () => {
                this.svc.cancelDownload();
                this.downloadProgress = null;
                this.syncDownloadedKeys();
              }
            })
          }
          .borderRadius(30)
          .position({
            top: this.screenHeightVp() * 0.5 - 63,
            left: this.handedness.leftHanded ? 12 : undefined,
            right: this.handedness.leftHanded ? undefined : 12
          })
          .systemMaterial(this.floatMaterial)
          .animation({ duration: 220, curve: Curve.EaseOut })
        } else if (this.gallerySelectMode) {
          Column() {
            SelectionActionBar({
              selectedCount: this.gallerySelectedCount,
              onDownload: () => { this.downloadVersion++; }
            })
          }
          .width(96)
          .height(56)
          .borderRadius(28)
          .position({
            // 与底部页签完全同一基线：高 56vp，底边贴着导航手势条避让区
            top: this.screenHeightVp() - this.navIndicatorVp() - 56,
            left: (this.screenWidthVp() - 96) / 2
          })
          .systemMaterial(this.floatMaterial)
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 多选态标题栏：左叉 + 左对齐的「已选择 N 项」+ 右侧全选胶囊。
   *
   * 对齐官方图库（也是官方 EditableTitleBar 的形态：左叉右操作，标题左对齐），
   * 不要做成居中标题 —— 大标题体系里居中会跟浏览态完全断开。
   */
  @Builder
  SelectTitleRow() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .accessibilityText('退出选择')
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        interactive: true
      }))
      .onClick(() => { this.exitSelectMode(); })

      Text(this.selectTitleText())
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Button() {
        Text(this.allSelected() ? '取消全选' : '全选')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
      }
      .height(40)
      .padding({ left: 16, right: 16 })
      .backgroundColor(Color.Transparent)
      .borderRadius(20)
      .accessibilityText(this.allSelected() ? '取消全选' : '全选')
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        interactive: true
      }))
      .onClick(() => { this.selectAllVersion++; })
    }
    .width('100%')
    .height(TITLE_BAR_HEIGHT)
    .padding({ left: 16, right: 16 })
  }

  /** 浏览态标题栏：大标题 + 右侧浮动玻璃胶囊。 */
  @Builder
  NormalTitleRow() {
    Row() {
      Text(this.tabTitle())
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .layoutWeight(1)

      if (this.currentTab === 0 && this.svc.photos.length > 0) {
        if (this.settings.displayMode === 'file_first') {
          // 格式筛选用 Select（官方选择类控件）：点开是带勾选态的下拉菜单。
          // 以前是「点一下换下一个格式」的循环按钮，用户根本猜不到下一下会到哪。
          Select(this.filterOptions())
            .selected(this.filterSelectedIndex())
            .value(this.filterLabel())
            .font({ size: 15, weight: FontWeight.Medium })
            .fontColor($r('app.color.text_primary'))
            .selectedOptionFont({ size: 15, weight: FontWeight.Medium })
            .selectedOptionFontColor($r('app.color.primary'))
            .optionFont({ size: 15 })
            .optionFontColor($r('app.color.text_primary'))
            .height(40)
            .borderRadius(20)
            .backgroundColor(Color.Transparent)
            .margin({ right: 8 })
            .accessibilityText('格式筛选，当前' + this.filterLabel())
            .arrowModifier(new SymbolGlyphModifier($r('sys.symbol.chevron_down'))
              .fontColor([$r('app.color.text_primary')]))
            .systemMaterial(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
              interactive: true
            }))
            .onSelect((index: number) => { this.applyFilterIndex(index); })
        }
        Button() {
          Text('选择')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
        }
        .height(40)
        .padding({ left: 16, right: 16 })
        .backgroundColor(Color.Transparent)
        .borderRadius(20)
        .accessibilityText('选择照片')
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true
        }))
        .onClick(() => { this.toggleSelectVersion++; })
      }

      if (this.currentTab === 1) {
        // 相机页的主操作放在标题栏里：真·沉浸光感只在标题栏内生效，
        // 内容区的大按钮拿不到材质。不设 backgroundColor、不设 materialColor
        // 时材质取 Button 主题色（蓝），正好当主操作。
        if (this.svc.scanning) {
          Button('扫描中')
            .height(40)
            .padding({ left: 18, right: 18 })
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_on_primary'))
            .borderRadius(20)
            .opacity(0.6)
            .systemMaterial(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
              interactive: true
            }))
        } else {
          Button(this.svc.connected ? '快速扫描' : '搜索相机')
            .height(40)
            .padding({ left: 18, right: 18 })
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_on_primary'))
            .borderRadius(20)
            .accessibilityText(this.svc.connected ? '快速扫描相机' : '搜索相机')
            .systemMaterial(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
              interactive: true
            }))
            .onClick(() => { this.svc.scanForCamera(true); })
        }
      }
    }
    .width('100%')
    .height(TITLE_BAR_HEIGHT)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  syncDownloadedKeys(): void {
    this.downloadedKeys = this.svc.getDownloadedKeys();
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
            filterValue: this.galleryFilter,
            scroller: this.galleryScroller,
            onSelectModeChange: (v: boolean) => { this.gallerySelectMode = v; },
            onSelectionStats: (selected: number, selectable: number) => {
              this.gallerySelectedCount = selected;
              this.gallerySelectableCount = selectable;
            },
            exitSelectModeVersion: this.exitSelectModeVersion,
            toggleSelectVersion: this.toggleSelectVersion,
            selectAllVersion: this.selectAllVersion,
            downloadVersion: this.downloadVersion,
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
            scroller: this.cameraScroller,
            onScan: (quick: boolean) => { this.svc.scanForCamera(quick); },
            onDisconnect: () => { this.svc.disconnect(); this.syncDownloadedKeys(); }
          })
        }
        .tabBar(this.TabItem('相机', $r('sys.symbol.camera'), 1))

        TabContent() {
          SettingsPage({
            scroller: this.settingsScroller,
            logText: this.logText,
            onClear: () => { this.svc.getLog().clear(); this.syncDownloadedKeys(); },
            onCopy: () => {
              const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);
              pasteboard.getSystemPasteboard().setData(data);
              this.svc.getLog().add('日志已复制到剪贴板');
              this.syncDownloadedKeys();
            },
            onOpenGpsManagement: () => { this.pageInfos.pushPath({ name: 'GpsManagementPage' }); },
            onOpenCacheManagement: () => { this.pageInfos.pushPath({ name: 'CacheManagementPage' }); }
          })
        }
        .tabBar(this.TabItem('设置', $r('sys.symbol.gearshape'), 2))
      }
      .barOverlap(true)
      .barFloatingStyle({
        // 底边距要自己把导航手势条的高度加进来：窗口是全屏布局，Tabs 不会
        // 自动避让。官方图库的悬浮栏就压在手势条避让区的上沿，多选操作栏用
        // 同一个公式定位，两者才能严丝合缝地叠在同一位置。
        barBottomMargin: this.navIndicatorVp(),
        maskColor: Color.Transparent,
        // 官方沉浸材质：接管胶囊的背景、模糊与折射（模拟器与真机均生效）
        systemMaterial: new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR,
          interactive: true
        })
      })

      .animationDuration(220)
      // 多选时页签栏让位给底部操作栏：高度置 0，操作栏占据同一位置。
      // 非多选态恢复系统默认高度，悬浮样式（barFloatingStyle 的材质与圆角）不受影响。
      .barHeight(this.gallerySelectMode ? 0 : 56)
      .onChange((idx: number) => {
        this.currentTab = idx;
        if (idx === 2) { this.logText = this.svc.getLog().getText(); }
      })
      .width('100%').height('100%')
      // 不裁剪超界子组件，页面里的列表才能穿透到标题栏下方
      .clip(false)
      // 内容区的渐进磨砂：模糊强度从顶部到底部连续衰减到 0，
      // 没有硬边（backdropBlur 做不到这一点，会在标题栏下边缘留一条线）
      .linearGradientBlur(96, {
        fractionStops: [[1, 0], [0.9, 0.06], [0, 0.18]],
        direction: GradientDirection.Bottom
      })
    }
    .title({ builder: this.TitleBar, height: titleBarTotalVp() }, {
      // STACK：内容区延伸到标题栏下方，标题栏材质才有可折射的底层
      barStyle: BarStyle.STACK
    })
    .hideBackButton(true)
    // 不要 bindToScrollable：ArkUI NavDestination 上它的作用是「上滑隐藏、下滑显示」标题栏，
    // 会把标题栏整个藏掉（HDS 时代用它驱动动态模糊，换回 ArkUI 后必须去掉）
    .backgroundColor($r('app.color.bg_page'))
    .onBackPressed(() => {
      if (this.currentTab === 0 && this.gallerySelectMode) {
        this.exitSelectMode();
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
