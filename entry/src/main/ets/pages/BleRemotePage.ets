import { PageHeader } from '../components/PageHeader';
import { BleSpecialShoot, CameraService } from '../services/CameraService';
import { L10n } from '../utils/L10n';
import { WindowUtils } from '../utils/WindowUtils';
import { CardShadow, FontSize, IconSize, RowHeight } from '../utils/UiTokens';
import { Haptics } from '../utils/Haptics';
import { GlassEffect } from '../utils/GlassEffect';
import { uiMaterial } from '@kit.ArkUI';

/**
 * 蓝牙遥控拍摄（1.70.0，1.71.0 加工具区）。
 *
 * 只有蓝牙模式、已配对并连着相机时才会进来。进入页面 = 写 `0x11=1`，页面
 * 消失 = 写 `0x11=0`：相机在遥控模式下会**锁住回放与菜单**，不退出的话用户
 * 在相机上什么都看不了（真机踩过）。
 *
 * 交互照官方 SnapBridge：按下 = 半按对焦，松手 = 半按 OFF + 全按 ON 触发；
 * 全按 OFF 由服务层在 600ms 后补一笔复位。状态从 `0x2020` 的指示来，页面只用
 * `CameraService` 的 @Trace 字段，不直接碰 GATT。
 *
 * 工具区三件事（1.71.0 起；「相机菜单」在 1.71.3 移除——真机探针证明相机在
 * 遥控模式下收下 `MENU` 却不进菜单，见 SERVICES.md）：
 * - **录像**：只放入口，禁用并标「尚未开发」（用户明确要求先摆位、不实现）；
 * - **特殊拍摄**：`0x14` 启停相机侧的间隔定时 / 延时摄影 / 焦点移位；
 * - **相机回放**：`PLAYBACK` 进回放，方向键翻页、变焦键放大缩小。
 *
 * 后两件走半模态容器（`bindSheet`），因为快门才是这一页的主角：面板收起来时
 * 页面结构完全不变，只多一张工具卡。
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
  /** 三个工具半模态各自独立开关：同一次只会有一个是 true。 */
  @Local specialSheetOpen: boolean = false;
  @Local playSheetOpen: boolean = false;

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

  /**
   * 底部手势条高度（vp）。
   *
   * 窗口是全屏布局，内容会一直铺到手势条下面，页面末尾的说明文字必须自己
   * 让开这一截，否则最后一行会被手势条压住。
   */
  private navIndicatorVp(): number {
    const px = WindowUtils.navigationIndicatorHeightPx;
    return px > 0 ? this.getUIContext().px2vp(px) : 0;
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

  /** 相机是不是停在回放模式（`0x2020` main = 2）。 */
  private inPlayback(): boolean {
    return this.svc.bleRemoteActive && this.svc.bleRemoteMain === 2;
  }

  /** 相机是不是停在菜单里（`0x2020` main = 3）。 */
  private inMenu(): boolean {
    return this.svc.bleRemoteActive && this.svc.bleRemoteMain === 3;
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

  /**
   * 工具区：四行入口，点开各自的半模态。
   *
   * 遥控还没进去时整块置灰但**不消失**：页面布局从一开始就稳定，不会在
   * `0x11=1` 回来的一瞬间把快门顶走。
   */
  @Builder
  ToolGroup() {
    Column() {
      Text($r('app.string.camera_remote_tool_group'))
        .fontSize(FontSize.Section)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: 4, bottom: 2 })

      RemoteToolRow({
        label: $r('app.string.camera_remote_movie'),
        badge: $r('app.string.camera_remote_movie_desc'),
        disabled: true
      })
      RemoteToolRow({
        label: $r('app.string.camera_remote_special'),
        subtitle: $r('app.string.camera_remote_special_desc'),
        disabled: !this.svc.bleRemoteActive,
        onTap: () => { this.openSpecial(); }
      })
      RemoteToolRow({
        label: $r('app.string.camera_remote_playback'),
        subtitle: $r('app.string.camera_remote_playback_desc'),
        disabled: !this.svc.bleRemoteActive,
        last: true,
        onTap: () => {
          this.svc.clearBleRemoteToolError();
          this.playSheetOpen = true;
        }
      })

    }
    .width('100%')
  }

  private openSpecial(): void {
    this.svc.clearBleRemoteToolError();
    if (this.svc.bleRemoteSpecial === BleSpecialShoot.None) {
      // 默认落在最常用的间隔定时上，省一次点击；真正的间隔/张数在相机菜单里。
      this.svc.setBleRemoteSpecial(BleSpecialShoot.Interval);
    }
    this.specialSheetOpen = true;
  }

  /** 半模态统一外观：底部、贴合内容高度、系统标题区带关闭键。 */
  private toolSheetOptions(title: ResourceStr): SheetOptions {
    const opts: SheetOptions = {
      height: SheetSize.FIT_CONTENT,
      preferType: SheetType.BOTTOM,
      dragBar: true,
      showClose: true,
      title: { title: title }
    };
    if (GlassEffect.isEnabled()) {
      opts.systemMaterial = GlassEffect.material(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THICK
      }));
    } else {
      opts.backgroundColor = $r('app.color.bg_surface');
    }
    return opts;
  }

  /** 特殊拍摄：选一种，然后开始/停止。 */
  @Builder
  SpecialSheet() {
    Column({ space: 16 }) {
      Text($r('app.string.camera_remote_special_hint'))
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Column() {
        this.SpecialOption(BleSpecialShoot.Interval,
          $r('app.string.camera_remote_special_interval'), false)
        this.SpecialOption(BleSpecialShoot.Lapse,
          $r('app.string.camera_remote_special_lapse'), false)
        this.SpecialOption(BleSpecialShoot.FocusShift,
          $r('app.string.camera_remote_special_focus'), true)
      }
      .width('100%')

      if (this.svc.bleRemoteSpecialRunning) {
        Text($r('app.string.camera_remote_special_running'))
          .fontSize(FontSize.Caption)
          .lineHeight(18)
          .fontColor($r('app.color.status_connected'))
          .width('100%')
      } else if (!this.canShoot()) {
        Text($r('app.string.camera_remote_special_need_shooting'))
          .fontSize(FontSize.Caption)
          .lineHeight(18)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }

      if (this.svc.bleRemoteToolError !== '') {
        Text(this.svc.bleRemoteToolError)
          .fontSize(FontSize.Caption)
          .lineHeight(18)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }

      RemoteSheetButton({
        label: this.svc.bleRemoteSpecialRunning
          ? $r('app.string.camera_remote_special_stop')
          : $r('app.string.camera_remote_special_start'),
        danger: this.svc.bleRemoteSpecialRunning,
        active: this.svc.bleRemoteSpecialRunning || this.canShoot(),
        onTap: () => {
          Haptics.tap();
          if (this.svc.bleRemoteSpecialRunning) {
            this.svc.bleRemoteSpecialStop();
          } else {
            this.svc.bleRemoteSpecialStart();
          }
        }
      })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 4, bottom: 24 })
  }

  /** 特殊拍摄的一个选项行（单选）。 */
  @Builder
  SpecialOption(kind: number, label: ResourceStr, last: boolean) {
    Row() {
      Text(label)
        .fontSize(FontSize.Body)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (this.svc.bleRemoteSpecial === kind) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(IconSize.Body)
          .fontColor([$r('app.color.primary')])
      }
    }
    .width('100%')
    .height(RowHeight.Single)
    .border({ width: { bottom: last ? 0 : 0.5 }, color: $r('app.color.divider') })
    .opacity(this.svc.bleRemoteSpecialRunning ? 0.4 : 1)
    .onClick(() => {
      if (this.svc.bleRemoteSpecialRunning) return;
      Haptics.tap();
      this.svc.setBleRemoteSpecial(kind);
    })
  }

  /** 相机回放：进回放 → 翻页/放大 → 回拍摄。 */
  @Builder
  PlaybackSheet() {
    Column({ space: 16 }) {
      Text($r('app.string.camera_remote_playback_hint'))
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      if (this.inPlayback()) {
        // 两行两列，不用「一行四颗」：半模态两侧各 24vp 内边距之后，一颗只有
        // 约 73vp，「上一张」这种三字标签加上 Button 默认内边距会直接截断
        // （用户 2026-11-15 反馈「文字都显示不全」）。两列之后每颗约 150vp，
        // 任何语言都排得下。
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Column() {
              RemoteKeyButton({
                label: $r('app.string.camera_remote_playback_prev'),
                onTap: () => {
                  Haptics.tap();
                  this.svc.bleRemotePlaybackStep(true);
                }
              })
            }
            .layoutWeight(1)

            Column() {
              RemoteKeyButton({
                label: $r('app.string.camera_remote_playback_next'),
                onTap: () => {
                  Haptics.tap();
                  this.svc.bleRemotePlaybackStep(false);
                }
              })
            }
            .layoutWeight(1)
          }
          .width('100%')

          Row({ space: 8 }) {
            Column() {
              RemoteKeyButton({
                label: $r('app.string.camera_remote_playback_zoom_out'),
                onTap: () => {
                  Haptics.tap();
                  this.svc.bleRemotePlaybackZoom(false);
                }
              })
            }
            .layoutWeight(1)

            Column() {
              RemoteKeyButton({
                label: $r('app.string.camera_remote_playback_zoom_in'),
                onTap: () => {
                  Haptics.tap();
                  this.svc.bleRemotePlaybackZoom(true);
                }
              })
            }
            .layoutWeight(1)
          }
          .width('100%')
        }
        .width('100%')

        RemoteSheetButton({
          label: $r('app.string.camera_remote_playback_exit'),
          active: this.svc.bleRemoteActive,
          onTap: () => {
            Haptics.tap();
            // 官方切回拍摄模式发的是「半按 ON」；这里补一笔 OFF，等同一次半按。
            this.svc.bleRemoteHalfTap();
          }
        })
      } else {
        RemoteSheetButton({
          label: $r('app.string.camera_remote_playback_enter'),
          active: this.svc.bleRemoteActive,
          onTap: () => {
            Haptics.tap();
            this.svc.bleRemoteEnterPlayback();
          }
        })
        if (this.svc.bleRemoteToolError === '') {
          Text($r('app.string.camera_remote_playback_need_mode'))
            .fontSize(FontSize.Caption)
            .lineHeight(18)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
      }

      if (this.svc.bleRemoteToolError !== '') {
        Text(this.svc.bleRemoteToolError)
          .fontSize(FontSize.Caption)
          .lineHeight(18)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 4, bottom: 24 })
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
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 24, right: 24 })
        .bindSheet($$this.playSheetOpen, this.PlaybackSheet(),
          this.toolSheetOptions($r('app.string.camera_remote_playback_title')))

        Column() {
          this.ToolGroup()
        }
        .width('100%')
        .padding({ left: 24, right: 24, bottom: 12 })
        .bindSheet($$this.specialSheetOpen, this.SpecialSheet(),
          this.toolSheetOptions($r('app.string.camera_remote_special_title')))

        Text($r('app.string.camera_remote_hint'))
          .fontSize(FontSize.Caption)
          .lineHeight(18)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 24, right: 24, bottom: 20 + this.navIndicatorVp() })
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

/**
 * 遥控工具行：标题 + 说明 + 右箭头；禁用时整行变灰、没有箭头。
 *
 * `badge` 是「尚未开发」这类状态胶囊，用在录像那一行——它永远不可点，
 * 但接口位置先摆好。
 */
@ComponentV2
struct RemoteToolRow {
  @Param label: ResourceStr = '';
  @Param subtitle: ResourceStr = '';
  @Param badge: ResourceStr = '';
  @Param disabled: boolean = false;
  @Param last: boolean = false;
  @Event onTap: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(this.label)
            .fontSize(FontSize.Body)
            .fontColor(this.disabled
              ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
          if (this.badge !== '') {
            Text(this.badge)
              .fontSize(FontSize.Micro)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.filter_chip_bg'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(6)
          }
        }
        .alignItems(VerticalAlign.Center)

        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_tertiary'))
            .alignSelf(ItemAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!this.disabled) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(IconSize.Body)
          .fontColor([$r('app.color.text_tertiary')])
      }
    }
    .width('100%')
    .height(RowHeight.Double)
    .border({ width: { bottom: this.last ? 0 : 0.5 }, color: $r('app.color.divider') })
    .onClick(() => {
      if (!this.disabled) this.onTap();
    })
  }
}

/** 半模态里的主按钮：实心胶囊，危险操作用红底。 */
@ComponentV2
struct RemoteSheetButton {
  @Param label: ResourceStr = '';
  @Param danger: boolean = false;
  @Param active: boolean = true;
  @Event onTap: () => void = () => {};

  build() {
    Button(this.label)
      .width('100%')
      .height(44)
      .fontSize(FontSize.Body)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_on_primary'))
      .backgroundColor(this.danger
        ? $r('app.color.button_danger') : $r('app.color.primary'))
      .borderRadius(22)
      .enabled(this.active)
      .opacity(this.active ? 1 : 0.4)
      .onClick(() => {
        if (this.active) this.onTap();
      })
  }
}

/** 半模态里的次要按键：一行四颗等分，中性底。 */
@ComponentV2
struct RemoteKeyButton {
  @Param label: ResourceStr = '';
  @Event onTap: () => void = () => {};

  build() {
    Button(this.label)
      .width('100%')
      .height(44)
      .fontSize(FontSize.Reading)
      .fontColor($r('app.color.text_primary'))
      .backgroundColor($r('app.color.action_neutral_fill'))
      .borderRadius(22)
      .onClick(() => { this.onTap(); })
  }
}
