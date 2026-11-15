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
import { NikonWifiLiveView } from '../services/NikonWifiLiveView';
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
  @Local focusOk: boolean = false;
  private focusTimer: number = -1;

  aboutToAppear(): void {
    this.applyDarkSystemBars();
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
    this.live?.stop().catch((_e: Error) => {
      // 链路已断时只清本地状态
    });
    WindowUtils.applyThemeSystemBars(
      WindowUtils.isDarkMode(this.getUIContext().getHostContext()));
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
    if (live.shooting) return $r('app.string.camera_wifi_remote_shooting');
    if (live.focusing) return $r('app.string.camera_wifi_remote_focusing');
    if (live.starting) return $r('app.string.camera_wifi_remote_connecting');
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
    return this.live !== null && this.live.active && !this.live.shooting;
  }

  private canAf(): boolean {
    return this.live !== null && this.live.active && this.live.supportsAf
      && !this.live.focusing;
  }

  private canZoom(): boolean {
    return this.live !== null && this.live.active && this.live.supportsZoom
      && !this.live.zooming;
  }

  private onShutter(): void {
    if (!this.canShoot()) return;
    Haptics.tap();
    this.live?.capture().catch((_e: Error) => {
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
    const px = (event.x - left) / scale;
    const py = (event.y - top) / scale;
    if (px < 0 || py < 0 || px > live.frameWidth || py > live.frameHeight) return;

    this.focusX = event.x;
    this.focusY = event.y;
    this.focusVisible = true;
    this.focusOk = false;
    if (this.focusTimer >= 0) clearTimeout(this.focusTimer);
    live.focusAt(px, py).then((ok: boolean) => {
      this.focusOk = ok;
      this.focusTimer = setTimeout(() => {
        this.focusVisible = false;
        this.focusTimer = -1;
      }, 900);
    }).catch((_e: Error) => {
      this.focusTimer = setTimeout(() => {
        this.focusVisible = false;
        this.focusTimer = -1;
      }, 900);
    });
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

  @Builder
  LiveCanvas() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.live !== null && this.live.frameVersion >= 0
        && this.live.getPixelMap() !== null) {
        Image(this.live.getPixelMap())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .interpolation(ImageInterpolation.High)
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
            .border({
              width: 1.5,
              color: this.focusOk ? $r('app.color.status_connected') : $r('app.color.text_on_dark')
            })
          Row()
            .width(4).height(4)
            .backgroundColor(this.focusOk
              ? $r('app.color.status_connected') : $r('app.color.text_on_dark'))
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
          .backgroundColor($r('app.color.text_on_dark'))
        if (this.live !== null && this.live.shooting) {
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

  @Builder
  BottomBar() {
    Column({ space: 10 }) {
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
