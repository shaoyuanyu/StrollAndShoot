/**
 * WifiRemotePage.ets
 *
 * Wi-Fi STA 实时取景 + 遥控拍摄。
 *
 * 页面只做三件事：
 * 1. 把 `NikonWifiLiveView` 的帧画在黑色画布上；
 * 2. 点画面 → 移动 AF 区域并驱动一次对焦；
 * 3. 底部快门 / AF / 变焦三个入口。
 *
 * 离开页面 = 结束实时取景并把控制权还给相机；相机在实时取景期间会锁回放/
 * 菜单（和蓝牙遥控一样），不能只靠用户按返回。
 */
import { CameraService } from '../services/CameraService';
import { NikonWifiLiveView, type AfBox } from '../services/NikonWifiLiveView';
import {
  EXPOSURE_PARAM_APERTURE,
  EXPOSURE_PARAM_EV,
  EXPOSURE_PARAM_ISO,
  EXPOSURE_PARAM_SHUTTER,
  type ExposureOption
} from '../services/NikonWifiExposure';
import { WindowUtils } from '../utils/WindowUtils';
import { FontSize, IconSize } from '../utils/UiTokens';
import { Haptics } from '../utils/Haptics';

@Builder
export function WifiRemotePageBuilder() {
  WifiRemotePage();
}

@ComponentV2
export struct WifiRemotePage {
  private pageInfos: NavPathStack = new NavPathStack();
  @Local svc: CameraService = CameraService.getInstance();
  @Local live: NikonWifiLiveView | null = null;
  @Local viewW: number = 0;
  @Local viewH: number = 0;
  @Local focusX: number = 0;
  @Local focusY: number = 0;
  @Local focusVisible: boolean = false;
  /** 当前打开的参数面板：'' 表示关闭。 */
  @Local exposureSheetOpen: boolean = false;
  @Local exposureParam: string = '';
  /** 本次遥控里至少产生了一张照片/一段录像；退出页面时自动补一次快速扫描。 */
  private mediaChanged: boolean = false;
  private focusTimer: number = -1;

  aboutToAppear(): void {
    this.applyDarkSystemBars();
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

  /** 黑底页面需要白色状态栏图标；离开时恢复应用主题。 */
  private applyDarkSystemBars(): void {
    const w = WindowUtils.window;
    if (!w) return;
    w.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      statusBarContentColor: '#FFFFFF',
      navigationBarColor: '#00000000',
      navigationBarContentColor: '#FFFFFF'
    }).catch((_e: Error) => { /* best effort */ });
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
    if (live.frameVersion === 0) return $r('app.string.camera_wifi_remote_waiting');
    return $r('app.string.camera_wifi_remote_live');
  }

  private statusColor(): ResourceStr {
    const live = this.live;
    if (live !== null && live.error !== '') return $r('app.color.status_error');
    return $r('app.color.viewer_text_on_dark_70');
  }

  private canShoot(): boolean {
    return this.live !== null && this.live.active && !this.live.shooting
      && !this.live.starting && !this.live.movieSwitching;
  }

  private canSwitchMode(): boolean {
    return this.live !== null && this.live.active && this.live.supportsMovie
      && !this.live.starting && !this.live.movieSwitching && !this.live.movieRecording;
  }

  private canAf(): boolean {
    return this.live !== null && this.live.active && this.live.supportsAf
      && !this.live.focusing;
  }

  private canZoom(): boolean {
    return this.live !== null && this.live.active && this.live.supportsZoom
      && !this.live.zooming;
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
      && !this.live.starting && this.live.exposureWriting === '';
  }

  private openExposure(param: string): void {
    if (!this.canAdjustExposure()) return;
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

  private isSelectedExposure(value: number): boolean {
    const live = this.live;
    return live !== null && live.getExposureRaw(this.exposureParam) === value;
  }

  private exposureSheetOptions(): SheetOptions {
    const opts: SheetOptions = {
      height: SheetSize.MEDIUM,
      preferType: SheetType.BOTTOM,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.bg_surface')
    };
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
    if (live === null) return $r('app.color.viewer_text_on_dark_70');
    if (live.focusDrive === 1) return $r('app.color.viewer_text_on_dark_70');
    if (live.focusState === 2) return $r('app.color.status_connected');
    if (live.focusState === 1) return $r('app.color.button_danger');
    return $r('app.color.viewer_text_on_dark_70');
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
    const scale = Math.min(this.viewW / live.frameWidth, this.viewH / live.frameHeight);
    if (scale <= 0) return [];
    const drawW = live.frameWidth * scale;
    const drawH = live.frameHeight * scale;
    const left = (this.viewW - drawW) / 2;
    const top = (this.viewH - drawH) / 2;
    const w = Math.max(8, box.w / live.afWidth * drawW);
    const h = Math.max(8, box.h / live.afHeight * drawH);
    const cx = left + box.cx / live.afWidth * drawW;
    const cy = top + box.cy / live.afHeight * drawH;
    const x = Math.max(left, Math.min(left + drawW - w, cx - w / 2));
    const y = Math.max(top, Math.min(top + drawH - h, cy - h / 2));
    return [x, y, w, h];
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
   * 点画面：把 Stack 内坐标换算成实时取景 JPEG 像素坐标。
   *
   * Image 用 Contain，画面可能上下或左右留黑；这里按同一比例算显示矩形，
   * 落在黑边里的点击直接忽略，避免把焦点移到画面外。
   */
  private onLiveTap(event: ClickEvent): void {
    const live = this.live;
    if (live === null || !live.active || live.frameWidth <= 0 || live.frameHeight <= 0) {
      return;
    }
    const scale = Math.min(this.viewW / live.frameWidth, this.viewH / live.frameHeight);
    if (scale <= 0) return;
    const drawW = live.frameWidth * scale;
    const drawH = live.frameHeight * scale;
    const left = (this.viewW - drawW) / 2;
    const top = (this.viewH - drawH) / 2;
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
    this.focusVisible = true;
    if (this.focusTimer >= 0) clearTimeout(this.focusTimer);
    this.focusTimer = setTimeout(() => {
      this.focusVisible = false;
      this.focusTimer = -1;
    }, 800);
    live.focusAt(px, py).catch((_e: Error) => { /* 错误已写进 live.error */ });
  }

  @Builder
  TopBar() {
    Row({ space: 10 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(IconSize.Nav)
          .fontColor([$r('app.color.text_on_dark')])
      }
      .width(40)
      .height(40)
      .padding(0)
      .backgroundColor($r('app.color.viewer_glass_button'))
      .borderRadius(20)
      .onClick(() => { this.pageInfos.pop(); })

      Column({ space: 2 }) {
        Text($r('app.string.camera_wifi_remote_title'))
          .fontSize(FontSize.CardTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_on_dark'))
          .maxLines(1)
        Text(this.statusText())
          .fontSize(FontSize.Caption)
          .fontColor(this.statusColor())
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.focusBadgeVisible()) {
        Text(this.focusBadgeText())
          .fontSize(FontSize.Micro)
          .fontColor(this.focusBadgeColor())
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.viewer_glass_button'))
          .borderRadius(9)
          .flexShrink(0)
      }

      if (this.live !== null && this.live.active && this.live.fps > 0) {
        Text($r('app.string.camera_wifi_remote_fps', this.live.fps))
          .fontSize(FontSize.Micro)
          .fontColor($r('app.color.viewer_text_on_dark_70'))
          .flexShrink(0)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 16, top: this.statusBarVp() + 4, bottom: 8 })
  }

  /** 相机实时取景头里返回的 AF 框；不是本地点击画的假框。 */
  @Builder
  AfBoxes() {
    if (this.live !== null && this.live.afBoxes.length > 0
      && this.afRect(this.live.afBoxes[0]).length === 4) {
      Stack({ alignContent: Alignment.Center }) {
        Row()
          .width(this.afRect(this.live.afBoxes[0])[2])
          .height(this.afRect(this.live.afBoxes[0])[3])
          .border({ width: 1.4, color: this.afColor() })
          .backgroundColor(Color.Transparent)
        Row()
          .width(4)
          .height(4)
          .backgroundColor(this.afColor())
      }
      .width(this.afRect(this.live.afBoxes[0])[2])
      .height(this.afRect(this.live.afBoxes[0])[3])
      .position({ x: this.afRect(this.live.afBoxes[0])[0],
        y: this.afRect(this.live.afBoxes[0])[1] })
      .hitTestBehavior(HitTestMode.None)
    }
  }

  @Builder
  LiveCanvas() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.live !== null && this.live.frameVersion >= 0
        && this.live.getPixelMap() !== null) {
        Image(this.live.getPixelMap())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          // 实时取景是连续换帧，High 插值只在静态大图上值回票价；
          // 这里用 Medium 减少每帧的 GPU 采样开销。
          .interpolation(ImageInterpolation.Medium)
        this.AfBoxes()
      } else if (this.live !== null && this.live.starting) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(28).height(28)
            .color($r('app.color.text_on_dark'))
          Text($r('app.string.camera_wifi_remote_connecting'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.viewer_text_on_dark_70'))
        }
      } else {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(36)
            .fontColor([$r('app.color.viewer_text_on_dark_70')])
          Text(this.live === null
            ? $r('app.string.camera_wifi_remote_not_connected')
            : (this.live.error !== ''
              ? this.live.error : $r('app.string.camera_wifi_remote_waiting')))
            .fontSize(FontSize.Reading)
            .fontColor($r('app.color.viewer_text_on_dark_70'))
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .padding({ left: 32, right: 32 })
          if (this.live !== null && !this.live.active && !this.live.starting) {
            Button($r('app.string.camera_wifi_remote_restart'))
              .height(36)
              .padding({ left: 16, right: 16 })
              .fontSize(FontSize.Body)
              .fontColor($r('app.color.text_on_dark'))
              .backgroundColor($r('app.color.viewer_glass_button'))
              .borderRadius(18)
              .onClick(() => { this.restartLive(); })
          }
        }
      }

      if (this.focusVisible) {
        Stack({ alignContent: Alignment.Center }) {
          Row()
            .width(46)
            .height(46)
            .border({ width: 1.5, color: $r('app.color.text_on_dark') })
          Row()
            .width(4).height(4)
            .backgroundColor($r('app.color.text_on_dark'))
        }
        .width(46)
        .height(46)
        .position({
          x: Math.max(0, Math.min(this.viewW - 46, this.focusX - 23)),
          y: Math.max(0, Math.min(this.viewH - 46, this.focusY - 23))
        })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(Color.Black)
    .onAreaChange((_o: Area, now: Area) => {
      this.viewW = Number(now.width);
      this.viewH = Number(now.height);
    })
    .onClick((event: ClickEvent) => { this.onLiveTap(event); })
  }


  @Builder
  Shutter() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(82)
          .height(82)
          .borderRadius(41)
          .border({ width: 2, color: $r('app.color.text_on_dark') })
        Column()
          .width(64)
          .height(64)
          .borderRadius(32)
          .backgroundColor(this.live !== null && this.live.movieMode
            ? $r('app.color.button_danger') : $r('app.color.text_on_dark'))
        if (this.live !== null && this.live.movieRecording) {
          Row()
            .width(18)
            .height(18)
            .borderRadius(3)
            .backgroundColor($r('app.color.text_on_dark'))
        } else if (this.live !== null && this.live.shooting) {
          LoadingProgress()
            .width(24).height(24)
            .color($r('app.color.bg_page'))
        }
      }
      .width(82)
      .height(82)
    }
    .width(82)
    .height(82)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .borderRadius(41)
    .enabled(this.canShoot())
    .opacity(this.canShoot() ? 1 : 0.5)
    .onClick(() => { this.onShutter(); })
  }

  /** 底部一行曝光参数胶囊：光圈 / 快门 / ISO / 曝光补偿。 */
  @Builder
  ExposureChip(param: string) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Column({ space: 1 }) {
        Text(this.exposureTitle(param))
          .fontSize(FontSize.Micro)
          .fontColor($r('app.color.viewer_text_on_dark_70'))
          .maxLines(1)
        Text(this.exposureValue(param))
          .fontSize(FontSize.Caption)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_on_dark'))
          .maxLines(1)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .height(42)
    .padding({ left: 2, right: 2 })
    .backgroundColor($r('app.color.viewer_glass_button'))
    .borderRadius(10)
    .enabled(this.canAdjustExposure())
    .opacity(this.canAdjustExposure() ? 1 : 0.45)
    .onClick(() => { this.openExposure(param); })
  }

  @Builder
  ExposureStrip() {
    Row({ space: 6 }) {
      this.ExposureChip(EXPOSURE_PARAM_APERTURE)
      this.ExposureChip(EXPOSURE_PARAM_SHUTTER)
      this.ExposureChip(EXPOSURE_PARAM_ISO)
      this.ExposureChip(EXPOSURE_PARAM_EV)
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
  }

  /** 参数选择半模态：只列相机返回的可用值，选中后写相机并回读。 */
  @Builder
  ExposureSheet() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text(this.exposureTitle(this.exposureParam))
            .fontSize(FontSize.CardTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.camera_wifi_remote_exposure_hint'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.exposureValue(this.exposureParam))
          .fontSize(FontSize.Reading)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary'))
          .flexShrink(0)
      }
      .width('100%')
      .padding({ right: 36 })
      .alignItems(VerticalAlign.Top)

      if (this.live !== null && this.live.exposureLoading
        && this.currentExposureOptions().length === 0) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(18).height(18)
            .color($r('app.color.primary'))
          Text($r('app.string.camera_wifi_remote_exposure_loading'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 24, bottom: 24 })
      } else if (this.currentExposureOptions().length === 0) {
        Text($r('app.string.camera_wifi_remote_exposure_empty'))
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 24, bottom: 24 })
      } else {
        List({ space: 2 }) {
          Repeat(this.currentExposureOptions()).each((item: RepeatItem<ExposureOption>) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(item.item.label)
                  .fontSize(FontSize.Body)
                  .fontColor(this.isSelectedExposure(item.item.value)
                    ? $r('app.color.primary') : $r('app.color.text_primary'))
                  .layoutWeight(1)
                if (this.isSelectedExposure(item.item.value)) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(IconSize.Small)
                    .fontColor([$r('app.color.primary')])
                }
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
              .backgroundColor(this.isSelectedExposure(item.item.value)
                ? $r('app.color.primary_soft') : Color.Transparent)
              .borderRadius(9)
            }
            .onClick(() => { this.applyExposure(item.item.value); })
          }).key((opt: ExposureOption) => `${opt.value}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 4, bottom: 20 })
  }

  @Builder
  BottomBar() {
    Column({ space: 10 }) {
      this.ExposureStrip()

      if (this.live !== null && this.live.supportsMovie) {
        Row({ space: 2 }) {
          Button($r('app.string.camera_wifi_remote_photo_mode'))
            .height(30)
            .padding({ left: 14, right: 14 })
            .fontSize(FontSize.Caption)
            .fontColor(this.live.movieMode
              ? $r('app.color.viewer_text_on_dark_70') : Color.Black)
            .backgroundColor(this.live.movieMode
              ? Color.Transparent : $r('app.color.text_on_dark'))
            .borderRadius(15)
            .enabled(this.canSwitchMode())
            .onClick(() => { this.switchMode(false); })
          Button($r('app.string.camera_wifi_remote_movie_mode'))
            .height(30)
            .padding({ left: 14, right: 14 })
            .fontSize(FontSize.Caption)
            .fontColor(this.live.movieMode
              ? Color.Black : $r('app.color.viewer_text_on_dark_70'))
            .backgroundColor(this.live.movieMode
              ? $r('app.color.text_on_dark') : Color.Transparent)
            .borderRadius(15)
            .enabled(this.canSwitchMode())
            .onClick(() => { this.switchMode(true); })
        }
        .padding(2)
        .backgroundColor($r('app.color.viewer_glass_button'))
        .borderRadius(17)
      }

      Row({ space: 24 }) {
        RoundControlButton({
          label: $r('app.string.camera_wifi_remote_af'),
          isEnabled: this.canAf(),
          onTap: () => { this.onAf(); }
        })

        this.Shutter()

        Column({ space: 6 }) {
          RoundControlButton({
            label: $r('app.string.camera_wifi_remote_wide'),
            isEnabled: this.canZoom(),
            onTap: () => { this.onZoom(false); }
          })
          RoundControlButton({
            label: $r('app.string.camera_wifi_remote_tele'),
            isEnabled: this.canZoom(),
            onTap: () => { this.onZoom(true); }
          })
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.camera_wifi_remote_hint'))
        .fontSize(FontSize.Micro)
        .lineHeight(14)
        .fontColor($r('app.color.viewer_text_on_dark_70'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .padding({ left: 28, right: 28 })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 + this.navIndicatorVp() })
  }

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        this.LiveCanvas()
        this.BottomBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .bindSheet($$this.exposureSheetOpen, this.ExposureSheet(),
        this.exposureSheetOptions())
    }
    .hideTitleBar(true)
    .backgroundColor(Color.Black)
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}


/** 圆形工具按钮：AF / W / T；@Param 随页面状态刷新。 */
@ComponentV2
struct RoundControlButton {
  @Param label: ResourceStr = '';
  @Param isEnabled: boolean = true;
  @Event onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      Text(this.label)
        .fontSize(FontSize.Caption)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_on_dark'))
    }
    .width(56)
    .height(56)
    .padding(0)
    .backgroundColor($r('app.color.viewer_glass_button'))
    .borderRadius(28)
    .enabled(this.isEnabled)
    .opacity(this.isEnabled ? 1 : 0.35)
    .onClick(() => { this.onTap(); })
  }
}
