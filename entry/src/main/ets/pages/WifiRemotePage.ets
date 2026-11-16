/**
 * WifiRemotePage.ets
 *
 * Wi-Fi STA 实时取景 + 遥控拍摄。
 *
 * 页面只做三件事：
 * 1. 把 `NikonWifiLiveView` 的帧画在取景台中央；
 * 2. 点画面 → 移动 AF 区域并驱动一次对焦；
 * 3. 底部玻璃控制台：曝光 / 白平衡 / 对焦 / 快门 / AF / 变焦。
 *
 * 视觉上刻意不像“黑底上摆一排按钮”：
 * - 同一帧再铺一层低透明度的 Cover 背景，让画面外的留白延续取景内容的颜色；
 * - 顶部工具胶囊与底部控制台都使用系统沉浸光感，随浅色/深色模式自动换材质；
 * - 曝光只读成一个连续读数条，不再是一排互不相干的小方块。
 *
 * 离开页面 = 结束实时取景并把控制权还给相机；相机在实时取景期间会锁回放/
 * 菜单（和蓝牙遥控一样），不能只靠用户按返回。
 */
import { LengthMetrics, uiMaterial } from '@kit.ArkUI';
import { CameraService } from '../services/CameraService';
import { NikonWifiLiveView, type AfBox } from '../services/NikonWifiLiveView';
import {
  EXPOSURE_PARAM_APERTURE,
  EXPOSURE_PARAM_EV,
  EXPOSURE_PARAM_ISO,
  EXPOSURE_PARAM_SHUTTER,
  type ExposureOption
} from '../services/NikonWifiExposure';
import { type CameraOption } from '../services/NikonWifiCameraSettings';
import { WindowUtils } from '../utils/WindowUtils';
import { CardShadow, FontSize, IconSize, Radius } from '../utils/UiTokens';
import { Haptics } from '../utils/Haptics';
import { GlassEffect } from '../utils/GlassEffect';

/** 顶部标题栏高度（不含状态栏）：56vp 胶囊 + 上下各 6vp 呼吸边。 */
const REMOTE_TOP_BAR_HEIGHT: number = 62;
/** 底部控制台高度：专业参数条 56 + 快门区 132 + 分隔线 + 上下内边距。 */
const REMOTE_DECK_HEIGHT: number = 200;
/** 取景画面四周的呼吸边距。 */
const REMOTE_IMAGE_INSET: number = 8;
/** 专业参数拨盘：每个刻度的宽度、面板高度、白平衡参数的占位标识。 */
const DIAL_ITEM_WIDTH: number = 52;
const DIAL_PANEL_HEIGHT: number = 92;
const DIAL_WB: string = '__wb__';

@Builder
export function WifiRemotePageBuilder() {
  WifiRemotePage();
}

@ComponentV2
export struct WifiRemotePage {
  private pageInfos: NavPathStack = new NavPathStack();
  @Local svc: CameraService = CameraService.getInstance();
  @Local live: NikonWifiLiveView | null = null;
  /** 取景台尺寸；AF 框和点按坐标都相对它换算。 */
  @Local stageW: number = 0;
  @Local stageH: number = 0;
  @Local focusX: number = 0;
  @Local focusY: number = 0;
  @Local focusVisible: boolean = false;
  /** 当前打开的参数面板：'' 表示关闭。 */
  @Local exposureSheetOpen: boolean = false;
  @Local exposureParam: string = '';
  @Local wbSheetOpen: boolean = false;
  @Local focusSheetOpen: boolean = false;
  /** 专业参数拨盘：当前参数、候选刻度、是否展开。 */
  @Local dialOpen: boolean = false;
  @Local dialParam: string = '';
  @Local dialIndex: number = 0;
  /** 拖动时刻度直接透过玻璃；停稳后才淡入蓝色大数字。 */
  @Local dialShowValue: boolean = true;
  @Local dialScrolling: boolean = false;
  private dialScroller: Scroller = new Scroller();
  private dialAppliedValue: number = -1;
  /** 本次遥控里至少产生了一张照片/一段录像；退出页面时自动补一次快速扫描。 */
  private mediaChanged: boolean = false;
  private focusTimer: number = -1;

  aboutToAppear(): void {
    this.syncSystemBars();
    // 遥控取景期间不要熄屏：用户双手可能在操作相机/构图。
    WindowUtils.window?.setWindowKeepScreenOn(true).catch((_e: Error) => {});
    this.live = this.svc.ensureWifiLiveView();
    if (this.live !== null) {
      this.live.start().catch((_e: Error) => {
        // 错误已经写进 live.error
      });
    }
  }

  aboutToDisappear(): void {
    if (this.focusTimer >= 0) {
      clearTimeout(this.focusTimer);
      this.focusTimer = -1;
    }
    // 退出前如果还在录像，这段录像也算新增媒体。
    const hadMedia = this.mediaChanged || (this.live !== null && this.live.movieRecording);
    const stop = this.live !== null ? this.live.stop().catch((_e: Error) => {
      // 链路已断时只清本地状态
    }) : Promise.resolve();
    WindowUtils.window?.setWindowKeepScreenOn(false).catch((_e: Error) => {});
    WindowUtils.applyThemeSystemBars(
      WindowUtils.isDarkMode(this.getUIContext().getHostContext()));
    stop.finally(() => {
      if (!hadMedia) return;
      this.svc.scanForCamera(true, true).catch((_e: Error) => {
        this.svc.getLog().add(`遥控退出后自动扫描失败: ${(_e as Error).message}`);
      });
    });
  }

  /**
   * 系统栏跟随应用主题。
   *
   * 这一页不再是恒定的黑底：浅色下顶部是浅色玻璃，状态栏图标必须转成深色；
   * 深色下反过来。离开页面时 `aboutToDisappear` 会按同一规则恢复。
   */
  private syncSystemBars(): void {
    WindowUtils.applyThemeSystemBars(
      WindowUtils.isDarkMode(this.getUIContext().getHostContext()));
  }

  /** 重新取一次当前会话的控制器再启动：退后台 / 重连后旧控制器可能已失效。 */
  private restartLive(): void {
    this.live = this.svc.ensureWifiLiveView();
    if (this.live === null) return;
    this.live.start().catch((_e: Error) => {
      // 错误已写进 live.error
    });
  }

  private statusBarVp(): number {
    const px = WindowUtils.topAvoidAreaHeightPx;
    return px > 0 ? this.getUIContext().px2vp(px) : 0;
  }

  private navIndicatorVp(): number {
    const px = WindowUtils.navigationIndicatorHeightPx;
    return px > 0 ? this.getUIContext().px2vp(px) : 0;
  }

  private statusText(): ResourceStr {
    const live = this.live;
    if (live === null) return $r('app.string.camera_wifi_remote_not_connected');
    if (live.error !== '') return live.error;
    if (live.movieRecording) return $r('app.string.camera_wifi_remote_recording');
    if (live.shooting) return $r('app.string.camera_wifi_remote_shooting');
    if (live.focusing) return $r('app.string.camera_wifi_remote_focusing');
    if (live.starting || live.movieSwitching) {
      return $r('app.string.camera_wifi_remote_connecting');
    }
    if (!live.active) {
      return $r('app.string.camera_wifi_remote_not_live');
    }
    if (live.lastAction !== '') return live.lastAction;
    return $r('app.string.camera_wifi_remote_live');
  }

  /** 还没有画面时，取景台中央那张卡片的文案。 */
  private emptyText(): ResourceStr {
    const live = this.live;
    if (live === null) return $r('app.string.camera_wifi_remote_not_connected');
    if (live.error !== '') return live.error;
    if (live.starting) return $r('app.string.camera_wifi_remote_connecting');
    if (live.active) return $r('app.string.camera_wifi_remote_waiting');
    return $r('app.string.camera_wifi_remote_not_live');
  }

  private statusColor(): ResourceStr {
    const live = this.live;
    if (live === null) return $r('app.color.text_secondary');
    if (live.error !== '') return $r('app.color.status_error');
    if (live.movieRecording) return $r('app.color.button_danger');
    return $r('app.color.text_secondary');
  }

  private statusDotColor(): ResourceStr {
    const live = this.live;
    if (live === null) return $r('app.color.text_tertiary');
    if (live.error !== '') return $r('app.color.status_error');
    if (live.movieRecording) return $r('app.color.button_danger');
    if (live.starting || live.movieSwitching) return $r('app.color.status_disconnected');
    if (live.active) return $r('app.color.status_connected');
    return $r('app.color.text_tertiary');
  }

  private topBarHeight(): number {
    return this.statusBarVp() + REMOTE_TOP_BAR_HEIGHT;
  }

  private screenWidthVp(): number {
    const px = WindowUtils.windowWidthPx;
    return px > 0 ? this.getUIContext().px2vp(px) : 360;
  }

  private screenHeightVp(): number {
    const px = WindowUtils.windowHeightPx;
    return px > 0 ? this.getUIContext().px2vp(px) : 800;
  }

  /** 控制台内容宽度。 */
  private deckWidthVp(): number {
    return Math.min(this.screenWidthVp() - 24, 520);
  }

  private deckX(): number {
    return (this.screenWidthVp() - this.deckWidthVp()) / 2;
  }

  private deckY(): number {
    return this.screenHeightVp() - this.navIndicatorVp() - 10 - REMOTE_DECK_HEIGHT;
  }

  private deckVisible(): boolean {
    if (this.live === null) return false;
    // 切照片/视频时服务会先 stop 再 start；把 movieSwitching 也算进来，
    // 否则控制台会在切换的一两秒里消失、取景台跟着跳一下。
    return this.live.active || this.live.starting || this.live.movieSwitching;
  }

  /** 取景台底部要给悬浮控制台让出的高度。 */
  private stageBottomSpace(): number {
    if (!this.deckVisible()) return this.navIndicatorVp() + 12;
    return REMOTE_DECK_HEIGHT + this.navIndicatorVp() + 12;
  }

  /** 实时画面在取景台里的显示比例；与 AF 框换算共用。 */
  private imageScale(): number {
    const live = this.live;
    if (live === null || live.frameWidth <= 0 || live.frameHeight <= 0) return 0;
    const availW = this.stageW - REMOTE_IMAGE_INSET * 2;
    const availH = this.stageH - REMOTE_IMAGE_INSET * 2;
    if (availW <= 0 || availH <= 0) return 0;
    return Math.min(availW / live.frameWidth, availH / live.frameHeight);
  }

  private imageWidth(): number {
    const live = this.live;
    return live === null ? 0 : live.frameWidth * this.imageScale();
  }

  private imageHeight(): number {
    const live = this.live;
    return live === null ? 0 : live.frameHeight * this.imageScale();
  }

  private imageLeft(): number {
    return (this.stageW - this.imageWidth()) / 2;
  }

  private imageTop(): number {
    return (this.stageH - this.imageHeight()) / 2;
  }

  private canShoot(): boolean {
    return this.live !== null && this.live.active && !this.live.shooting
      && !this.live.starting && !this.live.movieSwitching
      && this.live.exposureWriting === '' && this.live.settingsWriting === '';
  }

  private canSwitchMode(): boolean {
    return this.live !== null && this.live.active && this.live.supportsMovie
      && !this.live.starting && !this.live.movieSwitching && !this.live.movieRecording
      && this.live.exposureWriting === '' && this.live.settingsWriting === '';
  }

  private canAf(): boolean {
    return this.live !== null && this.live.active && this.live.supportsAf
      && !this.live.focusing
      && this.live.exposureWriting === '' && this.live.settingsWriting === '';
  }

  private canZoom(): boolean {
    return this.live !== null && this.live.active && this.live.supportsZoom
      && !this.live.zooming
      && this.live.exposureWriting === '' && this.live.settingsWriting === '';
  }

  private exposureTitle(param: string): ResourceStr {
    if (param === EXPOSURE_PARAM_APERTURE) return $r('app.string.camera_wifi_remote_aperture');
    if (param === EXPOSURE_PARAM_SHUTTER) return $r('app.string.camera_wifi_remote_shutter');
    if (param === EXPOSURE_PARAM_ISO) return $r('app.string.camera_wifi_remote_iso');
    return $r('app.string.camera_wifi_remote_ev');
  }

  private exposureValue(param: string): string {
    const live = this.live;
    if (live === null || !live.active || !live.exposureReady) return '--';
    return live.getExposureLabel(param);
  }

  private canAdjustExposure(): boolean {
    return this.live !== null && this.live.active && this.live.exposureReady
      && !this.live.starting && this.live.exposureWriting === ''
      && this.live.settingsWriting === '';
  }

  private canAdjustExposureParam(param: string): boolean {
    return this.canAdjustExposure() && this.live !== null
      && this.live.isExposureParamEnabled(param);
  }

  private exposureModeLabel(): string {
    return this.live !== null ? this.live.getExposureModeLabel() : '--';
  }

  private whiteBalanceLabel(): string {
    const live = this.live;
    if (live === null || !live.active || !live.whiteBalanceReady) return '--';
    return live.getWhiteBalanceLabel();
  }

  private wbOptions(): CameraOption[] {
    const live = this.live;
    return live !== null ? live.whiteBalanceOptions : [];
  }

  private afModeOptions(): CameraOption[] {
    const live = this.live;
    return live !== null ? live.afModeOptions : [];
  }

  private afAreaOptions(): CameraOption[] {
    const live = this.live;
    return live !== null ? live.afAreaOptions : [];
  }

  private wbLoading(): boolean {
    const live = this.live;
    return live !== null && live.whiteBalanceLoading;
  }

  private focusLoading(): boolean {
    const live = this.live;
    return live !== null && live.focusSettingsLoading;
  }

  private focusSettingLabel(): string {
    const live = this.live;
    if (live === null || !live.active || !live.focusSettingsReady) return '--';
    return `${live.getAfModeLabel()} · ${live.getAfAreaLabel()}`;
  }

  /** 专业参数条只放得下一行，AF 格显示模式；区域在面板里看。 */
  private focusModeLabel(): string {
    const live = this.live;
    if (live === null || !live.active || !live.focusSettingsReady) return '--';
    return live.getAfModeLabel();
  }

  private canAdjustWb(): boolean {
    const live = this.live;
    return live !== null && live.active && live.supportsWhiteBalance
      && live.whiteBalanceReady && !live.starting && live.whiteBalanceLoading === false
      && live.exposureWriting === '' && live.settingsWriting === '';
  }

  private canAdjustFocus(): boolean {
    const live = this.live;
    return live !== null && live.active && live.focusSettingsReady
      && !live.starting && live.focusSettingsLoading === false
      && (live.supportsAfModeSetting || live.supportsAfAreaSetting)
      && live.exposureWriting === '' && live.settingsWriting === '';
  }

  private openWb(): void {
    if (!this.canAdjustWb()) return;
    Haptics.tap();
    this.wbSheetOpen = true;
    this.live?.ensureWhiteBalance();
  }

  private openFocus(): void {
    if (!this.canAdjustFocus()) return;
    Haptics.tap();
    this.focusSheetOpen = true;
    this.live?.ensureFocusSettings();
  }

  private applyWhiteBalance(value: number): void {
    if (this.live === null || this.live.settingsWriting !== '') return;
    Haptics.tap();
    this.wbSheetOpen = false;
    this.live.setWhiteBalance(value).catch((_e: Error) => {
      // 错误已写进 live.error
    });
  }

  private applyAfMode(value: number): void {
    if (this.live === null || this.live.settingsWriting !== '') return;
    Haptics.tap();
    this.live.setAfMode(value).catch((_e: Error) => {
      // 错误已写进 live.error
    });
  }

  private applyAfArea(value: number): void {
    if (this.live === null || this.live.settingsWriting !== '') return;
    Haptics.tap();
    this.live.setAfAreaMode(value).catch((_e: Error) => {
      // 错误已写进 live.error
    });
  }

  private isSelectedWb(value: number): boolean {
    return this.live !== null && this.live.whiteBalance === value;
  }

  private isSelectedAfMode(value: number): boolean {
    return this.live !== null && this.live.afMode === value;
  }

  private isSelectedAfArea(value: number): boolean {
    return this.live !== null && this.live.afAreaMode === value;
  }

  private openExposure(param: string): void {
    if (!this.canAdjustExposureParam(param)) return;
    Haptics.tap();
    this.exposureParam = param;
    this.exposureSheetOpen = true;
    this.live?.ensureExposure();
  }

  private applyExposure(value: number): void {
    const live = this.live;
    if (live === null) return;
    Haptics.tap();
    this.exposureSheetOpen = false;
    live.setExposure(this.exposureParam, value).catch((_e: Error) => {
      // 错误已写进 live.error
    });
  }

  private currentExposureOptions(): ExposureOption[] {
    const live = this.live;
    return live !== null ? live.getExposureOptions(this.exposureParam) : [];
  }

  private exposureOptionsFor(param: string): ExposureOption[] {
    const live = this.live;
    return live !== null ? live.getExposureOptions(param) : [];
  }

  private dialOptions(): ExposureOption[] {
    if (this.dialParam === DIAL_WB) {
      const out: ExposureOption[] = [];
      for (const item of this.wbOptions()) {
        const opt: ExposureOption = { value: item.value, label: item.label };
        out.push(opt);
      }
      return out;
    }
    return this.exposureOptionsFor(this.dialParam);
  }

  private dialTitle(): ResourceStr {
    if (this.dialParam === DIAL_WB) return $r('app.string.camera_wifi_remote_wb');
    if (this.dialParam === EXPOSURE_PARAM_APERTURE) return $r('app.string.camera_wifi_remote_aperture');
    if (this.dialParam === EXPOSURE_PARAM_SHUTTER) return $r('app.string.camera_wifi_remote_shutter');
    if (this.dialParam === EXPOSURE_PARAM_ISO) return $r('app.string.camera_wifi_remote_iso');
    if (this.dialParam === EXPOSURE_PARAM_EV) return $r('app.string.camera_wifi_remote_ev');
    return $r('app.string.camera_wifi_remote_mode');
  }

  private dialValueLabel(): string {
    const opts = this.dialOptions();
    if (opts.length === 0) return '--';
    const index = Math.max(0, Math.min(opts.length - 1, this.dialIndex));
    return opts[index].label;
  }

  private dialViewportWidth(): number {
    return Math.max(0, this.deckWidthVp() - 24);
  }

  private dialSpacerWidth(): number {
    return Math.max(0, (this.dialViewportWidth() - DIAL_ITEM_WIDTH) / 2);
  }

  private openExposureDial(param: string): void {
    if (!this.canAdjustExposureParam(param)) return;
    Haptics.tap();
    if (this.dialOpen && this.dialParam === param) {
      this.closeDial();
      return;
    }
    this.dialParam = param;
    this.dialOpen = true;
    this.dialIndex = 0;
    this.dialShowValue = true;
    this.dialScrolling = false;
    this.dialAppliedValue = -1;
    this.live?.ensureExposure();
    this.syncDialToCurrent();
    this.scheduleDialSync(0);
  }

  private openWbDial(): void {
    if (!this.canAdjustWb()) return;
    Haptics.tap();
    if (this.dialOpen && this.dialParam === DIAL_WB) {
      this.closeDial();
      return;
    }
    this.dialParam = DIAL_WB;
    this.dialOpen = true;
    this.dialIndex = 0;
    this.dialShowValue = true;
    this.dialScrolling = false;
    this.dialAppliedValue = -1;
    this.live?.ensureWhiteBalance();
    this.syncDialToCurrent();
    this.scheduleDialSync(0);
  }

  private closeDial(): void {
    this.dialOpen = false;
    this.dialParam = '';
    this.dialShowValue = true;
    this.dialScrolling = false;
    this.dialAppliedValue = -1;
  }

  /** 参数是异步读取的：面板先出现，数据到了再对齐到当前值。 */
  private scheduleDialSync(attempt: number): void {
    setTimeout(() => {
      if (!this.dialOpen) return;
      if (this.dialOptions().length > 0) {
        this.syncDialToCurrent();
        return;
      }
      if (attempt < 20) this.scheduleDialSync(attempt + 1);
    }, 50);
  }

  private syncDialToCurrent(): void {
    const live = this.live;
    if (!this.dialOpen || live === null) return;
    const opts = this.dialOptions();
    if (opts.length === 0) return;
    const current = this.dialParam === DIAL_WB
      ? live.whiteBalance : live.getExposureRaw(this.dialParam);
    const index = opts.findIndex((item: ExposureOption) => item.value === current);
    if (index < 0) return;
    this.dialIndex = index;
    this.dialAppliedValue = current;
    this.dialScroller.scrollTo({
      xOffset: index * DIAL_ITEM_WIDTH,
      yOffset: 0,
      animation: false
    });
  }

  private dialIndexAtCurrentOffset(): number {
    const length = this.dialOptions().length;
    if (length === 0) return 0;
    const offset = Math.abs(this.dialScroller.currentOffset().xOffset);
    const index = Math.round(offset / DIAL_ITEM_WIDTH);
    return Math.max(0, Math.min(length - 1, index));
  }

  private onDialScrollStart(): void {
    this.dialScrolling = true;
    this.dialShowValue = false;
  }

  private onDialScroll(): void {
    if (this.dialOptions().length === 0) return;
    this.dialIndex = this.dialIndexAtCurrentOffset();
  }

  private onDialScrollStop(): void {
    if (this.dialOptions().length === 0) return;
    this.dialScrolling = false;
    this.dialIndex = this.dialIndexAtCurrentOffset();
    this.dialScroller.scrollTo({
      xOffset: this.dialIndex * DIAL_ITEM_WIDTH,
      yOffset: 0,
      animation: true
    });
    this.applyDialValue();
    setTimeout(() => {
      if (this.dialOpen && !this.dialScrolling) this.dialShowValue = true;
    }, 140);
  }

  private selectDialIndex(index: number): void {
    const length = this.dialOptions().length;
    if (length === 0) return;
    this.dialShowValue = false;
    this.dialScrolling = false;
    this.dialIndex = Math.max(0, Math.min(length - 1, index));
    this.dialScroller.scrollTo({
      xOffset: this.dialIndex * DIAL_ITEM_WIDTH,
      yOffset: 0,
      animation: true
    });
    this.applyDialValue();
    setTimeout(() => {
      if (this.dialOpen && !this.dialScrolling) this.dialShowValue = true;
    }, 140);
  }

  private applyDialValue(): void {
    const opts = this.dialOptions();
    if (opts.length === 0) return;
    const option = opts[Math.max(0, Math.min(opts.length - 1, this.dialIndex))];
    if (option.value === this.dialAppliedValue) return;
    const live = this.live;
    if (live === null) return;
    if (this.dialParam === DIAL_WB) {
      if (!this.canAdjustWb() || live.settingsWriting !== '') return;
      this.dialAppliedValue = option.value;
      Haptics.tap();
      live.setWhiteBalance(option.value).catch((_e: Error) => {
        // 错误已经写进 live.error
      });
      return;
    }
    if (!this.canAdjustExposureParam(this.dialParam) || live.exposureWriting !== '') return;
    this.dialAppliedValue = option.value;
    Haptics.tap();
    live.setExposure(this.dialParam, option.value).catch((_e: Error) => {
      // 错误已经写进 live.error
    });
  }

  private isSelectedExposure(value: number): boolean {
    const live = this.live;
    return live !== null && live.getExposureRaw(this.exposureParam) === value;
  }

  /**
   * 半模态参数。
   *
   * 标题必须交给系统的 `SheetOptions.title`：半模态自身已经为拖拽条、关闭键
   * 和圆角留好了标题区，自己再画一行标题会贴到圆角上、和关闭键抢位置。
   */
  private sheetOptions(title: ResourceStr): SheetOptions {
    const opts: SheetOptions = {
      height: SheetSize.MEDIUM,
      preferType: SheetType.BOTTOM,
      dragBar: true,
      showClose: true,
      title: { title }
    };
    // 半模态不跟随应用级材质开关，必须显式给；给材质时不能再设背景色。
    if (GlassEffect.isEnabled()) {
      opts.systemMaterial = GlassEffect.material(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THICK,
        materialColor: $r('app.color.viewer_material_tint')
      }));
    } else {
      opts.backgroundColor = $r('app.color.bg_surface');
    }
    return opts;
  }

  private focusBadgeVisible(): boolean {
    const live = this.live;
    return live !== null && live.active
      && (live.focusDrive === 1 || live.focusState === 1 || live.focusState === 2);
  }

  private focusBadgeText(): ResourceStr {
    const live = this.live;
    if (live === null) return '';
    if (live.focusDrive === 1) return $r('app.string.camera_wifi_remote_focus_driving');
    if (live.focusState === 2) return $r('app.string.camera_wifi_remote_focus_match');
    if (live.focusState === 1) return $r('app.string.camera_wifi_remote_focus_deviated');
    return '';
  }

  private focusBadgeColor(): ResourceStr {
    const live = this.live;
    if (live === null) return $r('app.color.text_secondary');
    if (live.focusDrive === 1) return $r('app.color.text_secondary');
    if (live.focusState === 2) return $r('app.color.status_connected');
    if (live.focusState === 1) return $r('app.color.button_danger');
    return $r('app.color.text_secondary');
  }

  private afColor(): ResourceStr {
    const live = this.live;
    if (live === null) return $r('app.color.text_on_dark');
    if (live.focusState === 2) return $r('app.color.status_connected');
    if (live.focusState === 1) return $r('app.color.button_danger');
    return $r('app.color.text_on_dark');
  }

  /** 把 wholeSize 坐标里的 AF 框映射到 Contain 后的屏幕矩形。 */
  private afRect(box: AfBox): number[] {
    const live = this.live;
    if (live === null || live.afWidth <= 0 || live.afHeight <= 0
      || live.frameWidth <= 0 || live.frameHeight <= 0) {
      return [];
    }
    if (box.cx <= 0 || box.cy <= 0 || box.w <= 0 || box.h <= 0
      || box.cx > live.afWidth || box.cy > live.afHeight
      || box.w > live.afWidth || box.h > live.afHeight) {
      return [];
    }
    if (this.imageScale() <= 0) return [];
    const drawW = this.imageWidth();
    const drawH = this.imageHeight();
    const left = this.imageLeft();
    const top = this.imageTop();
    const w = Math.max(8, box.w / live.afWidth * drawW);
    const h = Math.max(8, box.h / live.afHeight * drawH);
    const cx = left + box.cx / live.afWidth * drawW;
    const cy = top + box.cy / live.afHeight * drawH;
    const x = Math.max(left, Math.min(left + drawW - w, cx - w / 2));
    const y = Math.max(top, Math.min(top + drawH - h, cy - h / 2));
    return [x, y, w, h];
  }

  private afRectAt(index: number): number[] {
    const live = this.live;
    if (live === null || index < 0 || index >= live.afBoxes.length) return [];
    return this.afRect(live.afBoxes[index]);
  }


  private onShutter(): void {
    if (!this.canShoot()) return;
    Haptics.tap();
    if (this.live !== null && this.live.movieMode) {
      const wasRecording = this.live.movieRecording;
      const op = wasRecording ? this.live.stopMovie() : this.live.startMovie();
      op.then((ok: boolean) => {
        if (ok && wasRecording) this.mediaChanged = true;
      }).catch((_e: Error) => {
        // 错误已写进 live.error
      });
      return;
    }
    this.live?.capture().then((ok: boolean) => {
      if (ok) this.mediaChanged = true;
    }).catch((_e: Error) => {
      // 错误已写进 live.error
    });
  }

  private switchMode(movie: boolean): void {
    if (!this.canSwitchMode() || this.live === null) return;
    Haptics.tap();
    this.live.setMovieMode(movie).catch((_e: Error) => {
      // 错误已写进 live.error
    });
  }

  private onAf(): void {
    if (!this.canAf()) return;
    Haptics.tap();
    this.live?.afDrive().catch((_e: Error) => {
      // 同上
    });
  }

  private onZoom(tele: boolean): void {
    if (!this.canZoom()) return;
    Haptics.tap();
    this.live?.zoom(tele).catch((_e: Error) => {
      // 同上
    });
  }

  /**
   * 点画面：把取景台内坐标换算成实时取景 JPEG 像素坐标。
   *
   * 画面按 Contain 摆在取景台中央，四周留出呼吸边距；这里用同一套几何算
   * 显示矩形，落在画面外的点击直接忽略，避免把焦点移到画面外。
   */
  private onLiveTap(event: ClickEvent): void {
    const live = this.live;
    if (live === null || !live.active || live.frameWidth <= 0 || live.frameHeight <= 0
      || live.exposureWriting !== '' || live.settingsWriting !== '') {
      return;
    }
    const drawW = this.imageWidth();
    const drawH = this.imageHeight();
    if (drawW <= 0 || drawH <= 0) return;
    const left = this.imageLeft();
    const top = this.imageTop();
    if (event.x < left || event.y < top || event.x > left + drawW || event.y > top + drawH) {
      return;
    }
    // 画面按 JPEG 的宽高比摆放，但 ChangeAfArea 用的是头里的 wholeSize 坐标系。
    const afW = live.afWidth > 0 ? live.afWidth : live.frameWidth;
    const afH = live.afHeight > 0 ? live.afHeight : live.frameHeight;
    const px = (event.x - left) / drawW * afW;
    const py = (event.y - top) / drawH * afH;
    this.svc.getLog().add(`实时取景: 点按 (${Math.round(event.x)},${Math.round(event.y)})`
      + ` → AF (${Math.round(px)},${Math.round(py)}) / ${afW}x${afH}`);

    this.focusX = event.x;
    this.focusY = event.y;
    // 自动区域 / 3D 跟踪不接受点选，点画面只触发对焦；此时不画本地十字，
    // 避免看起来像对焦点被移过去了。
    this.focusVisible = live.supportsPointAf();
    if (this.focusTimer >= 0) clearTimeout(this.focusTimer);
    if (this.focusVisible) {
      this.focusTimer = setTimeout(() => {
        this.focusVisible = false;
        this.focusTimer = -1;
      }, 800);
    } else {
      this.focusTimer = -1;
    }
    live.focusAt(px, py).catch((_e: Error) => { /* 错误已写进 live.error */ });
  }

  private settingsIdle(): boolean {
    const live = this.live;
    return live !== null && live.exposureWriting === '' && live.settingsWriting === '';
  }

  @Builder
  TopBar() {
    Row({ space: 8 }) {
      Row() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(IconSize.Nav)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(20)
        .onClick(() => { this.pageInfos.pop(); })

        Column({ space: 2 }) {
          Text($r('app.string.camera_wifi_remote_title'))
            .fontSize(FontSize.CardTitle)
            .fontWeight(FontWeight.Medium)
            .lineHeight(22)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Row({ space: 4 }) {
            Circle()
              .width(6)
              .height(6)
              .fill(this.statusDotColor())
            Text(this.statusText())
              .fontSize(FontSize.Section)
              .lineHeight(17)
              .fontColor(this.statusColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 120 })
            if (this.live !== null && this.live.active && this.live.error === ''
              && this.live.fps > 0) {
              Text('·')
                .fontSize(FontSize.Caption)
                .lineHeight(17)
                .fontColor($r('app.color.text_tertiary'))
              Text($r('app.string.camera_wifi_remote_fps', this.live.fps))
                .fontSize(FontSize.Caption)
                .lineHeight(17)
                .fontColor($r('app.color.text_tertiary'))
                .flexShrink(0)
            }
          }
          .height(17)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .constraintSize({ maxWidth: 300 })
      .height(56)
      .padding({ left: 8, right: 16 })
      .borderRadius(28)
      .backgroundColor(GlassEffect.isEnabled() ? Color.Transparent : $r('app.color.bg_surface'))
      .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        interactive: true
      })))

      Blank()

      if (this.focusBadgeVisible()) {
        this.FocusBadge()
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .position({ x: 0, y: this.statusBarVp() + 6 })
  }

  @Builder
  FocusBadge() {
    Row({ space: 6 }) {
      Circle()
        .width(6)
        .height(6)
        .fill(this.focusDotColor())
      Text(this.focusBadgeText())
        .fontSize(FontSize.Caption)
        .lineHeight(16)
        .fontColor(this.focusBadgeColor())
        .maxLines(1)
    }
    .height(36)
    .padding({ left: 10, right: 12 })
    .borderRadius(18)
    .backgroundColor(GlassEffect.isEnabled() ? Color.Transparent : $r('app.color.bg_surface'))
    .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      interactive: true
    })))
  }

  private focusDotColor(): ResourceStr {
    const live = this.live;
    if (live === null) return $r('app.color.text_tertiary');
    if (live.focusDrive === 1) return $r('app.color.status_disconnected');
    if (live.focusState === 2) return $r('app.color.status_connected');
    if (live.focusState === 1) return $r('app.color.button_danger');
    return $r('app.color.text_tertiary');
  }

  /**
   * 背景不是纯黑：把同一帧再铺一层低透明度 Cover，再盖一层主题色压暗。
   *
   * 3:2 的画面放在竖屏上必然会有上下留白；留白延续取景内容的颜色，玻璃材质
   * 才有东西可以折射，也不会像在黑幕上悬着一块图。两层都是同一个 PixelMap，
   * 只有一次解码。
   */
  @Builder
  Backdrop() {
    Stack() {
      if (this.live !== null && this.live.frameVersion >= 0
        && this.live.getPixelMap() !== null) {
        Image(this.live.getPixelMap())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.Low)
          .blur(44)
          .scale({ x: 1.12, y: 1.12 })
          .opacity(0.55)
      }
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.remote_scrim_top'), 0.0],
            [$r('app.color.remote_scrim_mid'), 0.46],
            [$r('app.color.remote_scrim_bottom'), 1.0]
          ]
        })
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }

  @Builder
  EmptyState() {
    Column({ space: 10 }) {
      if (this.live !== null && this.live.starting) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color($r('app.color.primary'))
      } else {
        SymbolGlyph($r('sys.symbol.camera'))
          .fontSize(36)
          .fontColor([$r('app.color.text_tertiary')])
      }

      Text(this.emptyText())
        .fontSize(FontSize.Reading)
        .lineHeight(20)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(4)
        .padding({ left: 4, right: 4 })

      if (this.live === null || (!this.live.active && !this.live.starting)) {
        Button($r('app.string.camera_wifi_remote_restart'))
          .height(36)
          .padding({ left: 16, right: 16 })
          .fontSize(FontSize.Body)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.primary_soft'))
          .borderRadius(18)
          .onClick(() => { this.restartLive(); })
      }
    }
    .width('84%')
    .constraintSize({ maxWidth: 320 })
    .padding({ left: 24, right: 24, top: 22, bottom: 20 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
    .shadow(CardShadow)
  }

  @Builder
  LiveStage() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.live !== null && this.live.frameVersion >= 0
        && this.live.getPixelMap() !== null
        && this.imageWidth() > 0 && this.imageHeight() > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Image(this.live.getPixelMap())
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            // 实时取景是连续换帧，High 插值只在静态大图上值回票价；
            // 这里用 Medium 减少每帧的 GPU 采样开销。
            .interpolation(ImageInterpolation.Medium)
            .borderRadius(Radius.Inner)
            .clip(true)
        }
        .width(this.imageWidth())
        .height(this.imageHeight())
        .border({ width: 0.5, color: $r('app.color.remote_image_rim') })
        .borderRadius(Radius.Inner)
        .shadow({
          radius: 26,
          color: $r('app.color.remote_image_shadow'),
          offsetX: 0,
          offsetY: 10
        })
        .hitTestBehavior(HitTestMode.None)

        this.AfBoxes()
      } else {
        this.EmptyState()
      }

      if (this.focusVisible && this.stageW > 52 && this.stageH > 52) {
        Stack({ alignContent: Alignment.Center }) {
          Row()
            .width(52)
            .height(52)
            .border({ width: 3, color: $r('app.color.viewer_scrim') })
            .borderRadius(12)
          Row()
            .width(46)
            .height(46)
            .border({ width: 1.5, color: $r('app.color.text_on_dark') })
            .borderRadius(9)
          Row()
            .width(4)
            .height(4)
            .borderRadius(2)
            .backgroundColor($r('app.color.text_on_dark'))
        }
        .width(52)
        .height(52)
        .position({
          x: Math.max(0, Math.min(this.stageW - 52, this.focusX - 26)),
          y: Math.max(0, Math.min(this.stageH - 52, this.focusY - 26))
        })
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.live !== null && this.live.active && this.live.error !== ''
        && this.stageW > 24) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(IconSize.Body)
            .fontColor([$r('app.color.status_error')])
          Text(this.live.error)
            .fontSize(FontSize.Caption)
            .lineHeight(18)
            .fontColor($r('app.color.status_error'))
            .maxLines(2)
            .layoutWeight(1)
        }
        .width(this.stageW - 24)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.remote_error_bg'))
        .borderRadius(Radius.Chip)
        .position({ x: 12, y: 8 })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .onAreaChange((_old: Area, now: Area) => {
      this.stageW = Number(now.width);
      this.stageH = Number(now.height);
    })
    .onClick((event: ClickEvent) => { this.onLiveTap(event); })
  }

  /** 相机实时取景头里返回的 AF 框；不是本地点击画的假框。 */
  @Builder
  AfBoxAt(index: number) {
    if (this.afRectAt(index).length === 4) {
      Stack({ alignContent: Alignment.Center }) {
        Row()
          .width(this.afRectAt(index)[2] + 4)
          .height(this.afRectAt(index)[3] + 4)
          .border({ width: 3, color: $r('app.color.viewer_scrim') })
          .borderRadius(4)
        Row()
          .width(this.afRectAt(index)[2])
          .height(this.afRectAt(index)[3])
          .border({ width: 1.5, color: this.afColor() })
          .borderRadius(2)
        Row()
          .width(4)
          .height(4)
          .borderRadius(2)
          .backgroundColor(this.afColor())
      }
      .width(this.afRectAt(index)[2] + 4)
      .height(this.afRectAt(index)[3] + 4)
      .position({
        x: this.afRectAt(index)[0] - 2,
        y: this.afRectAt(index)[1] - 2
      })
      .hitTestBehavior(HitTestMode.None)
    }
  }

  @Builder
  AfBoxes() {
    // 固定画前 5 块，直接按下标读取，避免 Repeat 按 key 复用单元格导致
    // 「日志里框动了、画面不动」。自动区域 AF 会同时返回多块框。
    this.AfBoxAt(0)
    this.AfBoxAt(1)
    this.AfBoxAt(2)
    this.AfBoxAt(3)
    this.AfBoxAt(4)
  }

  @Builder
  VDivider() {
    Row()
      .width(0.5)
      .height(22)
      .backgroundColor($r('app.color.divider'))
  }

  /** 专业参数条：一行排下模式 / ISO / 光圈 / 快门 / EV / AF / WB，数值直接可点。 */
  @Builder
  ProParamsRow() {
    Row() {
      Column({ space: 1 }) {
        Text($r('app.string.camera_wifi_remote_mode'))
          .fontSize(FontSize.Micro)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
        Text(this.exposureModeLabel())
          .fontSize(FontSize.Reading)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .height(52)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      this.VDivider()
      RemoteExposureCell({
        label: $r('app.string.camera_wifi_remote_iso'),
        currentValue: this.exposureValue(EXPOSURE_PARAM_ISO),
        isEnabled: this.canAdjustExposureParam(EXPOSURE_PARAM_ISO),
        isActive: this.dialOpen && this.dialParam === EXPOSURE_PARAM_ISO,
        onTap: () => { this.openExposureDial(EXPOSURE_PARAM_ISO); }
      })
      this.VDivider()
      RemoteExposureCell({
        label: $r('app.string.camera_wifi_remote_aperture'),
        currentValue: this.exposureValue(EXPOSURE_PARAM_APERTURE),
        isEnabled: this.canAdjustExposureParam(EXPOSURE_PARAM_APERTURE),
        isActive: this.dialOpen && this.dialParam === EXPOSURE_PARAM_APERTURE,
        onTap: () => { this.openExposureDial(EXPOSURE_PARAM_APERTURE); }
      })
      this.VDivider()
      RemoteExposureCell({
        label: $r('app.string.camera_wifi_remote_shutter'),
        currentValue: this.exposureValue(EXPOSURE_PARAM_SHUTTER),
        isEnabled: this.canAdjustExposureParam(EXPOSURE_PARAM_SHUTTER),
        isActive: this.dialOpen && this.dialParam === EXPOSURE_PARAM_SHUTTER,
        onTap: () => { this.openExposureDial(EXPOSURE_PARAM_SHUTTER); }
      })
      this.VDivider()
      RemoteExposureCell({
        label: $r('app.string.camera_wifi_remote_ev'),
        currentValue: this.exposureValue(EXPOSURE_PARAM_EV),
        isEnabled: this.canAdjustExposureParam(EXPOSURE_PARAM_EV),
        isActive: this.dialOpen && this.dialParam === EXPOSURE_PARAM_EV,
        onTap: () => { this.openExposureDial(EXPOSURE_PARAM_EV); }
      })
      this.VDivider()
      this.FocusTool()
      this.VDivider()
      this.WbTool()
    }
    .width('100%')
    .height(56)
    .padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  WbTool() {
    Row() {
      RemoteExposureCell({
        label: $r('app.string.camera_wifi_remote_wb_abbr'),
        currentValue: this.whiteBalanceLabel(),
        isEnabled: this.canAdjustWb(),
        isActive: this.dialOpen && this.dialParam === DIAL_WB,
        onTap: () => { this.openWbDial(); }
      })
    }
    .layoutWeight(1)
  }

  @Builder
  FocusTool() {
    Row() {
      RemoteExposureCell({
        label: $r('app.string.camera_wifi_remote_af_abbr'),
        currentValue: this.focusModeLabel(),
        isEnabled: this.canAdjustFocus(),
        onTap: () => { this.openFocus(); }
      })
    }
    .layoutWeight(1)
    .bindSheet($$this.focusSheetOpen, this.FocusSheet(), this.sheetOptions($r('app.string.camera_wifi_remote_focus_settings')))
  }

  @Builder
  CaptureRow() {
    Column({ space: 8 }) {
      RemoteZoomBar({
        isEnabled: this.canZoom(),
        onWide: () => { this.onZoom(false); },
        onTele: () => { this.onZoom(true); }
      })

      Row() {
        Column() {
          RemoteRoundControl({
            label: $r('app.string.camera_wifi_remote_af_abbr'),
            diameter: 52,
            labelSize: 16,
            isEnabled: this.canAf(),
            onTap: () => { this.onAf(); }
          })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Column() {
          RemoteShutter({
            isMovie: this.live !== null && this.live.movieMode,
            isRecording: this.live !== null && this.live.movieRecording,
            isShooting: this.live !== null && this.live.shooting,
            isEnabled: this.canShoot(),
            onTap: () => { this.onShutter(); }
          })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Column() {
          if (this.live !== null && this.live.supportsMovie) {
            RemoteModeButton({
              isMovie: this.live.movieMode,
              isEnabled: this.canSwitchMode(),
              onToggle: () => { this.switchMode(this.live !== null && !this.live.movieMode); }
            })
          } else {
            Blank().width(52).height(52)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height(64)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(132)
    .padding({ top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  BottomDeck() {
    Column() {
      this.ProParamsRow()
      Row()
        .width('100%')
        .height(0.5)
        .backgroundColor($r('app.color.divider'))
      this.CaptureRow()
    }
    .width(this.deckWidthVp())
    .height(REMOTE_DECK_HEIGHT)
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .borderRadius(Radius.Card)
    .backgroundColor(GlassEffect.isEnabled() ? Color.Transparent : $r('app.color.bg_surface'))
    .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      interactive: true,
      materialColor: $r('app.color.remote_material_tint')
    })))
    .position({ x: this.deckX(), y: this.deckY() })
  }

  /**
   * 专业参数拨盘：点击参数条上的 ISO / 光圈 / 快门 / EV / WB 后，在控制台上方
   * 浮出一条可横向滑动、中心指针取值的刻度盘；松手才写相机。
   */
  @Builder
  DialPanel() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text(this.dialTitle())
          .fontSize(FontSize.Section)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
        Row() {
          Blank()
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(IconSize.Body)
              .fontColor([$r('app.color.text_secondary')])
          }
          .width(28)
          .height(28)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .borderRadius(14)
          .onClick(() => { this.closeDial(); })
        }
        .width('100%')
        .height(28)
      }
      .width('100%')
      .height(24)

      if (this.dialOptions().length === 0) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color($r('app.color.primary'))
          Text($r('app.string.camera_wifi_remote_exposure_loading'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .height(48)
        .justifyContent(FlexAlign.Center)
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Scroll(this.dialScroller) {
            Row() {
              Row().width(this.dialSpacerWidth())
              Repeat(this.dialOptions()).each((item: RepeatItem<ExposureOption>) => {
                Column() {
                  Row()
                    .width(1)
                    .height(6)
                    .backgroundColor($r('app.color.text_tertiary'))
                  Text(item.item.label)
                    .fontSize(FontSize.Caption)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                }
                .width(DIAL_ITEM_WIDTH)
                .height(48)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick(() => { this.selectDialIndex(item.index); })
              }).key((item: ExposureOption) => `${item.value}`)
              Row().width(this.dialSpacerWidth())
            }
            .height(48)
          }
          .width('100%')
          .height(48)
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
          .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(24) })
          .onScrollStart(() => { this.onDialScrollStart(); })
          .onDidScroll(() => { this.onDialScroll(); })
          .onScrollStop(() => { this.onDialScrollStop(); })

          Column() {
            Row()
              .width(2)
              .height(12)
              .borderRadius(1)
              .backgroundColor($r('app.color.primary'))
          }
          .width('100%')
          .height(48)
          .justifyContent(FlexAlign.Start)
          .alignItems(HorizontalAlign.Center)
          .hitTestBehavior(HitTestMode.None)

          Stack() {
            // 拖动时透明，刻度数字从下面透出来；停稳后这层不透明底淡入，盖住
            // 滚动标签，让胶囊里的蓝色大数字成为唯一读数。
            Row()
              .width(DIAL_ITEM_WIDTH)
              .height(28)
              .borderRadius(14)
              .backgroundColor($r('app.color.bg_surface'))
              .opacity(this.dialShowValue || !GlassEffect.isEnabled() ? 1 : 0)
              .animation({ duration: 180, curve: Curve.EaseOut })

            Row()
              .width(DIAL_ITEM_WIDTH)
              .height(28)
              .borderRadius(14)
              .backgroundColor(GlassEffect.isEnabled() ? Color.Transparent : $r('app.color.bg_surface'))
              .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
                style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
                interactive: true,
                materialColor: $r('app.color.remote_material_tint')
              })))
              .shadow({
                radius: 6,
                color: $r('app.color.remote_image_shadow'),
                offsetX: 0,
                offsetY: 2
              })
              .opacity(this.dialShowValue ? 1 : 0.12)
              .animation({ duration: 180, curve: Curve.EaseOut })

            Row()
              .width(DIAL_ITEM_WIDTH)
              .height(28)
              .borderRadius(14)
              .border({ width: 0.5, color: $r('app.color.remote_image_rim') })

            Text(this.dialValueLabel())
              .width(DIAL_ITEM_WIDTH)
              .fontSize(FontSize.CardTitle)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary'))
              .textAlign(TextAlign.Center)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .opacity(this.dialShowValue ? 1 : 0)
              .scale({ x: this.dialShowValue ? 1 : 0.82, y: this.dialShowValue ? 1 : 0.82 })
              .animation({ duration: 200, curve: Curve.EaseOut })
          }
          .width(DIAL_ITEM_WIDTH)
          .height(28)
          .offset({ y: 0 })
          .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height(48)
      }
    }
    .width(this.deckWidthVp())
    .height(DIAL_PANEL_HEIGHT)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(Radius.Card)
    .backgroundColor(GlassEffect.isEnabled() ? Color.Transparent : $r('app.color.bg_surface'))
    .border({ width: 0.5, color: $r('app.color.remote_image_rim') })
    .shadow(CardShadow)
    .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      interactive: true,
      materialColor: $r('app.color.remote_material_tint')
    })))
    .onAppear(() => { this.syncDialToCurrent(); })
    .position({ x: this.deckX(), y: this.deckY() - DIAL_PANEL_HEIGHT - 8 })
  }

  /**
   * 整页都画在标题栏 builder 里。
   *
   * 沉浸光感的材质只认 Navigation/NavDestination 标题栏与底部 TabBar；而这一页
   * 既需要底部一整块玻璃控制台，又不能让标题栏盖住取景区的点按。把取景台、
   * 顶部胶囊和控制台放进同一个标题栏树，材质拿到了，点按也仍然落在取景台上。
   */
  @Builder
  PageBody() {
    Stack() {
      this.Backdrop()
      Column() {
        Blank().height(this.topBarHeight() + 8)
        this.LiveStage()
        Blank().height(this.stageBottomSpace())
      }
      .width('100%')
      .height('100%')

      this.TopBar()
      if (this.deckVisible()) {
        this.BottomDeck()
      }
      if (this.dialOpen) {
        this.DialPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .bindSheet($$this.exposureSheetOpen, this.ExposureSheet(), this.sheetOptions(this.exposureTitle(this.exposureParam)))
  }

  @Builder
  LoadingRow(text: ResourceStr) {
    Row({ space: 8 }) {
      LoadingProgress()
        .width(18)
        .height(18)
        .color($r('app.color.primary'))
      Text(text)
        .fontSize(FontSize.Caption)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 24, bottom: 24 })
  }

  @Builder
  EmptyRow() {
    Text($r('app.string.camera_wifi_remote_exposure_empty'))
      .fontSize(FontSize.Caption)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 24, bottom: 24 })
  }

  /** 参数选择半模态：只列相机返回的可用值，选中后写相机并回读。 */
  @Builder
  ExposureSheet() {
    Column({ space: 12 }) {
      RemoteSheetIntro({
        hint: $r('app.string.camera_wifi_remote_exposure_hint'),
        currentValue: this.exposureValue(this.exposureParam)
      })

      if (this.live !== null && this.live.exposureLoading
        && this.currentExposureOptions().length === 0) {
        this.LoadingRow($r('app.string.camera_wifi_remote_exposure_loading'))
      } else if (this.currentExposureOptions().length === 0) {
        this.EmptyRow()
      } else {
        Scroll() {
          Column({ space: 2 }) {
            Repeat(this.currentExposureOptions()).each((item: RepeatItem<ExposureOption>) => {
              RemoteOptionRow({
                label: item.item.label,
                isSelected: this.isSelectedExposure(item.item.value),
                isEnabled: this.settingsIdle(),
                onTap: () => { this.applyExposure(item.item.value); }
              })
            }).key((opt: ExposureOption) => `${opt.value}`)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // Scroll 在顶部继续上滑时把手势交给半模态换挡/展开，下滑时先滚列表。
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 12, bottom: 24 })
    // 系统材质很薄，取景画面亮时隔着玻璃看列表会花；这一层同色薄洗只压
    // 内容区，不动半模态自己的材质和圆角。
    .backgroundColor($r('app.color.remote_sheet_wash'))
  }

  /** 白平衡：只列相机描述里的枚举值，选中后写相机并回读。 */
  @Builder
  WhiteBalanceSheet() {
    Column({ space: 12 }) {
      RemoteSheetIntro({
        hint: $r('app.string.camera_wifi_remote_wb_hint'),
        currentValue: this.whiteBalanceLabel()
      })

      if (this.wbLoading() && this.wbOptions().length === 0) {
        this.LoadingRow($r('app.string.camera_wifi_remote_exposure_loading'))
      } else if (this.wbOptions().length === 0) {
        this.EmptyRow()
      } else {
        Scroll() {
          Column({ space: 2 }) {
            Repeat(this.wbOptions()).each((item: RepeatItem<CameraOption>) => {
              RemoteOptionRow({
                label: item.item.label,
                isSelected: this.isSelectedWb(item.item.value),
                isEnabled: this.settingsIdle(),
                onTap: () => { this.applyWhiteBalance(item.item.value); }
              })
            }).key((opt: CameraOption) => `wb-${opt.value}`)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // Scroll 在顶部继续上滑时把手势交给半模态换挡/展开，下滑时先滚列表。
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 12, bottom: 24 })
    .backgroundColor($r('app.color.remote_sheet_wash'))
  }

  /** 对焦设置：AF 模式与 AF 区域分两组，选完不关面板，方便连续调整。 */
  @Builder
  FocusSheet() {
    Column({ space: 12 }) {
      RemoteSheetIntro({
        hint: $r('app.string.camera_wifi_remote_af_hint'),
        currentValue: this.focusSettingLabel(),
        valueSize: 13
      })

      if (this.focusLoading() && this.afModeOptions().length === 0
        && this.afAreaOptions().length === 0) {
        this.LoadingRow($r('app.string.camera_wifi_remote_focus_loading'))
      } else if (this.afModeOptions().length === 0 && this.afAreaOptions().length === 0) {
        this.EmptyRow()
      } else {
        Scroll() {
          Column({ space: 2 }) {
            Text($r('app.string.camera_wifi_remote_af_mode'))
              .fontSize(FontSize.Caption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 12, top: 4, bottom: 4 })
            Repeat(this.afModeOptions()).each((item: RepeatItem<CameraOption>) => {
              RemoteOptionRow({
                label: item.item.label,
                isSelected: this.isSelectedAfMode(item.item.value),
                isEnabled: this.settingsIdle(),
                onTap: () => { this.applyAfMode(item.item.value); }
              })
            }).key((opt: CameraOption) => `afm-${opt.value}`)

            Text($r('app.string.camera_wifi_remote_af_area'))
              .fontSize(FontSize.Caption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 12, top: 16, bottom: 4 })
            Repeat(this.afAreaOptions()).each((item: RepeatItem<CameraOption>) => {
              RemoteOptionRow({
                label: item.item.label,
                isSelected: this.isSelectedAfArea(item.item.value),
                isEnabled: this.settingsIdle(),
                onTap: () => { this.applyAfArea(item.item.value); }
              })
            }).key((opt: CameraOption) => `afa-${opt.value}`)

            Text($r('app.string.camera_wifi_remote_af_point_hint'))
              .fontSize(FontSize.Caption)
              .lineHeight(18)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 12, right: 12, top: 16, bottom: 8 })
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // Scroll 在顶部继续上滑时把手势交给半模态换挡/展开，下滑时先滚列表。
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 12, bottom: 24 })
    .backgroundColor($r('app.color.remote_sheet_wash'))
  }

  build() {
    NavDestination() {
      // 页面主体全部由标题栏 builder 承担；内容区只保留一层主题底色。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
    }
    .title({
      builder: this.PageBody,
      // 标题栏铺满整屏，页面才有足够空间放取景台和底部玻璃控制台。
      height: this.screenHeightVp()
    }, {
      // STACK：NavDestination 的内容层不再参与布局，取景、背景和控制台都由
      // 标题栏 builder 自己铺满整屏。
      barStyle: BarStyle.STACK,
      systemMaterial: uiMaterial.Material.empty
    })
    .hideBackButton(true)
    .backgroundColor($r('app.color.bg_page'))
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}


/** 曝光读数格：没有独立底色，整条读数共享控制台的玻璃。 */
@ComponentV2
struct RemoteExposureCell {
  @Param label: ResourceStr = '';
  @Param currentValue: string = '--';
  @Param isEnabled: boolean = true;
  @Param isActive: boolean = false;
  @Event onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Column({ space: 1 }) {
        Text(this.label)
          .fontSize(FontSize.Micro)
          .fontColor(this.isActive ? $r('app.color.primary') : $r('app.color.text_secondary'))
          .maxLines(1)
        Text(this.currentValue)
          .fontSize(FontSize.Reading)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isActive ? $r('app.color.primary') : $r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .height(52)
    .padding({ left: 2, right: 2 })
    .backgroundColor(this.isActive ? $r('app.color.primary_soft') : Color.Transparent)
    .borderRadius(10)
    .enabled(this.isEnabled)
    .opacity(this.isEnabled ? 1 : 0.35)
    .onClick(() => { this.onTap(); })
  }
}

/** 拍照 / 录像模式：参考系统相机底部的圆形侧键，图标 + 当前模式，点击切换。 */
@ComponentV2
struct RemoteModeButton {
  @Param isMovie: boolean = false;
  @Param isEnabled: boolean = true;
  @Event onToggle: () => void = () => {};

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      Column({ space: 2 }) {
        if (this.isMovie) {
          SymbolGlyph($r('sys.symbol.video'))
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        } else {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
        Text(this.isMovie
          ? $r('app.string.camera_wifi_remote_movie_mode')
          : $r('app.string.camera_wifi_remote_photo_mode'))
          .fontSize(FontSize.Micro)
          .lineHeight(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
      }
    }
    .width(52)
    .height(52)
    .padding(0)
    .backgroundColor($r('app.color.filter_chip_bg'))
    .borderRadius(26)
    .enabled(this.isEnabled)
    .opacity(this.isEnabled ? 1 : 0.35)
    .onClick(() => { this.onToggle(); })
  }
}

/** 圆形工具：AF。说明文字统一放在拍摄行的标签行，控制本身只保留一个圆钮。 */
@ComponentV2
struct RemoteRoundControl {
  @Param label: ResourceStr = '';
  @Param diameter: number = 40;
  @Param labelSize: number = 16;
  @Param isEnabled: boolean = true;
  @Event onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Stack({ alignContent: Alignment.Center }) {
        Text(this.label)
          .fontSize(this.labelSize)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
      }
      .width(this.diameter)
      .height(this.diameter)
      .borderRadius(this.diameter / 2)
      .backgroundColor($r('app.color.filter_chip_bg'))
    }
    .width(this.diameter)
    .height(this.diameter)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .borderRadius(this.diameter / 2)
    .enabled(this.isEnabled)
    .opacity(this.isEnabled ? 1 : 0.35)
    .onClick(() => { this.onTap(); })
  }
}

/** 变焦：参考系统相机的横向变焦条，两个方向各占半条，点击区约 97×32。 */
@ComponentV2
struct RemoteZoomBar {
  @Param isEnabled: boolean = true;
  @Event onWide: () => void = () => {};
  @Event onTele: () => void = () => {};

  build() {
    Row() {
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row({ space: 4 }) {
          Text('−')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.camera_wifi_remote_wide'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
      }
      .layoutWeight(1)
      .height(32)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(16)
      .enabled(this.isEnabled)
      .onClick(() => { this.onWide(); })

      Row()
        .width(0.5)
        .height(16)
        .backgroundColor($r('app.color.divider'))
        .opacity(0.7)

      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row({ space: 4 }) {
          Text('+')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.camera_wifi_remote_tele'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
      }
      .layoutWeight(1)
      .height(32)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(16)
      .enabled(this.isEnabled)
      .onClick(() => { this.onTele(); })
    }
    .width(200)
    .height(36)
    .padding(2)
    .borderRadius(18)
    .backgroundColor($r('app.color.filter_chip_bg'))
    .opacity(this.isEnabled ? 1 : 0.35)
  }
}

/** 快门：外圈 + 内圆；录像模式内圈变红，录制中显示方块。 */
@ComponentV2
struct RemoteShutter {
  @Param isMovie: boolean = false;
  @Param isRecording: boolean = false;
  @Param isShooting: boolean = false;
  @Param isEnabled: boolean = true;
  @Event onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      Stack({ alignContent: Alignment.Center }) {
        Row()
          .width(64)
          .height(64)
          .borderRadius(32)
          .border({
            width: 2,
            color: this.isMovie ? $r('app.color.button_danger') : $r('app.color.text_primary')
          })
        Row()
          .width(52)
          .height(52)
          .borderRadius(26)
          .backgroundColor(this.isMovie ? $r('app.color.button_danger') : $r('app.color.text_primary'))
        if (this.isRecording) {
          Row()
            .width(16)
            .height(16)
            .borderRadius(3)
            .backgroundColor($r('app.color.text_on_dark'))
        } else if (this.isShooting) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color($r('app.color.bg_surface'))
        }
      }
      .width(64)
      .height(64)
    }
    .width(64)
    .height(64)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .borderRadius(32)
    .enabled(this.isEnabled)
    .opacity(this.isEnabled ? 1 : 0.45)
    .onClick(() => { this.onTap(); })
  }
}

/** 半模态说明行：左边是相机能力说明，右边是当前值。标题已交给系统标题区。 */
@ComponentV2
struct RemoteSheetIntro {
  @Param hint: ResourceStr = '';
  @Param currentValue: string = '--';
  @Param valueSize: number = 20;

  build() {
    Row({ space: 12 }) {
      Text(this.hint)
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .layoutWeight(1)

      Column({ space: 1 }) {
        Text($r('app.string.camera_wifi_remote_current'))
          .fontSize(FontSize.Micro)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
        Text(this.currentValue)
          .fontSize(this.valueSize)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary'))
          .maxLines(this.valueSize >= 18 ? 1 : 2)
          .textAlign(TextAlign.End)
          .constraintSize({ maxWidth: this.valueSize >= 18 ? 120 : 150 })
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.End)
      .flexShrink(0)
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Top)
  }
}

/** 半模态选项行：选中态用主色浅底 + 勾选，按下有系统水波纹。 */
@ComponentV2
struct RemoteOptionRow {
  @Param label: string = '';
  @Param isSelected: boolean = false;
  @Param isEnabled: boolean = true;
  @Event onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 10 }) {
        Text(this.label)
          .fontSize(FontSize.Body)
          .fontColor(this.isSelected
            ? $r('app.color.primary') : $r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.isSelected) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(IconSize.Body)
            .fontColor([$r('app.color.primary')])
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .height(48)
    .padding(0)
    .backgroundColor(this.isSelected
      ? $r('app.color.primary_soft') : Color.Transparent)
    .borderRadius(Radius.Chip)
    .enabled(this.isEnabled)
    .opacity(this.isEnabled ? 1 : 0.45)
    .onClick(() => { this.onTap(); })
  }
}
