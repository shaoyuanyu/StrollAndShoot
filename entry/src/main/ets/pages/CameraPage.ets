import { CameraService } from '../services/CameraService';
import { BleIdentityStore } from '../services/BleIdentityStore';
import { StandeePreferenceStore } from '../model/StandeePreferenceStore';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';
import { CardShadow, HeroCardShadow, FontSize, IconSize, Radius, RowHeight, pillRadius } from '../utils/UiTokens';
import type { WifiCameraInfo } from '../services/NsdScanner';
import { CameraLinkMode, isWifiMode } from '../model/CameraLinkMode';
import { ColorMetrics, LengthMetrics, SegmentButtonV2Items, TabSegmentButtonV2, uiMaterial } from '@kit.ArkUI';
import type { BleCameraDevice } from '../services/BleScanner';
import { cameraStandeeAspect, cameraStandeeMedia } from '../utils/CameraStandee';
import { Haptics } from '../utils/Haptics';
import { WindowUtils } from '../utils/WindowUtils';
import { GlassEffect } from '../utils/GlassEffect';
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
 * 模式选择器的高度（vp）。连接后选择器被锁定，点击时整条左右震动，
 * 震动位移作用在同一行上、不改变高度。
 */
const MODE_PICKER_HEIGHT = 44;
/** 锁定后「快速点两次」的判定窗口（ms）。 */
const MODE_LOCK_DOUBLE_TAP_MS = 450;

/**
 * 相机页的展示阶段。
 *
 * 四种模式共用这一套阶段名，但每个阶段的文案与操作按模式分派（见 `phase()`）。
 * 页面上的状态点、状态文案、详情行、主操作全部由它派生，避免「文案一套、
 * 按钮一套、点色又是一套」互相打架。
 */
enum CameraPhase {
  Idle,
  Searching,
  Connecting,
  Pairing,
  Connected,
  Loading,
  Failed,
  Disconnecting,
  Switching
}

/**
 * 立牌高度（vp）。宽度不写死，按素材宽高比算（见 `standeeWidthFor()`）：
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
 * **主操作与模式选择器（1.64.0）**：`搜索相机 / 断开连接` 是状态头右侧那一颗胶囊，
 * 它和进度点、状态文案、阶段详情合成一句话——连接状态与「结束连接」本来就是
 * 同一件事。选择器常驻四段，连接后锁定，点别的段会抖一下并提示「快速点两次」。
 *
 * **每个模式只有一条状态线（1.64.0 第二轮）**：USB / BLE / AP / STA 各自有一套
 * 阶段（见 `CameraPhase`），页面只渲染当前阶段用得上的一句话、一个操作和一组
 * 控件。AP / STA 里不再常驻「蓝牙」前置行：配对是 AP 的第一步，Wi-Fi 一起来
 * 它就从页面上消失，不会出现「已连接」旁边还挂着一句蓝牙失败。
 *
 * 沉浸光感规则：内容区的 `Button` 与分段按钮都拿不到系统材质（官方《组件适配
 * 沉浸光感》只对 Navigation 标题栏、底部 TabBar，以及 Select / Toggle / Slider
 * 这类「按钮与选择类」全页面生效）。抽屉在白底上，也不需要材质——实心胶囊
 * 就是这里最干净的语言。
 */
@ComponentV2
export struct CameraPage {
  @Local svc: CameraService = CameraService.getInstance();
  /** 已配对过的相机身份（落盘）：决定「搜索相机」还是「连接相机」。 */
  @Local bleId: BleIdentityStore = BleIdentityStore.getInstance();
  /** 未识别机型时使用的默认立牌（用户设置）。 */
  @Local standeePref: StandeePreferenceStore = StandeePreferenceStore.getInstance();
  /** 立牌卡面交叉淡入淡出：当前 / 上一张 / 进度。 */
  @Local standeeCurrentKey: string = '';
  @Local standeePreviousKey: string = '';
  @Local standeeCrossfade: number = 1;
  @Param scroller: Scroller = new Scroller();
  @Event onScan: (quickMode: boolean) => void = (_q: boolean) => {};
  @Event onDisconnect: () => void = () => {};
  @Event onConnectWifi: (host: string) => void = (_h: string) => {};
  @Event onCompletePairing: () => void = () => {};
  @Event onConnectBle: (deviceId: string, deviceName: string) => void =
    (_id: string, _name: string) => {};
  @Event onDisconnectBle: () => void = () => {};
  /** 切换链路模式（USB / 蓝牙 / Wi-Fi AP / Wi-Fi STA）。 */
  @Event onSelectMode: (mode: number) => void = (_m: number) => {};
  /** 锁定确认后：先断开当前连接，再切到新模式（由 MainScreen 串行执行）。 */
  @Event onSwitchMode: (mode: number) => void = (_m: number) => {};

  /** 无线连接输入框；首次进入用上次成功的地址预填。 */
  @Local wifiInput: string = '';
  /** STA 的手动 IP 默认收起：主要操作是状态头的自动搜索。 */
  @Local staManualOpen: boolean = false;
  /** 半模态步骤面板是否打开。 */
  @Local guideSheetOpen: boolean = false;

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

  /**
   * 模式选择器的锁定反馈（1.64.0 第二轮）。
   *
   * 连接后四段仍然常驻，只是不允许切换；点别的段会让整条左右快震一下，
   * 并在 `MODE_LOCK_DOUBLE_TAP_MS` 内再点同一段时弹出切换确认。
   */
  @Local pickerShakeX: number = 0;
  /** 选择器实测宽度（vp）：既用来换算点击位置，也用来定位自绘滑块。 */
  @Local pickerWidth: number = 0;
  /** 上一次锁定点击的时间与目标段，用于识别「快速点两次」。 */
  private lockedTapAt: number = 0;
  private lockedTapIndex: number = -1;
  /** 当前轻提示的 id（`openToast` 返回），切换确认前用来收起它。 */
  private toastId: number = -1;

  aboutToAppear(): void {
    this.standeeCurrentKey = this.effectiveStandeeKey();
    this.standeePreviousKey = '';
    this.standeeCrossfade = 1;
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

  /** 换模式后收起上一模式的步骤面板，避免张冠李戴。 */
  @Monitor('svc.linkMode')
  onLinkModeChanged(): void {
    this.guideSheetOpen = false;
  }

  /** 真实机型变化：立牌交叉淡入淡出。 */
  @Monitor('svc.cameraModel')
  onStandeeModelChanged(): void {
    this.syncStandee();
  }

  /** 设置里换「默认相机立牌」：只有当前没有真实机型时才影响封面。 */
  @Monitor('standeePref.defaultKey')
  onDefaultStandeeChanged(): void {
    this.syncStandee();
  }

  // ------------------------------------------------------------------
  // 当前模式的连接状态
  // ------------------------------------------------------------------

  /** USB 会话（PTP over USB）。 */
  private usbConnected(): boolean {
    return this.svc.connected && !this.svc.wireless;
  }

  /** 无线会话（相机热点 / 局域网上的 PTP/IP）。 */
  private wifiConnected(): boolean {
    return this.svc.connected && this.svc.wireless;
  }

  /**
   * 配对是否真的落定。
   *
   * `bleConnected` 只代表 GATT 链路在（`connect()` 一返回就为真），配对要走完
   * 握手 / 断链 / 经典绑定好几段，中间那几十秒 `bleConnected` 已经是 true 了。
   * UI 一律以「链路 ✓ 且拿到序列号」才算已配对。
   */
  private blePaired(): boolean {
    return this.svc.bleConnected && this.svc.bleSerial !== '';
  }

  /**
   * 这台相机以前配对过（身份已落盘）。
   *
   * 与 `blePaired()` 不是一回事：断开之后链路没了，但相机那边还记着这台手机，
   * 再连不需要重新配对。按钮文案要能区分「找一台新相机」和「连回那台旧相机」。
   */
  private bleKnown(): boolean {
    if (this.blePaired()) return true;
    return this.bleId.hasIdentity() && this.bleId.deviceId !== '';
  }

  /**
   * 当前模式是否已经连上。
   *
   * 三种链路的「已连接」不是同一个字段：USB 是 PTP 会话（`connected` 且非无线），
   * 蓝牙是配对落定（链路在 + 拿到序列号），AP / STA 是 Wi-Fi 会话。
   * 主操作变「断开」、模式选择器上锁都以它为准。
   */
  private linked(): boolean {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) return this.usbConnected();
    if (m === CameraLinkMode.BLE) return this.blePaired();
    return this.wifiConnected();
  }

  /**
   * 当前展示阶段。整页的状态文案、状态点、主操作都只从这一个判断里出：
   *
   * - USB：空闲 → 搜索 → 已连接（数据线一条链路）；
   * - BLE：空闲 → 搜索 → 连接/配对 → 已配对（不传照片）；
   * - AP：空闲 → 配对 → 唤醒并加入相机热点 → 已连接；
   * - STA：空闲 → 搜索（网络 / 蓝牙）→ 连相机所在网络 → 已连接。
   *
   * 以前 AP/STA 里常驻一行「蓝牙 已配对 / 连接失败」，Wi-Fi 起来后蓝牙其实
   * 已经让位给 Wi-Fi，那一行却还在——同一张卡同时讲两条链路，这就是「模式
   * 分界不清」的来源。现在只在当前阶段真的在做那件事时，才出现那件事。
   */
  private phase(): CameraPhase {
    if (this.svc.switchingTo >= 0) return CameraPhase.Switching;
    if (this.svc.disconnecting) return CameraPhase.Disconnecting;
    if (this.linked()) {
      if (this.svc.pairingRequired) return CameraPhase.Pairing;
      return this.svc.scanning ? CameraPhase.Loading : CameraPhase.Connected;
    }
    if (this.svc.bleConnecting || this.svc.bleReconnecting) return CameraPhase.Connecting;
    if (this.svc.scanning || this.svc.bleScanning || this.svc.wifiScanning) {
      return CameraPhase.Searching;
    }
    if (this.svc.apJoining || this.svc.wifiAutoConnecting || this.svc.wifiReconnecting) {
      return CameraPhase.Connecting;
    }
    if (this.failReason() !== '') return CameraPhase.Failed;
    return CameraPhase.Idle;
  }

  /**
   * 当前模式下「上一次尝试为什么没成」。
   *
   * **只认当前模式的结论**：USB 不看无线失败，无线不看 USB 扫描错误。切模式
   * 时服务端已经清掉上一轮的错误，这里再按模式收口一次，杜绝任何残留串台。
   */
  private failReason(): ResourceStr {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) return this.svc.lastScanError;
    if (isWifiMode(m) && this.svc.wirelessFailed !== '') return this.svc.wirelessFailed;
    // GATT 连上却没有序列号 = 配对那一步没过。它可能发生在 BLE，也可能发生在
    // AP 的「配对」这一步，两种模式都要把这句说清楚。
    if (this.svc.bleConnected && !this.blePaired()) {
      return $r('app.string.camera_status_ble_pair_failed_detail');
    }
    return this.svc.lastScanError;
  }

  /** 上一次失败是不是「链路还挂着、只差取消」：蓝牙 GATT 在、配对没成。 */
  private bleStuck(): boolean {
    return this.svc.linkMode !== CameraLinkMode.USB
      && this.svc.bleConnected && !this.blePaired();
  }

  /** 状态头第一行：一句完整的话，讲清现在处在哪个阶段。 */
  private headline(): ResourceStr {
    const m = this.svc.linkMode;
    const phase = this.phase();
    if (phase === CameraPhase.Switching) return $r('app.string.camera_status_switching');
    if (phase === CameraPhase.Disconnecting) return $r('app.string.camera_status_disconnecting');
    if (phase === CameraPhase.Loading) {
      return this.svc.statusText !== ''
        ? this.svc.statusText : $r('app.string.camera_status_scanning');
    }
    if (phase === CameraPhase.Connected) {
      if (m === CameraLinkMode.BLE) {
        return this.svc.bleCameraName !== ''
          ? $r('app.string.camera_ble_connected_name', this.svc.bleCameraName)
          : $r('app.string.camera_ble_paired', this.svc.bleSerial);
      }
      return $r('app.string.camera_status_connected');
    }
    if (phase === CameraPhase.Pairing) return $r('app.string.camera_status_pairing_wait');
    if (phase === CameraPhase.Failed) {
      if (this.bleStuck()) return $r('app.string.camera_ble_pair_failed');
      // USB / 蓝牙的失败原因本身就是一句话，直接拿来做标题；再在下面重复
      // 一行同样的红字只会让人以为是两个问题。
      if (m === CameraLinkMode.USB) {
        return this.svc.lastScanError !== ''
          ? this.svc.lastScanError : $r('app.string.camera_status_no_camera');
      }
      if (m === CameraLinkMode.BLE) {
        return this.svc.lastScanError !== ''
          ? this.svc.lastScanError : $r('app.string.camera_status_ble_connect_failed');
      }
      return $r('app.string.camera_status_wifi_failed');
    }
    if (phase === CameraPhase.Searching) {
      if (m === CameraLinkMode.USB) {
        return this.svc.statusText !== ''
          ? this.svc.statusText : $r('app.string.camera_status_searching');
      }
      if (m === CameraLinkMode.BLE) return $r('app.string.camera_ble_scanning');
      return this.svc.bleScanning
        ? $r('app.string.camera_status_pair_searching') : $r('app.string.camera_wifi_scanning');
    }
    if (phase === CameraPhase.Connecting) {
      if (m === CameraLinkMode.BLE) {
        return this.svc.bleReconnecting
          ? $r('app.string.camera_ble_reconnecting_full') : $r('app.string.camera_ble_connecting');
      }
      // Wi-Fi 模式下蓝牙只当前置：断了在自动回连，页面就说「正在重新连接相机」，
      // 不再把蓝牙那半条链路的细节铺到 Wi-Fi 页面上。
      if (this.svc.bleReconnecting) return $r('app.string.camera_status_relinking');
      if (this.svc.bleConnecting) {
        // 已配对过的相机只是握手复用，不需要用户再把它切到「开始配对」页
        // （那一步只有首配才有）。
        return this.bleKnown()
          ? $r('app.string.camera_status_linking') : $r('app.string.camera_status_pairing');
      }
      if (this.svc.apJoining) return $r('app.string.camera_status_linking');
      if (this.svc.wifiAutoConnecting) {
        return m === CameraLinkMode.AP
          ? $r('app.string.camera_status_linking_ap') : $r('app.string.camera_status_linking_sta');
      }
      return $r('app.string.camera_status_relinking');
    }
    // 空闲：蓝牙模式下「配对过但当前链路断开」也显示已配对，和 Wi-Fi 模式
    // 的前置状态对齐；真正连着时走上面的 Connected 分支显示「已连接」。
    if (m === CameraLinkMode.BLE) {
      return this.bleKnown()
        ? $r('app.string.camera_state_paired') : $r('app.string.camera_conn_disconnected');
    }
    if (isWifiMode(m) && this.bleKnown()) return $r('app.string.camera_state_paired');
    return $r('app.string.camera_conn_disconnected');
  }

  /** 状态头第二行：只讲当前阶段的细节；空闲时讲下一步。 */
  private detail(): ResourceStr {
    const m = this.svc.linkMode;
    const phase = this.phase();
    if (phase === CameraPhase.Disconnecting) {
      return this.svc.wireless ? this.svc.wirelessStage : '';
    }
    if (phase === CameraPhase.Switching) return $r('app.string.camera_detail_switching');
    if (phase === CameraPhase.Connected || phase === CameraPhase.Loading
      || phase === CameraPhase.Pairing) {
      return '';
    }
    if (phase === CameraPhase.Failed) {
      // 无线的标题是泛化的「没能连上相机」，具体原因放这里；USB 的标题
      // 已经是原因本身。蓝牙配对失败是个例外：标题只说「配对失败」，
      // 还需要一行讲清楚链路停在哪、接下来该做什么。
      if (this.bleStuck()) return this.failReason();
      return isWifiMode(m) ? this.failReason() : '';
    }
    if (phase === CameraPhase.Connecting) {
      // 分步进度（AP 交接）优先：交接过程中蓝牙在重连时，别让「配对提示」
      // 盖掉真正的步骤。
      if (this.svc.apJoining || this.svc.wifiAutoConnecting) return this.svc.wirelessStage;
      // 首配才提示「停在开始配对页」；已配对过的只是重连。
      if (this.svc.bleConnecting && !this.bleKnown()) {
        return $r('app.string.camera_detail_pairing_hint');
      }
      return '';
    }
    if (phase === CameraPhase.Searching) {
      if (this.svc.bleScanning) return $r('app.string.camera_detail_pick_to_pair');
      return '';
    }
    // 空闲：下一步由状态头下方那行摘要和主操作承担，详情行不再重复。
    return '';
  }

  private dotColor(): Resource {
    const phase = this.phase();
    if (phase === CameraPhase.Connected) return $r('app.color.status_connected');
    if (phase === CameraPhase.Failed) return $r('app.color.status_error');
    if (phase === CameraPhase.Idle) return $r('app.color.text_tertiary');
    return $r('app.color.primary');
  }

  // ------------------------------------------------------------------
  // 主操作
  // ------------------------------------------------------------------

  /** 未连接时是「搜索 / 配对 / 连接」，已连接时是「断开」。 */
  private primaryActionLabel(): Resource {
    const phase = this.phase();
    if (phase === CameraPhase.Switching) return $r('app.string.camera_action_switching');
    if (phase === CameraPhase.Disconnecting) return $r('app.string.camera_action_disconnecting');
    if (phase === CameraPhase.Connected || phase === CameraPhase.Pairing) {
      return $r('app.string.camera_action_disconnect');
    }
    if (phase === CameraPhase.Loading || phase === CameraPhase.Searching) {
      return this.svc.linkMode === CameraLinkMode.USB
        ? $r('app.string.camera_main_scanning') : $r('app.string.camera_action_searching');
    }
    if (phase === CameraPhase.Connecting) {
      if (this.svc.bleConnecting) return $r('app.string.camera_ble_cancel');
      // 蓝牙断链后的自动重连可以放弃：它可能持续很久，用户不该只能等。
      if (this.svc.linkMode === CameraLinkMode.BLE && this.svc.bleReconnecting) {
        return $r('app.string.camera_action_disconnect');
      }
      return $r('app.string.camera_action_connecting');
    }
    if (phase === CameraPhase.Failed && this.bleStuck()) {
      return $r('app.string.camera_ble_cancel');
    }
    const m = this.svc.linkMode;
    // 无线链路失败后「重试」一把：`searchByMode` 会按当前进度补齐下一步
    // （没配对先扫蓝牙，配对过就直接重连），不需要用户自己判断卡在哪。
    if (phase === CameraPhase.Failed && isWifiMode(m) && this.svc.wirelessFailed !== '') {
      return $r('app.string.camera_action_retry');
    }
    // 空闲 / 失败后重试。USB 没有「按身份连回旧相机」的概念，按钮始终是搜索；
    // 只有 BLE 才按是否配对过区分「连接相机 / 搜索相机」。
    if (m === CameraLinkMode.USB) return $r('app.string.camera_main_find');
    if (m === CameraLinkMode.BLE) {
      return this.bleKnown()
        ? $r('app.string.camera_action_connect_camera') : $r('app.string.camera_main_find');
    }
    if (this.blePaired() || this.bleKnown()) return $r('app.string.camera_action_connect_camera');
    return $r('app.string.camera_main_find');
  }

  /** 主操作是否禁用：搜索 / 连接（且不能取消）/ 断开 / 切换时。 */
  private primaryActionDisabled(): boolean {
    const phase = this.phase();
    if (phase === CameraPhase.Searching || phase === CameraPhase.Loading
      || phase === CameraPhase.Disconnecting || phase === CameraPhase.Switching) {
      return true;
    }
    if (phase !== CameraPhase.Connecting) return false;
    if (this.svc.bleConnecting) return false;
    return !(this.svc.linkMode === CameraLinkMode.BLE && this.svc.bleReconnecting);
  }

  private primaryActionFill(): ResourceColor {
    const phase = this.phase();
    if (phase === CameraPhase.Connected || phase === CameraPhase.Pairing
      || phase === CameraPhase.Disconnecting || phase === CameraPhase.Switching) {
      return $r('app.color.action_neutral_fill');
    }
    if (phase === CameraPhase.Failed && this.bleStuck()) {
      return $r('app.color.action_neutral_fill');
    }
    // 可以取消的连接中（蓝牙在途）与「断开连接」同一档中性底：它是一颗
    // 能点的「结束」按钮，不是不可点的进度状态。
    if (phase === CameraPhase.Connecting
      && (this.svc.bleConnecting || this.svc.linkMode === CameraLinkMode.BLE)) {
      return $r('app.color.action_neutral_fill');
    }
    if (phase === CameraPhase.Searching || phase === CameraPhase.Loading
      || phase === CameraPhase.Connecting) {
      return $r('app.color.primary_light');
    }
    return $r('app.color.primary');
  }

  private primaryActionTextColor(): ResourceColor {
    const phase = this.phase();
    if (phase === CameraPhase.Connected || phase === CameraPhase.Pairing
      || phase === CameraPhase.Disconnecting || phase === CameraPhase.Switching) {
      return $r('app.color.text_primary');
    }
    if (phase === CameraPhase.Failed && this.bleStuck()) return $r('app.color.text_primary');
    if (phase === CameraPhase.Connecting
      && (this.svc.bleConnecting || this.svc.linkMode === CameraLinkMode.BLE)) {
      return $r('app.color.text_primary');
    }
    if (phase === CameraPhase.Searching || phase === CameraPhase.Loading
      || phase === CameraPhase.Connecting) {
      return $r('app.color.primary');
    }
    return $r('app.color.text_on_primary');
  }

  /** 主操作：永远是「当前这一步」的入口。 */
  private onPrimaryAction(): void {
    const phase = this.phase();
    if (this.primaryActionDisabled()) return;
    if (phase === CameraPhase.Connected || phase === CameraPhase.Pairing) {
      this.requestDisconnect();
      return;
    }
    if (phase === CameraPhase.Connecting && this.svc.bleConnecting) {
      this.onDisconnectBle();
      return;
    }
    if (phase === CameraPhase.Connecting && this.svc.linkMode === CameraLinkMode.BLE
      && this.svc.bleReconnecting) {
      this.requestDisconnect();
      return;
    }
    if (phase === CameraPhase.Failed && this.bleStuck()) {
      this.onDisconnectBle();
      return;
    }
    // 未连接 / 失败后重试：统一走 searchByMode。STA 也是「自动发现并连接」，
    // 不再让用户先看一张列表再手点一台。
    this.svc.searchByMode();
  }

  /** 已连接时断开：蓝牙走 BLE 断开，其余走会话断开（无线会先退出热点）。 */
  private requestDisconnect(): void {
    if (this.svc.linkMode === CameraLinkMode.BLE) {
      this.onDisconnectBle();
    } else {
      this.onDisconnect();
    }
  }

  // ------------------------------------------------------------------
  // 模式选择器的锁定
  // ------------------------------------------------------------------

  /**
   * 轻提示（1000ms）。
   *
   * 用 `openToast` 而不是 `showToast` 是为了拿到 toastId：双击在 450ms 内到达，
   * 弹确认框时要把还在屏上的「快速点击两次」收掉，否则弹窗后面挂着一句提示，
   * 看起来像两个控件在抢同一件事。
   */
  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().openToast({ message: message, duration: 1000 })
        .then((id: number) => { this.toastId = id; })
        .catch((_e: Error) => { /* 轻提示失败不影响主流程 */ });
    } catch (_e) {
      // 轻提示失败不影响主流程
    }
  }

  /** 收起还没到时间的轻提示（0.0：只给切模式确认框用）。 */
  private closeToast(): void {
    if (this.toastId < 0) return;
    try {
      this.getUIContext().getPromptAction().closeToast(this.toastId);
    } catch (_e) {
      // 已经消失 / 没找到都不影响流程
    }
    this.toastId = -1;
  }

  /** 整条选择器左右小幅快震：三段递减的位移，约 200ms。 */
  private runPickerShake(): void {
    this.pickerShakeX = 0;
    this.getUIContext().keyframeAnimateTo({ iterations: 1 }, [
      { duration: 42, curve: Curve.Sharp, event: () => { this.pickerShakeX = 6; } },
      { duration: 42, curve: Curve.Sharp, event: () => { this.pickerShakeX = -5; } },
      { duration: 42, curve: Curve.Sharp, event: () => { this.pickerShakeX = 3; } },
      { duration: 42, curve: Curve.Sharp, event: () => { this.pickerShakeX = -2; } },
      { duration: 48, curve: Curve.Sharp, event: () => { this.pickerShakeX = 0; } }
    ]);
  }

  /** 遮罩点击：选择器坐标系里的 x（vp）→ 分段下标；点当前那一段不反应。 */
  private onLockedPickerTap(x: number): void {
    const total = this.pickerWidth;
    if (total <= 0) return;
    const seg = (total - 8) / 4;
    let index = Math.floor((x - 4) / seg);
    index = Math.max(0, Math.min(3, index));
    if (index === this.svc.linkMode) return;
    this.onLockedModeTap(index);
  }

  /**
   * 已连接时点别的模式：先震一下 + 提示「快速点击两次进行切换」；
   * 在判定窗口内再点同一段，才弹出切换确认。
   */
  private onLockedModeTap(index: number): void {
    const now = Date.now();
    const isSecond = this.lockedTapIndex === index
      && now - this.lockedTapAt <= MODE_LOCK_DOUBLE_TAP_MS;
    if (isSecond) {
      this.lockedTapAt = 0;
      this.lockedTapIndex = -1;
      this.confirmSwitchMode(index);
      return;
    }
    this.lockedTapAt = now;
    this.lockedTapIndex = index;
    this.runPickerShake();
    this.toast($r('app.string.camera_mode_locked_hint'));
  }

  /** 切换确认：说清代价（会断开当前连接，且相机侧要手动改），再执行。 */
  private confirmSwitchMode(index: number): void {
    this.closeToast();
    this.getUIContext().showAlertDialog({
      title: $r('app.string.camera_mode_switch_title'),
      message: $r('app.string.camera_mode_switch_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: () => {}
      },
      secondaryButton: {
        value: $r('app.string.camera_mode_switch_confirm'),
        fontColor: $r('app.color.primary'),
        action: () => { this.onSwitchMode(index); }
      }
    });
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

  /** 当前模式的短标签（锁定态自绘滑块上显示的文字）。 */
  private modeLabel(): Resource {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) return $r('app.string.camera_mode_usb');
    if (m === CameraLinkMode.BLE) return $r('app.string.camera_mode_ble');
    if (m === CameraLinkMode.AP) return $r('app.string.camera_mode_ap');
    return $r('app.string.camera_mode_sta');
  }

  /** 滑块宽度 = 轨道内宽的四分之一（官方组件每个 item 的宽度）。 */
  private thumbWidth(): number {
    return this.pickerWidth > 0 ? (this.pickerWidth - 8) / 4 : 0;
  }

  /**
   * 锁定态的自绘滑块（1.64.0）。
   *
   * 只有这一层跟着 `pickerShakeX` 左右震；灰色轨道和另外三段文字都在官方
   * 组件里、原地不动。几何必须和官方 item 完全一致：轨道内边距 4、高 36、
   * 圆角 18、每段等宽。
   */
  @Builder
  PickerThumb() {
    Column() {
      Text(this.modeLabel())
        .fontSize(FontSize.Section)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary'))
        .maxLines(1)
    }
    .width(this.thumbWidth())
    .height(36)
    .justifyContent(FlexAlign.Center)
    .margin({ left: 4 + this.svc.linkMode * this.thumbWidth(), top: 4 })
    .backgroundColor($r('app.color.bg_surface'))
    .borderRadius(18)
    .translate({ x: this.pickerShakeX })
    // 不接点击：点击全部交给最上层的锁定遮罩
    .hitTestBehavior(HitTestMode.None)
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
    Stack({ alignContent: Alignment.TopStart }) {
      TabSegmentButtonV2({
        items: MODE_ITEMS,
        selectedIndex: this.svc.linkMode,
        onItemClicked: (index: number) => {
          // 遮罩在锁定时会接走点击，这里是兜底：绝不直接切模式。
          if (index !== this.svc.linkMode && this.linked()) {
            this.onLockedModeTap(index);
          }
        },
        $selectedIndex: (index: number) => {
          if (index === this.svc.linkMode) return;
          if (this.linked()) return;
          // 只有真的换了一档才震一下。点当前项、以及程序回写 selectedIndex
          // 都不该有反馈——振动一滥用就成了噪音。
          Haptics.tap();
          this.onSelectMode(index);
        },
        itemFontSize: LengthMetrics.fp(FontSize.Section),
        itemSelectedFontSize: LengthMetrics.fp(FontSize.Section),
        itemFontWeight: FontWeight.Regular,
        itemSelectedFontWeight: FontWeight.Bold,
        itemFontColor: ColorMetrics.resourceColor($r('app.color.text_secondary')),
        // 锁定时把官方自带的选中胶囊与选中文字都藏掉，改用下面自绘的滑块
        // （官方组件没有暴露滑块层，只有整体 translate，做不到「轨道不动」）。
        itemSelectedFontColor: ColorMetrics.resourceColor(
          this.linked() ? Color.Transparent : $r('app.color.primary')),
        itemPadding: {
          top: LengthMetrics.vp(0),
          bottom: LengthMetrics.vp(0),
          start: LengthMetrics.vp(4),
          end: LengthMetrics.vp(4)
        },
        itemMinHeight: LengthMetrics.vp(36),
        itemBorderRadius: LengthMetrics.vp(18),
        buttonMinHeight: LengthMetrics.vp(MODE_PICKER_HEIGHT),
        buttonPadding: LengthMetrics.vp(4),
        buttonBorderRadius: LengthMetrics.vp(pillRadius(MODE_PICKER_HEIGHT)),
        // 轨道不能用 bg_page：那是页面底色，浅色下白卡 255、轨道 242，差值只有 13，
        // 整条轨道像「卡片被切开一道缝」。control_track 浅色 228（差值 27），
        // 深色仍是纯黑（卡片 28 → 轨道 0，同样是 27），两种主题的层次强度对齐。
        buttonBackgroundColor: ColorMetrics.resourceColor($r('app.color.control_track')),
        itemSelectedBackgroundColor: ColorMetrics.resourceColor(
          this.linked() ? Color.Transparent : $r('app.color.bg_surface')),
        // 切换时胶囊滑动 + 文字颜色过渡（API 24 起，项目 target 26）
        enableStateAnimation: true
      })
        .width('100%')

      // 锁定态的滑块：官方组件的选中底色/文字已经透明，这里用同一套几何
      // （轨道内边距 4、每段等宽）画白底 + 选中文字，只有这一层跟着震动。
      if (this.linked() && this.pickerWidth > 0) {
        this.PickerThumb()
      }

      // 已连接时盖一层透明遮罩：把点击全部接走，四段的选中态就不会先跳到
      // 被点的那一段再跳回来。点哪里由 x 换算成下标（轨道两侧各 4vp）。
      if (this.linked()) {
        Column()
          .width('100%')
          .height(MODE_PICKER_HEIGHT)
          .onClick((event: ClickEvent) => { this.onLockedPickerTap(event.x); })
      }
    }
    .width('100%')
    .height(MODE_PICKER_HEIGHT)
    .onAreaChange((_old: Area, now: Area) => {
      const w = Number(now.width);
      if (w > 0 && Math.abs(w - this.pickerWidth) > 0.5) this.pickerWidth = w;
    })
  }

  /**
   * 连接引导：页面只留一句摘要，完整步骤和相机画面进系统半模态。
   *
   * 图片来源：Nikon SnapBridge 在线帮助。画面按面板宽度铺满（3:2），
   * AP 的相机段是热点图、手机段是配对图；BLE 是配对图；STA 是配置文件图。
   */
  @Builder
  GuideShotImage(shotKey: number) {
    Image(this.guideShotMedia(shotKey))
      .width('100%')
      .aspectRatio(1.5)
      .objectFit(ImageFit.Cover)
      .interpolation(ImageInterpolation.High)
      .borderRadius(8)
      .border({ width: 0.5, color: $r('app.color.divider') })
      .draggable(false)
  }

  /** 某个步骤对应的相机画面素材。 */
  private guideShotMedia(shotKey: number): Resource {
    if (this.svc.linkMode === CameraLinkMode.AP) {
      return shotKey === 1
        ? $r('app.media.camera_guide_ble_pair')
        : $r('app.media.camera_guide_ap_hotspot');
    }
    if (this.svc.linkMode === CameraLinkMode.STA) {
      return $r('app.media.camera_guide_sta_menu');
    }
    return $r('app.media.camera_guide_ble_pair');
  }

  /** 一句话摘要：只讲「先做什么、再做什么」，细节交给面板。 */
  private guideSummary(): Resource {
    const known = this.bleKnown();
    if (this.svc.linkMode === CameraLinkMode.USB) {
      return $r('app.string.camera_guide_summary_usb');
    }
    if (this.svc.linkMode === CameraLinkMode.BLE) {
      return known
        ? $r('app.string.camera_guide_summary_ble_ready')
        : $r('app.string.camera_guide_summary_ble');
    }
    if (this.svc.linkMode === CameraLinkMode.AP) {
      return known
        ? $r('app.string.camera_guide_summary_ap_ready')
        : $r('app.string.camera_guide_summary_ap');
    }
    return known
      ? $r('app.string.camera_guide_summary_sta_ready')
      : $r('app.string.camera_guide_summary_sta');
  }

  @Builder
  GuideSummary() {
    Column({ space: 2 }) {
      Row({ space: 8 }) {
        Text(this.guideSummary())
          .fontSize(FontSize.Caption)
          .lineHeight(20)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Row({ space: 2 }) {
          Text($r('app.string.camera_guide_view_steps'))
            .fontSize(FontSize.Caption)
            .lineHeight(20)
            .fontColor($r('app.color.primary'))
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(12)
            .fontColor([$r('app.color.primary')])
        }
        .height(20)
        .alignItems(VerticalAlign.Center)
        .flexShrink(0)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .onClick(() => { this.guideSheetOpen = true; })

    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
    .margin({ top: 4 })
  }

  /**
   * 面板初始高度按当前模式的内容量给：USB 只有两句话，用中等高度会空出
   * 一大片白；AP 有两张图，给高一点，打开后不用先滚一屏。都还能上拉到 LARGE。
   */
  private guideSheetHeight(): number {
    if (this.svc.linkMode === CameraLinkMode.USB) {
      return 240;
    }
    if (this.bleKnown()) {
      return 260;
    }
    if (this.svc.linkMode === CameraLinkMode.AP) {
      return 730;
    }
    if (this.svc.linkMode === CameraLinkMode.STA) {
      return 420;
    }
    return 460;
  }

  private guideSheetOptions(): SheetOptions {
    const height = this.guideSheetHeight();
    const opts: SheetOptions = {
      height,
      detents: [height, SheetSize.LARGE],
      preferType: SheetType.BOTTOM,
      dragBar: true,
      showClose: false
    };
    // bindSheet 的沉浸光感只能组件级开启；设置 systemMaterial 后不要再设
    // backgroundColor / blurStyle，否则会把材质盖掉。调试机关闭磨砂时退回
    // 不透明底，内容仍然可读。
    if (GlassEffect.isEnabled()) {
      opts.systemMaterial = GlassEffect.material(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THICK
      }));
    } else {
      opts.backgroundColor = $r('app.color.bg_surface');
    }
    return opts;
  }

  @Builder
  GuideSheetStep(lead: ResourceStr, body: Resource, shotKey: number) {
    Column({ space: 12 }) {
      Text() {
        Span(lead).fontColor($r('app.color.text_primary')).fontWeight(FontWeight.Medium)
        Span(body).fontColor($r('app.color.text_secondary'))
      }
      .fontSize(FontSize.Reading)
      .lineHeight(22)
      .width('100%')

      if (shotKey >= 0) {
        this.GuideShotImage(shotKey)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 相机侧的两句话合成一段：同一台相机上的两个连续动作，不另起一行缩进。
   * 图片跟段落同宽，不再因为缩进变窄。
   */
  @Builder
  GuideSheetCameraStep(body: Resource, continuation: Resource, shotKey: number) {
    Column({ space: 12 }) {
      // 两句话在句号处分行，第二行不缩进；让换行点可控，避免「建立连接」
      // 被折断成「建 / 立连接」这种中文断词。
      Column({ space: 2 }) {
        Text() {
          Span($r('app.string.camera_guide_on_camera'))
            .fontColor($r('app.color.text_primary')).fontWeight(FontWeight.Medium)
          Span(body).fontColor($r('app.color.text_secondary'))
        }
        .fontSize(FontSize.Reading)
        .lineHeight(22)
        .width('100%')

        Text(continuation)
          .fontSize(FontSize.Reading)
          .lineHeight(22)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      this.GuideShotImage(shotKey)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  GuideSheet() {
    Column({ space: 0 }) {
      Text($r('app.string.camera_guide_steps'))
        .fontSize(FontSize.Title)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ top: 4, bottom: 2 })

      Scroll() {
        Column({ space: 20 }) {
          if (this.svc.linkMode !== CameraLinkMode.USB && this.bleKnown()) {
            // 已配对过：首配的相机菜单步骤不再适用，面板只留一句重连动作。
            this.GuideSheetStep('', this.guideSummary(), -1)
          } else if (this.svc.linkMode === CameraLinkMode.USB) {
            this.GuideSheetStep($r('app.string.camera_guide_on_camera'),
              $r('app.string.camera_guide_usb_1'), -1)
            this.GuideSheetStep($r('app.string.camera_guide_on_phone'),
              $r('app.string.camera_guide_usb_2'), -1)
          } else if (this.svc.linkMode === CameraLinkMode.BLE) {
            this.GuideSheetStep($r('app.string.camera_guide_on_camera'),
              $r('app.string.camera_guide_ble_1'), 0)
            this.GuideSheetStep($r('app.string.camera_guide_on_phone'),
              $r('app.string.camera_guide_ble_2'), -1)
          } else if (this.svc.linkMode === CameraLinkMode.AP) {
            this.GuideSheetCameraStep(
              $r('app.string.camera_guide_ap_1'),
              $r('app.string.camera_guide_ap_screen'), 0)
            this.GuideSheetStep($r('app.string.camera_guide_on_phone'),
              $r('app.string.camera_guide_ap_2'), 1)
          } else {
            this.GuideSheetCameraStep(
              $r('app.string.camera_guide_sta_2'),
              $r('app.string.camera_guide_sta_screen'), 0)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 14, bottom: 32 })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 阶段是不是「正在进行中」：状态点换成转圈，避免再单开一行进度。 */
  private inProgress(): boolean {
    const phase = this.phase();
    return phase === CameraPhase.Searching || phase === CameraPhase.Connecting
      || phase === CameraPhase.Loading || phase === CameraPhase.Disconnecting
      || phase === CameraPhase.Switching;
  }

  /**
   * 状态头：进度点 + 一句状态 + 一行阶段细节 +（已连接时）照片数 + 主操作胶囊。
   *
   * 主操作永远是「当前这一步」：未连接是「搜索 / 配对 / 连接」，进行中禁用，
   * 已连接变中性底的「断开连接」。它也是页面上**唯一**的断开入口——同一张卡里
   * 出现两个「断开」只会让人犹豫点哪个。
   */
  @Builder
  StatusHeader() {
    Row({ space: 10 }) {
      if (this.inProgress()) {
        LoadingProgress()
          .width(16).height(16)
          .color($r('app.color.primary'))
          .flexShrink(0)
      } else {
        Row()
          .width(8).height(8)
          .borderRadius(pillRadius(8))
          .backgroundColor(this.dotColor())
          .flexShrink(0)
      }
      Column({ space: 3 }) {
        Text(this.headline())
          .fontSize(FontSize.CardTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .maxLines(2)
        if (this.detail() !== '') {
          Text(this.detail())
            .fontSize(FontSize.Caption)
            .lineHeight(18)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .maxLines(3)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.linked() && this.svc.photoCount > 0) {
        Text($r('app.plural.photo_count', this.svc.photoCount, this.svc.photoCount))
          .fontSize(FontSize.Caption)
          .fontColor($r('app.color.primary'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.primary_soft'))
          .borderRadius(Radius.Chip)
          .flexShrink(0)
      }
      Button(this.primaryActionLabel())
        .height(36)
        .padding({ left: 16, right: 16 })
        .fontSize(FontSize.Body)
        .fontWeight(FontWeight.Medium)
        .borderRadius(pillRadius(36))
        .backgroundColor(this.primaryActionFill())
        .fontColor(this.primaryActionTextColor())
        .enabled(!this.primaryActionDisabled())
        .flexShrink(0)
        .onClick(() => { this.onPrimaryAction(); })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 蓝牙相机列表：BLE 模式与 AP 的「配对」这一步共用。
   *
   * AP 未配对时「搜索相机」扫到的就是这些设备，点一台 = 配对 + 交接热点，
   * 所以列表在两种模式下长得一样、动作也一样。
   */
  @Builder
  BleCameraList() {
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
  }

  /**
   * 已连上无线：只显示地址。
   *
   * 「断开」不在这里——状态头右侧那颗胶囊已经是全页唯一的断开入口。
   */
  @Builder
  AddressRow() {
    Row({ space: 12 }) {
      Text($r('app.string.camera_conn_wifi_host', this.svc.wifiHost, `${this.svc.wifiPort}`))
        .fontSize(FontSize.Caption)
        .fontColor($r('app.color.text_tertiary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  /** 蓝牙回不来时的说明（只在对它有意义的阶段渲染）。 */
  @Builder
  BleHintLine() {
    if (this.svc.bleHint !== '') {
      Text(this.svc.bleHint)
        .fontSize(FontSize.Micro)
        .lineHeight(16)
        .fontColor($r('app.color.status_error'))
        .width('100%')
    }
  }

  /**
   * AP 模式的主体：只剩「等它连」和「已连上」两种画面。
   *
   * 配对设备列表在未配对时出现；配对完成后提示相机会切到热点，主动作是
   * 「连接相机」。以前这里还有一颗「查看照片」按钮，和状态头的「搜索相机」
   * 指向同一条流程，用户得猜点哪个——现在只留状态头那一颗。
   */
  @Builder
  ApControls() {
    if (this.wifiConnected()) {
      this.AddressRow()
    } else {
      if (this.blePaired()) {
        Text($r('app.string.camera_conn_open_wifi_hint'))
          .fontSize(FontSize.Micro)
          .lineHeight(16)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      this.BleCameraList()
      this.BleHintLine()
    }
  }

  /** STA 空闲且不在搜索/交接时，才显示网络元信息与手动 IP。 */
  private staMetaVisible(): boolean {
    return this.svc.linkMode === CameraLinkMode.STA && !this.wifiConnected()
      && !(this.svc.apJoining || this.svc.wifiAutoConnecting
        || this.svc.wifiReconnecting || this.svc.wifiScanning);
  }

  /** STA 的网络摘要 + 手动 IP：紧贴四选一下方，一行收起。 */
  @Builder
  StaNetworkRow() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        if (this.svc.networkSummary !== '') {
          Text($r('app.string.camera_conn_network', this.svc.networkSummary))
            .fontSize(FontSize.Micro)
            .lineHeight(16)
            .fontColor($r('app.color.text_tertiary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Blank()
        }
        Row({ space: 2 }) {
          Text(this.staManualOpen
            ? $r('app.string.camera_sta_manual_hide')
            : $r('app.string.camera_sta_manual_show'))
            .fontSize(FontSize.Micro)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(12)
            .fontColor([$r('app.color.text_tertiary')])
            .rotate({ angle: this.staManualOpen ? 180 : 0 })
        }
        .padding({ top: 6, bottom: 6, left: 6 })
        .onClick(() => { this.staManualOpen = !this.staManualOpen; })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.staManualOpen) {
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
            .backgroundColor(this.wifiInput.trim() !== ''
              ? $r('app.color.primary') : $r('app.color.filter_chip_bg'))
            .fontColor(this.wifiInput.trim() !== ''
              ? $r('app.color.text_on_primary') : $r('app.color.text_tertiary'))
            .enabled(!this.svc.scanning && this.wifiInput.trim() !== '')
            .onClick(() => { this.onConnectWifi(this.wifiInput.trim()); })
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** STA 状态区：已连接地址、发现但未连上的相机、错误/提示。 */
  @Builder
  StaControls() {
    if (this.wifiConnected()) {
      this.AddressRow()
    } else if (!(this.svc.apJoining || this.svc.wifiAutoConnecting
      || this.svc.wifiReconnecting || this.svc.wifiScanning)) {
      // 自动连失败后还能点一台：平时这里没有内容，只有发现过、但没连上的情况。
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

      // 失败原因已经写在状态头的详情行里，这里只在「空闲但网络有条件问题」时
      // 提醒，避免同一句红字出现两遍。
      if (this.svc.wifiHint !== '' && this.phase() !== CameraPhase.Failed) {
        Text(this.svc.wifiHint)
          .fontSize(FontSize.Micro)
          .lineHeight(16)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
      this.BleHintLine()
    }
  }

  /** 模式专属的交互区：只渲染当前模式用得上的控件。 */
  @Builder
  ModeControls() {
    if (this.svc.linkMode === CameraLinkMode.BLE) {
      this.BleCameraList()
    } else if (this.svc.linkMode === CameraLinkMode.AP) {
      this.ApControls()
    } else if (this.svc.linkMode === CameraLinkMode.STA) {
      this.StaControls()
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

      // 连接阶段的失败写在状态头的详情行里（唯一一处）；这里只保留「会话还在，
      // 但这次扫描失败」——那时状态头是「已连接」，需要单独一行讲扫描错误。
      if (this.svc.lastScanError !== '' && this.svc.connected) {
        Text(this.svc.lastScanError)
          .fontSize(FontSize.Caption)
          .lineHeight(18)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }

      Divider().color($r('app.color.divider'))

      // 四选一：不再配一句模式说明，模式差异交给下面的相机操作说明。
      this.ModePicker()

      if (this.staMetaVisible()) {
        this.StaNetworkRow()
      }

      this.ModeControls()

      // 连接引导：页面只留一句摘要，完整步骤和相机画面进系统半模态。
      // 已配对相机的重连过程中不再显示「点连接相机」——那时按钮已经变成
      // 「取消连接」，再留着这句会自相矛盾；首配/搜索新相机时保留步骤。
      if (!this.linked() && !(this.bleKnown() && this.inProgress())) {
        this.GuideSummary()
      }

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
        // 卡面交叉淡入淡出：上一层旧图 1→0，新图 0→1；同型号换序列号时
        // effectiveStandeeKey 不变，不会白闪一下。
        Stack({ alignContent: Alignment.Bottom }) {
          if (this.standeePreviousKey !== '') {
            Image(cameraStandeeMedia(this.standeePreviousKey))
              .width(this.standeeWidthFor(this.standeePreviousKey))
              .height(STANDEE_HEIGHT)
              .objectFit(ImageFit.Contain)
              .interpolation(ImageInterpolation.High)
              .draggable(false)
              .opacity((this.linked() ? 1 : 0.72) * (1 - this.standeeCrossfade))
          }
          if (this.standeeCurrentKey !== '') {
            Image(cameraStandeeMedia(this.standeeCurrentKey))
              .width(this.standeeWidthFor(this.standeeCurrentKey))
              .height(STANDEE_HEIGHT)
              .objectFit(ImageFit.Contain)
              .interpolation(ImageInterpolation.High)
              .draggable(false)
              .opacity((this.linked() ? 1 : 0.72) * this.standeeCrossfade)
          }
        }
        .width('100%')
        .height(STANDEE_HEIGHT)

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
  /** 真实型号优先；没有真实型号（标题为「相机」）时才看用户设置的默认立牌。 */
  private effectiveStandeeKey(): string {
    return this.svc.cameraModel !== '' ? this.svc.cameraModel : this.standeePref.defaultKey;
  }

  private standeeWidthFor(key: string): number {
    return key === '' ? 0 : STANDEE_HEIGHT * cameraStandeeAspect(key);
  }

  /** 卡面换型号：保留上一张，280ms 交叉淡入淡出，不硬切。 */
  private syncStandee(): void {
    const next = this.effectiveStandeeKey();
    if (next === this.standeeCurrentKey) return;
    this.standeePreviousKey = this.standeeCurrentKey;
    this.standeeCurrentKey = next;
    this.standeeCrossfade = 0;
    animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
      this.standeeCrossfade = 1;
    });
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
    const base = this.linked() ? 0.7 : 0.7 * 0.7;
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
      // 倒影与主图同步交叉淡入淡出，避免「机身已经换图、脚下的镜像还是上一台」。
      Stack({ alignContent: Alignment.Top }) {
        if (this.standeePreviousKey !== '') {
          Image(cameraStandeeMedia(this.standeePreviousKey))
            .width(this.standeeWidthFor(this.standeePreviousKey))
            .height(STANDEE_HEIGHT)
            .objectFit(ImageFit.Contain)
            .interpolation(ImageInterpolation.High)
            .draggable(false)
            .scale({ x: 1, y: -1 })
            .translate({ y: 0 })
            .opacity(this.reflectionOpacity() * (1 - this.standeeCrossfade))
        }
        if (this.standeeCurrentKey !== '') {
          Image(cameraStandeeMedia(this.standeeCurrentKey))
            .width(this.standeeWidthFor(this.standeeCurrentKey))
            .height(STANDEE_HEIGHT)
            .objectFit(ImageFit.Contain)
            .interpolation(ImageInterpolation.High)
            .draggable(false)
            .scale({ x: 1, y: -1 })
            .translate({ y: 0 })
            .opacity(this.reflectionOpacity() * this.standeeCrossfade)
        }
      }
      .width('100%')
      .height(STANDEE_HEIGHT)
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
        .width(this.standeeWidthFor(this.standeeCurrentKey) * STANDEE_SHADOW_WIDTH_RATIO)
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

  /**
   * 数据操作：快速扫描 / 全量扫描。
   *
   * 「断开连接」已经交给状态头那颗胶囊（1.64.0），这里只留与照片数据有关的两条：
   * 上面管「补新增」，下面管「忽略缓存重来」。
   */
  @Builder
  ActionRows() {
    Column() {
      CameraActionRow({
        label: $r('app.string.camera_main_quick_scan'),
        subtitle: $r('app.string.camera_action_quick_scan_desc'),
        disabled: this.svc.scanning,
        onTap: () => { this.onScan(true); }
      })
      CameraActionRow({
        label: $r('app.string.camera_action_full_scan'),
        subtitle: $r('app.string.camera_action_full_scan_desc'),
        disabled: this.svc.scanning,
        last: true,
        onTap: () => { this.onScan(false); }
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
    .bindSheet($$this.guideSheetOpen, this.GuideSheet(), this.guideSheetOptions())
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
