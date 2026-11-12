import { CameraService } from '../services/CameraService';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';
import { HeroCardShadow, FontSize, IconSize, Radius, RowHeight, pillRadius } from '../utils/UiTokens';
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
const STANDEE_HEIGHT = 144;
/** 倒影高度：取机身下半截，再盖一层渐变淡出。 */
const REFLECTION_HEIGHT = 48;

/**
 * 相机区总高（vp）：上内边距 + 立牌 + 倒影。抽屉从这一条线开始。
 */
const COVER_HEIGHT = 14 + STANDEE_HEIGHT + REFLECTION_HEIGHT;

/**
 * 抽屉在第二段最多上收多少 vp：正好等于倒影高度。
 *
 * 贴顶时抽屉顶边落在**机身底边**上（1.62.10 起不再留深色边距，用户对比后觉得
 * 贴齐更干净），倒影也正好被收干净；`reflectionOpacity()` 在同一段里把它淡到 0，
 * 于是「倒影消失」和「抽屉收位」同时完成，接缝处不会出现半截淡掉的镜像。
 */
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
 * 贴顶（第三段）时屏幕最顶部的深色兜底高度（vp）。
 *
 * 相机面板的「钉住」是 JS 补偿出来的（`offset` 里减去滚动偏移），而滚动偏移
 * 本身是渲染属性。快速上滑时偶尔会有一帧补偿值与实际偏移对不齐，面板被画低
 * 十几到几十 vp，屏幕最顶部就露出一条页面底色——用户实测就是「顶部一条白色
 * 闪烁」。贴顶时面板上沿只在屏幕外 2vp，没有任何余量，所以这一层兜底必须
 * 存在：它不参与任何位移，只在贴顶后垫在滚动内容**后面**、盖住顶部
 * `TOP_BACKSTOP`，把那一帧的浅色横带压成面板色。正常帧里它整个被面板盖住
 * （面板上沿在屏幕外），只有面板被画低时才露出来。
 */
const TOP_BACKSTOP = 56;
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
 * 顶边下拉时，**整张深色卡片**（圆角、深色底、机身与倒影一起）走多少比例。
 *
 * 抽屉走满 1，卡片只走 1/3：下拉时卡片先自己往下弹一小段（这是"卡面也有弹簧"
 * 的那一段），剩下的行程让抽屉在卡内继续打开、露出更多倒影。**不能为 0**——
 * 用户要的就是卡面也跟着弹；也不能太大，否则抽屉在卡内几乎不动、倒影不增长。
 */
const CARD_PULL_RATIO = 1 / 3;
/**
 * 静止时露出的倒影高度（= `REFLECTION_HEIGHT`）之外，最多还能再看出来多少 vp。
 * 翻转图自身只有 144 高，所以最多再加 96：再多也没有画面可露了。
 */
const REFLECTION_GROW_MAX = STANDEE_HEIGHT - REFLECTION_HEIGHT;
/**
 * 倒影盒子高度（布局上恒定）= 翻转图自身高度。抽屉静止时用 `offset` 把
 * `REFLECTION_GROW_MAX` 那段藏到抽屉后面，下拉时滑出来。
 */
const REFLECTION_BOX = REFLECTION_HEIGHT + REFLECTION_GROW_MAX;
/**
 * 顶边下拉时**抽屉**最多能走多少 vp（卡片走其中的 `CARD_PULL_RATIO`）。
 *
 * **这个数是算出来的，不要手写。** 卡片自己也在往下走，抽屉在卡片内部又能再
 * 打开一截，所以「倒影完整露出」要求：
 *   可见倒影 = REFLECTION_HEIGHT + 抽屉位移 − 卡片位移
 *           = REFLECTION_HEIGHT + p·(1 − CARD_PULL_RATIO)
 * 要求它 ≥ REFLECTION_BOX：
 *   p ≥ REFLECTION_GROW_MAX / (1 − CARD_PULL_RATIO) = 96 / (2/3) = 144
 * 取小一点就会出现「倒影还没露完，抽屉已经停住」的硬边。
 */
const TOP_PULL_MAX = REFLECTION_GROW_MAX / (1 - CARD_PULL_RATIO);
/** 倒影渐变的「保持透明」段长度（vp）：这一段完全透出镜像，之后才开始淡出。 */
const REFLECTION_FADE_HOLD = 16;
/**
 * 第二段「形变」（面板撑满 / 白面收边）相对滚动进度的提前量指数（1.63.5）。
 *
 * 为什么不是 1（= 跟滚动线性同步）：松手吸附用的是框架的限位动画，它的曲线在
 * **前一半时间就走掉 88% 的偏移**，后一半（约 300ms）只走最后 1vp。偏移没动多少，
 * 但「进度」还有 12% 没走完——面板那 4.6% 的放大（≈16vp 宽）会在这 300ms 里继续
 * 慢慢长完，眼睛看到的就是「已经吸附住了，卡面还在放大」。
 * 把形变进度换成 `1 − (1 − p)^2.2`：到位 87.5% 时形变已经到 99%（残余 ≈0.2vp，
 * 看不见），于是收尾那段只剩偏移在爬，形变早就落定。**面板与白面必须用同一条曲线**
 * ——任何一个时刻面板比白面宽，面板的深色就会从边缝里漏出来。
 * 想让它更早收：调大指数；1 就是退回线性同步。
 */
const STAGE2_SHAPE_EXP = 2.2;

/*
 * 下面三个常数是「立体感」的三层光，合起来讲一个光源在正上方的故事：
 * 顶边吃到光（`COVER_RIM_HEIGHT`）、立牌把地面压暗一小片（`STANDEE_SHADOW_HEIGHT`）、
 * 深色面板与抽屉的接缝处压一层落影（`PANEL_SHADOW_HEIGHT`）。
 *
 * 为什么只能靠光而不是「材质」：沉浸光感在内容区不生效（官方《沉浸光感总览》：
 * 除弹窗类接口与 Toggle / Slider / Select 外，其他组件只在 Navigation/NavDestination
 * 标题栏或横向 Tabs 的底部 TabBar 里生效）。而且这张抽屉背后就是页面底色——
 * 一块纯色，模糊与折射都没有东西可采样，即便能用也不会比现在好看。
 */

/** 卡片顶边受光带的高度（vp）：一条极窄的白光，收进卡片圆角。 */
const COVER_RIM_HEIGHT = 2;
/** 立牌底座的接触阴影高度（vp），画在倒影上、从底边往下淡出。 */
const STANDEE_SHADOW_HEIGHT = 18;
/**
 * 接触阴影宽度相对立牌盒子的比例。
 *
 * 立牌素材左右各有 40–67vp 透明余量，按盒子满宽画会比机身宽出一大截，
 * 看着像地面上一条横线；0.72 落在机身两肩以内，是「影子」而不是「地平线」。
 */
const STANDEE_SHADOW_WIDTH_RATIO = 0.72;
/** 深色面板底部落在抽屉上的投影高度（vp），跟着抽屉顶边走。 */
const PANEL_SHADOW_HEIGHT = 24;
/**
 * 白色抽屉**静止时**的左右外边距（vp）。
 *
 * 演变：16（与标题栏内边距相同，上滑后卡片边线和标题文字左边缘连成一条竖线，
 * 用户反馈"严丝合缝"）→ 12 → 8 → 0（通栏，用户觉得"完全贴上不太好看"）→ **4**：
 * 几乎通栏，但两侧仍留一线页面底色，抽屉顶边的 24 圆角因此能落下来、边界看得见。
 *
 * 第二段里它和立牌面板**一起收到 0**（`sheetSideMargin()`）：两者按同一个
 * `1 − 进度` 收，抽屉面永远不小于面板，面板下半截始终被抽屉盖住——只要有任何一个
 * 时刻面板比抽屉宽，面板的深色就会从抽屉边缝里漏出来（试过用补缝条去盖，
 * 补缝条和抽屉白面的接缝会露出 1~2px 的深色竖线，比漏色还显眼）。
 */
const CARD_SIDE_MARGIN = 4;
/**
 * 立牌面板的左右缩进（vp）：**抽屉通栏、面板缩进**，两者不再同宽。
 *
 * 面板是一张独立的卡（24 圆角 + 投影 + 裁剪），抽屉是通栏的白面；面板缩进
 * 8vp 让它在抽屉上方「浮着」，抽屉顶边的圆角弧压在它下沿上。改这一个数就能
 * 把面板收窄/放宽，抽屉不受影响。
 */
const PANEL_SIDE_MARGIN = 8;

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
   * 两层卡的位置只由它决定（见 `cardContentY`）：它们被 `position` 钉在内容
   * 坐标系里，页面每上移 1vp 就相对内容下移 1vp，两者相消，相机原地不动。
   * 这里一旦按内容高度截断，多出来的那点滚动就会重新变成「相机被顶上去」，
   * 也就是反复出现的「第四段」。
   */
  @Local scrollOver: number = 0;
  /** 抽屉内容的自然高度（在内层 Scroll 里测，不受父级高度约束）。 */
  @Local drawerContentH: number = 0;
  /** `panelGrowScale()` 的缓存（窗口宽度不变，算一次即可，别在滚动帧里反复换算）。 */
  private panelGrowScaleValue: number = 0;
  /**
   * 顶边下拉量（0..TOP_PULL_MAX）：倒影被拉长多少、抽屉就下移多少。
   *
   * 由底边/顶边弹簧的越界量驱动（`currentOffset()` 在顶边下拉时是负值），
   * 松手后跟着原生弹簧衰减回 0，不需要自己写动画。
   */
  @Local pullDown: number = 0;

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
   * 抽屉盒子的高度：从相机区下沿一直到卡片底边，再加 `DRAWER_MAX_LIFT`（48）。
   *
   * 那 48vp 是第二段抽屉上收的量：静止时多出来的这一截被屏幕裁掉（看不见），
   * 上收之后正好补满卡片底部。于是抽屉里的**可视高度恒定**，不会因为抽屉
   * 正在上移而一会儿多一会儿少——第三段的可滚总量才算得准。
   */
  private drawerBoxHeight(): number {
    return this.cardHeight() - COVER_HEIGHT + DRAWER_MAX_LIFT;
  }

  /**
   * 第二段的进度（0..1）：`drawerLift` 从 0 走到 `DRAWER_MAX_LIFT` 的那 48vp。
   *
   * 只有这一段（相机已经贴住屏幕顶、抽屉还在往上收）才让立牌面板横过来撑满、
   * 倒影淡出、白面收到通栏；第一段（整页上移）与下拉回弹都不动这些。
   */
  private stage2Progress(): number {
    return Math.max(0, Math.min(1, this.drawerLift / DRAWER_MAX_LIFT));
  }

  /**
   * 第二段的「形变进度」：面板撑满 + 白面收边按它走，比滚动进度更早收尾。
   *
   * 吸附动画后 300ms 只走不到 1vp 的偏移，线性同步会让放大一直拖到动画结束；
   * 提前量见 `STAGE2_SHAPE_EXP`。
   */
  private stage2Shape(): number {
    const p = this.stage2Progress();
    return 1 - Math.pow(1 - p, STAGE2_SHAPE_EXP);
  }

  /**
   * 面板横向撑满所需的缩放比 = 屏幕宽 /（屏幕宽 − 2×`PANEL_SIDE_MARGIN`）。
   *
   * 365.7vp 的机器上 = 365.7 / 349.7 ≈ 1.046。面板宽 349.7 乘它正好 365.7，
   * 两侧的 8vp 缝隙刚好补平；素材、径向光、倒影都是面板的子节点，一起等比
   * 放大 4.6%——变宽后多出来的留白被相机自己吃掉，看起来是「相机走近了一点」
   * 而不是「画框变宽了」。
   */
  private panelGrowScale(): number {
    if (this.panelGrowScaleValue > 0) return this.panelGrowScaleValue;
    const w = WindowUtils.windowWidthPx > 0
      ? this.getUIContext().px2vp(WindowUtils.windowWidthPx) : 0;
    if (w > 2 * PANEL_SIDE_MARGIN) {
      this.panelGrowScaleValue = w / (w - 2 * PANEL_SIDE_MARGIN);
    }
    return this.panelGrowScaleValue > 0 ? this.panelGrowScaleValue : 1;
  }

  /** 当前缩放：静止 1，第二段结束时 `panelGrowScale()`。 */
  private panelScale(): number {
    return 1 + (this.panelGrowScale() - 1) * this.stage2Shape();
  }

  /**
   * 白面当前的左右外边距：静止 `CARD_SIDE_MARGIN`，第二段结束时 0（通栏）。
   *
   * 与面板的缩放**按同一个进度**收，所以抽屉面永远不小于面板：面板下半截被它
   * 完整盖住，不会从边缝里漏出深色；两者同时到 0，贴顶那一帧整个画面左右齐边。
   */
  private sheetSideMargin(): number {
    return CARD_SIDE_MARGIN * (1 - this.stage2Shape());
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
    // 顶边下拉时面板再往下走一小段（`cardPullShift`），卡面因此也有回弹
    return titleBarTotalVp() + 8 + this.scrollOver + this.cardPullShift();
  }

  /**
   * 白抽屉在**卡片坐标系**里的 y（1.62.6）：面板在卡片里固定在 0，抽屉只在这里
   * 相对面板动。
   *
   * = `COVER_HEIGHT`（静止时抽屉顶边就在封面下沿）+ `drawerPullShift`（= 下拉总量
   * − 面板已走的那段）− `drawerLift`（第二段整体上收）。于是抽屉的屏幕位移是
   * `pullDown` 走满、面板只走 `CARD_PULL_RATIO`；**第三段里它是常数**
   * （`COVER_HEIGHT − DRAWER_MAX_LIFT` = 162vp），整张卡只由一个 `position` 驱动。
   */
  private sheetLocalY(): number {
    return COVER_HEIGHT + this.drawerPullShift() - this.drawerLift;
  }

  /**
   * 立牌面板（1.62.3）：深色底 + 径向光 + 立牌 + 倒影，**左右各缩进
   * `PANEL_SIDE_MARGIN`**，自己带 24 圆角、投影与裁剪——它是一张独立的卡，
   * 不再是「整张卡的上半截」。
   *
   * 高度比静止时的可见范围多铺两段，两段都藏在白色抽屉后面：
   * - `REFLECTION_GROW_MAX`（96）：顶边下拉时抽屉往下滑，这一段露出来是倒影；
   * - `COVER_ROUND`（24）：抽屉顶边的圆角弧里要透出深色，而且下拉到底时抽屉
   *   顶边正好落在 `COVER_HEIGHT + 96`，圆角弧仍然压在面板上。
   */
  @Builder
  CameraPanel() {
    // 外层只负责「缩进」：`.width('100%')` 加水平 padding，面板本体才拿到
    // 屏幕宽 − 2×PANEL_SIDE_MARGIN。直接在面板上写 margin 不会缩窄 100% 宽度。
    Column() {
      Column() {
        this.CameraCover()
      }
      .width('100%')
      .height(COVER_HEIGHT + REFLECTION_GROW_MAX + COVER_ROUND)
      .backgroundColor($r('app.color.cover_bg'))
      // 圆角绘制策略保持默认 `RenderStrategy.FAST`：1.62.8 试过 `OFFSCREEN`
      // （官方为「圆角 + 模糊」推荐的离屏路径），重影没变，说明不是合成层的问题，
      // 已回退——离屏每帧要多一张 350×326 的缓冲，没必要。
      .borderRadius(Radius.Card)
      .shadow(HeroCardShadow)
      .clip(true)
    }
    .width('100%')
    .padding({ left: PANEL_SIDE_MARGIN, right: PANEL_SIDE_MARGIN })
    // 第二段里横向撑满：绕「机身底边」（面板内 158vp 处）缩放，底边因此不动，
    // 相机只往上长——抽屉顶边正好压在这条线上，接缝不会错开。
    // `scale` 是渲染属性，滚动时不触发重排。
    .scale({
      x: this.panelScale(),
      y: this.panelScale(),
      centerX: '50%',
      centerY: COVER_TOP_PAD + STANDEE_HEIGHT
    })
  }

  /**
   * 白色抽屉：顶部 24 圆角，装整页的全部内容。
   *
   * 它与立牌面板是**同一张卡里的上下两段**（1.62.6）：面板固定在卡片坐标系
   * y=0，抽屉按 `sheetLocalY()`（= `COVER_HEIGHT` + 卡内打开量 − 第二段上收量）
   * 相对面板动——下拉时走满整段行程，把面板多铺的倒影露出来；第三段里它是常数，
   * 于是整张卡只由外层那一个 `position` 驱动，接缝两侧不可能错开。
   *
   * **白面和内容是两层**（1.62.1 起）：白面的左右边距跟着第二段收到 0
   * （`sheetSideMargin()`），内容的内边距却是常数 `16 + CARD_SIDE_MARGIN`。
   * 合在一层会因为「白面每帧改宽度」把文字排版和自然高度测量一起重算。
   *
   * 页面仍然只有一条手势链路：内层这层 Scroll **不接收触摸**，只用来量内容的
   * 自然高度（Scroll 不约束子元素高度）并把内容裁在抽屉范围内。
   */
  @Builder
  CameraSheet() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 白面：单独一层，只在左右收边（静止 4vp → 第二段末 0），其余不变
      Column() {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.bg_surface'))
          .borderRadius({ topLeft: Radius.Card, topRight: Radius.Card })
      }
      .width('100%')
      .height(this.drawerBoxHeight())
      .padding({ left: this.sheetSideMargin(), right: this.sheetSideMargin() })

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
          // 内容高度变了，可滚范围随之变化，按新范围重算
          // （`syncFromScroll` 会把偏移夹到新上限，不用再单独传参数）
          this.syncFromScroll();
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
    .height(this.drawerBoxHeight())
    // 内容左右内边距 = 16 + 静止边距：白面收边到 0 之后，内容与屏幕边的距离不变
    .padding({ left: 16 + CARD_SIDE_MARGIN, right: 16 + CARD_SIDE_MARGIN, top: 16, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // 抽屉盒子定高（含第二段要上移的 48vp）：可视高度恒定，第三段总量才算得准
    .height(this.drawerBoxHeight())
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
    Stack({ alignContent: Alignment.Top }) {
      // 径向光单独一层、**固定 `COVER_HEIGHT` 高**：倒影盒子在布局上预留到了
      // 下拉上限（比静止视觉的倒影高一截），光晕要是跟着那个盒子的百分比走，
      // 圆心会随盒子变高而下移，静止时的观感就变了。
      Column()
        .width('100%')
        .height(COVER_HEIGHT)
        .radialGradient({
          center: ['50%', '44%'],
          radius: 210,
          // 外圈用背板底色的透明版，避免径向渐变中段发灰
          colors: [[$r('app.color.hero_glow'), 0], [$r('app.color.cover_bg_fade'), 1]]
        })

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
      .padding({ top: COVER_TOP_PAD })

      // 面板底部落影：面板与抽屉的交界不是一刀切，接缝上方 24vp 压暗，
      // 像抽屉从面板底下抽出来、缝里进不去光。它跟着抽屉顶边走，所以下拉时
      // 影子跟着往下滑，永远贴在接缝上方。
      // 用 `offset` 而不是 `position`：offset 不参与布局，下拉时只有绘制在动。
      Column()
        .width('100%')
        .height(PANEL_SHADOW_HEIGHT)
        .offset({ y: this.panelShadowOffset() })
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.shadow_fade'), 0], [$r('app.color.shadow_soft'), 1]]
        })
        .hitTestBehavior(HitTestMode.None)

      // 顶边受光：最上沿 2vp 白光。深色面板是「一块面」，加了这条边才是「一块板」：
      // 光从上方来，边缘先吃到光。画在内容之上，由面板自己的 `clip` 收进 24vp 圆角。
      Column()
        .width('100%')
        .height(COVER_RIM_HEIGHT)
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.cover_rim'), 0], [$r('app.color.cover_rim_fade'), 1]]
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .backgroundColor($r('app.color.cover_bg'))
  }

  /**
   * 落影层的 `offset`：影子底边永远压在抽屉顶边上。
   *
   * 抽屉在布局上紧跟在封面之后（封面高 = 立牌 + 整个倒影盒子），再用负 `offset`
   * 把它拉回 `COVER_HEIGHT`，所以静止时顶边正好落在封面视觉底边上；下拉时它在卡内
   * 继续打开（`drawerPullShift()`），影子跟着往下滑。
   *
   * **刻意不算 `drawerLift`（第二段的向上收）**：那一段抽屉是把盖子往上滑、把倒影
   * 盖住，影子要是跟着往上走，24vp 的暗带就压到机身底座上去了（第二段末抽屉顶边
   * 正好落在底座线上）。让它留在静止位置，抽屉自己会把它盖掉。
   */
  private panelShadowOffset(): number {
    return COVER_HEIGHT + this.drawerPullShift() - PANEL_SHADOW_HEIGHT;
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
   * 倒影渐变「淡到底」的位置（0~1，相对倒影盒子）。
   *
   * 静止时 = `REFLECTION_HEIGHT / REFLECTION_BOX`（只露 48）；下拉 p 时把收尾点
   * 推到 `(48 + p) / REFLECTION_BOX`，于是渐变始终在不透明的抽屉顶边处结束。
   */
  private reflectionFadeEnd(): number {
    // 可见倒影 = 48 + 抽屉位移 − 立牌位移；收尾点再除盒子高，钳到 1
    const visible = REFLECTION_HEIGHT + this.drawerPullShift();
    return Math.min(1, visible / REFLECTION_BOX);
  }

  /** 整张深色卡片的下移量：抽屉行程的 `CARD_PULL_RATIO`。 */
  private cardPullShift(): number {
    return this.pullDown * CARD_PULL_RATIO;
  }

  /** 抽屉在**卡片内部**再打开多少：总行程减去卡片自己已经走掉的那段。 */
  private drawerPullShift(): number {
    return this.pullDown - this.cardPullShift();
  }

  /**
   * 倒影强度。
   *
   * 底是深的（`cover_bg`，两套主题都是），所以两套主题用同一个值。产品图的机身
   * 本来就黑（倒影那条带平均亮度只有 29/255），0.26 落在深底上等于看不见。
   * 断开时乘 0.7，和主图的 0.72 呼应。
   */
  private reflectionOpacity(): number {
    const base = this.svc.connected ? 0.7 : 0.7 * 0.7;
    // 第二段里跟着抽屉一起淡出：抽屉收位与倒影淡出同时完成，接缝处不会出现
    // 「白面已经贴到机身、下面还挂着半截镜像」的硬切。
    return base * (1 - this.stage2Progress());
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
        //
        // 收尾那一档跟着 `pullDown` 走（`reflectionFadeEnd()`）：渐变必须**永远
        // 收在抽屉顶边**，否则下拉时露出的是「已经淡成背板色的一段」再接新露出的
        // 镜像，中间出现一条硬边。改的是颜色停靠点，不是高度——不触发重排。
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.cover_bg_fade'), 0],
            [$r('app.color.cover_bg_fade'), REFLECTION_FADE_HOLD / REFLECTION_BOX],
            [$r('app.color.cover_bg'), this.reflectionFadeEnd()],
            [$r('app.color.cover_bg'), 1]
          ]
        })

      // 底座接触阴影：立牌压在台面上，脚下一小片被压暗。画在倒影**之上**、
      // 从底边往下淡出——只盖倒影不盖机身，于是立牌是「踩」在台面上，不是浮着。
      // 倒影盒子顶边正好是机身底边（镜像线），所以这一层天然对齐底座。
      Column()
        .width(this.standeeWidth() * STANDEE_SHADOW_WIDTH_RATIO)
        .height(STANDEE_SHADOW_HEIGHT)
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.shadow_soft'), 0], [$r('app.color.shadow_fade'), 1]]
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    // 盒子高度恒定（= 翻转图自身高度）：抽屉用 offset 抵消预留段，下拉时露出来。
    // **不要**写成 `REFLECTION_HEIGHT + pullDown`，那是每帧改布局。
    .height(REFLECTION_BOX)
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
    // 外层 Stack 只为一件事：贴顶时在滚动内容后面垫一条深色（`TOP_BACKSTOP`）。
    // 它不跟着滚动、也不跟着补偿位移，所以面板那一帧画低了也只会露出深色。
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.scrollOver > 0.5) {
        Column()
          .width('100%')
          .height(TOP_BACKSTOP)
          .backgroundColor($r('app.color.cover_bg'))
          .hitTestBehavior(HitTestMode.None)
      }

      Scroll(this.scroller) {
        // 滚动层里只有两样东西：一块不可见的占位（决定可滚范围），和两层脱离
        // 文档流的卡。两层的屏幕位置由 `position` + `cardContentY()` 算出来，只跟
        // 滚动偏移有关，跟内容高度、测量结果彻底解耦——可滚范围里就算多出十几 vp，
        // 相机也不可能被顶出去（那正是「第四段」的成因）。
        Stack({ alignContent: Alignment.TopStart }) {
          // 幽灵占位：高度 = 卡片静止位置 + 卡高 + 第三段总量，所以可滚范围
          // 恰好是 `stick + 第三段总量`。它本身不可见、也不接收触摸。
          Column()
            .width('100%')
            .height(this.contentHeight())
            .hitTestBehavior(HitTestMode.None)

          // **卡片层**（1.62.6）：面板与白抽屉合成同一层，整页的滚动补偿只作用在
          // 这一个 `position` 上。面板固定在卡片坐标系 y=0，抽屉用 `sheetLocalY()`
          // 在卡片内相对面板动（第三段里它是常数）。
          //
          // 为什么必须合成一层：1.62.3–1.62.5 里面板和抽屉是两个各自 `position`
          // 的兄弟层，屏幕位移都在 JS 里算；快速上滑时两者偶尔差一帧，面板的
          // 旧位置会以「半透明的第二台相机」形式留在屏幕上（跨在接缝上，几帧后
          // 消失）。合成一层之后，接缝两侧只可能整体一起动，不会再互相错开。
          //
          // 用 `position` 而不是 `offset`：`offset` 是渲染属性，1.62.4 试过，面板
          // 的合成层会比滚动偏移晚几帧落位，同样留下残影。
          Stack({ alignContent: Alignment.TopStart }) {
            // 立牌面板：缩进 `PANEL_SIDE_MARGIN`，自己的圆角、投影与裁剪。
            Column() {
              this.CameraPanel()
            }
            .width('100%')

            // 白抽屉：画在面板之后，所以压住面板多铺出来的倒影段。
            // 抽屉自身通栏（白面按 `sheetSideMargin()` 收边），这一层不加左右边距。
            Column() {
              this.CameraSheet()
            }
            .width('100%')
            .position({ x: 0, y: this.sheetLocalY() })
          }
          .width('100%')
          .height(this.cardHeight())
          .position({ x: 0, y: this.cardContentY() })
        }
        .width('100%')
        .height(this.contentHeight())
      }
      .width('100%').height('100%')
      .scrollBar(BarState.Off)
      // 只给「顶边」开弹簧（`effectEdge: EffectEdge.START`，API 18 起的单边开关）：
      // 初始位置继续下拉时 `currentOffset()` 会变成负值，用来把立牌倒影拉长一点点；
      // 底边保持硬停——滚到底再拉没有任何位移（1.58.0 试过底边回弹，按用户意见关掉）。
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true, effectEdge: EffectEdge.START })
      .align(Alignment.Top)
      // 第一段（0 → stick）：整页上移，把相机顶到屏幕顶、只留 COVER_TOP_GAP；
      // 第二段（stick-48 → stick）：抽屉相对相机上收 48，正好收到机身底边；
      // 第三段（stick 之后）：相机不动，抽屉内容自己滚。
      //
      // **第一段 / 第二段松手吸附**（1.63.0）：这两段是一条连续动画（整页上移，
      // 同时抽屉追上去把倒影收干净），手指在半路松开的话画面会冻在「相机悬在半空、
      // 倒影只淡掉一半」的中间态，所以松手后由框架的限位滚动归位到最近端点。
      //
      // **1.63.1–1.63.3 曾改成自己 scrollTo + 自定义贝塞尔**（为了把漫长的收尾
      // 加速），落点正确、数值也确实更硬，但用户实测觉得「不连贯」——手写动画
      // 从零速起步、而框架的吸附接着松手时的速度走，衔接处的手感对不上。
      // 1.63.4 起**回到官方 scrollSnap**：宁可接受它 575ms 的长尾巴，也要衔接
      // 自然。要再动这条动画，先看 PAGES.md「其余要点」里 1.63.1–1.63.4 的实测。
      //
      // 分页点只有两个：0（原位）与 `stickScrollVp()`（贴顶）。第二段的终点与
      // 第一段共用同一个偏移，所以只有两个停留点。
      // `enableSnapToEnd: false` 是**关键**：官方语义是「允许在最后一页和末尾之间
      // 自由滑动」，去掉它第三段就废了（抽屉内容一松手就弹回开头）。
      .scrollSnap({
        snapAlign: ScrollSnapAlign.START,
        snapPagination: [0, stickScrollVp()],
        enableSnapToStart: true,
        enableSnapToEnd: false
      })
      .onScrollStop(() => {
        // 惯性结束补一帧：最后一帧如果没进 onScroll，三个位移会停在倒数第二个
        // 位置（大约差 1~2vp），停下来之后相机就歪了那一两 vp。
        this.syncFromScroll();
      })
      .onScroll(() => {
        this.syncFromScroll();
      })
      }
    .width('100%').height('100%')
  }

  /**
   * 按当前滚动偏移同步三个位移。
   *
   * 三段的位移都是**滚动偏移的纯函数**，不依赖任何测量值：
   * - 面板 / 抽屉的位置 → `scrollOver`（上界夹到可滚上限；顶边下拉的负值不夹）；
   * - 抽屉上收 → `drawerLift`（stick 前的 `DRAWER_MAX_LIFT` 区间）；
   * - 抽屉内容 → `innerOffset`（clamp 在第三段总量上，滚到底不露白）。
   */
  private syncFromScroll(): void {
    // onScroll 的第二个参数是「本帧滚动增量」，不是累计位置（实测每帧 1~2vp），
    // 拿它算 lift 永远得 0。这里直接问 Scroller 要当前偏移。
    let y = this.scroller.currentOffset().yOffset;
    const maxY = this.maxScrollY();
    // **末端过冲必须夹掉**（1.62.9，真机 1.62.8 上定位）：
    // 滚到最底部之后继续用力上滑，`EdgeEffect.Spring` 会让偏移先冲过最大值一小段
    // 再弹回来（用户看到的是「顶一下 + 抖动 + 重影」）。`scrollOver` 是卡片位置的
    // 输入，如果跟着这段过冲走，卡片会被多顶上去几 vp、下一帧再锁回来——两帧之间
    // 就是几十 vp 的位移差，立牌素材看起来就是抖出来的重影。
    // 这里永远按「夹到可滚上限」的偏移算补偿：过冲只交给 Scroll 自己的弹簧去表现。
    if (y > maxY) {
      y = maxY;
    }

    const stick = stickScrollVp();
    // 卡片补偿：0 ≤ y ≤ stick 时为 0（卡片跟着页面正常上移）；越过 stick 后
    // 取越界量把卡片钉住；**顶边下拉（y < 0）时取 y 本身**，把卡片按回原位，
    // 否则整张卡会往下挪、把标题栏那 130vp 的页面底色带出来。
    const shift = y > stick ? y - stick : (y < 0 ? y : 0);
    if (Math.abs(shift - this.scrollOver) > 0.2) {
      this.scrollOver = shift;
    }

    // 顶边下拉：倒影长度 + 抽屉下移量，都取这一份（上限 TOP_PULL_MAX）
    const pull = y < 0 ? Math.min(TOP_PULL_MAX, -y) : 0;
    if (Math.abs(pull - this.pullDown) > 0.2) {
      this.pullDown = pull;
    }

    // 抽屉内容 = 第三段总量，clamp 住，滚到底不露白
    const over = Math.max(0, y - stick);
    const span = this.innerScrollSpan();
    const inner = Math.min(span, over);
    if (Math.abs(inner - this.innerOffset) > 0.5) {
      this.innerOffset = inner;
    }

    // lift 在「立牌到顶」之前 48vp 就启动：页面继续上移的同时抽屉追上去，
    // 等滚到头时 lift 正好走满，相机完整留在屏幕上。
    const lift = Math.max(0, Math.min(DRAWER_MAX_LIFT, y - (stick - DRAWER_MAX_LIFT)));
    if (Math.abs(lift - this.drawerLift) > 0.5) {
      this.drawerLift = lift;
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
