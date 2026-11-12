import { CameraService } from '../services/CameraService';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';
import { CardShadow, FontSize, IconSize, Radius, RowHeight, pillRadius } from '../utils/UiTokens';
import type { WifiCameraInfo } from '../services/NsdScanner';
import { CameraLinkMode } from '../model/CameraLinkMode';
import { ColorMetrics, LengthMetrics, SegmentButtonV2Items, TabSegmentButtonV2 } from '@kit.ArkUI';
import type { BleCameraDevice } from '../services/BleScanner';
import { cameraStandeeAspect, cameraStandeeMedia } from '../utils/CameraStandee';
import { Haptics } from '../utils/Haptics';
import { WindowUtils } from '../utils/WindowUtils';
/**
 * 四选一的四项，顺序与 `CameraLinkMode` 的枚举值一一对应。
 *
 * **只有文字，没有图标**（1.49.0）。四种链路本来就是四种互不相干的隐喻：
 * 线缆 / 蓝牙符号 / 电波 / 路由器。系统符号里没有同一支笔画的成套图标，
 * 摆在一起就是现在这个样子——USB 是实心插头、蓝牙是单线、Wi-Fi 是三根粗弧、
 * STA 是线框方盒，粗细差两三倍，18fp 下尤其明显，越看越像拼凑。
 * 而「Wi-Fi AP」与「Wi-Fi STA」的区别本来也不是任何一张图能画出来的，只能靠字。
 */
const MODE_ITEMS: SegmentButtonV2Items = new SegmentButtonV2Items([
  { text: $r('app.string.camera_mode_usb') },
  { text: $r('app.string.camera_mode_ble') },
  { text: $r('app.string.camera_mode_ap') },
  { text: $r('app.string.camera_mode_sta') }
]);

/**
 * 立牌高度（vp）。宽度不写死，按素材宽高比算（见 `standeeWidth()`）：
 * 盒子与画布同比例，`Contain` 才不会在上下留透明带，立牌底边和倒影才能严丝合缝。
 */
const STANDEE_HEIGHT = 172;
/** 倒影高度：取机身下半截，再盖一层渐变淡出。 */
const REFLECTION_HEIGHT = 76;

/**
 * 封面底部的羽化高度（vp）。深色背板靠这一层在底部渐隐到卡片色，
 * 不能省：省掉就是深色与白卡之间一刀切。取值要盖住倒影区的大半，
 * 否则倒影还会在硬边上方"被截断"。
 */
const COVER_FADE = 96;

/**
 * 相机页。
 *
 * **整页只有一套容器语言**：页面底色上是 24vp 圆角的白卡，卡与卡之间用分组小标题
 * 拉开节奏（和设置页同一套）。1.46.0 之前立牌是通栏、无背板、无边距，下面再压一张
 * 缩进 16vp 的卡，两种尺度并排，用户反馈「立牌和别的组件没有任何交流」。
 *
 * 现在的组织：
 *
 * 1. **相机卡**：立牌（图 + 倒影）是这张卡的「封面」，卡片自己就是立牌的背板。
 *    倒影淡出到的颜色由 `bg_surface` 给出，所以物体是被「压」在这张卡上，而不是
 *    浮在页面上；封面的下沿直接接状态头，看照片就知道这台机器现在什么状态。
 *    — 分隔线 — 下面是「换一种连接方式」：四选一胶囊 + 当前模式一句话 + 专属控件。
 * 2. **连接步骤**：分组小标题 + 三步引导卡（相机侧怎么设）。
 * 3. **设备信息 / 操作**：已连接时才出现。
 *
 * 沉浸光感规则：内容区的 `Button` 与分段按钮都拿不到系统材质（官方《组件适配
 * 沉浸光感》只对 Navigation 标题栏、底部 TabBar，以及 Select / Toggle / Slider
 * 这类「按钮与选择类」全页面生效）。所以主操作仍然放在标题栏里（见
 * MainScreen.NormalTitleRow），本页只负责状态、模式专属控件与说明。
 */
@ComponentV2
export struct CameraPage {
  @Local svc: CameraService = CameraService.getInstance();
  @Param scroller: Scroller = new Scroller();
  @Event onScan: (quickMode: boolean) => void = (_q: boolean) => {};
  @Event onDisconnect: () => void = () => {};
  @Event onConnectWifi: (host: string) => void = (_h: string) => {};
  @Event onCompletePairing: () => void = () => {};
  @Event onScanWifi: () => void = () => {};
  @Event onConnectBle: (deviceId: string, deviceName: string) => void =
    (_id: string, _name: string) => {};
  @Event onDisconnectBle: () => void = () => {};
  /** 用户主动把相机切到 Wi-Fi（BLE 与 Wi-Fi 互斥，交接有代价，所以由用户点）。 */
  @Event onConnectWireless: () => void = () => {};
  /** 切换链路模式（USB / 蓝牙 / Wi-Fi AP / Wi-Fi STA）。 */
  @Event onSelectMode: (mode: number) => void = (_m: number) => {};

  /** 无线连接输入框；首次进入用上次成功的地址预填。 */
  @Local wifiInput: string = '';

  aboutToAppear(): void {
    if (this.wifiInput === '' && this.svc.wifiHost !== '') {
      this.wifiInput = this.svc.wifiHost;
    }
  }

  // ------------------------------------------------------------------
  // 当前模式的文案
  // ------------------------------------------------------------------

  /** 一句话说明这个模式是干什么的。 */
  private modeDesc(): Resource {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) return $r('app.string.camera_mode_desc_usb');
    if (m === CameraLinkMode.BLE) return $r('app.string.camera_mode_desc_ble');
    if (m === CameraLinkMode.AP) return $r('app.string.camera_mode_desc_ap');
    return $r('app.string.camera_mode_desc_sta');
  }

  /** 三步引导的第 index 条（0..2）。 */
  private stepText(index: number): Resource {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) {
      if (index === 0) return $r('app.string.camera_guide_usb_1');
      if (index === 1) return $r('app.string.camera_guide_usb_2');
      return $r('app.string.camera_guide_usb_3');
    }
    if (m === CameraLinkMode.BLE) {
      if (index === 0) return $r('app.string.camera_guide_ble_1');
      if (index === 1) return $r('app.string.camera_guide_ble_2');
      return $r('app.string.camera_guide_ble_3');
    }
    if (m === CameraLinkMode.AP) {
      if (index === 0) return $r('app.string.camera_guide_ap_1');
      if (index === 1) return $r('app.string.camera_guide_ap_2');
      return $r('app.string.camera_guide_ap_3');
    }
    if (index === 0) return $r('app.string.camera_guide_sta_1');
    if (index === 1) return $r('app.string.camera_guide_sta_2');
    return $r('app.string.camera_guide_sta_3');
  }

  /** 引导末尾的注意事项；USB 没有。 */
  private guideNote(): ResourceStr {
    if (this.svc.linkMode === CameraLinkMode.BLE) return $r('app.string.camera_guide_ble_note');
    if (this.svc.linkMode === CameraLinkMode.AP) return $r('app.string.camera_guide_ap_note');
    if (this.svc.linkMode === CameraLinkMode.STA) return $r('app.string.camera_guide_sta_note');
    return '';
  }

  // ------------------------------------------------------------------
  // 当前模式的连接状态
  // ------------------------------------------------------------------

  /** USB 会话（PTP over USB）。 */
  private usbConnected(): boolean {
    return this.svc.connected && !this.svc.wireless;
  }

  /** 无线会话（BLE 配对 + 相机热点上的 PTP/IP）。 */
  private wifiConnected(): boolean {
    return this.svc.connected && this.svc.wireless;
  }

  /**
   * 配对是否真的落定。
   *
   * `bleConnected` 只代表 GATT 链路在（`connect()` 一返回就为真），配对要走完
   * 四步握手 / 断链 / 经典绑定 / 复用握手好几段，中间那几十秒两条状态会同时
   * 成立。UI 一律以「链路 ✓ 且拿到序列号」才算已配对。
   */
  private blePaired(): boolean {
    return this.svc.bleConnected && this.svc.bleSerial !== '';
  }

  /**
   * 状态头那一行：**只讲当前模式**。
   *
   * 以前是「未连接」+ 模式块再写一遍状态，同一句话一屏出现三四次；
   * 现在每个模式各自给一句完整的话，全页只此一处。
   */
  private headline(): ResourceStr {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) {
      if (this.svc.scanning) {
        return this.svc.statusText !== '' ? this.svc.statusText : $r('app.string.camera_status_scanning');
      }
      return this.usbConnected()
        ? $r('app.string.camera_status_connected')
        : $r('app.string.camera_conn_disconnected');
    }
    if (m === CameraLinkMode.BLE) {
      if (this.svc.bleConnecting) return $r('app.string.camera_ble_connecting');
      if (this.svc.bleReconnecting) return $r('app.string.camera_ble_reconnecting');
      if (this.blePaired()) {
        return this.svc.bleCameraName !== ''
          ? $r('app.string.camera_ble_connected_name', this.svc.bleCameraName)
          : $r('app.string.camera_ble_paired', this.svc.bleSerial);
      }
      if (this.svc.bleConnected) return $r('app.string.camera_ble_pair_failed');
      if (this.svc.bleScanning) return $r('app.string.camera_ble_scanning');
      return $r('app.string.camera_conn_disconnected');
    }
    // AP / STA：照片通道是 Wi-Fi，蓝牙只是前置
    if (this.wifiConnected()) return $r('app.string.camera_status_connected');
    if (this.svc.apJoining) return $r('app.string.camera_conn_open_wifi');
    if (this.svc.wifiAutoConnecting) return $r('app.string.camera_conn_wifi_linking');
    if (this.svc.wifiReconnecting) return $r('app.string.camera_conn_wifi_relinking');
    // 蓝牙的瞬时状态由下面的「蓝牙」前置行负责，状态头只讲 Wi-Fi 这一段，
    // 否则「正在连接蓝牙相机…」会在同一张卡里出现两遍。
    if (this.blePaired()) return $r('app.string.camera_state_ble_ready');
    return $r('app.string.camera_conn_disconnected');
  }

  /**
   * 状态点的颜色必须和那一行的文案同源。
   *
   * 按模式分开判断：AP / STA 模式下蓝牙在连、但无线还没起来时，状态头写的是
   * 「未连接」，点就不能跟着变蓝——否则蓝点配「未连接」，自相矛盾。
   */
  private headlineColor(): Resource {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) {
      if (this.usbConnected()) return $r('app.color.status_connected');
      return this.svc.scanning ? $r('app.color.primary') : $r('app.color.text_tertiary');
    }
    if (m === CameraLinkMode.BLE) {
      if (this.blePaired()) return $r('app.color.status_connected');
      if (this.svc.bleConnecting || this.svc.bleScanning) return $r('app.color.primary');
      if (this.svc.bleReconnecting || this.svc.bleConnected) return $r('app.color.status_error');
      return $r('app.color.text_tertiary');
    }
    if (this.wifiConnected()) return $r('app.color.status_connected');
    if (this.svc.apJoining || this.svc.wifiAutoConnecting) return $r('app.color.primary');
    if (this.svc.wifiReconnecting) return $r('app.color.status_error');
    if (this.blePaired()) return $r('app.color.status_connected');
    // 未连接用灰点：琥珀色在「两种模式各自未连接」的场景下会显得像告警。
    return $r('app.color.text_tertiary');
  }

  /** 蓝牙前置行的状态（AP / STA 共用）。 */
  private bleStatusText(): ResourceStr {
    if (this.svc.bleConnecting) return $r('app.string.camera_ble_connecting');
    if (this.svc.bleReconnecting) return $r('app.string.camera_ble_reconnecting');
    if (this.blePaired()) {
      return this.svc.bleCameraName !== ''
        ? $r('app.string.camera_ble_connected_name', this.svc.bleCameraName)
        : $r('app.string.camera_state_ble_paired');
    }
    if (this.svc.bleConnected) return $r('app.string.camera_ble_pair_failed');
    return $r('app.string.camera_conn_disconnected');
  }

  private bleStatusColor(): Resource {
    if (this.svc.bleConnecting) return $r('app.color.primary');
    if (this.svc.bleReconnecting) return $r('app.color.status_error');
    if (this.blePaired()) return $r('app.color.status_connected');
    if (this.svc.bleConnected) return $r('app.color.status_error');
    return $r('app.color.text_tertiary');
  }

  // ------------------------------------------------------------------
  // 组件
  // ------------------------------------------------------------------

  /** 分组小标题：与设置页同一套（13fp 次级色，左缩进 4）。 */
  @Builder
  GroupTitle(title: ResourceStr) {
    Text(title)
      .fontSize(FontSize.Section)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 4, top: 6 })
  }

  /**
   * 四选一：官方页签型分段按钮（灰轨道 + 浮起的选中胶囊）。
   *
   * 试过三种形态：
   * - `CapsuleSegmentButtonV2`（选中项实心主色）：一整块 73×52 的纯蓝，比下面
   *   真正的操作还抢眼，而它只是「换一种连接方式」的次级开关；
   * - 四段独立胶囊（只给选中项描边）：只有一个框、其余三个是裸文字，
   *   看起来是「一个按钮 + 三个字」，比改进前更散；
   * - 现在这个：轨道给整体感，选中项从轨道上浮起来（浅色 `bg_page` 浮
   *   `bg_surface`，深色纯黑浮 `#1C1C1E`，都是「选中更亮」），主色只落在
   *   13fp 的文字上，不再占一块面积。
   *
   * 内容区拿不到沉浸光感（官方限制），这里不用材质。
   */
  @Builder
  ModePicker() {
    TabSegmentButtonV2({
      items: MODE_ITEMS,
      selectedIndex: this.svc.linkMode,
      $selectedIndex: (index: number) => {
        // 只有真的换了一档才震一下。点当前项、以及程序回写 selectedIndex
        // 都不该有反馈——振动一滥用就成了噪音。
        if (index !== this.svc.linkMode) {
          Haptics.tap();
        }
        this.onSelectMode(index);
      },
      itemFontSize: LengthMetrics.fp(FontSize.Section),
      itemSelectedFontSize: LengthMetrics.fp(FontSize.Section),
      itemFontWeight: FontWeight.Regular,
      itemSelectedFontWeight: FontWeight.Bold,
      itemFontColor: ColorMetrics.resourceColor($r('app.color.text_secondary')),
      itemSelectedFontColor: ColorMetrics.resourceColor($r('app.color.primary')),
      itemPadding: {
        top: LengthMetrics.vp(0),
        bottom: LengthMetrics.vp(0),
        start: LengthMetrics.vp(4),
        end: LengthMetrics.vp(4)
      },
      itemMinHeight: LengthMetrics.vp(36),
      itemBorderRadius: LengthMetrics.vp(18),
      buttonMinHeight: LengthMetrics.vp(44),
      buttonPadding: LengthMetrics.vp(4),
      buttonBorderRadius: LengthMetrics.vp(22),
      // 轨道不能用 bg_page：那是页面底色，浅色下白卡 255、轨道 242，差值只有 13，
      // 整条轨道像「卡片被切开一道缝」。control_track 浅色 228（差值 27），
      // 深色仍是纯黑（卡片 28 → 轨道 0，同样是 27），两种主题的层次强度对齐。
      buttonBackgroundColor: ColorMetrics.resourceColor($r('app.color.control_track')),
      itemSelectedBackgroundColor: ColorMetrics.resourceColor($r('app.color.bg_surface')),
      // 切换时胶囊滑动 + 文字颜色过渡（API 24 起，项目 target 26）
      enableStateAnimation: true
    })
      .width('100%')
  }

  /** 三步引导的一条：编号徽章 + 一句话。 */
  @Builder
  StepRow(index: number) {
    Row({ space: 10 }) {
      Text(`${index + 1}`)
        .fontSize(FontSize.Micro)
        .fontColor($r('app.color.primary'))
        .textAlign(TextAlign.Center)
        .width(18)
        .height(18)
        .lineHeight(18)
        .borderRadius(pillRadius(18))
        .backgroundColor($r('app.color.primary_soft'))
        .flexShrink(0)
      Text(this.stepText(index))
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 连接步骤：小标题 + 一张说明卡（先一句话说清这个模式，再是相机侧的三步）。 */
  @Builder
  GuideSection() {
    Column({ space: 10 }) {
      this.GroupTitle($r('app.string.camera_guide_title'))
      Column({ space: 12 }) {
        // 模式说明已经搬到相机卡里（选择器正下方）——那里切换时立刻可见。
        // 这张卡只留「相机侧怎么设」的三步。
        Column({ space: 10 }) {
          this.StepRow(0)
          this.StepRow(1)
          this.StepRow(2)
          if (this.guideNote() !== '') {
            Text(this.guideNote())
              .fontSize(FontSize.Micro)
              .lineHeight(16)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.bg_surface'))
      .borderRadius(Radius.Card)
      .shadow(CardShadow)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 状态头：圆点 + 一句完整的话 +（已连接时）照片数 / 蓝牙断开口。 */
  @Builder
  StatusHeader() {
    Row({ space: 10 }) {
      Row()
        .width(8).height(8)
        .borderRadius(pillRadius(8))
        .backgroundColor(this.headlineColor())
        .flexShrink(0)
      Text(this.headline())
        .fontSize(FontSize.CardTitle)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(2)
      if (this.svc.connected && this.svc.photoCount > 0) {
        Text($r('app.plural.photo_count', this.svc.photoCount, this.svc.photoCount))
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.primary'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.primary_soft'))
          .borderRadius(Radius.Chip)
          .flexShrink(0)
      }
      // 蓝牙模式的「取消 / 断开」跟状态同一行：状态头已经说明蓝牙断到哪一步，
      // 动作就该贴着它，不再单独占一行。
      if (this.svc.linkMode === CameraLinkMode.BLE
        && (this.svc.bleConnecting || this.svc.bleConnected || this.svc.bleReconnecting)) {
        Text(this.svc.bleConnecting
          ? $r('app.string.camera_ble_cancel')
          : $r('app.string.camera_ble_disconnect'))
          .fontSize(FontSize.Caption)
          .fontColor(this.svc.bleConnecting
            ? $r('app.color.text_secondary') : $r('app.color.button_danger'))
          .flexShrink(0)
          .onClick(() => { this.onDisconnectBle(); })
      }
    }
    .width('100%')
  }

  /** 蓝牙前置行：AP / STA 模式都要先有蓝牙。 */
  @Builder
  BlePrereqRow() {
    Row({ space: 8 }) {
      Text($r('app.string.camera_conn_ble'))
        .fontSize(FontSize.Caption)
        .fontColor($r('app.color.text_secondary'))
        .flexShrink(0)
      Text(this.bleStatusText())
        .fontSize(FontSize.Caption)
        .fontColor(this.bleStatusColor())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 连接/配对进行中给「取消连接」而不是「断开蓝牙」：这几十秒里链路可能
      // 已通但配对还没落定，写「断开」会和「正在连接」打架。
      if (this.svc.bleConnecting) {
        Text($r('app.string.camera_ble_cancel'))
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => { this.onDisconnectBle(); })
      } else if (this.svc.bleConnected || this.svc.bleReconnecting) {
        Text($r('app.string.camera_ble_disconnect'))
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.button_danger'))
          .onClick(() => { this.onDisconnectBle(); })
      }
    }
    .width('100%')
  }

  /** 已连上无线：显示地址与断开。 */
  @Builder
  WifiConnectedRow() {
    Row({ space: 12 }) {
      Text($r('app.string.camera_conn_wifi_host', this.svc.wifiHost, this.svc.wifiPort))
        .fontSize(FontSize.Caption)
        .fontColor($r('app.color.text_tertiary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Button($r('app.string.camera_wifi_disconnect'))
        .height(36)
        .fontSize(FontSize.Caption)
        .borderRadius(pillRadius(36))
        .backgroundColor($r('app.color.bg_page'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => { this.onDisconnect(); })
    }
    .width('100%')
  }

  /**
   * 模式专属的交互区：只渲染当前模式用得上的控件。
   *
   * 之前 USB 模式下也会整块渲染「蓝牙」，还带上本机网络，甚至把 USB 的引导文案
   * 也塞进蓝牙块，一条页面里同时讲三条链路；现在按模式分支。
   */
  @Builder
  ModeControls() {
    if (this.svc.linkMode !== CameraLinkMode.USB) {
      if (this.svc.linkMode === CameraLinkMode.BLE) {
        // BLE 模式的状态头已经是蓝牙状态，这里只保留「取消 / 断开」入口，
        // 不再重复一行「蓝牙 已配对」。
        if (this.svc.bleCameras.length > 0) {
          Column() {
            ForEach(this.svc.bleCameras, (cam: BleCameraDevice) => {
              Row({ space: 8 }) {
                Text(cam.name !== '' ? cam.name : $r('app.string.camera_ble_unnamed'))
                  .fontSize(FontSize.Body)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${cam.rssi} dBm`)
                  .fontSize(FontSize.Caption)
                  .fontColor($r('app.color.text_tertiary'))
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(IconSize.Body)
                  .fontColor([$r('app.color.text_tertiary')])
              }
              .width('100%')
              .height(RowHeight.Single)
              .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
              .opacity(this.svc.bleConnecting || this.svc.bleConnected ? 0.4 : 1)
              .onClick(() => {
                if (!this.svc.bleConnecting && !this.svc.bleConnected) {
                  this.onConnectBle(cam.deviceId, cam.name);
                }
              })
            }, (cam: BleCameraDevice) => cam.deviceId)
          }
          .width('100%')
        }
      } else {
        this.BlePrereqRow()

        if (this.wifiConnected()) {
          this.WifiConnectedRow()
        } else if (this.svc.apJoining) {
          // 交接进行中：显示分步进度，别让用户对着一个不动的按钮反复点。
          Row({ space: 10 }) {
            LoadingProgress()
              .width(18).height(18)
              .color($r('app.color.primary'))
            Text(this.svc.wirelessStage !== ''
              ? this.svc.wirelessStage
              : $r('app.string.camera_conn_open_wifi'))
              .fontSize(FontSize.Caption)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
          }
          .width('100%')
        } else if (this.svc.linkMode === CameraLinkMode.AP) {
          if (this.blePaired() && !this.svc.wifiAutoConnecting) {
            Button($r('app.string.camera_conn_open_wifi'))
              .width('100%')
              .height(44)
              .fontSize(FontSize.Body)
              .borderRadius(pillRadius(44))
              .backgroundColor($r('app.color.primary'))
              .fontColor($r('app.color.text_on_primary'))
              .onClick(() => { this.onConnectWireless(); })
            Text($r('app.string.camera_conn_open_wifi_hint'))
              .fontSize(FontSize.Micro)
              .lineHeight(16)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }
        } else {
          // STA：手动地址 + 附近搜索两条路都留着（mDNS 在部分网络里出不来）
          Row({ space: 8 }) {
            TextInput({
              placeholder: $r('app.string.camera_wifi_host_placeholder'),
              text: this.wifiInput
            })
              .height(40)
              .layoutWeight(1)
              .fontSize(FontSize.Body)
              .borderRadius(Radius.Chip)
              .backgroundColor($r('app.color.bg_page'))
              .onChange((value: string) => { this.wifiInput = value; })
              .onSubmit(() => {
                if (this.wifiInput.trim() !== '' && !this.svc.scanning) {
                  this.onConnectWifi(this.wifiInput.trim());
                }
              })
            Button($r('app.string.camera_wifi_connect'))
              .height(40)
              .fontSize(FontSize.Body)
              .borderRadius(pillRadius(40))
              // 不可点时换成中性底 + 灰字：主色整体变淡会看着还能点。
              .backgroundColor(this.wifiInput.trim() !== ''
                ? $r('app.color.primary') : $r('app.color.filter_chip_bg'))
              .fontColor(this.wifiInput.trim() !== ''
                ? $r('app.color.text_on_primary') : $r('app.color.text_tertiary'))
              .enabled(!this.svc.scanning && this.wifiInput.trim() !== '')
              .onClick(() => { this.onConnectWifi(this.wifiInput.trim()); })
          }
          .width('100%')

          Row() {
            Text(this.svc.wifiScanning
              ? $r('app.string.camera_wifi_scanning')
              : $r('app.string.camera_wifi_scan_nearby'))
              .fontSize(FontSize.Caption)
              .fontColor(this.svc.wifiScanning
                ? $r('app.color.text_tertiary') : $r('app.color.primary'))
              .onClick(() => {
                if (!this.svc.wifiScanning) {
                  this.onScanWifi();
                }
              })
            Blank()
          }
          .width('100%')

          if (this.svc.wifiCameras.length > 0) {
            Column() {
              ForEach(this.svc.wifiCameras, (cam: WifiCameraInfo) => {
                Row({ space: 8 }) {
                  Text(cam.name)
                    .fontSize(FontSize.Body)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(cam.host)
                    .fontSize(FontSize.Caption)
                    .fontColor($r('app.color.text_tertiary'))
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(IconSize.Body)
                    .fontColor([$r('app.color.text_tertiary')])
                }
                .width('100%')
                .height(RowHeight.Single)
                .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
                .onClick(() => { this.onConnectWifi(cam.host); })
              }, (cam: WifiCameraInfo) => cam.name)
            }
            .width('100%')
          }

          // 本机网络快照只对 STA 有意义：AP 模式连的是相机自己的热点，
          // 手机当前连哪个 Wi-Fi 与它无关，写出来只会让人以为「网络不对」。
          if (this.svc.networkSummary !== '') {
            Text($r('app.string.camera_conn_network', this.svc.networkSummary))
              .fontSize(FontSize.Micro)
              .lineHeight(16)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }
          if (this.svc.wifiHint !== '') {
            Text(this.svc.wifiHint)
              .fontSize(FontSize.Micro)
              .lineHeight(16)
              .fontColor($r('app.color.status_error'))
              .width('100%')
          }
        }

        if (this.svc.bleHint !== '') {
          Text(this.svc.bleHint)
            .fontSize(FontSize.Micro)
            .lineHeight(16)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }
      }
    }
  }

  /**
   * 相机卡：立牌当封面，下面是「现在什么状态」与「换一种连接方式」。
   *
   * 封面没有自己的背板——**卡片就是背板**。倒影的渐隐落点与卡片底色同为
   * `bg_surface`，所以物体是被压在这张卡上；卡片再统一 24vp 圆角与 16vp 内边距，
   * 立牌于是和其它卡处在同一套尺度里，不再是通栏的一条「海报」。
   */
  @Builder
  CameraCard() {
    Column() {
      if (this.svc.cameraModel !== '') {
        this.CameraCover()
      }
      Column({ space: 12 }) {
        this.StatusHeader()

        if (this.svc.scanTotal > 0) {
          Column({ space: 6 }) {
            Progress({
              value: this.svc.scanProgress,
              total: this.svc.scanTotal,
              type: ProgressType.Linear
            })
              .width('100%').height(3)
              .color($r('app.color.primary'))
              .backgroundColor($r('app.color.divider'))
            Row() {
              Text(this.svc.scanPhaseText || $r('app.string.camera_scanning_fallback'))
                .fontSize(FontSize.Caption).fontColor($r('app.color.text_secondary'))
              Blank()
              Text(`${this.svc.scanProgress}/${this.svc.scanTotal}`)
                .fontSize(FontSize.Caption).fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
          }
          .width('100%')
        }

        // 照片数已经在状态头右侧的胶囊里了，这行统计再报一遍只是重复；
        // 只有拿不到胶囊（未连接、或者连上了但还没照片）时才补这一行。
        if (this.svc.scanStatsText !== '' && !(this.svc.connected && this.svc.photoCount > 0)) {
          Text(this.svc.scanStatsText)
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }

        // 失败原因统一写进 lastScanError，切换模式时清空，所以这里显示的一定
        // 属于当前模式。以前切到 USB 还挂着上一轮的「蓝牙连接失败」。
        if (this.svc.lastScanError !== '') {
          Text(this.svc.lastScanError)
            .fontSize(FontSize.Caption)
            .lineHeight(18)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }

        // 分隔线把这张卡分成两半：线上是「这台机器现在怎么样」，
        // 线下是「换一种连接方式」——四选一 + 当前模式的专属控件。
        Divider().color($r('app.color.divider'))

        // 选择器 + 当前模式的一句话，读成一组（8vp，比卡片内常规的 12vp 紧一档）。
        // 这句话必须留在选择器正下方：模式说明原来在下面「连接步骤」卡的开头，
        // 而那张卡在首屏之外——切完模式屏幕上什么都不变，用户会以为没点上。
        // 现在切完立刻能读到这一句变了，这才是切换的反馈。
        Column({ space: 8 }) {
          this.ModePicker()
          Text(this.modeDesc())
            .fontSize(FontSize.Caption)
            .lineHeight(18)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        this.ModeControls()
      }
      .width('100%')
      .padding({
        left: 16,
        right: 16,
        top: this.svc.cameraModel !== '' ? 12 : 16,
        bottom: 16
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
    .shadow(CardShadow)
    // 圆角裁剪：封面那层径向光的矩形边界落在卡片四角上，不裁会露出直角
    .clip(true)
  }

  /**
   * 封面：当前（或上次）连接的相机商品图 + 倒影，压在一条**深色背板**上。
   *
   * 背板为什么是深的（1.52.0）：相机机身本身就是黑的，产品图也是按深底棚拍
   * 的——倒影、边缘的高光、机身后面那圈径向光都建立在深底上。同一张图放到
   * 白卡上，倒影很快被白吃掉，光也托不出轮廓，观感就是「贴纸」。所以浅色
   * 模式下这条封面单独用 `cover_bg`（`#1B1C1E`），深色模式下它就是卡片色
   * （`#1C1C1E`），**深色模式一个像素都不变**。
   *
   * 只改封面这一层、不改整张卡：卡内的状态、选择器、说明仍然用白底黑字，
   * 不需要另配一套 on-dark 文字与控件色，也不会在浅色页面里压一块黑。
   *
   * 型号名与序列号都在标题栏（`MainScreen.NormalTitleRow`），封面只留产品。
   */
  @Builder
  CameraCover() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Image(cameraStandeeMedia(this.svc.cameraModel))
          .width(this.standeeWidth())
          .height(STANDEE_HEIGHT)
          .objectFit(ImageFit.Contain)
          .interpolation(ImageInterpolation.High)
          .draggable(false)
          .opacity(this.svc.connected ? 1 : 0.72)
          .animation({ duration: 260, curve: Curve.EaseOut })
        this.StandeeReflection()
      }
      .width('100%')
      .padding({ top: 14 })
      .backgroundColor($r('app.color.cover_bg'))
      .radialGradient({
        center: ['50%', '44%'],
        radius: 210,
        // 外圈用背板底色的透明版，避免径向渐变中段发灰
        colors: [[$r('app.color.hero_glow'), 0], [$r('app.color.cover_bg_fade'), 1]]
      })

      // 底边羽化（1.52.1）：深色背板如果一条直线切在倒影中间再接白卡，就是
      // 「泾渭分明」。这里盖一层从透明到卡片色的渐变，深色在底部自己溶掉——
      // 倒影正好在这一段里淡出，读起来像产品摄影的无缝背景纸。
      // 用 `bg_surface_fade → bg_surface` 而不是写死白色：深色模式下两端都是
      // 卡片色，这一层等于不存在，不需要按主题分支。
      Column()
        .width('100%')
        .height(COVER_FADE)
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.bg_surface_fade'), 0],
            [$r('app.color.bg_surface'), 1]
          ]
        })
    }
    .width('100%')
  }

  /**
   * 立牌盒子的宽度（vp）＝高度 × 素材宽高比。
   *
   * **不要写 `.width('100%')`**：卡片比素材比例窄时会变成按宽度顶满，`Contain`
   * 于是把画布缩到 165vp 高、在 172vp 的盒子里上下各留 3.3vp 透明带；倒影盒子
   * 又是同一张图，顶部再留 3.3vp —— 两条叠起来就是立牌底边和倒影之间那条
   * 6.6vp 的白缝（1.46.0 用户一眼看出来）。盒子比卡片略宽没关系：多出来的
   * 只是素材左右两侧的透明边，最大 45vp（Z 30），而素材本身左右各留了
   * 40–67vp 透明余量，机身不会被裁到。
   */
  private standeeWidth(): number {
    return STANDEE_HEIGHT * cameraStandeeAspect(this.svc.cameraModel);
  }

  /**
   * 倒影强度。
   *
   * 底是深的（`cover_bg`，两套主题都是），所以两套主题用同一个值。产品图的机身
   * 本来就黑（倒影那条带平均亮度只有 29/255），0.26 落在深底上等于看不见。
   * 断开时乘 0.7，和主图的 0.72 呼应。
   */
  private reflectionOpacity(): number {
    const base = 0.7;
    return this.svc.connected ? base : base * 0.7;
  }

  /**
   * 立牌倒影：同一张图上下翻转，塞进一个只有半高的裁剪盒里。
   *
   * 裁剪盒与图片同宽、`alignContent: Top`，所以盒子露出的正好是被翻转后的
   * 「上半截」＝原图的下半截，接在原图脚下就是镜像。两个必须注意的点：
   * - 图片不位移：素材已裁到「机身实心底＝画布底」，镜像线正好落在机身底边上；
   * - 渐变的第二档取 0.34 而不是直接线性到底，纯线性时平均不透明度只剩一半，
   *   倒影会淡到看不见。
   */
  @Builder
  StandeeReflection() {
    Stack({ alignContent: Alignment.Top }) {
      Image(cameraStandeeMedia(this.svc.cameraModel))
        .width(this.standeeWidth())
        .height(STANDEE_HEIGHT)
        .objectFit(ImageFit.Contain)
        .interpolation(ImageInterpolation.High)
        .draggable(false)
        .scale({ x: 1, y: -1 })
        .translate({ y: 0 })
        .opacity(this.reflectionOpacity())
      Column()
        .width('100%')
        .height('100%')
        // 起手两档必须用 `bg_surface_fade`（卡片底色的「全透明版」），不能用
        // '#00000000'：线性渐变按「非预乘」插值，从透明黑渐变到不透明浅色会在
        // 中段经过一段灰——浅色下就是一条全宽灰带（深色下恰好是黑，看不出来，
        // 所以只在浅色暴露）。只有 RGB 保持一致、只让 alpha 变，才是纯淡出。
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.cover_bg_fade'), 0],
            [$r('app.color.cover_bg_fade'), 0.34],
            [$r('app.color.cover_bg'), 1]
          ]
        })
    }
    .width('100%')
    .height(REFLECTION_HEIGHT)
    // 渐变遮罩的收尾色必须与「这块下面的背板」完全同色，否则会把背板涂出一块
    // 带硬边的矩形。这里显式铺一层 bg_surface，让遮罩和卡片由构造保证同色。
    .backgroundColor($r('app.color.cover_bg'))
    .clip(true)
  }

  @Builder
  DeviceCard() {
    Column() {
      CameraInfoRow({ label: $r('app.string.camera_info_brand'), value: this.svc.deviceManufacturer || $r('app.string.common_unknown') })
      CameraInfoRow({ label: $r('app.string.camera_info_model'), value: this.svc.cameraName || $r('app.string.common_unknown') })
      CameraInfoRow({ label: $r('app.string.camera_info_serial'), value: this.svc.deviceSerialNumber || $r('app.string.common_none') })
      CameraInfoRow({ label: $r('app.string.camera_info_firmware'), value: this.svc.deviceVersion || $r('app.string.common_unknown') })
      CameraInfoRow({ label: $r('app.string.camera_info_usb_id'), value: this.svc.usbVidPid || $r('app.string.common_unknown') })
      CameraInfoRow({ label: $r('app.string.camera_info_usb_serial'), value: this.svc.usbSerialNumber || $r('app.string.common_none') })
      CameraInfoRow({ label: $r('app.string.camera_info_cache_id'), value: this.svc.cameraIdentity || $r('app.string.common_none') })
      CameraInfoRow({ label: $r('app.string.camera_info_photo_count'), value: `${this.svc.photoCount}` })
      CameraInfoRow({
        label: $r('app.string.camera_info_connection'),
        value: this.svc.wireless ? `Wi-Fi · ${this.svc.wifiHost}` : $r('app.string.camera_connection_ptp'),
        last: true
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
    .shadow(CardShadow)
  }

  /** 次要操作单独一张卡：全量扫描（会丢缓存）与断开连接。 */
  @Builder
  ActionsCard() {
    Column() {
      CameraActionRow({
        label: $r('app.string.camera_action_full_scan'),
        subtitle: $r('app.string.camera_action_full_scan_desc'),
        disabled: this.svc.scanning,
        onTap: () => { this.onScan(false); }
      })
      CameraActionRow({
        label: $r('app.string.camera_action_disconnect'),
        danger: true,
        last: true,
        onTap: () => { this.onDisconnect(); }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
    .shadow(CardShadow)
  }

  /**
   * 配对核对卡。
   *
   * 相机在「连接向导」页等主机注册：它先开 15740 让我们连上，再等 0x952B
   * 取的验证码与 0x935A 确认；不确认就 10 秒后收线、Wi-Fi 配置不落盘。
   */
  @Builder
  PairingCard() {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.link'))
          .fontSize(IconSize.Body)
          .fontColor([$r('app.color.primary')])
        Text($r('app.string.camera_wifi_pairing_title'))
          .fontSize(FontSize.CardTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')

      Text(this.svc.pairingCode)
        .fontSize(40)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary'))
        .letterSpacing(8)
        .width('100%')
        .textAlign(TextAlign.Center)

      Text($r('app.string.camera_wifi_pairing_hint'))
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')

      Button($r('app.string.camera_wifi_pairing_confirm'))
        .width('100%')
        .height(44)
        .borderRadius(pillRadius(44))
        .backgroundColor($r('app.color.primary'))
        .fontColor($r('app.color.text_on_primary'))
        .onClick(() => { this.onCompletePairing(); })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
    .shadow(CardShadow)
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 10 }) {
        // 相机卡没有分组标题：整页讲的就是这一台相机，标题栏里已经写着型号。
        this.CameraCard()
        this.GuideSection()
        if (this.svc.pairingRequired) {
          this.PairingCard()
        }
        if (this.svc.connected) {
          this.GroupTitle($r('app.string.camera_group_device'))
          this.DeviceCard()
          this.GroupTitle($r('app.string.camera_group_actions'))
          this.ActionsCard()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 96 })
    }
    .width('100%').height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    // 标题栏浮在内容之上，首屏内容按其高度内缩；滚动时从标题栏下方穿过
    .contentStartOffset(titleBarTotalVp())
  }
}

/** 设备信息行。 */
@ComponentV2
struct CameraInfoRow {
  @Param label: ResourceStr = '';
  @Param value: ResourceStr = '';
  @Param last: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(FontSize.Body)
        .fontColor($r('app.color.text_secondary'))
        .flexShrink(0)
      Text(this.value)
        .fontSize(FontSize.Body)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 16 })
    }
    .width('100%')
    .height(RowHeight.Single)
    .border({ width: { bottom: this.last ? 0 : 0.5 }, color: $r('app.color.divider') })
  }
}

/** 设备卡里的操作行：普通操作带右箭头，危险操作用红字。 */
@ComponentV2
struct CameraActionRow {
  @Param label: ResourceStr = '';
  @Param subtitle: ResourceStr = '';
  @Param danger: boolean = false;
  @Param disabled: boolean = false;
  @Param last: boolean = false;
  @Event onTap: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(this.label)
          .fontSize(FontSize.CardTitle)
          .fontColor(this.danger ? $r('app.color.button_danger') : $r('app.color.text_primary'))
          .alignSelf(ItemAlign.Start)
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_tertiary'))
            .alignSelf(ItemAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!this.danger) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(IconSize.Body)
          .fontColor([$r('app.color.text_tertiary')])
      }
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .opacity(this.disabled ? 0.4 : 1)
    .border({ width: { bottom: this.last ? 0 : 0.5 }, color: $r('app.color.divider') })
    .onClick(() => {
      if (!this.disabled) {
        this.onTap();
      }
    })
  }
}
