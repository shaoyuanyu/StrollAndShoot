import { PageHeader } from '../components/PageHeader';
import { CameraService } from '../services/CameraService';
import { L10n } from '../utils/L10n';
import { CardShadow, FontSize } from '../utils/UiTokens';
import { Haptics } from '../utils/Haptics';

/**
 * 蓝牙遥控拍摄（1.70.0）。
 *
 * 只有蓝牙模式、已配对并连着相机时才会进来。进入页面 = 写 `0x11=1`，页面
 * 消失 = 写 `0x11=0`：相机在遥控模式下会**锁住回放与菜单**，不退出的话用户
 * 在相机上什么都看不了（真机踩过）。
 *
 * 交互照官方 SnapBridge：按下 = 半按对焦，松手 = 半按 OFF + 全按 ON 触发；
 * 全按 OFF 由服务层在 600ms 后补一笔复位。状态从 `0x2020` 的指示来，页面只用
 * `CameraService` 的 @Trace 字段，不直接碰 GATT。
 */
@Builder
export function BleRemotePageBuilder() {
  BleRemotePage();
}

@ComponentV2
export struct BleRemotePage {
  private pageInfos: NavPathStack = new NavPathStack();
  @Local svc: CameraService = CameraService.getInstance();
  @Local pressed: boolean = false;

  aboutToAppear(): void {
    this.enter();
  }

  aboutToDisappear(): void {
    // 相机在遥控模式下会锁回放/菜单：离开这一页必须放掉，不能只靠用户再点。
    this.svc.stopBleRemote().catch((_e: Error) => {
      // 链路已断时只清本地状态
    });
  }

  private enter(): void {
    this.svc.startBleRemote().catch((_e: Error) => {
      // 错误原因服务层已经写进 bleRemoteError
    });
  }

  private subtitle(): ResourceStr {
    const name = this.svc.bleCameraName;
    const battery = this.svc.bleBatteryPercent;
    if (name !== '' && battery >= 0) {
      return `${name} · ${L10n.tr('camera_remote_battery', battery)}`;
    }
    if (name !== '') return name;
    if (battery >= 0) return L10n.tr('camera_remote_battery', battery);
    return $r('app.string.camera_remote_title');
  }

  /** 快门能不能按：遥控已进入、相机在拍摄模式、释放没被限制。 */
  private canShoot(): boolean {
    if (!this.svc.bleRemoteActive) return false;
    const main = this.svc.bleRemoteMain;
    if (main !== 1 && main !== -1) return false;
    return (this.svc.bleRemoteRestriction & 0x05) === 0;
  }

  private statusText(): ResourceStr {
    if (this.svc.bleRemoteEntering) return $r('app.string.camera_remote_entering');
    if (!this.svc.bleRemoteActive) {
      return this.svc.bleRemoteError !== ''
        ? this.svc.bleRemoteError
        : $r('app.string.camera_remote_inactive');
    }
    const main = this.svc.bleRemoteMain;
    if (main === 2) return $r('app.string.camera_remote_play_mode');
    if (main === 3) return $r('app.string.camera_remote_menu_mode');
    if (main === 0) return $r('app.string.camera_remote_not_control');
    if ((this.svc.bleRemoteRestriction & 0x05) !== 0) {
      return $r('app.string.camera_remote_locked');
    }
    if (this.svc.bleRemoteCapture === 1) return $r('app.string.camera_remote_shooting');
    if (this.pressed) return $r('app.string.camera_remote_shooting');
    return $r('app.string.camera_remote_ready');
  }

  private statusColor(): ResourceStr {
    if (!this.svc.bleRemoteActive && this.svc.bleRemoteError !== '') {
      return $r('app.color.status_error');
    }
    if (this.svc.bleRemoteActive && this.canShoot()) {
      return $r('app.color.text_secondary');
    }
    return $r('app.color.text_tertiary');
  }

  private onShutterTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (!this.canShoot()) return;
      this.pressed = true;
      Haptics.tap();
      // 官方在按下时就发「半按 ON + 全按 ON」，拍摄在按下时触发；松手只是
      // 把两段按键状态放掉（B 门则结束曝光）。
      this.svc.bleRemotePressDown().catch((_e: Error) => {
        // 失败会写进 bleRemoteError
      });
      return;
    }
    if (event.type === TouchType.Up) {
      if (!this.pressed) return;
      this.pressed = false;
      this.svc.bleRemoteRelease().catch((_e: Error) => {
        // 同上
      });
      return;
    }
    if (event.type === TouchType.Cancel) {
      if (!this.pressed) return;
      this.pressed = false;
      this.svc.bleRemoteRelease().catch((_e: Error) => {
        // 同上
      });
    }
  }

  /**
   * 快门键。
   *
   * 自绘原因：ArkUI 没有「相机快门」这类控件，官方的圆形 `Button` 也无法表达
   * 「按住半按对焦、松手全按」这套两段式触感；外壳仍用官方 `Button`，只把
   * 内容画成两层圆环，点击/触控事件走标准 `onTouch`，没有另造手势系统。
   */
  @Builder
  Shutter() {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(116)
          .height(116)
          .borderRadius(58)
          .border({ width: 1, color: $r('app.color.divider') })
        Column()
          .width(98)
          .height(98)
          .borderRadius(49)
          .backgroundColor($r('app.color.bg_surface'))
          .shadow(CardShadow)
        Column()
          .width(76)
          .height(76)
          .borderRadius(38)
          .backgroundColor(this.pressed
            ? $r('app.color.primary_soft') : $r('app.color.bg_page'))
          .border({ width: 0.5, color: $r('app.color.divider') })
        if (this.svc.bleRemoteFocus) {
          Column()
            .width(10)
            .height(10)
            .borderRadius(5)
            .backgroundColor($r('app.color.status_connected'))
        }
      }
      .width(116)
      .height(116)
    }
    .width(116)
    .height(116)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .borderRadius(58)
    .enabled(this.canShoot())
    .opacity(this.canShoot() ? 1 : 0.35)
    .scale({ x: this.pressed ? 0.94 : 1, y: this.pressed ? 0.94 : 1 })
    .animation({ duration: 120, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => { this.onShutterTouch(event); })
  }

  build() {
    NavDestination() {
      Column() {
        PageHeader({
          title: $r('app.string.camera_remote_title'),
          subtitle: this.subtitle(),
          onBack: () => { this.pageInfos.pop(); }
        })

        Column({ space: 20 }) {
          Text(this.statusText())
            .fontSize(FontSize.Reading)
            .lineHeight(22)
            .fontColor(this.statusColor())
            .textAlign(TextAlign.Center)
            .width('100%')
            .maxLines(2)

          this.Shutter()

          if (!this.svc.bleRemoteActive && !this.svc.bleRemoteEntering) {
            Button($r('app.string.camera_remote_reenter'))
              .height(36)
              .padding({ left: 16, right: 16 })
              .fontSize(FontSize.Body)
              .fontColor($r('app.color.primary'))
              .backgroundColor($r('app.color.primary_soft'))
              .borderRadius(18)
              .onClick(() => { this.enter(); })
          }

          Text($r('app.string.camera_remote_hint'))
            .fontSize(FontSize.Caption)
            .lineHeight(18)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 24, right: 24, bottom: 40 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .onReady((context: NavDestinationContext) => {
      this.pageInfos = context.pathStack;
    })
  }
}
