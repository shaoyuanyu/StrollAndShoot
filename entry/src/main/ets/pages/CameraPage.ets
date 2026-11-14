import { CameraService } from '../services/CameraService';
import { BleIdentityStore } from '../services/BleIdentityStore';
import { SavedCameraStore } from '../services/SavedCameraStore';
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

/** 说明面板两页的标题。 */
const GUIDE_TAB_ITEMS: SegmentButtonV2Items = new SegmentButtonV2Items([
  { text: $r('app.string.camera_guide_steps') },
  { text: $r('app.string.camera_guide_modes_title') }
]);

/**
 * 「连接模式」支持表：功能列宽与行高（vp）。
 *
 * 功能列固定 104vp（最长的一条是 7 个汉字 ≈ 84vp），四个模式列均分剩下的
 * 宽度：365.7vp 的机器上每列约 57vp，「Wi-Fi STA」在 12fp 下约 50vp，排得下。
 */
const GUIDE_FEATURE_COL = 104;
const GUIDE_ROW_HEIGHT = 34;
/** 支持表一格的状态：不支持 / 支持 / 部分支持（1.66.13 加了「部分」）。 */
const GUIDE_NONE = 0;
const GUIDE_FULL = 1;
const GUIDE_PARTIAL = 2;

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

/*
 * 顶边下拉刷新（1.65.0，第二轮）。
 *
 * **手势与下拉编排一行不改**：初始位置继续下拉时 `currentOffset()` 变负，
 * `pullDown` 跟着长，卡面走 1/3、卡内抽屉开 2/3、立牌倒影被拉长——全是既有行为。
 * 新增的只有「松手之后」这一段：
 *
 * - 松手高度不到最大下拉的 [REFRESH_TRIGGER_RATIO]（80%）→ 什么都不做，
 *   继续跟着弹簧回弹（和以前完全一致）；
 * - 到了阈值 → 手指抬起那一刻定格，用**一条** `animateTo` 把「下拉量」收回到 0：
 *   卡面与抽屉完整回弹到原位，系统刷新指示器贴在卡面正上方、跟着一起落到
 *   「标题栏与卡面之间」那段空白里继续转；
 * - [REFRESH_FAKE_MS] 之后（现在没有实质刷新动作，先写死 2s）指示器淡出，
 *   其余组件早已在原位，不需要再动。
 *
 * 这样「回弹」和「进入刷新」是同一条动画，不会出现「先弹回原位、再冒出一个转圈
 * 把卡面挤下去」的两段。指示器用官方 `SwipeRefresherV2`（系统加载动效）。
 */
const REFRESH_TRIGGER_RATIO = 0.8;
/** 触发刷新所需的下拉量（vp）= 最大下拉的 80%。 */
const REFRESH_THRESHOLD_VP = TOP_PULL_MAX * REFRESH_TRIGGER_RATIO;
/**
 * 刷新指示器：**不占布局**，画在标题栏与卡面之间那段空白里（1.65.0 第二轮第三版，
 * 用户要求）。松手后卡面与抽屉**完整回弹到原位**，指示器留在卡面正上方继续转，
 * 刷完淡出——回弹行程因此拿到卡面的 48vp 加抽屉的 144vp，比「卡面被顶下去一行」
 * 那版长得多。指示器 22vp 必须塞得进那段空白（模拟器上约 48vp，见 `REFRESH_ICON`）。
 */
/** 刷新动作时长（ms）：现在没有实质动作，写死 2s。 */
const REFRESH_FAKE_MS = 2000;
/** 「松手回弹到原位」与「指示器淡出」的动画时长（ms）。 */
const REFRESH_ANIM_MS = 260;
/**
 * 指示器的**盒子**尺寸（vp）：`LoadingProgress` 实际画出来的圆约是盒子的 2/3，
 * 盒子 27 → 视觉直径约 **18vp**（用户指定的尺寸；22 的盒子只有 13vp，太小）。
 *
 * 用系统 `LoadingProgress` 而不是 `SwipeRefresherV2`：后者自带尺寸固定 13vp 左右，
 * 想放大只能给容器加 `scale`，而 `scale` 是渲染变换，会按 1x 栅格化再放大、边缘发虚
 * （实测）。`LoadingProgress` 的 `width/height` 直接可给，放大后仍然清晰。
 */
const REFRESH_ICON = 27;
/** 指示器底边与卡面上沿的间距（vp）：图标永远贴在卡面正上方、与卡面同速移动。 */
const REFRESH_ICON_GAP = 4;

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
  /**
   * 吸附的分页点：`[0, stick]`。
   *
   * **贴在末端的那一页要往里让开 2vp**（1.65.0 修）：抽屉内容装得下时
   * （`innerScrollSpan() === 0`）可滚距离正好等于 `stick`，分页点因此落在可滚
   * 距离的端点上。官方文档只要求取值在 `[0, 可滚距离]` 内，但实测落在端点上时
   * **整条 `scrollSnap` 都不生效**——第一段/第二段松手停在半路，没有任何吸附。
   * 让开 2vp 之后它落在范围内部，吸附恢复；少这 2vp 肉眼看不出来。
   *
   * 有第三段（内容比抽屉高）时可滚距离大于 `stick`，分页点本来就在内部，仍用
   * 精确的 `stick`，贴顶那一帧才是严丝合缝的。
   */
  private snapPages(): number[] {
    const stick = stickScrollVp();
    const max = this.maxScrollY();
    return [0, max - stick > 2 ? stick : Math.max(1, stick - 2)];
  }

  /**
   * 顶边下拉刷新（1.65.0）。
   *
   * 界面这一层只管手势、阈值与动画：现在没有实质刷新动作，加载动画时长写死
   * `REFRESH_FAKE_MS`（2s）。这个回调是给后续接「重新扫描相机」留的口子——
   * 动作要接的时候在 MainScreen 里实现即可，页面不用动；它不影响动画时长。
   */
  @Event onRefresh: () => void = () => {};

  /** 无线连接输入框；首次进入用上次成功的地址预填。 */
  @Local wifiInput: string = '';
  /** 指定相机 IP 的半模态是否打开。 */
  @Local ipSheetOpen: boolean = false;
  /** 半模态说明面板是否打开。 */
  @Local guideSheetOpen: boolean = false;
  /** 说明面板当前页：0 = 连接步骤，1 = 连接模式。 */
  @Local guideTab: number = 0;

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
   * 下拉刷新（1.65.0）。
   *
   * - `pullProgress`：本次下拉进度（0..1，1 = `TOP_PULL_MAX`），指示器随它淡入；
   * - `refreshing`：刷新中（由 `onTopTouch()` 置真，`REFRESH_FAKE_MS` 后置假）；
   * - `refreshFade`：刷新结束那一下的淡出（1→0），让指示器不是硬消失。
   * 刷新时卡面与抽屉**回原位**，所以不再需要「撑开一行」的位移量。
   */
  @Local pullProgress: number = 0;
  @Local refreshing: boolean = false;
  @Local refreshFade: number = 1;

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
   * 蓝牙模式下的临时 Wi-Fi 浏览会话（1.67.0）。
   *
   * 蓝牙模式平时只待机；用户点「浏览与下载照片」后，App 会把相机推到热点，
   * 会话就变成一条 Wi-Fi PTP 会话——`linkMode` 仍然是蓝牙，因为用户选的就是
   * 这条链路，只是它临时借用了相机的 Wi-Fi。
   */
  private bleBrowsing(): boolean {
    return this.svc.linkMode === CameraLinkMode.BLE
      && this.svc.connected && this.svc.wireless;
  }

  /**
   * 这台相机以前配对过（身份已落盘）。
   *
   * 与 `blePaired()` 不是一回事：断开之后链路没了，但相机那边还记着这台手机，
   * 再连不需要重新配对。按钮文案要能区分「找一台新相机」和「连回那台旧相机」。
   */
  private bleKnown(): boolean {
    if (this.blePaired()) return true;
    if (this.bleId.hasIdentity() && this.bleId.deviceId !== '') return true;
    // 身份没装回活动位不等于没配过对（1.66.1）：仓库里还留着这台相机的
    // device/nonce，连接时服务端会先把它装回去。这条兜底让按钮仍是
    // 「连接相机」、摘要仍是「点「连接相机」重新连接」，而不是把一台配过对的
    // 相机当成新相机去「搜索」再首配（相机那边会秒拒）。
    return SavedCameraStore.getInstance().pickReal() !== null;
  }

  /**
   * 当前模式是否已经连上。
   *
   * 三种链路的「已连接」不是同一个字段：USB 是 PTP 会话（`connected` 且非无线），
   * 蓝牙是配对落定（链路在 + 拿到序列号）或临时浏览会话（相机热点上的 PTP，
   * 1.67.0），AP / STA 是 Wi-Fi 会话。主操作变「断开」、模式选择器上锁都以它为准。
   */
  private linked(): boolean {
    const m = this.svc.linkMode;
    if (m === CameraLinkMode.USB) return this.usbConnected();
    // 蓝牙模式有两种「已连上」：待机（配对落定）与临时浏览（相机热点上的 PTP）。
    if (m === CameraLinkMode.BLE) return this.blePaired() || this.bleBrowsing();
    return this.wifiConnected();
  }

  /**
   * 当前展示阶段。整页的状态文案、状态点、主操作都只从这一个判断里出：
   *
   * - USB：空闲 → 搜索 → 已连接（数据线一条链路）；
   * - BLE：空闲 → 搜索 → 连接/配对 → 已配对；点「浏览与下载照片」后进入
   *   「正在切换到相机热点」→ 已连上相机热点（1.67.0，回程自动回蓝牙）；
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
    // 蓝牙模式的按需浏览（1.67.0）：交接刚开始时 BLE 还连着（`linked()` 为真），
    // 不能让「已连接 · 蓝牙」把交接进度盖住——这一次的目标是 Wi-Fi 会话，
    // 还没连上。交接一结束 `apJoining` 归位，才会回到 Connected。
    if (this.linked() && !(this.svc.apJoining || this.svc.wifiAutoConnecting)) {
      if (this.svc.pairingRequired) return CameraPhase.Pairing;
      return this.svc.scanning ? CameraPhase.Loading : CameraPhase.Connected;
    }
    if (this.svc.bleConnecting || this.svc.bleReconnecting) return CameraPhase.Connecting;
    // 手填 IP 的 `connectWifi()`：没有这个标记，页面会一直停在「未连接」，
    // 用户按了键盘「前往」也看不到反应（`wifiAutoConnecting` 只管自动链路）。
    if (this.svc.wifiConnecting) return CameraPhase.Connecting;
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
      if (this.scanFailed()) return this.scanErrorTitle();
      if (m === CameraLinkMode.BLE) {
        // 临时浏览（1.67.0）：这时蓝牙已经让位给 Wi-Fi，再说「已连接 · 蓝牙」
        // 会让人以为待机链路还在。
        if (this.bleBrowsing()) return $r('app.string.camera_ble_browsing');
        return this.svc.bleCameraName !== ''
          ? $r('app.string.camera_ble_connected_name', this.svc.bleCameraName)
          : $r('app.string.camera_ble_paired', this.svc.bleSerial);
      }
      return $r('app.string.camera_status_connected');
    }
    if (phase === CameraPhase.Pairing) return $r('app.string.camera_status_pairing_wait');
    if (phase === CameraPhase.Failed) {
      if (this.bleStuck()) return $r('app.string.camera_ble_pair_failed');
      // USB / 蓝牙的失败原因本身就是一句话，直接拿来做标题；但标题只放冒号前的
      // 结论，「请确认…」那句动作交给 `detail()`（1.65.2），否则一句「结论：动作」
      // 在 16fp 下发字号标题里要折两行，动作会被当成第二个结论读。
      if (m === CameraLinkMode.USB) {
        return this.svc.lastScanError !== ''
          ? this.scanErrorTitle() : $r('app.string.camera_status_no_camera');
      }
      if (m === CameraLinkMode.BLE) {
        return this.svc.lastScanError !== ''
          ? this.scanErrorTitle() : $r('app.string.camera_status_ble_connect_failed');
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
        // 按需浏览的交接阶段：蓝牙已经让位，说的必须是「正在切到相机热点」，
        // 否则会显示成「正在连接相机」而看不出正在走 Wi-Fi。
        if (this.svc.apJoining || this.svc.wifiAutoConnecting) {
          return $r('app.string.camera_ble_browse_linking');
        }
        // 浏览会话掉线后的自动重连：说「正在重新连接相机」，不是「切换热点」。
        if (this.svc.wifiReconnecting) return $r('app.string.camera_status_relinking');
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
      // 手填 IP：`connectWifi()` 已经写好了「正在连接 Wi-Fi 相机 <地址>」。
      if (this.svc.wifiConnecting) {
        return this.svc.statusText !== ''
          ? this.svc.statusText : $r('app.string.camera_status_linking');
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
    if (phase === CameraPhase.Connected && this.bleBrowsing()) {
      return $r('app.string.camera_ble_browsing_detail');
    }
    if (phase === CameraPhase.Connected || phase === CameraPhase.Loading
      || phase === CameraPhase.Pairing) {
      return '';
    }
    if (phase === CameraPhase.Failed) {
      // 无线的标题是泛化的「没能连上相机」，具体原因放这里；USB / 蓝牙的标题
      // 就是原因本身，冒号后那句「下一步」放这里（1.65.2：和读卡失败态同一套
      // 拆行规则，标题只放结论，动作不挤进 16fp 的标题里）。蓝牙配对失败是个
      // 例外：标题只说「配对失败」，还需要一行讲清楚链路停在哪、接下来该做什么。
      if (this.bleStuck()) return this.failReason();
      return isWifiMode(m) ? this.failReason() : this.scanErrorHint();
    }
    if (phase === CameraPhase.Connecting) {
      // 分步进度（AP 交接）优先：交接过程中蓝牙在重连时，别让「配对提示」
      // 盖掉真正的步骤。
      if (this.svc.apJoining || this.svc.wifiAutoConnecting) return this.svc.wirelessStage;
      // 首配才提示「停在开始配对页」；已配对过的只是重连。
      if (this.svc.bleConnecting && !this.bleKnown()) {
        return $r('app.string.camera_detail_pairing_hint');
      }
      // 断链重连连相机广播都扫不到：多半进了待机，让用户去按一下快门。
      if (this.svc.linkMode === CameraLinkMode.BLE && this.svc.bleReconnecting
        && this.svc.bleAsleep) {
        return $r('app.string.camera_detail_ble_asleep');
      }
      return '';
    }
    if (phase === CameraPhase.Searching) {
      if (this.svc.bleScanning) return $r('app.string.camera_detail_pick_to_pair');
      return '';
    }
    // 空闲：「等相机回蓝牙」要说出来（1.67.0）。蓝牙模式的浏览会话一结束，
    // 相机要几十秒才退出 Wi-Fi，这段时间页面已经回到「已配对 · 未连接」，
    // 不说一声会以为是断开失败了。
    if (m === CameraLinkMode.BLE && this.svc.bleRecovering) {
      return $r('app.string.camera_ble_returning');
    }
    // 空闲：下一步由状态头下方那行摘要和主操作承担，详情行不再重复。
    return '';
  }

  /**
   * 「会话还在、这一轮却读不到卡」：状态头整块换成错误态。
   *
   * 相机页的失败有两种。一种是连不上（`Failed`，标题本身就是失败原因）；另一种是
   * **连上了但读不到卡**——USB 会话在、设备信息也读得到，只有 GetStorageIDs / 取
   * 元数据被相机拒绝（0x200F 等）。后一种以前是「绿灯 + 已连接」，下面再另起一行
   * 红字讲错误：一个绿点配一句红字，看着像两个互不相干的结论（用户反馈）。
   *
   * 现在错误直接顶到状态头：红灯 + 结论（`headline()`）+ 一行小字提示 + 「重试」，
   * 抽屉里不再另起红字。`phase()` 仍然是 `Connected`——会话确实还挂着，设备信息
   * 也还在，只是数据读不出来，主操作因此能让用户在原地重试而不必断开重连。
   */
  private scanFailed(): boolean {
    // 只认 PTP 会话（USB / Wi-Fi）：蓝牙「已配对」没有会话、也不读卡，
    // `lastScanError` 可能是上一轮连接留下的，不能拿它把状态头改成错误态。
    return this.svc.connected && this.phase() === CameraPhase.Connected
      && this.svc.lastScanError !== '';
  }

  /**
   * 错误文案拆成「结论」与「下一步」。
   *
   * 相机错误文案统一写成「结论：下一步」（`camera_status_*`，三种语言都用冒号
   * 分隔）。结论进状态头第一行（要一行放得下），冒号后那句动作说明用更小一号的
   * 字放在第二行。没有冒号的文案（如「相机返回错误 0x2008」）整句当结论，
   * 不显示第二行。
   */
  private scanErrorTitle(): string {
    const msg = this.svc.lastScanError;
    const idx = this.scanErrorColon(msg);
    return idx < 0 ? msg : msg.substring(0, idx);
  }

  private scanErrorHint(): string {
    const msg = this.svc.lastScanError;
    const idx = this.scanErrorColon(msg);
    return idx < 0 ? '' : msg.substring(idx + 1).trim();
  }

  /** 全角冒号（中文 / 繁体）与英文的 `": "` 都认，取最先出现的那个。 */
  private scanErrorColon(msg: string): number {
    const full = msg.indexOf('：');
    const half = msg.indexOf(': ');
    if (full < 0) return half;
    if (half < 0) return full;
    return Math.min(full, half);
  }

  private dotColor(): Resource {
    const phase = this.phase();
    if (this.scanFailed()) return $r('app.color.status_error');
    if (phase === CameraPhase.Connected) return $r('app.color.status_connected');
    if (phase === CameraPhase.Failed) return $r('app.color.status_error');
    if (phase === CameraPhase.Idle) return $r('app.color.text_tertiary');
    return $r('app.color.primary');
  }

  // ------------------------------------------------------------------
  // 主操作
  // ------------------------------------------------------------------

  /** 未连接时是「搜索 / 配对 / 连接」，已连接时是「断开」（读卡失败时是「重试」）。 */
  private primaryActionLabel(): Resource {
    const phase = this.phase();
    if (phase === CameraPhase.Switching) return $r('app.string.camera_action_switching');
    if (phase === CameraPhase.Disconnecting) return $r('app.string.camera_action_disconnecting');
    if (this.scanFailed()) return $r('app.string.camera_action_retry');
    if (phase === CameraPhase.Connected || phase === CameraPhase.Pairing) {
      return $r('app.string.camera_action_disconnect');
    }
    // 进行中的按钮跟着状态头用同一个动词（1.65.2）：状态头写「正在搜索 USB 相机…」
    // 时按钮是「搜索中」，写「正在获取元数据…」时才是「扫描中」。以前 USB 两段都
    // 写「扫描中」，同一件事在一行里有两个叫法。
    if (phase === CameraPhase.Searching) return $r('app.string.camera_action_searching');
    if (phase === CameraPhase.Loading) return $r('app.string.camera_main_scanning');
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
    // 手填 IP 的连接不能取消，也不能在连接中再点一次搜索。
    if (this.svc.wifiConnecting) return true;
    if (this.svc.bleConnecting) return false;
    return !(this.svc.linkMode === CameraLinkMode.BLE && this.svc.bleReconnecting);
  }

  private primaryActionFill(): ResourceColor {
    const phase = this.phase();
    // 读卡失败 = 一次失败后的主操作：「重试」用主色实心，和无线失败那颗一致，
    // 不能用「断开连接」的中性底——它不是「结束」，而是「再试一次」。
    if (this.scanFailed()) return $r('app.color.primary');
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
    if (this.scanFailed()) return $r('app.color.text_on_primary');
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
    if (this.scanFailed()) {
      // 相机还在，只是这一轮读不到卡：沿用同一会话重扫。断开重连要重新握手、
      // 还要重取设备信息，对「插上卡再试一次」没有帮助，反而把这一屏清掉。
      // 这里直接走扫描而不是 `searchByMode()`：无线模式下已连接时后者会
      // 在「已连上」那一行直接 return，点了按钮没有任何反应。
      // 全量扫描 + 跳过节流：重试就该是「重新读一遍」，不能命中上一轮的快照。
      this.svc.scanForCamera(false, true);
      return;
    }
    if (phase === CameraPhase.Connected || phase === CameraPhase.Pairing) {
      this.requestDisconnect();
      return;
    }
    if (phase === CameraPhase.Connecting && this.svc.bleConnecting) {
      // 取消要立刻看得见：服务端先把 `bleConnecting` 放掉（界面马上回到
      // 「已配对 · 未连接」），链路在后台收，这里再补一句确认。
      this.onDisconnectBle();
      this.toast($r('app.string.camera_ble_cancelled'));
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

  /**
   * 蓝牙模式：临时加入相机热点看照片（1.67.0）。
   *
   * 不自动切到画廊：交接的分步进度、失败原因都写在相机页的状态头里，跳走就
   * 看不见了；连上之后状态头会显示「已连上相机热点 + 照片数」，下面还有设备
   * 信息与快速/全量扫描，与 USB / Wi-Fi 连上之后的画面一致。
   */
  private onBrowsePhotos(): void {
    if (this.inProgress()) return;
    Haptics.tap();
    this.svc.browsePhotosOverWifi().catch((err: Error) => {
      this.svc.getLog().add(`浏览照片失败: ${err.message}`);
    });
  }

  /**
   * 已连接时断开。
   *
   * 蓝牙模式有两种会话：待机走 BLE 断开；临时浏览的会话是 Wi-Fi 的，必须走
   * `onDisconnect()` 才会离开相机热点（走 `disconnectBle()` 会把手机留在一个
   * 没有外网的热点上）。
   */
  private requestDisconnect(): void {
    if (this.svc.wireless) {
      this.onDisconnect();
      return;
    }
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
      .onClick(() => {
        this.guideTab = 0;
        this.guideSheetOpen = true;
      })

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
    // 「连接模式」页比步骤页高：说明 + 表头 + 五行功能表 + 一句总结 + 两份清单。
    // 1.66.20 把「部分支持」两条改写成实测结论（各两三行），690 → 740；1.67.0 表下
    // 那句总结又长了一行（蓝牙的按需浏览），740 → 760。1280×2832 上一屏仍看得全；
    // 再长就会被 LARGE 夹住改成滚动——加内容前先量一屏。
    if (this.guideTab === 1) {
      return 760;
    }
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

  /**
   * 「连接模式」表格的一格。
   *
   * 支持就打勾、不支持留空（用户要的就是这张勾选表：「按连接模式把所有功能列成
   * 一张表，该模式支持的打勾，不支持的空着」）。当前模式那一列不下底色——四列
   * 只有 60 多 vp 宽，底色会把表切碎——改成表头那格用主色 + 中等字重。
   */
  @Builder
  GuideCheckCell(mode: number, support: number) {
    Stack() {
      if (support === GUIDE_FULL) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(14)
          .fontColor([this.cellColor(mode)])
      } else if (support === GUIDE_PARTIAL) {
        // 半个圆：能做，但没做全（缺什么写在表下面的「部分支持」里）。
        Text('◐')
          .fontSize(13)
          .fontColor(this.cellColor(mode))
      }
    }
    .layoutWeight(1)
    .height('100%')
  }

  private cellColor(mode: number): ResourceColor {
    return this.svc.linkMode === mode
      ? $r('app.color.primary') : $r('app.color.text_primary');
  }

  /** 表格的一行：左侧功能名，右侧四个模式的支持标记。 */
  @Builder
  GuideFeatureRow(label: ResourceStr, usb: number, ble: number, ap: number,
                  sta: number, last: boolean) {
    Row() {
      Text(label)
        .fontSize(FontSize.Caption)
        .lineHeight(16)
        .fontColor($r('app.color.text_primary'))
        .width(GUIDE_FEATURE_COL)
        .padding({ right: 8 })
      this.GuideCheckCell(0, usb)
      this.GuideCheckCell(1, ble)
      this.GuideCheckCell(2, ap)
      this.GuideCheckCell(3, sta)
    }
    .width('100%')
    .height(GUIDE_ROW_HEIGHT)
    .border({ width: { bottom: last ? 0 : 0.5 }, color: $r('app.color.divider') })
  }

  /** 「官方有、我们没有 / 部分支持」列表的一行：一个小圆点 + 一句说明。 */
  @Builder
  GuideBullet(label: ResourceStr) {
    Row({ space: 8 }) {
      Circle({ width: 3, height: 3 })
        .fill($r('app.color.text_tertiary'))
        .margin({ top: 7 })
      Text(label)
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_tertiary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 6 })
  }

  /** 表头的一格：四种模式名，当前模式那格用主色标出来。 */
  @Builder
  GuideModeHeader(mode: number, label: Resource) {
    Text(label)
      .fontSize(FontSize.Caption)
      .fontWeight(this.svc.linkMode === mode ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.svc.linkMode === mode
        ? $r('app.color.primary') : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .maxLines(1)
  }

  /**
   * 功能 × 连接模式的支持表。
   *
   * 行是功能、列是模式：一眼能看出「哪种连接能做什么」。每一条都对应真实行为：
   * 照片只走 USB / Wi-Fi；GPS 有两个入口（导入时写进照片、蓝牙待机时把位置交给
   * 相机）；对时和后台守着相机只有蓝牙做得到；AP 会让手机加入相机热点、上网中断。
   */
  @Builder
  GuideModesTable() {
    Column() {
      Row() {
        Text($r('app.string.camera_guide_col_feature'))
          .fontSize(FontSize.Caption)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_tertiary'))
          .width(GUIDE_FEATURE_COL)
        this.GuideModeHeader(0, $r('app.string.camera_mode_usb'))
        this.GuideModeHeader(1, $r('app.string.camera_mode_ble'))
        this.GuideModeHeader(2, $r('app.string.camera_mode_ap'))
        this.GuideModeHeader(3, $r('app.string.camera_mode_sta'))
      }
      .width('100%')
      .height(GUIDE_ROW_HEIGHT)
      .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

      // 只有「功能」——能在这种连接下做什么事。以前的表把「相机停在连接页」
      // 「相机在同一网络」这类前置条件也塞成行，和功能混在一起，读下来既不是
      // 功能也不像限制（用户 1.66.12 反馈「一派胡言」）。前置条件归「连接步骤」页。
      // 蓝牙 1.67.0 起也能看图，但要走一次「临时加入相机热点」，所以是 ◐ 而不是勾。
      this.GuideFeatureRow($r('app.string.camera_guide_feature_photos'),
        GUIDE_FULL, GUIDE_PARTIAL, GUIDE_FULL, GUIDE_FULL, false)
      this.GuideFeatureRow($r('app.string.camera_guide_feature_exif'),
        GUIDE_FULL, GUIDE_NONE, GUIDE_FULL, GUIDE_FULL, false)
      // 对时与位置注入 1.66.17 起在蓝牙模式下真机跑通（相机菜单能看到经纬度与
      // UTC），不再是「部分支持」。
      this.GuideFeatureRow($r('app.string.camera_guide_feature_clock'),
        GUIDE_NONE, GUIDE_FULL, GUIDE_NONE, GUIDE_NONE, false)
      this.GuideFeatureRow($r('app.string.camera_guide_feature_standby'),
        GUIDE_NONE, GUIDE_FULL, GUIDE_NONE, GUIDE_NONE, false)
      this.GuideFeatureRow($r('app.string.camera_guide_feature_online'),
        GUIDE_FULL, GUIDE_FULL, GUIDE_NONE, GUIDE_FULL, true)
    }
    .width('100%')
  }

  @Builder
  GuideSheet() {
    Column({ space: 0 }) {
      Text($r('app.string.camera_guide_title'))
        .fontSize(FontSize.Title)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ top: 4, bottom: 2 })

      TabSegmentButtonV2({
        items: GUIDE_TAB_ITEMS,
        selectedIndex: this.guideTab,
        $selectedIndex: (index: number) => {
          if (index !== this.guideTab) this.guideTab = index;
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
        itemMinHeight: LengthMetrics.vp(32),
        itemBorderRadius: LengthMetrics.vp(16),
        buttonMinHeight: LengthMetrics.vp(40),
        buttonPadding: LengthMetrics.vp(4),
        buttonBorderRadius: LengthMetrics.vp(20),
        buttonBackgroundColor: ColorMetrics.resourceColor($r('app.color.control_track')),
        itemSelectedBackgroundColor: ColorMetrics.resourceColor($r('app.color.bg_surface')),
        enableStateAnimation: true
      })
        .width('100%')
        .padding({ top: 10, bottom: 2 })

      if (this.guideTab === 0) {
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
      } else {
        Scroll() {
          Column({ space: 0 }) {
            Text($r('app.string.camera_guide_modes_intro'))
              .fontSize(FontSize.Caption)
              .lineHeight(18)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
            this.GuideModesTable()
            Text($r('app.string.camera_guide_modes_note'))
              .fontSize(FontSize.Caption)
              .lineHeight(18)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding({ top: 10 })

            // 官方 SnapBridge 有、这里还没有的（用户 1.66.13 要求明示）。
            Text($r('app.string.camera_guide_official_title'))
              .fontSize(FontSize.Caption)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 18 })
            this.GuideBullet($r('app.string.camera_guide_official_1'))
            this.GuideBullet($r('app.string.camera_guide_official_2'))
            this.GuideBullet($r('app.string.camera_guide_official_3'))
            this.GuideBullet($r('app.string.camera_guide_official_4'))
            this.GuideBullet($r('app.string.camera_guide_official_5'))
            this.GuideBullet($r('app.string.camera_guide_official_6'))

            Text($r('app.string.camera_guide_partial_title'))
              .fontSize(FontSize.Caption)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 16 })
            this.GuideBullet($r('app.string.camera_guide_partial_1'))
            this.GuideBullet($r('app.string.camera_guide_partial_2'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 12, bottom: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
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
   * 状态头：进度点 + 一句状态 + 一行说明 +（已连接时）照片数 + 主操作胶囊。
   *
   * 主操作永远是「当前这一步」：未连接是「搜索 / 配对 / 连接」，进行中禁用，
   * 已连接变中性底的「断开连接」。它也是页面上**唯一**的断开入口——同一张卡里
   * 出现两个「断开」只会让人犹豫点哪个。
   *
   * **指定 IP 入口并进状态头的第二行**（1.65.0）：它以前是状态头下面另起的一行，
   * 中间还隔着 `Column` 的 12vp 间距，看着像两个互不相干的模块；现在它是状态头
   * 自己的副行，和状态文案在同一条竖线上。为了让两行合起来只占**一颗主操作胶囊**
   * 的高度（卡片不因此变高），有副行、没有阶段详情时标题让位成 `Section` 小字，
   * 标题 → 副行成为 13/12 的两行节奏。
   *
   * **读卡失败也走同一个两行节奏**（1.65.1）：红灯 + 结论（13fp）+「下一步」（10fp）
   * + 主色「重试」，两行合计仍在一颗胶囊的高度里，抽屉里不再另起红字。
   * 标题仍是主文本色——和「配对失败」「没能连上相机」一致，红色只给状态点。
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
      Column({ space: this.scanFailed() ? 2 : 3 }) {
        Text(this.headline())
          .fontSize(this.scanFailed() || this.compactHeadline()
            ? FontSize.Section : FontSize.CardTitle)
          .fontWeight(FontWeight.Medium)
          // 状态头第一行永远是主文本色（红色只留给点）：失败态靠红灯 + 文案本身，
          // 不给标题上红色——同一个页面里「配对失败」黑、「相机拒绝访问存储」红，
          // 会被当成两种不同严重级别（1.65.2 统一）。
          .fontColor(this.compactHeadline()
            ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          .width('100%')
          .maxLines(this.scanFailed() ? 1 : 2)
          // 结论必须一行放得下（13fp 下最长的一条是「相机没有可用存储（请插入存储卡）」），
          // 万一某个语言更长，宁可截断也不要让状态头长高、把两行节奏破掉。
          .textOverflow({ overflow: this.scanFailed() ? TextOverflow.Ellipsis : TextOverflow.Clip })
        if (this.scanFailed() && this.scanErrorHint() !== '') {
          Text(this.scanErrorHint())
            .fontSize(FontSize.Micro)
            .lineHeight(14)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .maxLines(2)
        }
        if (this.detail() !== '') {
          Text(this.detail())
            .fontSize(FontSize.Caption)
            .lineHeight(18)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .maxLines(3)
        }
        if (this.staIpLinkVisible()) {
          this.StaManualIpLink()
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 读卡失败时不显示照片数：那一行是「上次扫描留下的旧数字」，挂在红灯旁边
      // 读起来像「其实连得挺好」；而且它会挤窄文字列，把第二行提示顶成两行。
      if (this.linked() && !this.scanFailed() && this.svc.photoCount > 0) {
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
    .bindSheet($$this.ipSheetOpen, this.IpSheet(), this.ipSheetOptions())
  }

  /**
   * 标题要不要让位成小字：只「副行就是指定 IP 入口、且没有阶段详情」时。
   *
   * 失败状态下详情行（失败原因）还要占一到三行，标题保持 `CardTitle` 才有主次；
   * 空闲/已配对时第二行只有一条次级入口，标题缩一档，两行就合成一颗胶囊的高度。
   */
  private compactHeadline(): boolean {
    return this.staIpLinkVisible() && this.detail() === '';
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

  /**
   * 蓝牙回不来时的说明（只在对它有意义的阶段渲染）。
   *
   * 字号用「说明」档 12fp（1.65.2）：它是一整句诊断（「相机仍停在 Wi-Fi 模式。
   * 可检查相机的「Wi-Fi 待机时间」设定，或关机再开。」），10fp 会排成一条又长
   * 又小的红字；卡内所有说明文字统一 12fp，10fp 只留给状态头里那行紧凑提示。
   */
  @Builder
  BleHintLine() {
    if (this.svc.bleHint !== '') {
      Text(this.svc.bleHint)
        .fontSize(FontSize.Caption)
        .lineHeight(18)
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
   *
   * **提示只讲副作用**（1.65.2）：这一行原来写「相机会切到自己的 Wi-Fi 热点传
   * 照片，配对连接会暂停一次；退出后相机自动回到待机。」，和下面的连接摘要
   * 「点「连接相机」加入相机热点。」说的是同一件事，而且用 10fp 排在 12fp 的
   * 摘要上面，一大一小两条提示互相打架。现在它只说摘要里没有的那半句（蓝牙会断、
   * 退出后回待机），字号也回到「说明」档的 12fp。
   */
  @Builder
  ApControls() {
    if (this.wifiConnected()) {
      this.AddressRow()
    } else {
      if (this.blePaired()) {
        Text($r('app.string.camera_conn_open_wifi_hint'))
          .fontSize(FontSize.Caption)
          .lineHeight(18)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      this.BleCameraList()
      this.BleHintLine()
    }
  }

  /** STA 空闲或失败时，在状态头下方显示「无法连接？试试指定 IP」。 */
  private staIpLinkVisible(): boolean {
    if (this.svc.linkMode !== CameraLinkMode.STA || this.wifiConnected()) return false;
    const phase = this.phase();
    return phase === CameraPhase.Idle || phase === CameraPhase.Failed;
  }

  /** 打开指定 IP 面板；没有输入过时用上次成功的地址预填。 */
  private openIpSheet(): void {
    if (this.wifiInput === '' && this.svc.wifiHost !== '') {
      this.wifiInput = this.svc.wifiHost;
    }
    this.ipSheetOpen = true;
  }

  /** 提交指定 IP：先收起面板与键盘，连接进度与失败都交给状态头。 */
  private submitManualIp(): void {
    const host = this.wifiInput.trim();
    if (host === '' || this.svc.scanning || this.svc.wifiConnecting) return;
    this.getUIContext().getFocusController().clearFocus();
    this.ipSheetOpen = false;
    this.onConnectWifi(host);
  }

  /**
   * 指定 IP 半模态的样式。
   *
   * **标题区交给系统**（1.65.0）：`SheetOptions.title` + `showClose` 会把标题、
   * 副标题与关闭按钮排在半模态自己预留的标题区里，那个区域已经按 24vp 圆角与
   * 拖拽条算好了边距。此前是自己往内容里画标题和「取消」，字就顶在圆角弧里，
   * 和上面的拖拽条挤成一团，怎么调 padding 都像贴着头皮写上去的。
   *
   * **键盘弹起时不能有「输入框下面的东西」**：半模态避让只保证获得焦点的输入框
   * 露在键盘上方（够用就停），所以「输入框 + 下面一整颗提交按钮」的排法在被键盘
   * 顶起来时，按钮一定落在键盘后面（`TRANSLATE_AND_RESIZE` 会把面板裁到输入框
   * 那么高，`TRANSLATE_AND_SCROLL` 只是少抬一点，两种都试过）。因此提交按钮改成
   * 输入框**同一行**的行尾胶囊：整块交互都在输入框这一行里，键盘一起来它跟着上移，
   * 不需要任何额外的避让计算。
   */
  private ipSheetOptions(): SheetOptions {
    const opts: SheetOptions = {
      height: SheetSize.FIT_CONTENT,
      preferType: SheetType.BOTTOM,
      dragBar: true,
      showClose: true,
      title: { title: $r('app.string.camera_ip_sheet_title') },
      keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL
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

  /**
   * 指定相机 IP 的半模态内容。
   *
   * 只剩「一句说明 + 输入框 + 主按钮」三件事：标题、关闭按钮都由系统标题区承担，
   * 内容区不重复。三项之间 12vp，底部 24vp 收口。
   */
  @Builder
  IpSheet() {
    Column({ space: 12 }) {
      Text($r('app.string.camera_ip_sheet_hint'))
        .fontSize(FontSize.Caption)
        .lineHeight(18)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      // 输入框 + 行尾「连接」：同一行是键盘避让的关键，见 ipSheetOptions 的注释。
      Row({ space: 8 }) {
        TextInput({
          placeholder: $r('app.string.camera_wifi_host_placeholder'),
          text: this.wifiInput
        })
          .layoutWeight(1)
          .height(48)
          .fontSize(FontSize.Body)
          .fontColor($r('app.color.text_primary'))
          .placeholderFont({ size: FontSize.Body })
          .placeholderColor($r('app.color.text_tertiary'))
          .caretColor($r('app.color.primary'))
          .maxLength(15)
          .borderRadius(Radius.Chip)
          // 材质上是半透明底 + 细描边；直接用 bg_page 会变成一块实心灰。
          .backgroundColor($r('app.color.filter_chip_bg'))
          .border({ width: 0.5, color: $r('app.color.card_border') })
          .padding({ left: 12, right: 12 })
          .enterKeyType(EnterKeyType.Go)
          .onChange((value: string) => { this.wifiInput = value; })
          .onSubmit(() => { this.submitManualIp(); })

        Button($r('app.string.camera_wifi_connect'))
          .height(48)
          .padding({ left: 18, right: 18 })
          .fontSize(FontSize.Body)
          .fontWeight(FontWeight.Medium)
          .borderRadius(pillRadius(48))
          .backgroundColor(this.wifiInput.trim() !== ''
            ? $r('app.color.primary') : $r('app.color.control_track'))
          .fontColor(this.wifiInput.trim() !== ''
            ? $r('app.color.text_on_primary') : $r('app.color.text_tertiary'))
          .enabled(this.wifiInput.trim() !== '' && !this.svc.scanning && !this.svc.wifiConnecting)
          .onClick(() => { this.submitManualIp(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 20 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 状态头第二行：指定 IP 的次级入口，整行可点。
   *
   * 它是状态头的一部分（1.65.0 起），不再自己带外边距与上下 padding：行高固定
   * 18vp，等于阶段详情行的高度，所以「标题 + 入口」和「标题 + 详情」一样高。
   */
  @Builder
  StaManualIpLink() {
    Row({ space: 4 }) {
      Text($r('app.string.camera_sta_manual_lead'))
        .fontSize(FontSize.Caption)
        .fontColor($r('app.color.text_tertiary'))
      Text($r('app.string.camera_sta_manual_action'))
        .fontSize(FontSize.Caption)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(10)
        .fontColor([$r('app.color.primary')])
    }
    .height(18)
    .padding({ right: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => { this.openIpSheet(); })
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
      // 提醒，避免同一句红字出现两遍。字号和其它说明文字一致用 12fp（1.65.2）：
      // 这些是一整句网络诊断，不是标签，10fp 会排成又长又小的一条红字。
      if (this.svc.wifiHint !== '' && this.phase() !== CameraPhase.Failed) {
        Text(this.svc.wifiHint)
          .fontSize(FontSize.Caption)
          .lineHeight(18)
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
      // 已配对/已连接时列表必须消失：那是「搜索出来的候选」，不是当前相机。
      // （服务端连上之后也会把 `bleCameras` 清空，这里再兜一层。）
      if (!this.blePaired() && !this.bleBrowsing()) this.BleCameraList()
      // 待机连着、或断着但配对过：给一条去照片的入口（1.67.0）。
      // 浏览会话已经在跑时不再显示——那时相机的操作行已经由 `connected` 那段
      // 渲染出来了，同一条入口出现两次会让人猜点哪个。
      // 进行中（搜索 / 连接 / 交接）时也收起：交接的分步进度已经由状态头在说，
      // 同一件事再挂一行置灰的入口会让人以为还要再点一次。
      if (!this.bleBrowsing() && !this.svc.bleRecovering && !this.inProgress()
        && (this.blePaired() || (this.bleKnown() && this.phase() === CameraPhase.Idle))) {
        CameraActionRow({
          label: $r('app.string.camera_ble_browse_photos'),
          subtitle: $r('app.string.camera_ble_browse_photos_desc'),
          last: true,
          onTap: () => { this.onBrowsePhotos(); }
        })
      }
      // 首配被相机拒绝时，这里给一句能直接照做的说明（1.66.1）：
      // 相机端还记着这台手机，得先去相机菜单删掉本机。
      this.BleHintLine()
      // 按需浏览没起来（交接冷却 / 没拿到热点凭据 / 热点连不上）：结论写在这里。
      // 蓝牙模式的状态头不认 `wirelessFailed`，不单独渲染就等于没提示。
      if (this.svc.wirelessFailed !== '' && !this.bleBrowsing()) {
        Text(this.svc.wirelessFailed)
          .fontSize(FontSize.Caption)
          .lineHeight(18)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
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

      // 连接阶段的失败写在状态头的详情行里（唯一一处）；「会话还在、这一轮读卡
      // 失败」也顶到状态头了（1.65.1：红灯 + 结论 +「下一步」+「重试」），
      // 所以这里不再另有红字——同一个结论在一张卡里出现两遍，谁都会以为是两件事。
      Divider().color($r('app.color.divider'))

      // 四选一：不再配一句模式说明，模式差异交给下面的相机操作说明。
      this.ModePicker()

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
        Stack({ alignContent: Alignment.Center }) {
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

          // 没有立牌时舞台上放一块淡圆牌（见 StandeePlaceholder 注释）。
          if (!this.hasStandee()) {
            this.StandeePlaceholder()
          }
        }
        .width('100%')
        .height(STANDEE_HEIGHT)

        // 没有立牌就没有倒影：倒影盒子的渐变是为镜像服务的，在一张空舞台上
        // 它只是一条把下半截压暗的横带——用户看到的「脏」就是它。
        if (this.hasStandee()) {
          this.StandeeReflection()
        }
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

  /** 整张深色卡片的下移量：手指下拉的 `CARD_PULL_RATIO`（1/3，与 1.62.x 起一致）。 */
  private cardPullShift(): number {
    return this.pullDown * CARD_PULL_RATIO;
  }

  /**
   * 抽屉在**卡片内部**再打开多少 = 下拉总量减去卡片自己走过的那段。
   *
   * 刷新时 `pullDown` 归零，它自然也是 0：抽屉收回卡面、倒影收干净。
   */
  private drawerPullShift(): number {
    return this.pullDown * (1 - CARD_PULL_RATIO);
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
   * 舞台上现在有没有「这一台」的立牌。
   *
   * 只看当前 key，不看正在淡出的上一张：从某台相机切到「连接新相机」时
   * `standeePreviousKey` 会一直留着上一台的 key（它只是淡出到 0），
   * 若把它算进来，空舞台就永远切不到占位圆牌，倒影盒子那层渐变还会一直
   * 压在下半截上（看起来就是「脏」）。
   */
  private hasStandee(): boolean {
    return this.standeeCurrentKey !== '';
  }

  /**
   * 没有立牌时的舞台占位。
   *
   * 认不出机型（Z fc / ZR 这类没有商品图，或调试包选了「未知型号」）或者用户把
   * 默认立牌设成「不显示」时，封面原本只剩一块深色板加一圈径向光；卡的上半截
   * 空在那里，看着像图片没加载出来。这里放一块很淡的圆牌：不假装自己是某台
   * 相机，但让这块舞台有个落点，圆心正好压在径向光的中心。
   *
   * 圆牌不参与倒影（见 `CameraCover`）：它是「没有产品」的状态，不是一件立在
   * 台面上的产品。
   */
  @Builder
  StandeePlaceholder() {
    Column() {
      SymbolGlyph($r('sys.symbol.camera'))
        .fontSize(38)
        .fontColor([Color.White])
        .opacity(0.34)
    }
    .width(96)
    .height(96)
    .borderRadius(pillRadius(96))
    .backgroundColor($r('app.color.standee_placeholder_fill'))
    .border({ width: 0.5, color: $r('app.color.standee_placeholder_border') })
    .justifyContent(FlexAlign.Center)
    // 与立牌同一个「断开时变暗」口径；从有立牌切过来时跟着同一个 crossfade 淡入
    .opacity((this.linked() ? 1 : 0.72) * this.standeeCrossfade)
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
      // 模拟相机（调试包）：整条流程与真机一样，光看品牌/型号分不出来，
      // 所以在设备信息里显式写一行来源，测试截图不会把结论当真机结果。
      if (this.svc.mockSession()) {
        CameraInfoRow({
          label: $r('app.string.camera_info_mock'),
          value: $r('app.string.camera_info_mock_value')
        })
      }
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
        // 分页点见 snapPages()：贴在末端的那一页必须让开 2vp，否则整条吸附失效
        snapPagination: this.snapPages(),
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

      // 下拉刷新指示器画在滚动层之上：它只在露出来的那条缝里，不会盖住卡片。
      // 必须在 Stack 的子节点里（属性链之前），否则会被当成 build() 的第二个根节点。
      if (this.refreshIndicatorShown()) {
        this.RefreshIndicator()
      }
      }
    .width('100%').height('100%')
    // 顶边下拉松手判定：手指抬起那一刻就决定要不要进刷新（见 onTopTouch）。
    // 挂在不接收手势的外层 Stack 上，只观察、不拦截。
    .onTouch((e: TouchEvent) => { this.onTopTouch(e.type); })
    .bindSheet($$this.guideSheetOpen, this.GuideSheet(), this.guideSheetOptions())
  }

  /**
   * 手指从顶边下拉后松开（1.65.0）。
   *
   * 判定放在**手指抬起那一刻**（根 `Stack` 的 `onTouch`），不是 `onScrollStop`：
   * 松手后顶边弹簧会先把偏移弹回 0，等 `onScrollStop` 再判就已经晚了——那正是
   * 「先回原地、再被挤下去」两段动画的成因。
   *
   * 只有拉过 `REFRESH_THRESHOLD_VP`（最大下拉的 80%）才进刷新；不够就什么都不做，
   * 交给弹簧回弹（与以前完全一致）。
   */
  private onTopTouch(type: TouchType): void {
    if (type !== TouchType.Up && type !== TouchType.Cancel) return;
    if (this.refreshing) return;
    if (this.pullDown < REFRESH_THRESHOLD_VP) return;
    this.beginRefresh();
  }

  /**
   * 进入刷新：**一条**动画把下拉量收回到 0。
   *
   * 起点就是松手那一帧的 `pullDown`（卡面 1/3、抽屉 2/3 开着），终点是原位——
   * 所以卡面与抽屉是一起完整回弹的（卡面 48vp、抽屉 144vp 的行程），
   * 指示器全程贴在卡面正上方，跟着一起落到「标题栏与卡面之间」那段空白里。
   * 刷新过程中不再跟随滚动偏移（`syncFromScroll` 里跳过），弹簧归零不可见。
   */
  private beginRefresh(): void {
    if (this.refreshing) return;
    this.refreshing = true;
    this.refreshFade = 1;
    Haptics.tap();
    this.onRefresh();
    animateTo({ duration: REFRESH_ANIM_MS, curve: Curve.EaseOut }, () => {
      this.pullDown = 0;
      this.pullProgress = 0;
    });
    setTimeout(() => { this.endRefresh(); }, REFRESH_FAKE_MS);
  }

  /** 刷新动作结束（现在没有实质动作，就是 2s 之后）：指示器淡出，其余已在原位。 */
  private endRefresh(): void {
    animateTo({ duration: REFRESH_ANIM_MS, curve: Curve.EaseInOut }, () => {
      this.refreshFade = 0;
    });
    setTimeout(() => { this.refreshing = false; }, REFRESH_ANIM_MS);
  }

  /** 指示器要不要画：只要它按卡面下移量算出来的透明度大于 0 就挂载。 */
  private refreshIndicatorShown(): boolean {
    return this.refreshIndicatorOpacity() > 0.01;
  }

  /** 指示器横向居中：这里是全屏坐标（不是标题栏 builder 的坐标系）。 */
  private refreshIndicatorX(): number {
    const w = WindowUtils.windowWidthPx > 0
      ? this.getUIContext().px2vp(WindowUtils.windowWidthPx) : 360;
    return (w - REFRESH_ICON) / 2;
  }

  /**
   * 指示器纵向位置：**贴在卡面上沿正上方**（固定间距）。
   *
   * 不能用「标题栏与卡面的中点」：卡面每上移 1vp，中点只上移 0.5vp，
   * 收行时卡面会追上图标并压过去（1.65.0 第二轮实测的「撞上」）。
   * 锚在卡面上沿之后，图标与卡面同速移动，永远不会被撞到；
   * 显隐由 `refreshIndicatorOpacity()` 按卡面下移量淡出。
   */
  private refreshIndicatorY(): number {
    const cardTop = titleBarTotalVp() + 8 + this.cardPullShift();
    return cardTop - REFRESH_ICON_GAP - REFRESH_ICON;
  }

  /**
   * 指示器透明度：随「卡面下移量」淡入淡出。
   *
   * 卡面下移到 20vp 时完全显现，收行回到 8vp 时完全消失——
   * 所以刷新结束、卡面回到原位的过程中图标是**边淡出边被卡面追上**的，
   * 不会出现「卡面撞在还在转的图标上」。
   */
  private refreshIndicatorOpacity(): number {
    // 刷新中卡面已经回到原位（卡面位移为 0），显隐必须由 `refreshing` 接管，
    // 否则指示器会在松手回弹的同一帧淡没
    if (this.refreshing) return this.refreshFade;
    const shift = this.cardPullShift();
    return Math.max(0, Math.min(1, (shift - 8) / 12));
  }

  /**
   * 下拉刷新指示器：**官方** `SwipeRefresherV2`（系统加载动效）。
   *
   * 只用它的「加载中」形态（`isLoading`），位置、显隐由我们自己按下拉量算：
   * 官方的 `Refresh` 容器会把整页下移，那会改掉本页既有的下拉编排（卡面 1/3、
   * 卡内抽屉 2/3、倒影拉长），所以容器不用、只用它的指示器组件。
   * 组件本身不要挂通用属性（官方说明：会挂到自动生成的 __Common__ 节点上），
   * 尺寸、透明度、位置都加在外层容器上。
   */
  @Builder
  RefreshIndicator() {
    Column() {
      LoadingProgress()
        .width(REFRESH_ICON)
        .height(REFRESH_ICON)
        .color($r('app.color.text_secondary'))
    }
    .width(REFRESH_ICON)
    .height(REFRESH_ICON)
    .justifyContent(FlexAlign.Center)
    .position({ x: this.refreshIndicatorX(), y: this.refreshIndicatorY() })
    .opacity(this.refreshIndicatorOpacity())
    .hitTestBehavior(HitTestMode.None)
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

    // 顶边下拉：倒影长度 + 抽屉下移量，都取这一份（上限 TOP_PULL_MAX）。
    // 刷新中（以及收行动画中）**不跟随偏移**：那段位移由 beginRefresh/endRefresh
    // 的同一条动画接管，弹簧归零不可见。
    if (!this.refreshing) {
      const pull = y < 0 ? Math.min(TOP_PULL_MAX, -y) : 0;
      if (Math.abs(pull - this.pullDown) > 0.2) {
        this.pullDown = pull;
      }
      const progress = Math.min(1, pull / TOP_PULL_MAX);
      if (Math.abs(progress - this.pullProgress) > 0.01) {
        this.pullProgress = progress;
      }
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
