import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';

import { CameraLinkMode } from '../model/CameraLinkMode';
import { cameraStandeeLabel } from '../utils/CameraStandee';
import { CameraModelStore } from '../model/CameraModelStore';
import { CameraService } from '../services/CameraService';
import { ExifGeotagger } from '../services/ExifGeotagger';
import { HandednessService } from '../services/HandednessService';
import { UsbAttachWatcher } from '../services/UsbAttachWatcher';
import { GalleryPage } from './GalleryPage';
import { CameraPage } from './CameraPage';
import { SettingsPage } from './SettingsPage';
import { DownloadProgressBar } from '../components/DownloadProgressBar';
import { SelectionActionBar } from '../components/SelectionActionBar';
import type { DownloadProgress, DisplayGroup } from '../model/PhotoEntry';
import { SettingsStore } from '../model/SettingsStore';
import { UiStateStore } from '../model/UiStateStore';
import { CustomTransition } from '../CustomTransition/CustomNavigationUtils';
import { ComponentAttrUtils } from '../utils/ComponentAttrUtils';
import { TITLE_BAR_HEIGHT, titleBarInsetVp, titleBarTotalVp } from '../utils/TitleBarMetrics';
import { WindowUtils } from '../utils/WindowUtils';
import { getExt } from '../utils/PhotoGroupUtil';
import { ControlHeight, FontSize, IconSize, pillRadius } from '../utils/UiTokens';
import { GlassEffect } from '../utils/GlassEffect';

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
  @Local usbWatcher: UsbAttachWatcher = UsbAttachWatcher.getInstance();
  /**
   * Tabs 的受控索引，只用于 Tabs({ index }) 与内容逻辑。
   * 它由 onChange 更新，而 onChange 在切换动画结束后才触发；不要拿它驱动
   * 标题栏、底部页签、浮岛等视觉状态，否则旧页的控件会在新页上停留整个动画时长。
   */
  @Local currentTab: number = 1;
  /**
   * 视觉索引：标题栏、底部页签、浮岛等“属于当前页”的 UI 都用它。
   * 在 Tabs 的 onSelected（点击页签 / 滑动离手开始切换动画时）同步更新，
   * 和内容切换同时发生，不等 onChange。
   */
  @Local visualTab: number = 1;
  @Local logText: string = '';
  @Local downloadProgress: DownloadProgress | null = null;
  @Local downloadedKeys: string[] = [];
  @Local settings: SettingsStore = SettingsStore.getInstance();
  @Local uiState: UiStateStore = UiStateStore.getInstance();
  @Local gallerySelectMode: boolean = false;
  @Local galleryFilter: string = '';
  @Local exitSelectModeVersion: number = 0;
  @Local toggleSelectVersion: number = 0;
  /** 多选态：已选数量与可选项总数，由 GalleryPage 上报。 */
  @Local gallerySelectedCount: number = 0;
  /**
   * 预览器返回时，若目标格子不在列表可视区（虚拟化没渲染、或渲染在屏幕外），
   * 先让画廊滚到那一行再收回，官方图库也是先把网格对齐到当前张。
   * 走计数版本 + handle 的既有约定（同 selectAllVersion），不跨组件调方法。
   */
  @Local galleryScrollVersion: number = 0;
  private galleryScrollHandle: number = -1;
  @Local gallerySelectableCount: number = 0;
  /** 点标题栏「全选 / 取消全选」时递增，GalleryPage 监听后执行。 */
  @Local selectAllVersion: number = 0;
  /** 点底部操作栏「下载」时递增，GalleryPage 监听后执行。 */
  @Local downloadVersion: number = 0;
  @Local handedness: HandednessService = HandednessService.getInstance();
  private usbDialogShowing: boolean = false;

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
    const tab = this.uiState.lastTab;
    this.currentTab = tab >= 0 && tab <= 2 ? tab : 1;
    this.visualTab = this.currentTab;
    this.galleryFilter = this.uiState.galleryFilter;
    // 智感握姿：订阅握持手，下载浮岛贴到拇指易触及的一侧。
    // 机型不支持时服务内部会静默降级为固定右侧。
    HandednessService.getInstance().start();
    // 冷启动就把已配对的相机接上：相机休眠时 BLE 仍连得上，握手里的
    // stage1 重发负责唤醒，用户不用手动点「搜索相机」。
    // USB 模式是明确的「走线」，此时不该再去占相机的蓝牙（BLE 与 Wi-Fi 互斥，
    // 蓝牙链路也会让相机以为有主机在连）。
    this.svc.initLinkMode();
    this.svc.initCameraModel();
    if (this.svc.linkMode !== CameraLinkMode.USB) {
      setTimeout(() => { this.svc.autoConnectBle(); }, 800);
    }
    // 由通知冷启动时，UsbAttachWatcher 可能在 MainScreen 创建前就递增了版本；
    // @Monitor 不会为初始值触发，这里补一次。
    if (this.usbWatcher.attachVersion > 0) {
      setTimeout(() => { this.onUsbCameraAttached(); }, 350);
    }
  }

  aboutToDisappear(): void {
    HandednessService.getInstance().stop();
  }

  /** 扫描完成 / Phase 0 部署后刷新“已下载”标记；筛选格式消失时回到“全部”。 */
  @Monitor('svc.photosVersion')
  onPhotosChanged(): void {
    this.syncDownloadedKeys();
    if (this.galleryFilter === '' || this.svc.photos.length === 0) return;
    let found = false;
    for (const p of this.svc.photos) {
      if (getExt(p.filename) === this.galleryFilter) {
        found = true;
        break;
      }
    }
    if (!found) {
      this.galleryFilter = '';
      this.uiState.galleryFilter = '';
    }
  }

  /** 扫描失败：用 toast 把原因说清楚（ISSUE-001）。 */
  @Monitor('svc.scanErrorVersion')
  onScanError(): void {
    const message = this.svc.lastScanError;
    if (message === '') return;
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 3000 });
    } catch (_e) {
      // toast 不可用（例如页面正在退出）时不影响扫描主流程
    }
  }

  /** USB 插入相机：切到相机页并询问是否开始扫描。 */
  @Monitor('usbWatcher.attachVersion')
  onUsbCameraAttached(): void {
    if (this.usbDialogShowing) return;
    if (this.svc.scanning) return;
    if (!this.isTopPage()) {
      this.svc.getLog().add('USB 相机接入：当前不在首屏，跳过提示');
      return;
    }
    if (this.gallerySelectMode) {
      this.exitSelectMode();
    }
    this.currentTab = 1;
    this.visualTab = 1;
    this.uiState.lastTab = 1;
    // 等 Tabs 的 220ms 切换动画走完再弹，避免对话框和页面切换叠在一起。
    setTimeout(() => { this.showUsbCameraDialog(); }, 260);
  }

  /** 当前 NavDestination 是否在栈顶；预览器/二级页打开时不要抢前台。 */
  private isTopPage(): boolean {
    if (this.pageId < 0) return true;
    const names = this.pageInfos.getAllPathName();
    return names.length === 0 || names.length - 1 === this.pageId;
  }

  private showUsbCameraDialog(): void {
    if (this.usbDialogShowing || this.svc.scanning) return;
    this.usbDialogShowing = true;
    this.getUIContext().showAlertDialog({
      title: $r('app.string.usb_camera_found_title'),
      message: $r('app.string.usb_camera_found_message', this.usbWatcher.cameraName),
      autoCancel: true,
      cancel: () => {
        this.usbDialogShowing = false;
      },
      // 与「发现新相机」的缓存对话框保持一致：primary 在左、secondary 在右，
      // 右侧放高亮的主动作。之前主动作在左且把「稍后」放在右，位置和主次都反了。
      primaryButton: {
        value: $r('app.string.usb_camera_found_later'),
        action: () => {
          this.usbDialogShowing = false;
        }
      },
      secondaryButton: {
        value: $r('app.string.usb_camera_found_scan'),
        fontColor: $r('app.color.primary'),
        action: () => {
          this.usbDialogShowing = false;
          // 弹窗里的「开始扫描」应与相机页的「快速扫描」同口径：
          // 有缓存走快速扫描，首次/无缓存由 scanForCamera 自动退化为全量。
          // 之前固定传 false，即使有缓存也会重新走一遍全量扫描。
          this.svc.scanForCamera(true, true);
        }
      }
    });
  }

  /** 下载注册表异步加载 / 增量写入后刷新“已下载”标记。 */
  @Monitor('svc.registryVersion')
  onRegistryChanged(): void {
    this.syncDownloadedKeys();
  }

  /** 新相机首次连接：扫描结束后询问是否启用缩略图缓存。 */
  @Monitor('svc.cachingDialogRequired')
  onCachingDialogRequired(): void {
    if (!this.svc.cachingDialogRequired) return;
    const camId = this.svc.pendingCamIdForDialog;
    const camName = this.svc.pendingCamNameForDialog;
    if (camId === '') return;
    this.getUIContext().showAlertDialog({
      title: $r('app.string.new_camera_title'),
      message: $r('app.string.new_camera_message', camName),
      autoCancel: false,
      primaryButton: {
        value: $r('app.string.new_camera_no_cache'),
        action: () => {
          this.svc.setCachingPreference(camId, false).catch((err: Error) => {
            this.svc.getLog().add(`缓存设置失败: ${JSON.stringify(err)}`);
          });
        }
      },
      secondaryButton: {
        value: $r('app.string.new_camera_enable_cache'),
        fontColor: $r('app.color.primary'),
        action: () => {
          this.svc.setCachingPreference(camId, true).catch((err: Error) => {
            this.svc.getLog().add(`缓存设置失败: ${JSON.stringify(err)}`);
          });
        }
      }
    });
  }

  /**
   * 大标题。相机页认出机型后直接显示型号（`Z 50II`）——页首那块立牌已经
   * 占了「产品图」，标题再写「相机」是重复信息；这也正是官方 SnapBridge
   * 的做法（把型号当页首主标题）。
   */
  private tabTitle(): ResourceStr {
    if (this.visualTab === 0) return $r('app.string.tab_gallery');
    if (this.visualTab === 1) {
      const label = cameraStandeeLabel(this.svc.cameraModel);
      if (label !== '') return label;
      return $r('app.string.tab_camera');
    }
    return $r('app.string.tab_settings');
  }

  /**
   * 型号右下角的序列号角标。
   *
   * 只在相机页、且认出了机型时显示：认不出机型时标题是「相机」，挂一串数字
   * 没有意义。序列号来自 `CameraModelStore`（BLE 广播名尾段），没连过 PTP 也有。
   */
  private cameraSerialBadge(): string {
    if (this.visualTab !== 1) return '';
    if (cameraStandeeLabel(this.svc.cameraModel) === '') return '';
    return CameraModelStore.getInstance().serial;
  }

  /** 多选态标题文字：官方图库是「已选择 N 项」，左对齐跟在关闭钮后面。 */
  private selectTitleText(): ResourceStr {
    return $r('app.string.gallery_select_title', this.gallerySelectedCount);
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

  private filterLabel(): ResourceStr {
    return this.galleryFilter === '' ? $r('app.string.common_all') : this.galleryFilter;
  }

  /** 下拉筛选项：第 0 项永远是「全部」，后面按照片里出现过的格式排列。 */
  private filterOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    const list = this.formatList();
    for (const ext of list) {
      out.push({ value: ext === '' ? $r('app.string.common_all') : ext });
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
      this.uiState.galleryFilter = this.galleryFilter;
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

        if (this.visualTab === 0 && this.gallerySelectMode) {
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
      if (this.visualTab === 0) {
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
          .borderRadius(pillRadius(60))
          .position({
            top: this.screenHeightVp() * 0.5 - 63,
            left: this.handedness.leftHanded ? 12 : undefined,
            right: this.handedness.leftHanded ? undefined : 12
          })
          .systemMaterial(GlassEffect.material(this.floatMaterial))
          .animation({ duration: 220, curve: Curve.EaseOut })
        } else if (this.gallerySelectMode) {
          Column() {
            SelectionActionBar({
              selectedCount: this.gallerySelectedCount,
              onDownload: () => { this.downloadVersion++; }
            })
          }
          .width(96)
          .height(ControlHeight.Bar)
          .borderRadius(pillRadius(ControlHeight.Bar))
          .position({
            // 与底部页签完全同一基线：高 56vp，底边贴着导航手势条避让区
            top: this.screenHeightVp() - this.navIndicatorVp() - ControlHeight.Bar,
            left: (this.screenWidthVp() - 96) / 2
          })
          .systemMaterial(GlassEffect.material(this.floatMaterial))
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
          .fontSize(IconSize.Nav)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(ControlHeight.Pill)
      .height(ControlHeight.Pill)
      .backgroundColor(Color.Transparent)
      .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        interactive: true
      })))
      .onClick(() => { this.exitSelectMode(); })

      Text(this.selectTitleText())
        .fontSize(FontSize.Title)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Button() {
        Text(this.allSelected() ? $r('app.string.common_deselect_all') : $r('app.string.common_select_all'))
          .fontSize(FontSize.Body)
          .fontColor($r('app.color.text_primary'))
      }
      .height(ControlHeight.Pill)
      .padding({ left: 16, right: 16 })
      .backgroundColor(Color.Transparent)
      .borderRadius(pillRadius(ControlHeight.Pill))
      .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        interactive: true
      })))
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
      // 型号 + 序列号角标：序列号跟型号右下角齐底、10fp，像机身上的铭牌
      Row({ space: 6 }) {
        Text(this.tabTitle())
          .fontSize(FontSize.Display)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .flexShrink(1)
        if (this.cameraSerialBadge() !== '') {
          Text(this.cameraSerialBadge())
            .fontSize(FontSize.Micro)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ bottom: 5 })
            .flexShrink(0)
        }
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Bottom)

      if (this.visualTab === 0 && this.svc.photos.length > 0) {
        if (this.settings.displayMode === 'file_first') {
          // 格式筛选用 Select（官方选择类控件）：点开是带勾选态的下拉菜单。
          // 以前是「点一下换下一个格式」的循环按钮，用户根本猜不到下一下会到哪。
          Select(this.filterOptions())
            .selected(this.filterSelectedIndex())
            .value(this.filterLabel())
            .font({ size: FontSize.Body, weight: FontWeight.Medium })
            .fontColor($r('app.color.text_primary'))
            .selectedOptionFont({ size: FontSize.Body, weight: FontWeight.Medium })
            .selectedOptionFontColor($r('app.color.primary'))
            .optionFont({ size: FontSize.Body })
            .optionFontColor($r('app.color.text_primary'))
            .height(ControlHeight.Pill)
            .borderRadius(pillRadius(ControlHeight.Pill))
            .backgroundColor(Color.Transparent)
            .margin({ right: 8 })
            .arrowModifier(new SymbolGlyphModifier($r('sys.symbol.chevron_down'))
              .fontColor([$r('app.color.text_primary')]))
            .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
              interactive: true
            })))
            .onSelect((index: number) => { this.applyFilterIndex(index); })
        }
        Button() {
          Text($r('app.string.common_select'))
            .fontSize(FontSize.Body)
            .fontColor($r('app.color.text_primary'))
        }
        .height(ControlHeight.Pill)
        .padding({ left: 16, right: 16 })
        .backgroundColor(Color.Transparent)
        .borderRadius(pillRadius(ControlHeight.Pill))
        .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true
        })))
        .onClick(() => { this.toggleSelectVersion++; })
      }

      if (this.visualTab === 1) {
        // 相机页的主操作放在标题栏里：真·沉浸光感只在标题栏内生效，
        // 内容区的大按钮拿不到材质。不设 backgroundColor、不设 materialColor
        // 时材质取 Button 主题色（蓝），正好当主操作。
        if (this.svc.scanning) {
          Button($r('app.string.camera_main_scanning'))
            .height(ControlHeight.Pill)
            .padding({ left: 18, right: 18 })
            .fontSize(FontSize.Body)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_on_primary'))
            .borderRadius(pillRadius(ControlHeight.Pill))
            .opacity(0.6)
            .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
              interactive: true
            })))
        } else {
          Button(this.svc.connected && this.svc.linkMode === CameraLinkMode.USB
            ? $r('app.string.camera_main_quick_scan')
            : $r('app.string.camera_main_find'))
            .height(ControlHeight.Pill)
            .padding({ left: 18, right: 18 })
            .fontSize(FontSize.Body)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_on_primary'))
            .borderRadius(pillRadius(ControlHeight.Pill))
            .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
              interactive: true
            })))
            .onClick(() => { this.svc.searchByMode(); })
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
  TabItem(label: ResourceStr, icon: Resource, index: number) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(IconSize.Large)
        .fontColor([this.visualTab === index
          ? $r('app.color.primary') : $r('app.color.text_tertiary')])
      Text(label)
        .fontSize(FontSize.Micro)
        .fontWeight(this.visualTab === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.visualTab === index
          ? $r('app.color.primary') : $r('app.color.text_tertiary'))
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /** 请求画廊把列表滚到某张照片（预览器返回转场对齐用）。 */
  private requestGalleryScroll(handle: number): void {
    this.galleryScrollHandle = handle;
    this.galleryScrollVersion++;
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
            galleryScrollVersion: this.galleryScrollVersion,
            galleryScrollHandle: this.galleryScrollHandle,
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

              // 2. Cache positions around the tapped item so the pop animation can
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

              // 3. Push PhotoViewer via Navigation (not router)
              const pushParam: Record<string, Object> = {};
              pushParam['handle'] = handle;
              pushParam['handles'] = handles;
              pushParam['startIndex'] = index;
              pushParam['cardItemInfo'] = cardItemInfoStr;
              pushParam['posCache'] = JSON.stringify(posCache);
              // 实时矩形优先（画廊可能已经被滚过，push 时缓存的位置会过期）
              pushParam['positionLookup'] = (targetHandle: number): string => {
                const r = ComponentAttrUtils.getRectInfoById(
                  this.getUIContext(), `thumb_${targetHandle}`);
                if (r) {
                  return JSON.stringify(r);
                }
                this.svc.getLog().add(`posLookup MISS handle=${targetHandle}`);
                return '';
              };
              pushParam['requestGalleryScroll'] = (targetHandle: number): void => {
                this.requestGalleryScroll(targetHandle);
              };
              // 预览器里「保存到相册」成功后刷新已下载集合，画廊绿点立即生效
              pushParam['onDownloadSaved'] = (): void => {
                this.syncDownloadedKeys();
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
        .tabBar(this.TabItem($r('app.string.tab_gallery'), $r('sys.symbol.square_grid_2x2'), 0))

        TabContent() {
          CameraPage({
            scroller: this.cameraScroller,
            // 全量扫描是用户明确点下的动作，跳过节流；快捷扫描保留 800ms 节流
            onScan: (quick: boolean) => { this.svc.scanForCamera(quick, !quick); },
            onDisconnect: () => { this.svc.disconnect(); this.syncDownloadedKeys(); },
            onConnectWifi: (host: string) => {
              this.svc.connectWifi(host).then(async (ok: boolean) => {
                if (!ok) return;
                if (this.svc.pairingRequired) {
                  // 相机那边不显示验证码，核对没有意义；直接确认，用户不用再点。
                  await this.svc.completeWifiPairing();
                } else {
                  this.svc.scanForCamera(true, true);
                }
              });
            },
            onCompletePairing: () => {
              this.svc.completeWifiPairing();
            },
            onScanWifi: () => {
              this.svc.scanWifiCameras();
            },
            onConnectBle: (deviceId: string, deviceName: string) => {
              this.svc.connectBle(deviceId, deviceName);
            },
            onDisconnectBle: () => {
              this.svc.disconnectBle();
            },
            onConnectWireless: () => {
              this.svc.connectWirelessNow();
            },
            onSelectMode: (mode: number) => {
              this.svc.setLinkMode(mode);
            }
          })
        }
        .tabBar(this.TabItem($r('app.string.tab_camera'), $r('sys.symbol.camera'), 1))

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
        .tabBar(this.TabItem($r('app.string.tab_settings'), $r('sys.symbol.gearshape'), 2))
      }
      .barOverlap(true)
      // REQ-001：多选要支持「按住拖拽框选」，而画廊里的横向拖动会被 Tabs 抢去
      // 切标签页，所以关掉标签页之间的左右滑动（用户已确认接受）。
      // 只设 scrollable，不设 barMode —— 悬浮页签的材质与圆角在模拟器/真机都要复核。
      .scrollable(false)
      .barFloatingStyle({
        // 底边距要自己把导航手势条的高度加进来：窗口是全屏布局，Tabs 不会
        // 自动避让。官方图库的悬浮栏就压在手势条避让区的上沿，多选操作栏用
        // 同一个公式定位，两者才能严丝合缝地叠在同一位置。
        barBottomMargin: this.navIndicatorVp(),
        maskColor: Color.Transparent,
        // 官方沉浸材质：接管胶囊的背景、模糊与折射（模拟器与真机均生效）。
        // 调试开关打开时换成空材质，避免模拟器 GPU 画不出磨砂着色器时整屏乱花。
        systemMaterial: GlassEffect.material(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR,
          interactive: true
        }))
      })

      .animationDuration(220)
      // 多选时页签栏让位给底部操作栏：高度置 0，操作栏占据同一位置。
      // 非多选态恢复系统默认高度，悬浮样式（barFloatingStyle 的材质与圆角）不受影响。
      .barHeight(this.gallerySelectMode ? 0 : ControlHeight.Bar)
      // 视觉索引必须在切换动画开始时就跟上：onChange 是动画结束后才触发，
      // 用它驱动标题栏会让旧页的按钮在目标页上停留整个动画时长（实测 220ms）。
      // onSelected 在点击页签 / 滑动离手开始切换动画时触发，和内容切换同时发生。
      .onSelected((idx: number) => {
        this.visualTab = idx;
      })
      .onChange((idx: number) => {
        // onChange 在切换动画结束后触发，只更新 Tabs 的受控索引与持久化；
        // 标题栏、底部页签、浮岛等视觉状态由上面的 onSelected 提前更新。
        this.currentTab = idx;
        this.uiState.lastTab = idx;
        if (idx === 2) { this.logText = this.svc.getLog().getText(); }
      })
      .width('100%').height('100%')
      // 不裁剪超界子组件，页面里的列表才能穿透到标题栏下方
      .clip(false)
      // 内容区的渐进磨砂：模糊强度从顶部到底部连续衰减到 0，
      // 没有硬边（backdropBlur 做不到这一点，会在标题栏下边缘留一条线）
      .linearGradientBlur(GlassEffect.blurRadius(96), {
        // fractionStops 的每一档是 [模糊程度, 模糊位置]，位置必须严格递增；
        // 之前最后一档停在 0.18，0.18→1 没有定义，模拟器上会画出三角碎片。
        // 调试开关打开时半径归零（模拟器 GPU 画不出磨砂效果时的纯色兜底）。
        fractionStops: [[1, 0], [0.9, 0.06], [0, 0.18], [0, 1]],
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
