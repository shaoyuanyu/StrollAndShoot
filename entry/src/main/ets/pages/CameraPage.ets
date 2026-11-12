import { CameraService } from '../services/CameraService';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';
import { CardShadow, FontSize, IconSize, Radius, RowHeight, pillRadius } from '../utils/UiTokens';
import type { WifiCameraInfo } from '../services/NsdScanner';
import { CameraLinkMode } from '../model/CameraLinkMode';
import { ColorMetrics, LengthMetrics, SegmentButtonV2Items, TabSegmentButtonV2 } from '@kit.ArkUI';
import type { BleCameraDevice } from '../services/BleScanner';
import { cameraStandeeAspect, cameraStandeeMedia } from '../utils/CameraStandee';
import { Haptics } from '../utils/Haptics';
import { UiScrollState } from '../model/UiScrollState';
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
const STANDEE_HEIGHT = 144;
/** 倒影高度：取机身下半截，再盖一层渐变淡出。 */
const REFLECTION_HEIGHT = 48;

/**
 * 封面底部的羽化高度（vp）。深色背板靠这一层在底部渐隐到卡片色，
 * 不能省：省掉就是深色与白卡之间一刀切。取值要盖住倒影区的大半，
 * 否则倒影还会在硬边上方"被截断"。
 */
const COVER_FADE = 76;

/**
 * 相机区总高（vp）：上内边距 + 立牌 + 倒影。抽屉从这一条线开始。
 * 抽屉最多上拉到「倒影完全被盖住」，也就是 `DRAWER_MAX_LIFT`。
 */
const COVER_HEIGHT = 14 + STANDEE_HEIGHT + REFLECTION_HEIGHT;
const DRAWER_MAX_LIFT = REFLECTION_HEIGHT;
/**
 * 相机区底色要比内容区多铺一个圆角高度。
 *
 * 抽屉的顶部圆角在圆角弧内是透明的，露出的颜色取决于它下面是谁——相机区
 * 只有正好到抽屉顶边的话，弧里露出来的是卡片底色（白），圆角就消失了。
 * 让深色往下多铺一个圆角、再用负 margin 把布局高度收回去，弧里才是深色。
 */
const COVER_ROUND = Radius.Card;
/** 立牌上沿在卡片内的位置（相机区上内边距）。 */
const COVER_TOP_PAD = 14;
/** 滚到头时立牌上沿与屏幕顶之间留的呼吸间距（vp）。 */
const COVER_TOP_GAP = 12;
/**
 * 「立牌刚好顶到屏幕顶」需要滚过的距离：页面顶部内边距 + 立牌上沿。
 * 滚到这里时相机完整可见、上沿贴着屏幕顶，再往下就没有内容可滚了。
 */
function stickScrollVp(): number {
  return titleBarTotalVp() + 8 + COVER_TOP_PAD - COVER_TOP_GAP;
}

/**
 * TEMP: 假内容的行下标（18 行）。验收完连同 `TempTestRows()` 一起删掉。
 *
 * 为什么需要它：抽屉内容在「未连接」时只有 235vp，而抽屉可视高度是 621vp，
 * 第三段（内容内部滚动）根本触发不了。补 18 行 56vp 的假行，任何模式下都能滚。
 */
const TEMP_ROW_INDEXES: number[] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17
];

/**
 * 底边回弹的最大位移（vp）——只让**抽屉内容**弹这么多，整张卡不动。
 *
 * 原生 `EdgeEffect.Spring` 的振幅不可调：真机实测轻拉一屏的 1/4 就有 47vp、
 * 猛拉有 238vp，而卡片一旦跟着走，相机会被顶出屏幕（就是「第四段」的观感）。
 * 所以弹簧只当「越界量发生器」用，取它越界的那一小段、砍到 16vp 换算成内容位移：
 * 相机与抽屉纹丝不动，只有内容自己弹一下再顺着弹簧的衰减回到原位。
 */
const CONTENT_BOUNCE_MAX = 16;

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
  @Local scrollState: UiScrollState = UiScrollState.getInstance();
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
  /** 滚动进度回调（0~1）：标题栏靠它决定何时反色。 */
  @Event onScrollProgress: (progress: number) => void = (_p: number) => {};

  /** 无线连接输入框；首次进入用上次成功的地址预填。 */
  @Local wifiInput: string = '';

  /**
   * 抽屉状态。
   *
   * - `drawerLift`：抽屉相对静止位置上移了多少 vp（0..DRAWER_MAX_LIFT），
   *   上拉时相机区的倒影被逐渐盖住；
   * - `drawerContentH`：抽屉内容实测高度，卡片总高 = 相机区 + 它 - lift，
   *   所以抽屉上移不会在卡片底部漏出空白；
   * - `drawerDragStart`：本次拖拽的起点，用来把 offsetY 换算成绝对位移。
   */
  @Local drawerLift: number = 0;
  /** 第三段：抽屉内容上移量（外层滚动驱动，内层 Scroll 不参与滚动）。 */
  @Local innerOffset: number = 0;
  /**
   * 滚过「立牌到顶」之后又滚了多少 vp，**不 clamp**。
   *
   * 相机卡的位置只由它决定（见 `cardContentY`）：卡片被 `position` 钉在内容
   * 坐标系里，页面每上移 1vp 卡片就相对内容下移 1vp，两者相消，相机原地不动。
   * 这里一旦按内容高度截断，多出来的那点滚动就会重新变成「相机被顶上去」，
   * 也就是反复出现的「第四段」。
   */
  @Local scrollOver: number = 0;
  /** 抽屉内容的自然高度（在内层 Scroll 里测，不受父级高度约束）。 */
  @Local drawerContentH: number = 0;

  aboutToAppear(): void {
    if (this.wifiInput === '' && this.svc.wifiHost !== '') {
      this.wifiInput = this.svc.wifiHost;
    }
    // 抽屉入场：先停在「盖住倒影」，再滑到「倒影完整露出」。这就是抽屉动画，
    // 不需要把手、也不需要额外手势；之后滚动继续驱动它。
    this.drawerLift = DRAWER_MAX_LIFT;
    setTimeout(() => {
      animateTo({ duration: 420, curve: Curve.EaseOut }, () => {
        this.drawerLift = 0;
      });
    }, 80);
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
   * 相机卡的精确高度 = 一屏 + 第一、二段要滚掉的距离。
   *
   * 卡片底边在「立牌到顶」时正好落到屏幕底边，抽屉因此能一直接到屏幕底部。
   */
  private cardHeight(): number {
    const screenVp = this.getUIContext().px2vp(WindowUtils.windowHeightPx);
    return screenVp + stickScrollVp() - (titleBarTotalVp() + 8);
  }

  /**
   * 抽屉盒子的高度：从相机区下沿一直到卡片底边，再加 `DRAWER_MAX_LIFT`。
   *
   * 那 48vp 是第二段抽屉上移的量：静止时多出来的这一截被卡片裁掉（看不见），
   * 上移之后正好补满卡片底部。于是抽屉里的**可视高度恒定**，不会因为抽屉
   * 正在上移而一会儿多一会儿少——第三段的可滚总量才算得准。
   */
  private drawerBoxHeight(): number {
    return this.cardHeight() - COVER_HEIGHT + DRAWER_MAX_LIFT;
  }

  /** 抽屉里真正能看见内容的高度（扣掉上下 16 的内边距）。 */
  private visibleContentH(): number {
    return this.drawerBoxHeight() - 32;
  }

  /** 第三段可滚总量：内容自然高度 - 抽屉可视高度。内容装得下就是 0。 */
  private innerScrollSpan(): number {
    return Math.max(0, this.drawerContentH - this.visibleContentH());
  }

  /**
   * 可滚范围的上限：第一、二段 + 第三段总量。
   *
   * 滚动容器的范围由 `contentHeight()` 精确给出，两者恒等；这个值用来在
   * 「内容变矮」的瞬间夹一下读到的偏移（见 `syncFromScroll`）。
   */
  private maxScrollY(): number {
    return stickScrollVp() + this.innerScrollSpan();
  }

  /**
   * 滚动内容的总高度：卡片静止位置 + 卡高 + 第三段总量。
   *
   * 减去一屏就是可滚范围，正好等于 `stickScrollVp() + 第三段总量`——一分不多、
   * 一分不少。范围精确，滚到底就不会有「多出来的一段」。
   */
  private contentHeight(): number {
    return titleBarTotalVp() + 8 + this.cardHeight() + this.innerScrollSpan();
  }

  /**
   * 相机卡在**内容坐标系**里的 y。
   *
   * 屏幕坐标 = 它 - 滚动偏移。第一段（y ≤ stick）里它恒等于静止位置，卡片跟着
   * 页面一起上移；滚过 stick 之后每滚 1vp 它就 +1vp，屏幕坐标恒等于
   * `标题栏 + 8 - stick`，相机于是钉在屏幕顶部、上方只留 `COVER_TOP_GAP`。
   */
  private cardContentY(): number {
    return titleBarTotalVp() + 8 + this.scrollOver;
  }

  /**
   * 相机卡 = 固定的相机区 + 一张**跟随页面滚动**上移的白色抽屉。
   *
   * 它不是可拖拽的抽屉组件，没有把手、没有手势：整个页面照常用上下滑动，
   * 抽屉的相对位移由滚动偏移驱动——滚到 `DRAWER_MAX_LIFT`（= 倒影高度）时
   * 倒影刚好被完全盖住，机身始终露在外面；继续滚动抽屉就跟着页面一起走。
   *
   * 抽屉里装的是**整页的全部内容**（1.57.0）：状态、配对、模式控件、连接步骤、
   * 设备信息、操作。1.56 之前设备信息与操作在卡片下方，但卡片本身就有一屏多高，
   * 它们永远落在屏幕外、根本滚不到；并进抽屉后第三段才是真内容，而不是占位条。
   *
   * 卡片位置由 `position` 决定（见 build），这里只管「卡里长什么样」：抽屉在
   * 文档流里排在相机区下面，位移只走 `offset`（不参与布局），所以卡片高度恒定、
   * 滚动时不会重排；抽屉高度多算 `DRAWER_MAX_LIFT`，静止时多出来的一截被卡片
   * 裁掉、上移后才露出来，内容不会被切。
   */
  @Builder
  CameraDrawer() {
    Stack({ alignContent: Alignment.Top }) {
      // 深色垫层：比相机区多铺一个圆角高度，抽屉顶部的圆角弧里才是深色。
      // 用独立垫层而不是给相机区加 padding + 负 margin —— 负 margin 在
      // Column 里不会把布局收回去，抽屉会整体下移，圆角又落到白底上。
      Column()
        .width('100%')
        .height(COVER_HEIGHT + COVER_ROUND)
        .backgroundColor($r('app.color.cover_bg'))

      Column() {
      this.CameraCover()

      Column() {
        Scroll() {
          Column({ space: 12 }) {
        this.StatusHeader()

        // 配对核对要用户当场读一串数字再确认，放在状态头底下，第一屏就能看到
        if (this.svc.pairingRequired) {
          this.PairingCard()
        }

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

        if (this.svc.scanStatsText !== '' && !(this.svc.connected && this.svc.photoCount > 0)) {
          Text(this.svc.scanStatsText)
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }

        if (this.svc.lastScanError !== '') {
          Text(this.svc.lastScanError)
            .fontSize(FontSize.Caption)
            .lineHeight(18)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }

        Divider().color($r('app.color.divider'))

        // 选择器 + 当前模式的一句话：切完立刻能读到这一句变了，才是切换的反馈。
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

        Divider().color($r('app.color.divider'))

        // 连接步骤：并入抽屉后不再单独成卡
        Column({ space: 10 }) {
          Text($r('app.string.camera_guide_title'))
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
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

        // TEMP: 第三段滚动验收用的假内容。搜索「TEMP」可以整块删掉。
        // 18 行 × 56vp ≈ 1008vp，未连接时也够把第三段撑出来。
        this.TempTestRows()

        // 设备信息 / 操作：抽屉本身就是一张卡，这里是平铺的行 + 小标题，
        // 不再套一层卡片（白卡压在白抽屉上只剩一道阴影，看不出层次）。
        if (this.svc.connected) {
          Divider().color($r('app.color.divider'))
          this.GroupTitle($r('app.string.camera_group_device'))
          this.DeviceRows()
          this.GroupTitle($r('app.string.camera_group_actions'))
          this.ActionRows()
        }

        // 末尾留白：底部页签是**浮在内容上**的，滚到底时最后一行会被胶囊压住。
        // 88 + 抽屉自身 16 的内边距 = 画廊列表末尾那 104vp，两页同一套留白。
        Row().width('100%').height(88)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .offset({ y: -this.innerOffset })
        .onAreaChange((_o: Area, now: Area) => {
          const h = Number(now.height);
          if (Math.abs(h - this.drawerContentH) > 0.5) {
            this.drawerContentH = h;
            // 内容高度变了，可滚范围随之变化，按新范围重算（并夹住旧偏移）
            this.syncFromScroll(true);
          }
        })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // 内容比可视高度矮时必须靠顶：Scroll 默认把矮内容**居中**，
        // 未连接时内容只有 235vp，会在抽屉顶上留出一大片空白。
        .align(Alignment.Top)
        // 这一层不滚：只用来让内容拿到「自然高度」（Scroll 不约束子元素高度，
        // 直接塞进固定高度的抽屉里会被压扁、测不到真实内容高度），
        // 以及把内容裁在抽屉范围内。
        .enableScrollInteraction(false)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      // 抽屉盒子定高（含第二段要上移的 48vp）：可视高度恒定，第三段总量才算得准
      .height(this.drawerBoxHeight())
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.bg_surface'))
      .borderRadius({ topLeft: Radius.Card, topRight: Radius.Card })
      .offset({ y: -this.drawerLift })
      }
      .width('100%')
      // 明确定高：相机区 + 抽屉盒子。它比卡片高 `DRAWER_MAX_LIFT`，多出来
      // 的一截由卡片裁掉——不能靠 Column 自己收缩，否则抽屉会被压扁。
      .height(COVER_HEIGHT + this.drawerBoxHeight())
    }
    .width('100%')
    .height(this.cardHeight())
    // 卡片的屏幕位置由 build 里的 position 施加，这里不再叠 offset
    // 卡片底是白的：抽屉上移后底部露出的 48vp 与抽屉同色。
    // 抽屉顶部圆角需要的深色由相机区自己多铺一个圆角来提供（见 COVER_ROUND）。
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(Radius.Card)
    .shadow(CardShadow)
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
      .radialGradient({
        center: ['50%', '44%'],
        radius: 210,
        // 外圈用背板底色的透明版，避免径向渐变中段发灰
        colors: [[$r('app.color.hero_glow'), 0], [$r('app.color.cover_bg_fade'), 1]]
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.cover_bg'))
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

  /**
   * TEMP: 第三段滚动验收用的假内容（搜索「TEMP」整块删除）。
   *
   * 用 `CameraInfoRow` 只是为了让假内容与抽屉里真实的设备信息行同一个尺度
   * （56vp 行高 + 分隔线），滚起来看不出拼接痕迹；行数够多，未连接时也能把
   * 第三段撑到「要滚两屏」。
   */
  @Builder
  TempTestRows() {
    Column() {
      Divider().color($r('app.color.divider'))
      this.GroupTitle('测试内容（临时）')
      ForEach(TEMP_ROW_INDEXES, (i: number) => {
        CameraInfoRow({
          label: `测试行 ${i + 1}`,
          value: `占位内容 ${i + 1}`,
          last: i === TEMP_ROW_INDEXES.length - 1
        })
      }, (i: number) => `temp_row_${i}`)
    }
    .width('100%')
  }

  /** 设备信息：平铺的行，抽屉本身就是它的卡片。 */
  @Builder
  DeviceRows() {
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
  }

  /** 次要操作：全量扫描（会丢缓存）与断开连接。 */
  @Builder
  ActionRows() {
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
    // 抽屉本身就是白卡，这里用主色淡底当「面板」，否则白压白只剩一道阴影
    .backgroundColor($r('app.color.primary_soft'))
    .borderRadius(Radius.Inner)
  }

  build() {
    Scroll(this.scroller) {
      // 滚动层里只有两样东西：一块不可见的占位（决定可滚范围），和一张
      // **脱离文档流**的相机卡。卡片的屏幕位置由 `position` + `cardContentY()`
      // 算出来，只跟滚动偏移有关，跟内容高度、测量结果彻底解耦——可滚范围里
      // 就算多出十几 vp，相机也不可能被顶出去（那正是「第四段」的成因）。
      Stack({ alignContent: Alignment.TopStart }) {
        // 幽灵占位：高度 = 卡片静止位置 + 卡高 + 第三段总量，所以可滚范围
        // 恰好是 `stick + 第三段总量`。它本身不可见、也不接收触摸。
        Column()
          .width('100%')
          .height(this.contentHeight())
          .hitTestBehavior(HitTestMode.None)

        // 相机卡：用 position 钉在内容坐标系里（页面滚多少，它就相对内容
        // 往下放多少，屏幕位置因此不变）。它仍在 Scroll 内部，所以整页
        // 只有一个手势链路——手指按在立牌、抽屉、任何地方，都是同一个滚动。
        Column() {
          this.CameraDrawer()
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .position({ x: 0, y: this.cardContentY() })
      }
      .width('100%')
      .height(this.contentHeight())
    }
    .width('100%').height('100%')
    .scrollBar(BarState.Off)
    // 只给「底边」开弹簧（`effectEdge: EffectEdge.END`，API 18 起）：顶边仍然是硬的，
    // 顶部是抽屉的入场位，回弹只会把相机往下拽、露出页面底色。
    //
    // 弹簧在这里**只当越界量发生器**：回弹期间 `currentOffset()` 会越过
    // `maxScrollY()`（真机实测猛拉 238vp、轻拉 47vp），`syncFromScroll()` 里
    // 卡片按未 clamp 的偏移补偿，所以整张卡不动、相机一 vp 都不移；只有抽屉内容
    // 取越界量的前 16vp 弹一下，再顺着弹簧自己的衰减曲线回到原位。
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true, effectEdge: EffectEdge.END })
    .align(Alignment.Top)
    // 第一段（0 → stick）：整页上移，把相机顶到屏幕顶、只留 COVER_TOP_GAP；
    // 第二段（stick-48 → stick）：抽屉相对相机上移 48，把倒影盖完；
    // 第三段（stick 之后）：相机不动，抽屉内容自己滚。
    .onScrollStop(() => {
      // 惯性结束补一帧：最后一帧如果没进 onScroll，三个位移会停在倒数第二个
      // 位置（大约差 1~2vp），停下来之后相机就歪了那一两 vp。
      this.syncFromScroll();
    })
    .onScroll(() => {
      this.syncFromScroll();
    })
  }

  /**
   * 按当前滚动偏移同步三个位移。
   *
   * 三段的位移都是**滚动偏移的纯函数**，不依赖任何测量值：
   * - 卡片位置 → `scrollOver`（未 clamp，**连回弹的越界量也照原样补偿**，
   *   所以底边回弹期间相机一 vp 都不动）；
   * - 抽屉上移 → `drawerLift`（stick 前的 48vp 区间）；
   * - 抽屉内容 → `innerOffset`（第三段总量 + 一点点回弹）。
   *
   * @param clampRange 内容高度刚变过时传 true：此时可滚范围已经变短，但滚动
   *   容器这一帧还停在旧偏移上，不夹一下会让整张卡被推下去（相机飞出屏幕）。
   */
  private syncFromScroll(clampRange: boolean = false): void {
    // onScroll 的第二个参数是「本帧滚动增量」，不是累计位置（实测每帧 1~2vp），
    // 拿它算 lift 永远得 0。这里直接问 Scroller 要当前偏移。
    let y = this.scroller.currentOffset().yOffset;
    const maxY = this.maxScrollY();
    if (clampRange && y > maxY) {
      y = maxY;
    }

    const stick = stickScrollVp();
    // 未 clamp：底边回弹时偏移会越过 maxY，这里跟上它，卡片屏幕位置才恒定
    const over = Math.max(0, y - stick);
    if (Math.abs(over - this.scrollOver) > 0.2) {
      this.scrollOver = over;
    }

    // 抽屉内容 = 第三段（clamp 住，滚到底不露白）+ 底边回弹。
    // 回弹量取原生弹簧越界的那一小段、再砍到 `CONTENT_BOUNCE_MAX`：整张卡不跟着
    // 走（相机钉死），只有内容自己弹一下；原生弹簧的衰减曲线顺便就是回弹动画，
    // 不需要自己写 animateTo。
    const span = this.innerScrollSpan();
    const bounce = Math.min(CONTENT_BOUNCE_MAX, Math.max(0, over - span));
    const inner = Math.min(span, over) + bounce;
    if (Math.abs(inner - this.innerOffset) > 0.5) {
      this.innerOffset = inner;
    }

    // lift 在「立牌到顶」之前 48vp 就启动：页面继续上移的同时抽屉追上去，
    // 等滚到头时 lift 正好走满，相机完整留在屏幕上。
    const lift = Math.max(0, Math.min(DRAWER_MAX_LIFT, y - (stick - DRAWER_MAX_LIFT)));
    if (Math.abs(lift - this.drawerLift) > 0.5) {
      this.drawerLift = lift;
    }

    // 标题反色进度：滚到立牌顶到屏幕顶时走满。第三段相机是固定不动的，
    // 标题始终压在相机图上 —— 全程保持白字。
    const progress = Math.max(0, Math.min(1, y / stick));
    if (Math.abs(progress - this.scrollState.cameraProgress) > 0.002) {
      this.scrollState.cameraProgress = progress;
      this.onScrollProgress(progress);
    }
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
