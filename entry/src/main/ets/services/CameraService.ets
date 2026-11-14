import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { abilityAccessCtrl } from '@kit.AbilityKit';
import { wantAgent, type WantAgent } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import usbManager from '@ohos.usbManager';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { decodeThumbnailTask, decodeFullPhotoTask } from '../workers/ImageDecoder';
import { PtpSession, PtpPriority, PtpEndpointKind, setPtpLog, setPtpQuietOps, PtpError,
  PTP_ERR_USB, PTP_ERR_NOT_OPEN, type DeviceInfo, type ObjectInfo, type PtpEndpoint,
  type PtpTransport } from '../pages/PtpHost';
import { PtpScheduler } from './PtpScheduler';
import { WifiPtpSession } from './WifiPtpSession';
import { NsdScanner, type WifiCameraInfo } from './NsdScanner';
import { SubnetScanner } from './SubnetScanner';
import { BleScanner, BleCameraLink, type BleCameraDevice } from './BleScanner';
import { BleTimePayload, type BleGeoFix } from './BlePayloads';
import { BleIdentityStore } from './BleIdentityStore';
import { SavedCameraStore, type SavedCamera } from './SavedCameraStore';
import { WifiLinkStore } from './WifiLinkStore';
import { WifiApJoiner, type ApJoinOutcome } from './WifiApJoiner';
import { CameraLinkMode, DEFAULT_LINK_MODE, isWifiMode } from '../model/CameraLinkMode';
import { CameraLinkModeStore } from '../model/CameraLinkModeStore';
import { CameraModelStore } from '../model/CameraModelStore';
import { cameraSerialFromBleName, cameraStandeeKey } from '../utils/CameraStandee';
import { collectLocalNetworks, networkHint } from './LocalNetworks';
import { AtomicFile } from '../utils/AtomicFile';
import { AppLog } from './AppLog';
import { GpsRecorder } from './GpsRecorder';
import { BleGeoFeed } from './BleGeoFeed';
import { BleInjectStore } from '../model/BleInjectStore';
import { ExifGeotagger } from './ExifGeotagger';
import { TransferNotice } from './TransferNotice';
import { CameraCachePrefs } from './CameraCachePrefs';
import { ThumbnailCache, type CacheEntry } from './ThumbnailCache';
import { L10n } from '../utils/L10n';
import { MockPtpDevice } from '../debug/MockPtpDevice';
import { MockPtpSession } from '../debug/MockPtpSession';
import type { PhotoEntry, DownloadRecord, DownloadProgress, DownloadResult } from '../model/PhotoEntry';

const DOMAIN = 0x0000;
const TAG = 'CameraService';

/**
 * 全尺寸解码的最长边上限（px）。
 *
 * 预览器最大 5x 捏合，而手机屏幕长边约 2700px：3072px 的源图已经够用。
 * 不限制时 24MP 原图是 96MB/张，预览器「当前 + 前后各 3 张」同时驻留会把
 * 内存和纹理带宽打满，捏合、翻页都会发涩。
 */
const FULL_DECODE_MAX_EDGE = 3072;
/** 全图预览解码的最长边：先快速出图，再后台解 3072 全尺寸。 */
const PREVIEW_DECODE_MAX_EDGE = 2048;

/** 两次扫描的最小间隔，避免失败后连点把一次点击放大成多次 USB 会话（ISSUE-004）。 */
const SCAN_MIN_INTERVAL_MS = 800;
/**
 * 快速扫描复用元数据的有效期。
 *
 * 复用依据是「handle 仍在同一台相机的列表里」，PTP 不提供低成本的“对象是否变化”
 * 信号。超过这个时间就强制重读一遍，弥补相机侧改动/格式化等边界情况；用户随时
 * 可以用「全量扫描」强制刷新。
 */
const METADATA_REUSE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
/**
 * 断点续扫的有效期。
 *
 * 只有「上一轮扫描没跑完」（`metadata_cache.json` 里 `complete=false`）才会进入续扫。
 * 超过这个时间就当缓存不可信，宁可全量重读。
 */
const RESUME_MAX_AGE_MS = 24 * 60 * 60 * 1000;
/** 交织扫描时每隔多少张把元数据落一次盘（断点续扫用）。 */
const SCAN_PERSIST_EVERY = 256;
/**
 * 交织扫描的批大小：每读 64 张的元数据就先把这一批的缩略图取回来。
 * 太小会让「发布相册列表」过频，太大又会让首屏多等。
 */
const SCAN_CHUNK = 64;
/** 复用元数据前的抽样校验条数（防止卡被格式化后 handle 被重用导致张冠李戴）。 */
const METADATA_REUSE_PROBE = 8;
/**
 * 缩略图流水线的并发任务数。
 *
 * PTP 管道本身是串行的，这里并发的是「取图 + 解码」：一个任务在等 USB 时，
 * 另一个任务可以在 TaskPool 里解码。8 足够把管道喂饱，又不会一次占太多内存。
 */
const THUMB_PIPELINE = 8;
/** 等用户回答「是否启用缓存」的上限；超时按启用处理，避免扫描被对话框卡死。 */
const CACHING_PROMPT_TIMEOUT_MS = 90 * 1000;
/**
 * 无线心跳周期（1.66.0）：前台且已连上无线时，每隔这么久发一条 `GetDeviceInfo`。
 *
 * 为什么需要它：PTP/IP 跑在 TCP 上。相机突然断电、手机切换网络时，对端不会发
 * FIN，socket 也不会报错——那是一条**半开**连接，App 会一直停在「已连接」，
 * 点什么都失败（用户反馈「相机断了页面没反应」）。TCP 自带的 keepalive 默认要
 * 几小时才探一次，`socket` 的 `TCPExtraOptions` 也只给 `keepAlive: boolean`、
 * 不能配 keepidle，所以只能自己在应用层拍。15 秒是「用户能察觉」与「少打扰
 * 相机」之间的折中；应用进后台就整条停掉。
 */
const WIRELESS_HEARTBEAT_MS = 15000;
/**
 * 心跳多久没响应就判定链路已断。
 *
 * PTP/IP 单笔事务自带 30 秒超时，对「看一眼还在不在」太慢了；心跳只用这条
 * 兜底，真正的超时要短。
 */
const WIRELESS_HEARTBEAT_TIMEOUT_MS = 6000;
/**
 * 退到后台多久之后，无线会话必须按「已被系统释放」处理（1.66.17）。
 *
 * 官方《应用网络重连》：应用切到后台 2 秒后网络资源被冻结，**12 秒后释放**。
 * 所以 Wi-Fi 会话没有合法的长时任务可挂（系统类型里没有 Wi-Fi 连接），回来后
 * 直接重建比等 15 秒心跳超时快得多。
 */
const WIRELESS_BG_GRACE_MS = 12000;
/**
 * BLE 保活/注入的间隔。相机 2 分钟没有 BLE 流量会断链，45 秒留足余量；
 * 位置注入跟着这一拍走（官方 SnapBridge 同类实现 15~30 秒，45 秒够用）。
 */
const BLE_KEEPALIVE_MS = 45000;

// ---- EXIF orientation types (classes required for ArkTS object literal compliance) ----

class OrientationTransform {
  rotate: number = 0;
  flipH: boolean = false;
  flipV: boolean = false;
  constructor(rotate: number = 0, flipH: boolean = false, flipV: boolean = false) {
    this.rotate = rotate;
    this.flipH = flipH;
    this.flipV = flipV;
  }
}

class OrientedSize {
  w: number = 0;
  h: number = 0;
  constructor(w: number = 0, h: number = 0) {
    this.w = w;
    this.h = h;
  }
}

class DecodedPhotoResult {
  pixelMap: image.PixelMap;
  displayW: number;
  displayH: number;
  constructor(pixelMap: image.PixelMap, displayW: number, displayH: number) {
    this.pixelMap = pixelMap;
    this.displayW = displayW;
    this.displayH = displayH;
  }
}

/** 下载注册表快照的 schema 信封。 */
interface DownloadRegistryFile {
  version: number;
  records: Record<string, DownloadRecord>;
}

/** 注册表最多保留多少条，避免多年使用后无限增长。 */
const MAX_DOWNLOAD_RECORDS = 50000;
/** 图库“最近删除”保留 30 天；超过这个时间的失效记录可以安全丢掉。 */
const MISSING_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

/** 每成功保存一张照片就追加一行，崩溃后可从 journal 恢复。 */
interface DownloadJournalEntry {
  key: string;
  record: DownloadRecord;
}

@ObservedV2
export class CameraService {
  private static instance: CameraService;
  private session: PtpTransport = new PtpScheduler(new PtpSession());
  /** 当前 session 是不是调试用的假相机，用来判断是否需要换回真实 USB。 */
  private sessionIsMock: boolean = false;
  /** 上一次写进「已配对相机」的模拟相机签名：同一条记录只记一次日志。 */
  private mockLogged: string = '';
  private log: AppLog = new AppLog();

  // State
  @Trace statusText: string = L10n.isReady() ? L10n.tr('camera_status_ready') : '';
  /**
   * 轻量提示：只弹一次 toast，**不改变页面状态**（1.66.0）。
   *
   * 与 `scanErrorVersion` 分开：那个会把原因写进 `lastScanError`，页面随之变成
   * 失败态。而「USB 相机被拔掉」「无线断了」这类事件要的是「页面回到未连接 +
   * 一句提示」，不是让用户去修一个已经不存在的连接。
   */
  @Trace noticeVersion: number = 0;
  @Trace noticeText: string = '';
  @Trace cameraName: string = '';
  @Trace photoCount: number = 0;
  @Trace photos: PhotoEntry[] = [];
  @Trace scanning: boolean = false;
  /**
   * USB/PTP 会话是否建立。注意它**不等于**“相机可用”：会话建好但存储读不到时
   * 仍然是 `connected === true`，界面要看 `usable` 才能给出正确结论（ISSUE-003）。
   */
  @Trace connected: boolean = false;
  /**
   * 当前会话是否走 Wi-Fi（PTP/IP）。USB 为 false。
   *
   * 无线模式下 `scanForCamera()` 不再枚举 USB 设备，直接复用已建立的
   * PTP/IP 会话；`syncSessionMode()` 也不会把 session 换回 USB。
   */
  @Trace wireless: boolean = false;
  /** 最近一次无线连接使用的主机（展示与重连用）。 */
  @Trace wifiHost: string = '';
  /** 最近一次无线连接使用的端口。 */
  @Trace wifiPort: number = 15740;
  /** 相机要求的配对验证码（0x952B）；空串表示相机不要求配对。 */
  @Trace pairingCode: string = '';
  /** 相机正在等待主机注册，UI 应显示配对核对入口而不是扫描结果。 */
  @Trace pairingRequired: boolean = false;
  /** 当前无线会话实例，配对命令要直接落在它上面（PtpScheduler 不转发）。 */
  private wifiSession: WifiPtpSession | null = null;
  /** mDNS 发现的局域网相机。 */
  @Trace wifiCameras: WifiCameraInfo[] = [];
  /** mDNS 浏览是否进行中。 */
  @Trace wifiScanning: boolean = false;
  /**
   * 蓝牙配对落定后正在自动找/连无线。
   *
   * 与 `wifiScanning`（用户手点的 mDNS 浏览）分开：这条是链路自己推进的，
   * UI 要能把「蓝牙好了，正在接无线」讲出来，而不是显示成两张互不相干的卡。
   */
  @Trace wifiAutoConnecting: boolean = false;
  /**
   * 正在建立一次 Wi-Fi 会话（手动 IP 直连或自动链路里的 `connectWifi()`）。
   *
   * `wifiAutoConnecting` 只覆盖自动链路；手填 IP 走的是 `MainScreen.onConnectWifi`
   * → `connectWifi()`，没有这个标记页面会一直停在「未连接」，用户按了键盘
   * 「前往」也看不到任何反应（1.64.1）。
   */
  @Trace wifiConnecting: boolean = false;
  /** 第几次 Wi-Fi 连接尝试：重叠请求的 finally 不能互相清掉「连接中」。 */
  private wifiConnectSeq: number = 0;
  /** 无线会话掉线后正在自动重连。 */
  @Trace wifiReconnecting: boolean = false;
  /** 带着无线会话退到后台的时刻（0 表示没有待恢复的会话）。 */
  private backgroundedAt: number = 0;
  /** 退到后台时无线会话还活着：回前台可能要先重建。 */
  private wirelessSessionMayBeStale: boolean = false;
  /** 0x2007 回读只做一次（每轮连接），避免持续打扰相机。 */
  private geoReadbackDone: boolean = false;
  /** 扫不到相机时的原因（空串 = 网络没问题，是相机那边的事）。 */
  @Trace wifiHint: string = '';
  /**
   * 蓝牙回不来时的提示。
   *
   * 相机 BLE 与 Wi-Fi 互斥，而且**没有**从 Wi-Fi 侧关掉无线再回蓝牙的命令
   * （`0x2005=0x80` 只能走 BLE，那时 BLE 已经没了）。正常情况下相机会按自己
   * 的 Wi-Fi 空闲超时回落，App 只是等；等不到就把结论摆出来，别让用户对着
   * 一个永远转圈的「重连中」猜。
   */
  @Trace bleHint: string = '';
  private nsdScanner: NsdScanner | null = null;
  private subnetScanner: SubnetScanner | null = null;
  private wifiScanTimer: number = -1;
  /**
   * 当前 mDNS 浏览属于哪个链路代次；-1 表示没有浏览。
   *
   * `NsdScanner` 的回调只创建一次、跨多次扫描复用，不能把某一轮的 epoch
   * 捕获进闭包；用字段对 `linkEpoch`，切模式后迟到的回调直接丢掉。
   */
  private wifiScanEpoch: number = -1;
  /** 第几轮 mDNS 浏览：切模式后旧一轮的收尾不能把新一轮的标记清掉。 */
  private wifiScanGen: number = 0;
  /**
   * mDNS 浏览窗口的结束回调。
   *
   * `scanWifiCameras()` 等的是「窗口到点」这个 promise；`stopWifiScan()` 提前
   * 清掉计时器时必须把这个 promise 也 resolve 掉，否则它永远不 settle，
   * `await scanWifiCameras()` 会把调用方（自动接续 / 重连）一起挂死。
   */
  private wifiScanResolve: (() => void) | null = null;
  private wifiReconnectTimer: number = -1;
  private wifiReconnectIndex: number = 0;
  /** 无线自动重连退避（与 BLE 同款节奏）。 */
  private readonly wifiBackoffMs: number[] = [2000, 3000, 5000, 8000, 12000, 20000, 30000];
  /** 用户显式断开时置位，避免自动重连把刚断开的相机又接回来。 */
  private wifiAutoReconnectArmed: boolean = false;
  /** 前台标记：无线心跳只在应用前台跑，后台不做无谓的 Wi-Fi 流量。 */
  private appForeground: boolean = true;
  /** 无线心跳定时器；-1 表示没起来。 */
  private watchdogTimer: number = -1;
  /** 上一拍心跳还没落地：不要叠着发。 */
  private watchdogBusy: boolean = false;
  /**
   * 最近一次「把相机从 BLE 模式推到 Wi-Fi 模式」的时间。
   *
   * Z50II 实测：BLE 与 Wi-Fi **互斥**，写 `0x2005=0x01` 之后相机把 BLE 关掉，
   * Wi-Fi 空闲约 40 秒才回到 BLE。以前 resume 路径每连一次都补写这一笔，
   * 于是「连上 → 推进 Wi-Fi → 相机回 BLE → 再连上 → 再推进」无限乒乓，
   * 相机永远在两个模式之间被踢。所以交接必须节流、且只在真要传照片时做。
   */
  private lastHandoverAt: number = 0;
  /**
   * 交接冷却：这段时间内再连 BLE 只做待机，不推相机进 Wi-Fi。
   *
   * 取 **3 分钟**，口径来自 SnapBridge 官方帮助（Wi-Fi STA 模式页）：
   * 「完成或中断从照相机下载照片的进程后，无法立即切换至 Wi-Fi STA 模式。
   * 在下载照片或中断传送后，请等待至少 3 分钟后再进行切换。」
   * 说明相机侧在退出 Wi-Fi 之后有一段状态机在走，推早了会被拒绝、或者
   * 直接引发 BLE/Wi-Fi 乒乓。90 秒是拍脑袋的，按官方口径改掉。
   */
  private readonly handoverCooldownMs: number = 180000;
  /** Wi-Fi 会话期间「相机是否还在 BLE 广播」的探针计时器。 */
  private bleProbeTimer: number = -1;
  private bleProbeIndex: number = 0;
  private readonly bleProbeDelays: number[] = [5000, 20000, 30000];
  /** 退出无线后密集重扫 BLE 的计时器。 */
  private bleRecoveryTimer: number = -1;
  /**
   * 当前链路模式（相机页四选一，落盘，默认蓝牙）。
   *
   * 1.43.0 起 App 不再自己猜「该走哪条无线链路」：模式由用户明确选择，
   * 每种模式有自己的入口、引导与状态，所见即所得。
   */
  @Trace linkMode: number = DEFAULT_LINK_MODE;
  /**
   * 链路选择的代次（1.64.1）。
   *
   * 切模式是一次**显式取消**：正在跑的 BLE 搜索、mDNS / 网段扫描、自动无线
   * 连接都必须立刻收手。它们的 `await` 链没法从外面真正打断，所以入口记下
   * 代次、在每个 `await` 之后对一次——代次变了就静默返回，不写状态、不报错、
   * 不把旧模式的结果带进新模式。
   *
   * 只有 `setLinkMode()` 会递增。切相机（标题栏下拉）不换链路，搜索照常完成。
   */
  private linkEpoch: number = 0;

  /** 本次异步流程是否还属于当前链路选择。 */
  private epochCurrent(epoch: number): boolean {
    return epoch === this.linkEpoch;
  }
  /**
   * 相机页顶部立牌用哪个型号（见 `utils/CameraStandee.ets`）。
   *
   * `''` 表示还没认出过机型——此时整个立牌区块不渲染。连接后又断开时保留上一次
   * 的值，页面形状不跳（用户主动断开也一样，立牌只是变暗）。
   */
  @Trace cameraModel: string = '';
  /** Wi-Fi AP 模式下「加入相机热点」的执行者。 */
  private apJoiner: WifiApJoiner | null = null;
  /** 正在把相机切到 Wi-Fi AP 并连上（UI 用它显示分步进度）。 */
  @Trace apJoining: boolean = false;
  /** 分步进度文案（空串 = 不在进行中）。 */
  @Trace wirelessStage: string = '';
  /**
   * 无线链路的失败结论。
   *
   * `wirelessStage` 是**进行到哪一步**，成功/放弃后就该清掉；失败原因必须留到
   * 用户重试或切模式，否则「正在连接相机热点 → 未连接」中间会丢掉唯一的线索。
   */
  @Trace wirelessFailed: string = '';
  /**
   * 正在执行「断开连接」。
   *
   * 无线断开要退出相机热点、等相机回落，可能要几秒；这期间按钮不能装死，
   * 状态头要明确写「正在断开」，并把模式选择器继续锁住。
   */
  @Trace disconnecting: boolean = false;
  /** 正在切换链路模式（= 目标下标，-1 表示没有在切换）。 */
  @Trace switchingTo: number = -1;
  /** BLE 扫描到的相机（实验功能）。 */
  @Trace bleCameras: BleCameraDevice[] = [];
  /**
   * 蓝牙断链后连扫描都找不到相机（1.66.3）。
   *
   * 相机进了待机就把 BLE 广播也一起收掉，这时自动重连会一直失败——
   * 页面不能一直写「正在重新连接相机…」，要告诉用户「唤醒相机就好」。
   */
  @Trace bleAsleep: boolean = false;
  @Trace bleScanning: boolean = false;
  /** BLE 连接进行中（bond + GATT 最长几十秒，UI 必须给反馈）。 */
  @Trace bleConnecting: boolean = false;
  /**
   * BLE 连接轮次。
   *
   * 连接/首配是几段 await 串起来的：中途点「取消」、紧接着又点一次「连接」时，
   * 旧流程从 await 里醒过来不能接着往下写状态（会把新一轮的 `bleConnecting`
   * 抹掉、还会报一条假的「连接失败」）。每轮开始时自增，流程里对不上就安静退出。
   */
  private bleConnectSeq: number = 0;
  /** BLE 已连接。 */
  @Trace bleConnected: boolean = false;
  /** 已连接相机的 GATT 服务列表（调试用）。 */
  @Trace bleServices: string[] = [];
  /** 配对成功后相机回报的序列号；空串表示未配对。 */
  @Trace bleSerial: string = '';
  /** 已配对相机的广播名（UI 展示用，比序列号好认）。 */
  @Trace bleCameraName: string = '';
  /** 断链后正在自动重连（相机会休眠，链路断了自己爬起来）。 */
  @Trace bleReconnecting: boolean = false;
  /**
   * 刚结束一次 Wi-Fi 浏览，正在等相机回落蓝牙（1.67.0）。
   *
   * 蓝牙模式按需浏览结束后，相机要几十秒才退出 Wi-Fi（实测约 40 秒）。这段
   * 时间页面已经是「已配对 · 未连接」，不说一声的话用户会以为断开失败了。
   */
  @Trace bleRecovering: boolean = false;
  private bleScanner: BleScanner | null = null;
  private bleLink: BleCameraLink | null = null;
  private bleScanTimer: number = -1;
  /**
   * 当前这轮 BLE 扫描属于哪个链路代次；-1 表示没有扫描。
   *
   * 回调只会在构造 `BleScanner` 时创建一次，不能把某一轮的 epoch 捕获进去，
   * 所以用字段对 `linkEpoch`。切模式时 `stopBleScan()` 会把它置 -1。
   */
  private bleScanEpoch: number = -1;
  /** 存储是否可读（GetStorageIDs 成功）。 */
  @Trace usable: boolean = false;
  /** 最近一次扫描失败的原因，供 toast 与状态卡显示。 */
  @Trace lastScanError: string = '';
  /** 每次扫描失败递增；界面据此弹一次 toast，避免重复提示。 */
  @Trace scanErrorVersion: number = 0;

  // Thumbnail cache
  thumbnailPixelMapMap: Map<number, image.PixelMap> = new Map();
  thumbnailLoadedSet: Set<number> = new Set();
  @Trace thumbnailVersion: number = 0;

  /**
   * 取缩略图供界面渲染。
   * 方法内先读一次 thumbnailVersion，建立 V2 依赖：调用方组件在缩略图更新时会重建。
   * Map 本身不参与状态跟踪，不读版本号的话单元格会永远停在占位图。
   */
  thumbForRender(handle: number): image.PixelMap | undefined {
    if (this.thumbnailVersion < 0) return undefined;
    return this.thumbnailPixelMapMap.get(handle);
  }

  // Orientation-corrected display dimensions (populated during thumbnail/full decode)
  orientedDisplaySizes: Map<number, OrientedSize> = new Map();

  // Full-resolution compressed cache for preloading
  private compressedCache: Map<number, Uint8Array> = new Map();
  private preloadingSet: Set<number> = new Set();
  /** 等待某张原图预加载完成的调用方；用完成通知替代 200ms 轮询。 */
  private preloadWaiters: Map<number, Array<(ok: boolean) => void>> = new Map();
  private cacheTotalBytes: number = 0;
  private cacheMaxBytes: number = 200 * 1048576;
  private detailIndex: number = -1;
  private prevDetailIndex: number = -1;
  /**
   * 邻近照片预加载半径。
   *
   * 以前是 5（前后各 5 张），每翻一张照片就排队下载最多 10 张原图。真机上
   * USB 是串行管道，这些下载会和「用户正在等的那一张」抢带宽；预览器自己也
   * 有一套 ±3 的加载队列，所以 5 纯属重复劳动。收到 2 之后，预览器打开期间
   * 还会整体挂起（`suspendNeighborPreload`），把管道让给当前照片。
   */
  private preloadRadius: number = 2;
  private preloading: boolean = false;
  /** 预览器打开时挂起邻近预加载，避免与预览器自己的加载队列抢 USB。 */
  private neighborPreloadSuspended: boolean = false;

  // Scan progress
  @Trace scanProgress: number = 0;
  @Trace scanTotal: number = 0;
  @Trace scanStatsText: string = '';
  /** Quick-scan phase description ("获取元数据" / "加载缩略图") */
  @Trace scanPhaseText: string = '';
  /** Last decoded thumbnail handle — consumed by PhotoViewer for on-screen refresh */
  @Trace lastDecodedHandle: number = -1;

  // Format filter support detection (cached across directory levels)
  private formatFilterWorks: boolean | null = null;

  /** 上一次扫描开始时间（节流用）。 */
  private lastScanStartMs: number = 0;
  /** 本轮扫描成功解码的缩略图数（只用于扫描结束时的摘要日志）。 */
  private thumbDecoded: number = 0;
  /** 磁盘元数据缓存：handle → PhotoEntry，快速扫描时复用。 */
  private metadataCacheByHandle: Map<number, PhotoEntry> = new Map();
  /** metadata_cache.json 的写入时间，用于判断是否还能复用。 */
  private metadataCacheSavedAt: number = 0;
  /** metadata_cache.json 是否来自一轮**跑完**的扫描；false 表示可用于断点续扫。 */
  private metadataCacheComplete: boolean = true;

  // Orientation cache (EXIF Orientation → rotate/flipH/flipV)
  private orientationMap: Map<number, OrientationTransform> = new Map();

  // Orientations pre-loaded via GetPartialObject during scan, used to
  // apply correct rotate/flip at first thumbnail decode (no re-decode needed).
  private preloadedOrientations: Map<number, OrientationTransform> = new Map();

  // Original photo dimensions read from EXIF during scan (via GetPartialObject).
  // Used to compute precise thumbnail content area for black-bar-free cropping.
  private exifOrigDims: Map<number, OrientedSize> = new Map();

  // ---- 扫描阶段性能测量与自适应（每轮扫描重置） ----
  /** 遍历目录耗时。 */
  private statWalkMs: number = 0;
  /** 逐张 GetObjectInfo 的总耗时与次数。 */
  private statInfoMs: number = 0;
  private statInfoCount: number = 0;
  /** GetThumb 的总耗时与次数。 */
  private statThumbMs: number = 0;
  private statThumbCount: number = 0;
  /** GetPartialObject（读原图 EXIF 头）的总耗时与次数。 */
  private statExifMs: number = 0;
  private statExifCount: number = 0;
  /** 缩略图阶段累计：磁盘命中 / USB 读取（交织时按批累加）。 */
  private thumbCacheHits: number = 0;
  private thumbUsbLoads: number = 0;
  /** 命中 manifest 但文件已失效、被迫回退 USB 的张数。 */
  private thumbCacheFallback: number = 0;
  /** 缩略图写缓存盘的总耗时。 */
  private statSaveMs: number = 0;
  /** 缩略图 TaskPool 解码的总耗时。 */
  private statDecodeMs: number = 0;
  /** GetObjectPropList 探测是否已做过（每个会话只试一次）。 */
  private propListProbed: boolean = false;
  /** 相机自报支持的操作码，用来判断 GetObjectPropList(0x9805) 值不值得试。 */
  private deviceOps: number[] = [];
  /**
   * 缩略图 JPEG 自带的 EXIF 方向是否可信：
   * `null` = 还在验证，`0` = 不可信（继续读原图），`1` = 可信（省掉 GetPartialObject）。
   * 只靠“缩略图有 EXIF”就相信它是危险的：相机可能给缩略图写的是“不旋转”。
   * 因此先用一小批照片与原图比对，全部一致、且样本里包含竖拍，才切换到可信模式。
   */
  private thumbExifTrust: number | null = null;
  private thumbExifSamples: number = 0;
  private thumbExifPortrait: number = 0;
  private thumbExifMismatch: number = 0;
  private thumbExifMissing: number = 0;

  // ---- Camera identity & thumbnail caching ----

  /** Unique camera identity (serial/model/manufacturer based). */
  @Trace cameraIdentity: string = '';
  /** Whether thumbnail disk caching is enabled for the current camera. */
  @Trace cachingEnabled: boolean = false;
  /** True when the UI should show a caching opt-in dialog. */
  @Trace cachingDialogRequired: boolean = false;
  /** Camera ID for the pending dialog. */
  pendingCamIdForDialog: string = '';
  /** Camera name for the pending dialog. */
  pendingCamNameForDialog: string = '';
  // ---- Debug identity info (displayed on CameraPage) ----
  @Trace deviceManufacturer: string = '';
  @Trace deviceSerialNumber: string = '';
  @Trace deviceVersion: string = '';
  @Trace usbVidPid: string = '';
  @Trace usbSerialNumber: string = '';
  /** Thumbnail disk cache manager. */
  private thumbCache: ThumbnailCache = new ThumbnailCache();
  /** Camera cache preferences (cross-camera). */
  private cachePrefs: CameraCachePrefs = CameraCachePrefs.getInstance();
  /** Application files dir (for cache dir construction). */
  private filesDir: string = '';

  /**
   * Map EXIF Orientation value (1–8) to DecodingOptions rotation + pixelMap flip.
   * Reference: https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/image-rotate-faq
   *
   * HarmonyOS getImageProperty(PropertyKey.ORIENTATION) returns the string name
   * (e.g. "Top-left"), not the numeric string. Both formats are handled here for safety.
   */
  private static mapExifOrientation(orientation: string): OrientationTransform {
    switch (orientation) {
      // String names (HarmonyOS getImageProperty return value)
      case 'Top-left':     return new OrientationTransform(0, false, false);
      case 'Top-right':    return new OrientationTransform(0, true, false);
      case 'Bottom-right': return new OrientationTransform(180, false, false);
      case 'Bottom-left':  return new OrientationTransform(0, false, true);
      case 'Left-top':     return new OrientationTransform(90, true, false);
      case 'Right-top':    return new OrientationTransform(90, false, false);
      case 'Right-bottom': return new OrientationTransform(270, true, false);
      case 'Left-bottom':  return new OrientationTransform(270, false, false);
      // Numeric strings (fallback for other implementations)
      case '1': return new OrientationTransform(0, false, false);
      case '2': return new OrientationTransform(0, true, false);
      case '3': return new OrientationTransform(180, false, false);
      case '4': return new OrientationTransform(0, false, true);
      case '5': return new OrientationTransform(90, true, false);
      case '6': return new OrientationTransform(90, false, false);
      case '7': return new OrientationTransform(270, true, false);
      case '8': return new OrientationTransform(270, false, false);
      // Unknown / unsupported → no transform
      default:
        return new OrientationTransform(0, false, false);
    }
  }

  /**
   * Manually parse EXIF TIFF structure from raw JPEG data to extract
   * original image dimensions (ImageWidth/ImageLength).
   * The getImageProperty API fails for these tags (error 62980123).
   */
  private static parseExifDims(data: ArrayBuffer): OrientedSize | null {
    const bytes = new Uint8Array(data);
    if (bytes.length < 20) {
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] data too short: %{public}d', bytes.length);
      return null;
    }

    // Locate TIFF header: either at start (RAW/TIFF) or after JPEG APP1 Exif marker.
    let off = 0;
    const isTiff = (bytes[0] === 0x49 && bytes[1] === 0x49) || (bytes[0] === 0x4D && bytes[1] === 0x4D);
    hilog.info(DOMAIN, TAG, '[EXIF_PARSE] format=%{public}s totalBytes=%{public}d',
      isTiff ? 'TIFF/RAW' : 'JPEG', bytes.length);
    if (!isTiff) {
      // Must be JPEG — find APP1/Exif marker
      if (bytes[0] !== 0xFF || bytes[1] !== 0xD8) {
        hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] not JPEG SOI, b0=0x%{public}x b1=0x%{public}x', bytes[0], bytes[1]);
        return null; // not a recognized format
      }
      const foundApp1 = false;
      while (off < bytes.length - 14) {
        if (bytes[off] === 0xFF && bytes[off + 1] === 0xE1) {
          const app1Size = (bytes[off + 2] << 8) | bytes[off + 3];
          // Check "Exif\0\0" identifier
          if (off + 6 <= bytes.length &&
              bytes[off + 4] === 0x45 && bytes[off + 5] === 0x78 &&
              bytes[off + 6] === 0x69 && bytes[off + 7] === 0x66 &&
              bytes[off + 8] === 0x00 && bytes[off + 9] === 0x00) {
            hilog.info(DOMAIN, TAG, '[EXIF_PARSE] found APP1 Exif at offset=%{public}d size=%{public}d', off, app1Size);
            off += 10; // skip to TIFF header
            break;
          }
          // Skip to next marker (even if APP1 exceeds buffer, we already
          // checked the Exif\0\0 identifier above)
          off += 2 + app1Size;
        } else if (bytes[off] === 0xFF && bytes[off + 1] >= 0xE0 && bytes[off + 1] <= 0xEF) {
          const skip = (bytes[off + 2] << 8) | bytes[off + 3];
          off += 2 + (skip || 2);
        } else {
          off++;
        }
      }
      if (off >= bytes.length - 14) {
        hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] APP1 not found within %{public}d bytes', bytes.length);
        return null;
      }
    }
    // Now `off` points to TIFF header (II\0x2A\0 or MM\0x00\x2A)

    // Determine byte order: "II" (little-endian) or "MM" (big-endian)
    const le = (bytes[off] === 0x49 && bytes[off + 1] === 0x49);
    const be = (bytes[off] === 0x4D && bytes[off + 1] === 0x4D);
    if (!le && !be) {
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] unknown byte order: b0=%{public}d b1=%{public}d', bytes[off], bytes[off + 1]);
      return null;
    }

    // Helper: read 2 bytes at offset p
    const r16 = (p: number): number => {
      if (p + 2 > bytes.length) return 0;
      return le ? (bytes[p] | (bytes[p + 1] << 8)) : ((bytes[p] << 8) | bytes[p + 1]);
    };
    // Helper: read 4 bytes at offset p
    const r32 = (p: number): number => {
      if (p + 4 > bytes.length) return 0;
      if (le) return bytes[p] | (bytes[p + 1] << 8) | (bytes[p + 2] << 16) | (bytes[p + 3] << 24);
      return (bytes[p] << 24) | (bytes[p + 1] << 16) | (bytes[p + 2] << 8) | bytes[p + 3];
    };

    // Validate TIFF magic 0x002A
    if (r16(off + 2) !== 0x002A) {
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] invalid TIFF magic 0x%{public}x', r16(off + 2));
      return null;
    }

    // IFD0 offset is relative to start of TIFF header
    const ifd0Off = off + r32(off + 4);

    let imgW = 0, imgH = 0;
    let exifIfdOff = 0;

    // Parse IFD0 entries (12 bytes each).
    // 以前这里对每张 NEF 打印 25 行 IFD0 明细，1288 张就是几万行日志（ISSUE-007）；
    // 明细对定位“尺寸在 SubIFD”没有额外价值，只保留失败时的汇总。
    const entryCount = r16(ifd0Off);
    for (let i = 0; i < entryCount; i++) {
      const eOff = ifd0Off + 2 + i * 12;
      if (eOff + 12 > bytes.length) break;
      const tag = r16(eOff);
      const typ = r16(eOff + 2);
      if (tag === 0x0100) { // ImageWidth in IFD0
        imgW = (typ === 3) ? r16(eOff + 8) : r32(eOff + 8);
      } else if (tag === 0x0101) { // ImageLength in IFD0
        imgH = (typ === 3) ? r16(eOff + 8) : r32(eOff + 8);
      } else if (tag === 0x8769) { // ExifIFD pointer
        exifIfdOff = off + r32(eOff + 8);
      } else if (tag === 0x014A) { // SubIFD — beyond 192KB USB limit, skip
      } else if (tag === 0x0201) { // JPEGInterchangeFormat (embedded JPEG offset)
        if (imgW === 0 || imgH === 0) {
          // Parse the embedded JPEG preview's SOF marker for dimensions
          const jpegOff = off + r32(eOff + 8);
          if (jpegOff + 4 < bytes.length && bytes[jpegOff] === 0xFF && bytes[jpegOff + 1] === 0xD8) {
            // Scan JPEG markers for SOF (0xFFC0, 0xFFC1, 0xFFC2)
            let sp = jpegOff + 2;
            while (sp + 8 < bytes.length) {
              if (bytes[sp] !== 0xFF) break;
              const marker = bytes[sp + 1];
              if (marker >= 0xC0 && marker <= 0xC3) {
                imgH = (bytes[sp + 5] << 8) | bytes[sp + 6];
                imgW = (bytes[sp + 7] << 8) | bytes[sp + 8];
                break;
              }
              const segLen = (bytes[sp + 2] << 8) | bytes[sp + 3];
              sp += 2 + segLen;
            }
          }
        }
      }
    }

    if (imgW > 0 && imgH > 0) {
      hilog.info(DOMAIN, TAG, '[EXIF_PARSE] IFD0/SubIFD found %{public}dx%{public}d', imgW, imgH);
      return new OrientedSize(imgW, imgH);
    }

    // Try ExifIFD sub-directory
    if (exifIfdOff > 0 && exifIfdOff + 2 <= bytes.length) {
      const exifCount = r16(exifIfdOff);
      hilog.info(DOMAIN, TAG, '[EXIF_PARSE] ExifIFD at 0x%{public}x entries=%{public}d', exifIfdOff, exifCount);
      for (let i = 0; i < exifCount; i++) {
        const eOff = exifIfdOff + 2 + i * 12;
        if (eOff + 12 > bytes.length) break;
        const tag = r16(eOff);
        const typ = r16(eOff + 2);
        if (tag === 0xA002) { // ExifImageWidth
          imgW = (typ === 3) ? r16(eOff + 8) : r32(eOff + 8);
        } else if (tag === 0xA003) { // ExifImageLength
          imgH = (typ === 3) ? r16(eOff + 8) : r32(eOff + 8);
        }
      }
    } else if (exifIfdOff > 0) {
      // 指针存在但落在读取窗口之外：这是 16KB 头读不到 NEF 尺寸的真实原因，
      // 文案要如实说“越界”，否则会被误判成没有指针（ISSUE-012 顺带记录）。
      hilog.warn(DOMAIN, TAG,
        '[EXIF_PARSE] ExifIFD out of window: off=%{public}d len=%{public}d',
        exifIfdOff, bytes.length);
    } else {
      hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] no ExifIFD pointer (tag 0x8769) in IFD0');
    }

    if (imgW > 0 && imgH > 0) {
      hilog.info(DOMAIN, TAG, '[EXIF_PARSE] ExifIFD found %{public}dx%{public}d', imgW, imgH);
      return new OrientedSize(imgW, imgH);
    }
    hilog.warn(DOMAIN, TAG, '[EXIF_PARSE] FAILED ifd0W=%{public}d ifd0H=%{public}d exifIfdOff=%{public}d entryCount=%{public}d', imgW, imgH, exifIfdOff, entryCount);
    return null;
  }

  /**
   * Read EXIF Orientation from raw image data and return the corresponding transform.
   * Caches result by handle so subsequent decodes skip re-parsing.
   */
  private async getOrientation(handle: number, data: ArrayBuffer): Promise<OrientationTransform> {
    if (this.orientationMap.has(handle)) {
      return this.orientationMap.get(handle)!;
    }
    try {
      const imgSrc = image.createImageSource(data);
      const orientation = await imgSrc.getImageProperty(image.PropertyKey.ORIENTATION);
      imgSrc.release();
      hilog.info(DOMAIN, TAG, `[ORIENT] handle=0x%{public}s raw="%{public}s"`, handle.toString(16), orientation);
      const result = CameraService.mapExifOrientation(orientation);
      hilog.info(DOMAIN, TAG, `[ORIENT] handle=0x%{public}s → rotate=%{public}d flipH=%{public}s flipV=%{public}s`,
        handle.toString(16), result.rotate, result.flipH.toString(), result.flipV.toString());
      this.orientationMap.set(handle, result);
      return result;
    } catch (err) {
      // No EXIF / unsupported format → treat as normal
      hilog.error(DOMAIN, TAG, `[ORIENT] getOrientation FAIL handle=0x%{public}s err=%{public}s`,
        handle.toString(16), JSON.stringify(err));
      const result = new OrientationTransform(0, false, false);
      this.orientationMap.set(handle, result);
      return result;
    }
  }

  // Download registry — persisted across sessions
  private downloadRegistry: Map<string, DownloadRecord> = new Map();
  private downloadDir: string = '';
  private downloadTempDir: string = '';
  private downloadAborted: boolean = false;
  private registryLoaded: boolean = false;
  private registryLoading: Promise<void> | null = null;
  /** 用于按 URI 查询媒体库；没有 context 或没有权限时退化为逐个打开 URI。 */
  private context: common.UIAbilityContext | null = null;
  /**
   * 传输期间申请的 DATA_TRANSFER 长时任务。
   *
   * 传输（扫描缩略图 / 批量下载）是用户可感知的长任务，不申请长时任务的话，
   * 应用一退到后台就会被挂起，USB 传输直接停掉。这里用引用计数：
   * 扫描与下载可能同时进行，最后一个结束时才取消。
   */
  private transferTaskRefs: number = 0;
  private transferTaskOn: boolean = false;
  private transferTaskStarting: boolean = false;
  /**
   * 退到后台时额外持有的一份「保持相机会话」任务。
   *
   * 相机连着时退到后台，系统会挂起进程，USB / TCP 会话随之中断。进后台时
   * 借传输长时任务把进程留在后台，回前台释放（传输自己的引用不受影响）。
   * 与 `beginTransferTask()` 共用引用计数，避免与扫描/下载抢同一个任务。
   */
  private sessionKeepAlive: boolean = false;
  /** 当前长时任务用的模式（决定系统通知那句话）。 */
  private transferTaskMode: backgroundTaskManager.BackgroundMode =
    backgroundTaskManager.BackgroundMode.DATA_TRANSFER;
  /** 长时任务正在停/起：避免同一时刻两次切换。 */
  private taskBusy: boolean = false;
  /** 切换期间又有新的需求：这一轮结束后补一次。 */
  private taskApplyPending: boolean = false;
  /** 通知栏进度环（系统 downloadTemplate）的定时刷新句柄与当前进度。 */
  private noticeTimerId: number = -1;
  private noticeCurrent: number = 0;
  private noticeTotal: number = 0;
  private noticeLabel: string = '';
  private phAccessHelper: photoAccessHelper.PhotoAccessHelper | null = null;
  private mediaQuerySupported: boolean | null = null;

  // Change tracking
  @Trace registryVersion: number = 0;
  @Trace photosVersion: number = 0;

  static getInstance(): CameraService {
    if (!CameraService.instance) {
      CameraService.instance = new CameraService();
    }
    return CameraService.instance;
  }

  private constructor() {
    setPtpLog(this.log);
    this.log.add('App 启动');
  }

  getLog(): AppLog {
    return this.log;
  }

  initLogPath(dir: string): void {
    this.log.setFilePath(dir + '/app_log.txt');
    // 位置注入是独立服务，日志要并到同一份 AppLog，否则真机上根本看不到它
    // 有没有订上定位（1.66.18 之前就是这样悄悄丢了日志）。
    BleGeoFeed.getInstance().initLog(this.log);
  }

  initDownloadDir(dir: string, ctx?: common.UIAbilityContext): void {
    this.filesDir = dir;
    this.downloadDir = dir;
    if (ctx !== undefined) {
      this.context = ctx;
    }
    this.downloadTempDir = dir + '/download_temp';
    // 上次中断留下的沙箱临时图片不再需要；先清空再建目录。
    AtomicFile.deleteDirRecursive(this.downloadTempDir);
    try {
      fileIo.mkdirSync(this.downloadTempDir, true);
    } catch (_e) {
      // best effort
    }
    this.cachePrefs.init(dir);
    this.loadRegistry();
  }

  /**
   * 重新算一次长时任务的模式（1.66.17）。
   *
   * `syncBackgroundTask()` 在「要不要保活」没变时会直接返回；但模式本身还可能变
   * （位置注入起来了 → 蓝牙任务换成定位任务），那条路走不到，所以单独补一个入口。
   */
  private refreshBackgroundTaskMode(): void {
    if (!this.sessionKeepAlive && this.transferTaskRefs === 0) return;
    this.applyBackgroundTask().catch((_e: Error) => {
      // 换模式失败只影响通知文案与后台定位，不影响前台
    });
  }

  /** 应用进入后台时强制把待写缓存落盘。 */
  async flushPersistence(): Promise<void> {
    try {
      if (this.cachingEnabled) {
        await this.thumbCache.flush();
        this.thumbCache.close();
      }
    } catch (_e) {
      // best effort
    }
  }

  makeDownloadKey(filename: string, size: number): string {
    return `${this.cameraIdentity}::${filename}::${size}`;
  }

  /** 旧版本的全局键：没有相机身份，只在没有新记录时兼容读取。 */
  private makeLegacyDownloadKey(filename: string, size: number): string {
    return `${filename}::${size}`;
  }

  /** 先找当前相机的记录，再回退到旧版无相机字段的记录。 */
  private findDownloadRecord(filename: string, size: number): DownloadRecord | null {
    const current = this.downloadRegistry.get(this.makeDownloadKey(filename, size));
    if (current !== undefined) return current;
    const legacy = this.downloadRegistry.get(this.makeLegacyDownloadKey(filename, size));
    if (legacy !== undefined &&
        (legacy.cameraId === undefined || legacy.cameraId === '')) {
      return legacy;
    }
    return null;
  }

  @Trace downloadedCount: number = 0;

  getDownloadedKeys(): string[] {
    const keys: string[] = [];
    for (const p of this.photos) {
      const record = this.findDownloadRecord(p.filename, p.size);
      if (record !== null && record.missingSince === undefined) {
        // 返回当前相机键，GalleryPage 用 makeDownloadKey() 计算出的键才能命中。
        keys.push(this.makeDownloadKey(p.filename, p.size));
      }
    }
    this.downloadedCount = keys.length;
    return keys;
  }

  cancelDownload(): void {
    this.downloadAborted = true;
  }



  /** 传输期间每秒刷新一次通知栏进度环（系统 downloadTemplate）。 */
  private startNoticeTimer(): void {
    if (this.noticeTimerId >= 0) {
      return;
    }
    this.noticeTimerId = setInterval(() => { this.tickTransferNotice(); }, 1000);
  }

  private stopNoticeTimer(): void {
    if (this.noticeTimerId >= 0) {
      clearInterval(this.noticeTimerId);
      this.noticeTimerId = -1;
    }
    this.noticeCurrent = 0;
    this.noticeTotal = 0;
    this.noticeLabel = '';
  }

  private tickTransferNotice(): void {
    if (this.context === null) {
      return;
    }
    let current = 0;
    let total = 0;
    let label = '';
    if (this.scanning && this.scanTotal > 0) {
      current = this.scanProgress;
      total = this.scanTotal;
      label = this.scanPhaseText;
    } else if (this.noticeTotal > 0) {
      current = this.noticeCurrent;
      total = this.noticeTotal;
      label = this.noticeLabel;
    }
    if (total <= 0) {
      return;
    }
    const pct = Math.round(current * 100 / total);
    const detail = `${current}/${total}` + (label !== '' ? ` · ${label}` : '');
    TransferNotice.update(this.context, '正在导入照片', detail, pct).catch((_e: Error) => { /* 通知失败不影响传输 */ });
  }

  /** 传输开始：只管引用计数，真正的长时任务由 `applyBackgroundTask()` 统一申请。 */
  private async beginTransferTask(): Promise<void> {
    this.transferTaskRefs++;
    this.startNoticeTimer();
    await this.applyBackgroundTask();
  }

  /** 传输结束：引用减一，交给 `applyBackgroundTask()` 决定是换模式还是释放。 */
  private async endTransferTask(): Promise<void> {
    if (this.transferTaskRefs > 0) {
      this.transferTaskRefs--;
    }
    await this.applyBackgroundTask();
  }

  /**
   * 后台长时任务的唯一决策点（1.66.11）。
   *
   * 通知栏那句话是**系统按 `BackgroundMode` 生成的，应用改不了**。原来不管什么原因
   * 都申请 `DATA_TRANSFER`，于是「只是蓝牙待机」也会显示「正在运行数据传输任务」——
   * 用户一眼就看出名不副实。现在按真实原因分两种模式：
   *
   * - 正在传照片（`transferTaskRefs > 0`）→ `DATA_TRANSFER`（系统通知：数据传输任务）
   * - 只是蓝牙长连 / 等重连（`sessionKeepAlive`）→ `BLUETOOTH_INTERACTION`（蓝牙业务）
   *
   * 传照片优先：传输期间显示的必须是「数据传输」。两者切换时先停再起（同一个
   * UIAbility 同时只能有一个长时任务）。
   */
  private async applyBackgroundTask(): Promise<void> {
    if (this.taskBusy) {
      // 正在停/起：记一笔，等这一轮结束再补齐。
      this.taskApplyPending = true;
      return;
    }
    this.taskBusy = true;
    try {
      do {
        this.taskApplyPending = false;
        const transfer = this.transferTaskRefs > 0;
        const wantBt = this.sessionKeepAlive && !transfer;
        if (!transfer && !wantBt) {
          if (this.transferTaskOn) await this.stopTransferTask();
          continue;
        }
        // 位置注入在跑的时候用 LOCATION：后台定位必须有这个类型的长时任务，
        // 而它同样能把进程留住（BLE 写入不看任务类型）。只有做蓝牙待机、
        // 不供位置时才用 BLUETOOTH_INTERACTION（1.66.17）。
        const mode = transfer
          ? backgroundTaskManager.BackgroundMode.DATA_TRANSFER
          : (BleGeoFeed.getInstance().isRunning()
              ? backgroundTaskManager.BackgroundMode.LOCATION
              : backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION);
        if (this.transferTaskOn && this.transferTaskMode === mode) continue;
        if (this.transferTaskOn) await this.stopTransferTask();
        await this.startBackgroundTask(mode);
      } while (this.taskApplyPending);
    } finally {
      this.taskBusy = false;
    }
  }

  /** 真正申请系统长时任务。失败不抛：后台可能被挂起，但不该打断前台动作。 */
  private async startBackgroundTask(
    mode: backgroundTaskManager.BackgroundMode): Promise<void> {
    if (this.transferTaskOn || this.transferTaskStarting || this.context === null) {
      return;
    }
    this.transferTaskStarting = true;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'io.github.shaoyuanyu.strollandshoot',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1,
        actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
      };
      const wa: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(this.context, mode, wa);
      this.transferTaskOn = true;
      this.transferTaskMode = mode;
      this.log.add(mode === backgroundTaskManager.BackgroundMode.DATA_TRANSFER
        ? '后台传输长时任务已申请'
        : (mode === backgroundTaskManager.BackgroundMode.LOCATION
            ? '后台定位长时任务已申请（保持长连并继续注入位置）'
            : '后台蓝牙长时任务已申请（保持长连）'));
    } catch (err) {
      // 与定位长时任务冲突（同一 UIAbility 同时只允许一个）或系统拒绝时不要打断流程。
      this.log.add(`长时任务申请失败: ${(err as BusinessError).message}`);
    } finally {
      this.transferTaskStarting = false;
    }
  }

  /** 真正释放系统长时任务；先翻 `transferTaskOn`，防止并发 stop 同一任务。 */
  private async stopTransferTask(): Promise<void> {
    if (!this.transferTaskOn || this.context === null) {
      return;
    }
    this.transferTaskOn = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.log.add('后台传输长时任务已取消');
    } catch (err) {
      this.log.add(`后台传输长时任务取消失败: ${(err as BusinessError).message}`);
    }
    this.stopNoticeTimer();
    await TransferNotice.cancel();
  }

  /**
   * 应用切到后台：相机会话还在就申请长时任务。
   *
   * 官方长时任务指南建议把申请推迟到 `onBackground`，这样前台不会常驻一条
   * 长时任务通知；回前台由 `onAppForeground()` 释放。传输自己的引用计数
   * 不受影响。
   */
  onAppBackground(): void {
    // 后台不做无线心跳：没有界面要更新，也没必要陪相机跑流量。
    this.setAppForeground(false);
    // 记一笔「带着无线会话退到后台」。Wi-Fi 会话没有合法的长时任务（见
    // SERVICES.md「长时任务类型」），进程冻结后网络资源会在 12 秒左右被系统
    // 释放，所以回前台不能直接信 `connected`——超过宽限期就重建会话。
    if (this.connected && this.wireless) {
      this.backgroundedAt = Date.now();
      this.wirelessSessionMayBeStale = true;
    }
    this.syncBackgroundTask();
  }

  /** 应用回到前台：释放后台保活引用，并恢复无线心跳。 */
  onAppForeground(): void {
    const away = this.backgroundedAt > 0 ? Date.now() - this.backgroundedAt : 0;
    const stale = this.wirelessSessionMayBeStale && away > WIRELESS_BG_GRACE_MS;
    this.backgroundedAt = 0;
    this.setAppForeground(true);
    this.syncBackgroundTask();
    if (stale) {
      this.wirelessSessionMayBeStale = false;
      this.resumeWirelessAfterBackground();
    }
  }

  /**
   * 后台待久了回来：先把死掉的无线会话收掉，再用记得的地址接回来。
   *
   * 不走 15 秒心跳那条路——那条要等心跳超时（6 秒）才判定断开，回前台先卡
   * 六秒再说；这里直接重建，通常一两秒。重建失败再按模式做完整唤醒。
   */
  private resumeWirelessAfterBackground(): void {
    if (!this.wireless) return;
    // 后台还在传照片 / 扫描：会话是活的，别动。
    if (this.transferTaskRefs > 0 || this.scanning) return;
    this.log.add('回前台：无线会话可能已被系统释放，重建');
    this.connected = false;
    this.usable = false;
    this.statusText = L10n.tr('camera_status_wifi_connecting', this.wifiHost);
    this.dropBrokenWifiSession();
    this.autoLinkWifi('foreground', false).then((ok: boolean) => {
      if (ok || !this.appForeground) return;
      if (this.connected) return;
      // 相机自己的无线已经睡了：走完整唤醒（0x2005 + 入热点/发现）
      this.connectWirelessNow().then((restored: boolean) => {
        if (restored || this.connected) return;
        // 另一次连接已经在跑（`connectWirelessNow` 会立刻返回 false）：别抢它。
        if (this.apJoining || this.wifiAutoConnecting) return;
        this.endBleBrowsing('回前台没能恢复浏览会话');
      }).catch((err: Error) => {
        this.log.add(`回前台恢复无线失败: ${err.message}`);
        this.endBleBrowsing('回前台恢复无线异常');
      });
    }).catch((err: Error) => {
      this.log.add(`回前台恢复无线异常: ${err.message}`);
    });
  }

  /**
   * 后台保活的统一入口（1.66.9）。
   *
   * 原来只有「PTP 会话还在（这次真的在传照片）」才申请长时任务。蓝牙待机时进程可以
   * 被系统冻结，冻结期间定时器和 BLE 回调都不跑，相机唤醒也连不回来（真机实测：后台
   * 的重连窗口被拉长到 35–59 秒，再久就被冻结）。
   *
   * 现在「蓝牙待机连着」「正在等相机回来」也算需要保活——用户选了「后台纯待机也不
   * 断线」，代价是**通知栏常驻一条系统长时任务通知**（内容应用改不了）。
   * 相机一直关着时这条保活会一直挂着，扫描降到低功耗档、间隔 15 秒。
   */
  private syncBackgroundTask(): void {
    // 「等待循环还开着」也算需要保活：断链那一刻 `bleReconnecting` 还没置上，
    // 只看它会让任务先被释放、随即又申请一次（真机日志里 18:04:56 就是这么抖的）。
    const watching = this.bleLink !== null && this.bleLink.watchArmed();
    // Wi-Fi 会话（`connected && wireless`）**不算**保活理由：系统的长时任务类型
    // 里没有「Wi-Fi 连接」，借蓝牙类型去挂会被一致性校验判成「未执行相应业务」
    // 而挂起（1.66.17，见 SERVICES.md）。后台就让它按系统规则冻结，回前台重连。
    const wifiSessionOnly = this.connected && this.wireless;
    const need = !this.appForeground
      && (this.bleConnected || this.bleReconnecting || watching
          || (this.connected && !wifiSessionOnly));
    if (need === this.sessionKeepAlive) return;
    this.sessionKeepAlive = need;
    this.log.add(need
      ? (this.connected ? '退到后台：为保持相机会话保活' : '退到后台：为保持蓝牙长连与重连保活')
      : '不再需要后台保活');
    this.applyBackgroundTask().catch((_e: Error) => {
      // 申请/释放失败只影响通知与后台存活，不影响前台
    });
  }

  async downloadPhotos(
    handles: number[],
    onProgress: (progress: DownloadProgress) => void,
    context: common.UIAbilityContext
  ): Promise<DownloadResult[]> {
    // Ensure registry is loaded before starting
    await this.loadRegistry();

    const results: DownloadResult[] = [];
    const errors: string[] = [];

    const batch: PhotoEntry[] = [];
    let totalBytes = 0;
    for (const h of handles) {
      for (const p of this.photos) {
        if (p.handle === h) {
          batch.push(p);
          totalBytes += p.size;
          break;
        }
      }
    }

    if (batch.length === 0) {
      onProgress({
        phase: 'error', currentIndex: 0, totalCount: 0,
        currentFilename: '', currentSizeBytes: 0,
        downloadedCount: 0, totalBytes: 0, downloadedBytes: 0,
        errors: ['No matching photos found for selected handles']
      });
      return results;
    }

    // 批量下载同样是长任务：退到后台不能停，申请 DATA_TRANSFER 长时任务
    await this.beginTransferTask();

    this.downloadAborted = false;
    let downloadedBytes = 0;
    for (let i = 0; i < batch.length; i++) {
      if (this.downloadAborted) {
        this.downloadAborted = false;
        this.log.add('下载已取消');
        errors.push('用户取消下载');
        onProgress({
          phase: 'complete', currentIndex: i, totalCount: batch.length,
          currentFilename: '', currentSizeBytes: 0,
          downloadedCount: results.filter((r: DownloadResult) => r.success).length,
          totalBytes, downloadedBytes, errors
        });
        break;
      }

      const photo = batch[i];
      this.noticeCurrent = i + 1;
      this.noticeTotal = batch.length;
      this.noticeLabel = photo.filename;

      const key = this.makeDownloadKey(photo.filename, photo.size);

      const existing = this.findDownloadRecord(photo.filename, photo.size);
      if (existing !== null && existing.missingSince === undefined) {
        results.push({ handle: photo.handle, key, success: true, localPath: existing.localPath });
        onProgress({
          phase: 'downloading', currentIndex: i, totalCount: batch.length,
          currentFilename: photo.filename, currentSizeBytes: photo.size,
          downloadedCount: results.filter((r: DownloadResult) => r.success).length,
          totalBytes, downloadedBytes, errors
        });
        continue;
      }

      onProgress({
        phase: 'downloading', currentIndex: i, totalCount: batch.length,
        currentFilename: photo.filename, currentSizeBytes: photo.size,
        downloadedCount: results.filter((r: DownloadResult) => r.success).length,
        totalBytes, downloadedBytes, errors
      });

      let data: Uint8Array | null = null;

      // Reuse preloaded data from cache to avoid re-downloading via USB
      if (this.compressedCache.has(photo.handle)) {
        data = this.compressedCache.get(photo.handle)!;
        this.log.add(`下载(缓存命中): ${photo.filename} (${this.formatSize(data.length)})`);
      } else {
        try {
          data = await this.session.getObject(photo.handle);
        } catch (err) {
          const msg = `${photo.filename}: USB传输失败: ${JSON.stringify(err)}`;
          errors.push(msg);
          results.push({ handle: photo.handle, key, success: false, localPath: '', error: msg });
          continue;
        }
      }

      if (!data || data.length === 0) {
        errors.push(`${photo.filename}: USB传输返回空数据`);
        results.push({ handle: photo.handle, key, success: false,
          localPath: '', error: 'USB transfer returned empty data' });
        continue;
      }

      onProgress({
        phase: 'saving', currentIndex: i, totalCount: batch.length,
        currentFilename: photo.filename, currentSizeBytes: photo.size,
        downloadedCount: results.filter((r: DownloadResult) => r.success).length,
        totalBytes, downloadedBytes, errors
      });

      const localFilename = this.sanitizeFilename(photo.filename);
      const localPath = this.downloadTempDir + '/' + localFilename;
      try {
        const f = await fileIo.open(localPath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        await fileIo.write(f.fd, data.buffer as ArrayBuffer);
        await fileIo.close(f);
      } catch (err) {
        const msg = `${photo.filename}: 写入文件失败: ${JSON.stringify(err)}`;
        errors.push(msg);
        results.push({ handle: photo.handle, key, success: false, localPath: '', error: msg });
        continue;
      }

      downloadedBytes += data.length;
      results.push({ handle: photo.handle, key, success: true, localPath: localPath });

      // Apply GPS geotagging to the sandbox file before Gallery save
      if (photo.captureDate) {
        const gpsRecorder = GpsRecorder.getInstance();
        const gpsRecords = gpsRecorder.getRecords();
        if (gpsRecords.length > 0) {
          const photoTime = GpsRecorder.parseCaptureDate(photo.captureDate);
          const gps = gpsRecorder.findClosest(photo.captureDate);
          this.log.add(`GPS匹配: ${photo.filename} captureDate=${photo.captureDate} photoTime=${photoTime} gpsRange=[${gpsRecords[0].timestamp}..${gpsRecords[gpsRecords.length-1].timestamp}] match=${gps ? 'yes' : 'no'}`);
          if (gps) {
            const tagged = await ExifGeotagger.applyGps(localPath, gps);
            if (tagged) {
              this.log.add(`GPS标记: ${photo.filename} (${gps.latitude.toFixed(4)},${gps.longitude.toFixed(4)})`);
            }
          }
        }
      } else {
        this.log.add(`GPS跳过: ${photo.filename} 无captureDate`);
      }

      this.log.add(`沙箱暂存 [${i + 1}/${batch.length}]: ${photo.filename} (${this.formatSize(photo.size)})`);
    }

    // Phase: save to system Gallery via showAssetsCreationDialog
    const sandboxSuccesses = results.filter((r: DownloadResult) => r.success);
    if (sandboxSuccesses.length > 0) {
      onProgress({
        phase: 'saving', currentIndex: batch.length, totalCount: batch.length,
        currentFilename: '正在保存到相册...', currentSizeBytes: 0,
        downloadedCount: sandboxSuccesses.length, totalBytes, downloadedBytes, errors
      });

      const onSaved = (result: DownloadResult, galleryUri: string): void => {
        const photo = batch.find((p: PhotoEntry) => p.handle === result.handle);
        if (!photo) return;
        const record: DownloadRecord = {
          key: result.key,
          cameraId: this.cameraIdentity,
          filename: photo.filename,
          size: photo.size,
          localPath: galleryUri,
          downloadDate: new Date().toISOString()
        };
        // 每成功一张就写 journal；整批结束再压缩成快照。
        this.addDownloadRecord(record);
      };

      let galleryUris: Map<string, string> = new Map();
      try {
        galleryUris = await this.moveToGallery(sandboxSuccesses, context, onSaved);
      } catch (err) {
        this.log.add(`保存到相册失败: ${JSON.stringify(err)}`);
      }

      if (galleryUris.size > 0) {
        await this.compactRegistry();
      }
    }

    onProgress({
      phase: 'complete', currentIndex: batch.length - 1, totalCount: batch.length,
      currentFilename: '', currentSizeBytes: 0,
      downloadedCount: results.filter((r: DownloadResult) => r.success).length,
      totalBytes, downloadedBytes, errors
    });

    this.log.add(`批量下载完成: ${results.filter((r: DownloadResult) => r.success).length}/${batch.length} 成功`);
    if (errors.length > 0) {
      this.log.add(`错误: ${errors.join('; ')}`);
    }

    await this.endTransferTask();
    return results;
  }

  /**
   * Moves successfully downloaded sandbox files to the system Gallery
   * via showAssetsCreationDialog. User confirms once for all files.
   * Returns a map from download key to Gallery URI for successfully copied files.
   */
  private async moveToGallery(
    sandboxResults: DownloadResult[],
    context: common.UIAbilityContext,
    onSaved?: (result: DownloadResult, galleryUri: string) => void
  ): Promise<Map<string, string>> {
    const galleryUris = new Map<string, string>();
    const srcFileUris: string[] = [];
    const photoCreationConfigs: photoAccessHelper.PhotoCreationConfig[] = [];

    const prefix = this.sanitizeCameraName(this.cameraName);

    for (const r of sandboxResults) {
      const ext = this.getFileExtension(r.localPath);
      srcFileUris.push(fileUri.getUriFromPath(r.localPath));
      const fileName = r.localPath.substring(r.localPath.lastIndexOf('/') + 1);
      const nameWithoutExt = fileName.substring(0, fileName.lastIndexOf('.'));
      const title = prefix ? `${prefix}_${nameWithoutExt}` : nameWithoutExt;
      photoCreationConfigs.push({
        title: title,
        fileNameExtension: ext,
        photoType: photoAccessHelper.PhotoType.IMAGE,
      });
    }

    const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    let desFileUris: string[] = [];
    try {
      desFileUris = await phAccessHelper.showAssetsCreationDialog(
        srcFileUris, photoCreationConfigs
      );
    } catch (err) {
      this.log.add(`保存到相册弹窗失败: ${JSON.stringify(err)}`);
      return galleryUris;
    }

    if (desFileUris.length === 0) {
      this.log.add('用户取消保存到相册，文件保留在应用沙箱');
      return galleryUris;
    }

    // Copy from sandbox to Gallery URIs
    let copied = 0;
    for (let i = 0; i < desFileUris.length; i++) {
      try {
        const srcFile = fileIo.openSync(srcFileUris[i], fileIo.OpenMode.READ_ONLY);
        const desFile = fileIo.openSync(desFileUris[i],
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        // 用异步复制：原图/RAW 动辄几十 MB，`copyFileSync` 会把主线程按住到
        // 写完（1.66.15 排查时列出的一条主线程阻塞风险）。
        await fileIo.copyFile(srcFile.fd, desFile.fd);
        fileIo.closeSync(srcFile);
        fileIo.closeSync(desFile);
        if (i < sandboxResults.length) {
          galleryUris.set(sandboxResults[i].key, desFileUris[i]);
          if (onSaved !== undefined) {
            onSaved(sandboxResults[i], desFileUris[i]);
          }
        }
        copied++;
      } catch (err) {
        this.log.add(`相册写入失败 [${i}]: ${JSON.stringify(err)}`);
      }
    }

    // Delete sandbox temp files
    for (const r of sandboxResults) {
      try { fileIo.unlink(r.localPath); } catch (_e) { /* best effort */ }
    }

    this.log.add(`已保存到相册: ${copied}/${desFileUris.length} 张`);
    return galleryUris;
  }

  private sanitizeCameraName(name: string): string {
    if (!name) return '';
    return name.replace(/[\\/:*?"<>| ]/g, '_').substring(0, 32);
  }

  private getFileExtension(path: string): string {
    const dot = path.lastIndexOf('.');
    if (dot < 0) return 'jpg';
    return path.substring(dot + 1).toLowerCase();
  }


  private sanitizeFilename(name: string): string {
    return name.replace(/[/\\:*?"<>|]/g, '_');
  }

  private registryPath(): string {
    return this.downloadDir + '/download_registry.json';
  }

  private registryJournalPath(): string {
    return this.downloadDir + '/download_registry.jsonl';
  }

  private async loadRegistry(): Promise<void> {
    if (this.registryLoaded) return;
    const loading = this.registryLoading;
    if (loading !== null) {
      await Promise.resolve(loading);
      return;
    }
    const task = this.doLoadRegistry();
    this.registryLoading = task;
    try {
      await task;
    } finally {
      this.registryLoading = null;
    }
  }

  private async doLoadRegistry(): Promise<void> {
    const text = AtomicFile.readText(this.registryPath());
    if (text !== null && text !== '') {
      try {
        const parsed = JSON.parse(text) as Record<string, Object>;
        const version = parsed['version'];
        const raw = version !== undefined ? parsed['records'] : parsed;
        if (raw !== undefined && raw !== null) {
          const map = raw as Record<string, DownloadRecord>;
          for (const k of Object.keys(map)) {
            this.downloadRegistry.set(k, map[k]);
          }
        }
        this.log.add(`加载下载记录: ${this.downloadRegistry.size} 条`);
      } catch (err) {
        this.log.add(`加载下载记录失败: ${JSON.stringify(err)}`);
      }
    }
    this.registryVersion++;

    // 逐张追加的 journal 比整份快照更耐崩溃：先合并，再压缩回快照。
    const journalText = AtomicFile.readText(this.registryJournalPath());
    if (journalText !== null && journalText !== '') {
      let applied = 0;
      const lines = journalText.split('\n');
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed === '') continue;
        try {
          const entry = JSON.parse(trimmed) as DownloadJournalEntry;
          if (entry.key !== undefined && entry.key !== '' &&
              entry.record !== undefined && entry.record !== null) {
            this.downloadRegistry.set(entry.key, entry.record);
            applied++;
          }
        } catch (_e) {
          // 最后一行可能只写了一半，忽略
        }
      }
      if (applied > 0) {
        this.log.add(`下载记录 journal 恢复: ${applied} 条`);
      }
      await this.compactRegistry();
    }

    // 超过上限时按下载时间淘汰最旧记录。
    if (this.pruneDownloadRegistry()) {
      await this.compactRegistry();
    }

    // Prune entries whose Gallery files no longer exist (e.g. user deleted from Album)
    await this.validateRegistry();
    this.registryLoaded = true;
  }

  /** 注册表超过 MAX_DOWNLOAD_RECORDS 时删除最旧记录；返回是否删除过。 */
  private pruneDownloadRegistry(): boolean {
    if (this.downloadRegistry.size <= MAX_DOWNLOAD_RECORDS) return false;
    const keys: string[] = [];
    this.downloadRegistry.forEach((_record: DownloadRecord, key: string) => {
      keys.push(key);
    });
    keys.sort((a: string, b: string): number => {
      const da = this.downloadRegistry.get(a)?.downloadDate ?? '';
      const db = this.downloadRegistry.get(b)?.downloadDate ?? '';
      return da.localeCompare(db);
    });
    const drop = keys.length - MAX_DOWNLOAD_RECORDS;
    for (let i = 0; i < drop; i++) {
      this.downloadRegistry.delete(keys[i]);
    }
    this.log.add(`下载注册表超过 ${MAX_DOWNLOAD_RECORDS} 条，已清理最旧 ${drop} 条`);
    return true;
  }

  /**
   * 校验下载记录与系统图库的实际状态。
   *
   * 图库删除会先进「最近删除」，此时 media URI 打开失败（常见 13900001），
   * 但 30 天内仍可恢复。因此不做物理删除，只打 missingSince 标记：
   * 绿点只按 active 记录计算，恢复后下一次校验清掉标记即可回来。
   */
  private async validateRegistry(): Promise<void> {
    const keys: string[] = [];
    this.downloadRegistry.forEach((_record: DownloadRecord, key: string) => {
      keys.push(key);
    });
    const now = Date.now();
    let markedMissing = 0;
    let restored = 0;
    let changed = false;
    const skipped: string[] = [];
    for (const key of keys) {
      const record = this.downloadRegistry.get(key);
      if (!record || !record.localPath) continue;
      const state = await this.checkRecordAvailability(record);
      if (state === true) {
        if (record.missingSince !== undefined) {
          record.missingSince = undefined;
          restored++;
          changed = true;
        }
      } else if (state === false) {
        if (record.missingSince === undefined) {
          record.missingSince = now;
          markedMissing++;
          changed = true;
        }
      } else {
        skipped.push(record.filename);
      }
    }
    // 超过图库「最近删除」保留期的记录不再可能恢复，清掉避免无限增长。
    const expired: string[] = [];
    this.downloadRegistry.forEach((record: DownloadRecord, key: string) => {
      if (record.missingSince !== undefined &&
          now - record.missingSince > MISSING_RETENTION_MS) {
        expired.push(key);
      }
    });
    for (const key of expired) {
      this.downloadRegistry.delete(key);
    }
    if (changed || expired.length > 0) {
      await this.compactRegistry();
    }
    if (markedMissing > 0) {
      this.log.add(`下载记录标记失效: ${markedMissing} 条（可能在“最近删除”）`);
    }
    if (restored > 0) {
      this.log.add(`下载记录恢复: ${restored} 条`);
    }
    if (expired.length > 0) {
      this.log.add(`下载记录清理: 移除 ${expired.length} 条超过 30 天的失效记录`);
    }
    if (skipped.length > 0) {
      this.log.add(`下载记录校验跳过 ${skipped.length} 条（未知错误）`);
    }
  }

  /**
   * 判断一条下载记录是否仍可在图库中访问。
   * 先试 URI；失败时再按 URI 查询媒体库，查询不可用则按错误码判断。
   */
  private async checkRecordAvailability(record: DownloadRecord): Promise<boolean | null> {
    try {
      const f = await fileIo.open(record.localPath, fileIo.OpenMode.READ_ONLY);
      await fileIo.close(f);
      return true;
    } catch (err) {
      const code = (err as BusinessError).code;
      const isMediaUri = record.localPath.startsWith('file://media/');
      const likelyGone = code === 13900002 ||
        (isMediaUri && (code === 13900001 || code === 13900012 || code === 201));
      if (!likelyGone) {
        return null;
      }
      const mediaFound = await this.queryMediaAsset(record.localPath);
      if (mediaFound !== null) {
        return mediaFound;
      }
      return false;
    }
  }

  /**
   * 按 URI 查询媒体库，判断资产是否仍存在。
   * 未声明 READ_IMAGEVIDEO 时可能失败；失败返回 null，由调用方退化为 URI 探测。
   */
  private async queryMediaAsset(uri: string): Promise<boolean | null> {
    if (this.mediaQuerySupported === false || this.context === null) {
      return null;
    }
    try {
      if (this.phAccessHelper === null) {
        this.phAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context);
      }
      const predicates = new dataSharePredicates.DataSharePredicates();
      predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
      const options: photoAccessHelper.FetchOptions = {
        predicates: predicates,
        fetchColumns: [photoAccessHelper.PhotoKeys.URI]
      };
      const result = await this.phAccessHelper.getAssets(options);
      const count = result.getCount();
      result.close();
      this.mediaQuerySupported = true;
      return count > 0;
    } catch (err) {
      const code = (err as BusinessError).code;
      this.mediaQuerySupported = false;
      this.log.add(`媒体库查询不可用: code=${code}`);
      return null;
    }
  }

  private async saveRegistry(): Promise<boolean> {
    const records: Record<string, DownloadRecord> = {};
    this.downloadRegistry.forEach((v: DownloadRecord, k: string) => {
      records[k] = v;
    });
    const file: DownloadRegistryFile = {
      version: 1,
      records: records
    };
    try {
      AtomicFile.writeText(this.registryPath(), JSON.stringify(file));
      this.registryVersion++;
      return true;
    } catch (err) {
      this.log.add(`保存下载记录失败: ${JSON.stringify(err)}`);
      return false;
    }
  }

  /** 快照写成功后删除 journal；写失败则保留，下次启动继续恢复。 */
  private async compactRegistry(): Promise<void> {
    const ok = await this.saveRegistry();
    if (ok) {
      AtomicFile.delete(this.registryJournalPath());
    }
  }

  /** 单条记录立即写 journal，避免批次被杀时整批下载历史丢失。 */
  private appendRegistryRecord(record: DownloadRecord): void {
    this.downloadRegistry.set(record.key, record);
    this.registryVersion++;
    try {
      const entry: DownloadJournalEntry = { key: record.key, record: record };
      AtomicFile.appendText(this.registryJournalPath(), JSON.stringify(entry) + '\n');
    } catch (err) {
      this.log.add(`下载记录 journal 写入失败: ${JSON.stringify(err)}`);
    }
  }

  private addDownloadRecord(record: DownloadRecord): void {
    // 从「最近删除」恢复后重新下载同一张时，覆盖旧记录的 URI 与缺失标记。
    this.appendRegistryRecord(record);
  }

  /**
   * 连接 Wi-Fi 相机（PTP/IP over TCP 15740）。
   *
   * 只负责建立会话、取设备身份；照片扫描复用 `scanForCamera()`——它会
   * 识别 `wireless` 并跳过 USB 枚举。
   *
   * 前置条件：手机与相机在同一网络。既可以是相机 STA 模式加入同一路由器，
   * 也可以是手机开热点、相机连热点。连接失败时优先检查：相机 Wi-Fi 是否
   * 开启、是否已完成「主机注册」、15740 端口是否可达。
   */
  async connectWifi(host: string, port: number = 15740, silent: boolean = false): Promise<boolean> {
    const target = host.trim();
    if (target === '') {
      this.reportScanFailure(L10n.tr('camera_status_wifi_empty_host'));
      return false;
    }
    // 一次 Wi-Fi 连接属于按下它那一刻的链路选择；中途切模式就作废。
    const epoch = this.linkEpoch;
    const attempt = ++this.wifiConnectSeq;
    this.wifiConnecting = true;
    try {
      return await this.connectWifiAttempt(target, port, silent, epoch);
    } finally {
      // 只让最后一次尝试关闭「连接中」：重叠的连接请求不能互相把状态清掉。
      if (this.wifiConnectSeq === attempt) this.wifiConnecting = false;
    }
  }

  /** `connectWifi()` 的主体；`wifiConnecting` 的起落由外层统一管理。 */
  private async connectWifiAttempt(target: string, port: number, silent: boolean,
                                   epoch: number): Promise<boolean> {
    if (this.connected) {
      await this.disconnect();
      if (!this.epochCurrent(epoch)) return false;
    }
    this.syncSessionMode();
    const wifi = this.makeWifiSession();
    this.wifiSession = wifi;
    const session = new PtpScheduler(wifi);
    this.session = session;
    this.wireless = true;
    this.wifiHost = target;
    this.wifiPort = port;
    this.connected = false;
    this.usable = false;
    this.statusText = L10n.tr('camera_status_wifi_connecting', target);

    const endpoint: PtpEndpoint = {
      kind: PtpEndpointKind.WIFI,
      host: target,
      port: port,
      label: target
    };
    const ok = await this.session.connect(endpoint, PtpPriority.FOREGROUND);
    // 连接期间用户切了模式：把刚建立的会话收掉，不把「已连接」写进新模式。
    if (!this.epochCurrent(epoch)) {
      await this.abortWifiConnect(session, wifi, target);
      return false;
    }
    if (!ok) {
      this.wireless = false;
      this.connected = false;
      this.wifiSession = null;
      this.session = new PtpScheduler(new PtpSession());
      if (!silent) {
        this.reportScanFailure(L10n.tr('camera_status_wifi_connect_failed', target));
      }
      return false;
    }

    this.connected = true;
    this.usable = false;
    this.statusText = L10n.tr('camera_status_connected');
    const deviceInfo = await this.session.getDeviceInfo();
    if (!this.epochCurrent(epoch)) {
      await this.abortWifiConnect(session, wifi, target);
      return false;
    }
    if (deviceInfo) {
      this.deviceManufacturer = deviceInfo.manufacturer;
      this.deviceSerialNumber = deviceInfo.serialNumber;
      this.deviceVersion = deviceInfo.deviceVersion;
      this.deviceOps = deviceInfo.operationsSupported ?? [];
      this.cameraIdentity = this.buildWifiCameraIdentity(deviceInfo, target);
      this.cameraName = deviceInfo.model || deviceInfo.manufacturer || target;
      this.log.add(`Wi-Fi DeviceInfo: manu="${deviceInfo.manufacturer}" model="${deviceInfo.model}" ` +
        `serial="${deviceInfo.serialNumber}"`);
    } else {
      this.cameraIdentity = `wifi_${target.replace(/[^a-zA-Z0-9_.-]/g, '_')}`;
      this.cameraName = target;
      this.log.add('Wi-Fi DeviceInfo 未取到，用地址作为身份');
    }
    this.log.add(`无线连接建立: ${target}:${port}，身份 ${this.cameraIdentity}`);
    // 地址落盘：下次冷启动 / 断线重连先试这个地址，不用每次都扫一遍网段。
    WifiLinkStore.getInstance().save(target, port, this.cameraName);
    this.wifiAutoReconnectArmed = true;
    this.wifiHint = '';
    this.wirelessFailed = '';
    this.wirelessStage = '';
    // Wi-Fi 已经接管照片通道：BLE 侧上一轮的失败/等待提示都属于过去时，
    // 留在页面上会变成「Wi-Fi 已连接，旁边还挂着蓝牙失败」。
    this.bleHint = '';
    this.lastScanError = '';
    this.bleCameras = [];
    this.suspendBleForWifi();
    this.startBleVisibilityProbe();

    // 相机在「连接向导」里等主机注册时，会先开 15740 让我们连上，再等
    // 0x952B/0x935A 确认；不确认就 10 秒后自己收线，且 Wi-Fi 配置不落盘。
    const code = await wifi.getPairingCode();
    if (!this.epochCurrent(epoch)) {
      await this.abortWifiConnect(session, wifi, target);
      return false;
    }
    if (code !== null) {
      this.pairingCode = code;
      this.pairingRequired = true;
      this.statusText = L10n.tr('camera_status_wifi_pairing', code);
      this.log.add(`相机要求配对，验证码 ${code}，等待用户核对后确认`);
      return true;
    }
    this.pairingRequired = false;
    this.pairingCode = '';
    this.checkCachingState();
    return true;
  }

  /**
   * 连接被切模式取消后的收尾：关掉这一次建立的会话，把共享状态复位。
   *
   * 只在 `this.session` 仍是这一次创建的会话时复位——新一轮可能已经建了
   * 自己的会话，不能把它的状态清掉。`suspendBleForWifi()` 已经跑过的话
   * 把 BLE 的自动重连还回去，新模式还要靠蓝牙唤醒相机。
   */
  private async abortWifiConnect(session: PtpTransport, wifi: WifiPtpSession,
                                 host: string): Promise<void> {
    this.log.add(`无线连接 ${host} 已被切模式取消`);
    this.stopBleVisibilityProbe();
    if (this.bleLink !== null) {
      this.bleLink.enableAutoReconnect();
    }
    try {
      await session.closeSessionAndPipe();
    } catch (_e) {
      // 还没连上就取消时 close 会报错，忽略即可
    }
    if (this.session === session) {
      this.session = new PtpScheduler(new PtpSession());
      this.wireless = false;
      this.connected = false;
      this.usable = false;
    }
    if (this.wifiSession === wifi) {
      this.wifiSession = null;
    }
    this.pairingRequired = false;
    this.pairingCode = '';
    this.wifiAutoReconnectArmed = false;
  }

  /**
   * 完成主机注册（0x935A，参数 0x2001）。
   *
   * Z50II 实测：相机在回响应之前就收线，随后用它保存的配置重开 Wi-Fi。
   * 所以这里不把断链当失败，等一拍后直接重连；重连后再探一次配对码，
   * 拿不到才算配对完成，并接着触发扫描。
   */
  async completeWifiPairing(): Promise<boolean> {
    const wifi = this.wifiSession;
    if (!wifi) {
      this.reportScanFailure(L10n.tr('camera_status_wifi_connect_failed', this.wifiHost));
      return false;
    }
    this.statusText = L10n.tr('camera_status_wifi_pairing_confirm');
    this.log.add('发送 CompletePairing');
    await wifi.completePairing();
    this.pairingRequired = false;
    this.pairingCode = '';
    this.connected = false;
    this.wireless = false;
    this.wifiSession = null;
    this.session = new PtpScheduler(new PtpSession());

    const host = this.wifiHost;
    const port = this.wifiPort;
    // 相机收线后要重启 Wi-Fi 服务才会重新监听 15740。Z50II 实测约 6–7 秒，
    // 只试一次必然抢跑；这里按退避自动重试，别把「再点一次」甩给用户。
    const delays: number[] = [2000, 3000, 5000, 8000, 12000];
    let ok = false;
    for (let i = 0; i < delays.length; i++) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, delays[i]);
      });
      if (i > 0) {
        this.statusText = L10n.tr('camera_status_wifi_reconnecting', i + 1);
      }
      ok = await this.connectWifi(host, port, true);
      if (ok) {
        this.log.add(`配对后第 ${i + 1} 次重连成功`);
        break;
      }
      this.log.add(`配对后第 ${i + 1} 次重连失败`);
    }
    if (ok && !this.pairingRequired) {
      this.statusText = L10n.tr('camera_status_wifi_pairing_done');
      this.scanForCamera(true, true);
    } else if (!ok) {
      this.reportScanFailure(L10n.tr('camera_status_wifi_pairing_timeout', host));
    }
    return ok;
  }

  /**
   * 搜索局域网内的相机（mDNS `_ptp._tcp`），结果写进 `wifiCameras`。
   *
   * 浏览持续 [durationMs] 后自动收起；期间发现的相机随时追加，用户点哪台
   * 就连哪台，不需要手填 IP。
   */
  async scanWifiCameras(durationMs: number = 8000): Promise<void> {
    const ctx = this.context;
    if (ctx === null || this.wifiScanning) return;
    const epoch = this.linkEpoch;
    const gen = ++this.wifiScanGen;
    this.wifiScanning = true;
    this.wifiScanEpoch = epoch;
    this.wifiCameras = [];
    this.wifiHint = '';
    // 先摸一遍本机网络：扫不到相机时，是「网络前提不成立」还是「相机没进
    // Wi-Fi 模式」，这一步决定了给用户哪句提示。
    const nets = await collectLocalNetworks();
    // 等网络快照期间切了模式：不再启动 mDNS / 网段扫描。
    if (!this.wifiScanAlive(gen, epoch)) return;
    this.wifiHint = networkHint(nets);
    this.log.add(`本机网络: ${nets.summary}`);
    if (this.nsdScanner === null) {
      this.nsdScanner = new NsdScanner(ctx,
        (camera: WifiCameraInfo) => {
          // 回调复用：只认「当前仍是 Wi-Fi 浏览，且仍属于当前链路选择」。
          if (this.wifiScanEpoch !== this.linkEpoch) return;
          this.mergeWifiCamera(camera, 'mDNS');
        },
        (name: string) => {
          if (this.wifiScanEpoch !== this.linkEpoch) return;
          this.wifiCameras = this.wifiCameras.filter((c: WifiCameraInfo) => c.name !== name);
        },
        (msg: string) => { this.log.add(msg); });
    }
    try {
      await this.nsdScanner.start();
    } catch (err) {
      this.log.add(`mDNS 启动失败: ${(err as Error).message}`);
    }
    if (!this.wifiScanAlive(gen, epoch)) return;

    // mDNS 被客户端隔离挡掉时一个都收不到，同时跑一遍 /24 端口扫描兜底。
    if (this.subnetScanner === null) {
      this.subnetScanner = new SubnetScanner((msg: string) => { this.log.add(msg); });
    }
    const mdnsWindow = new Promise<void>((resolve: () => void) => {
      if (this.wifiScanTimer >= 0) clearTimeout(this.wifiScanTimer);
      this.wifiScanResolve = resolve;
      this.wifiScanTimer = setTimeout(() => {
        this.wifiScanTimer = -1;
        this.wifiScanResolve = null;
        resolve();
      }, durationMs);
    });
    const subnetWork = this.subnetScanner.scan().then((found: WifiCameraInfo[]) => {
      if (!this.wifiScanAlive(gen, epoch)) return;
      for (const camera of found) {
        this.mergeWifiCamera(camera, '网段扫描');
      }
    }).catch((err: Error) => {
      this.log.add(`网段扫描失败: ${err.message}`);
    });
    await Promise.all([mdnsWindow, subnetWork]);
    // 这一轮已被切模式取消，或者已经开了新一轮：本轮收尾什么都不写。
    if (!this.wifiScanAlive(gen, epoch)) {
      this.log.add('Wi-Fi 搜索已被切模式取消');
      return;
    }
    this.wifiScanning = false;
    this.wifiScanEpoch = -1;
    this.wifiScanResolve = null;
    if (this.wifiCameras.length === 0 && this.wifiHint === '') {
      // 网络前提成立却一台都没找到：问题在相机那边（没进 Wi-Fi 模式、
      // 被客户端隔离、或相机把上一个会话还挂在 15740 上）。
      this.wifiHint = '同一网络里没有发现相机。确认相机已进入「连接至智能设备」的 Wi-Fi 模式。';
    }
  }

  /** 这一轮 Wi-Fi 搜索是否仍是「当前链路选择 + 当前这一轮」。 */
  private wifiScanAlive(gen: number, epoch: number): boolean {
    return this.wifiScanning && this.wifiScanGen === gen && this.epochCurrent(epoch);
  }

  /**
   * 扫一段，**一发现相机就提前收工**。
   *
   * 网段扫描一轮要三十秒（507 个候选 × 700ms / 12 并发）。自动接续如果等满
   * 整轮，用户会以为卡住了；而 mDNS 命中往往只要一两秒。所以按 500ms 轮询，
   * 一看到相机就停扫、立刻去连。
   */
  private async scanUntilCamera(maxWaitMs: number): Promise<WifiCameraInfo | null> {
    const scan = this.scanWifiCameras(6000);
    const deadline = Date.now() + maxWaitMs;
    let found: WifiCameraInfo | null = null;
    while (Date.now() < deadline) {
      found = this.pickWifiCamera();
      if (found !== null) break;
      if (!this.wifiScanning) break;
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 500);
      });
    }
    if (found !== null) {
      this.log.add(`自动无线: 提前收工，命中 ${found.name}`);
      this.stopWifiScan();
    }
    await scan;
    return found !== null ? found : this.pickWifiCamera();
  }

  private mergeWifiCamera(camera: WifiCameraInfo, source: string): void {
    if (this.wifiCameras.some((c: WifiCameraInfo) =>
      c.name === camera.name || c.host === camera.host)) {
      return;
    }
    this.wifiCameras = this.wifiCameras.concat([camera]);
    this.log.add(`${source} 发现相机: ${camera.name} @ ${camera.host}:${camera.port}`);
  }

  /** 停止 mDNS 浏览、取消网段扫描并清掉计时器。 */
  stopWifiScan(): void {
    if (this.nsdScanner !== null) {
      this.nsdScanner.stop();
    }
    if (this.subnetScanner !== null) {
      this.subnetScanner.cancel();
    }
    if (this.wifiScanTimer >= 0) {
      clearTimeout(this.wifiScanTimer);
      this.wifiScanTimer = -1;
    }
    // 必须把窗口 promise 兑现：只清计时器会让 `await scanWifiCameras()`
    // 永远等下去（自动接续就卡在这儿）。
    const resolve = this.wifiScanResolve;
    this.wifiScanResolve = null;
    if (resolve !== null) {
      resolve();
    }
    this.wifiScanEpoch = -1;
    this.wifiScanning = false;
  }

  /** 申请蓝牙权限（ACCESS_BLUETOOTH 是 user_grant，首次会弹系统框）。 */
  private async ensureBlePermission(): Promise<boolean> {
    const ctx = this.context;
    if (ctx === null) return false;
    try {
      const at = abilityAccessCtrl.createAtManager();
      const result = await at.requestPermissionsFromUser(ctx, ['ohos.permission.ACCESS_BLUETOOTH']);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (err) {
      this.log.add(`BLE 权限申请失败: ${(err as Error).message}`);
      return false;
    }
  }

  /** 搜索 BLE 相机（实验）。只发现，不配对。 */
  async scanBleCameras(durationMs: number = 8000): Promise<void> {
    if (this.bleScanning) return;
    // 权限弹窗可能要等用户点很久；期间切了模式就不要再开一轮新扫描。
    const epoch = this.linkEpoch;
    if (!await this.ensureBlePermission()) {
      // 权限框关掉时可能已经切了模式：别把「没有蓝牙权限」写到新模式头上。
      if (this.epochCurrent(epoch)) {
        this.reportScanFailure(L10n.tr('camera_status_ble_permission'));
      }
      return;
    }
    if (!this.epochCurrent(epoch)) {
      this.log.add('BLE 搜索已被切模式取消');
      return;
    }
    this.bleScanning = true;
    this.bleScanEpoch = epoch;
    this.bleCameras = [];
    if (this.bleScanner === null) {
      this.bleScanner = new BleScanner(
        (device: BleCameraDevice) => {
          // 回调只创建一次，不能捕获某一轮的 epoch；用字段对当前链路代次。
          if (this.bleScanEpoch !== this.linkEpoch) return;
          if (!this.bleCameras.some((d: BleCameraDevice) => d.deviceId === device.deviceId)) {
            this.bleCameras = this.bleCameras.concat([device]);
          }
          // 扫到一台已经配对过的相机：别让用户从列表里再点一次、更别走首配
          // （相机那边还记着这份身份，全新 stage1 会被秒拒）。
          this.connectIfPaired(device);
        },
        (msg: string) => { this.log.add(msg); },
        0,
        // 用户按「搜索相机」正盯着页面等结果：这一轮用低延迟扫描，
        // 8 秒窗口内就该把相机报上来（默认低功耗档常常要等好几秒）。
        true);
    }
    this.bleScanner.start();
    if (this.bleScanTimer >= 0) clearTimeout(this.bleScanTimer);
    this.bleScanTimer = setTimeout(() => {
      this.bleScanTimer = -1;
      // 旧窗口的计时器不能停掉新模式刚开的扫描。
      if (this.bleScanEpoch !== this.linkEpoch) return;
      if (this.bleScanner !== null) this.bleScanner.stop();
      this.bleScanning = false;
    }, durationMs);
  }

  /**
   * 扫描命中的相机如果已经配对过，直接按保存的身份连上。
   *
   * 只有「蓝牙」模式这么做：那个模式的主操作就是「连回这台相机」，让用户从
   * 列表里再点一次没有意义，更不能走首配（相机那边还记着这份身份，全新的
   * stage1 会被 `Remote device has an error` 秒拒）。AP / STA 的扫描是在找一台
   * **新**相机（配对完还要交接热点），仍然留给用户在列表里选。
   */
  private connectIfPaired(device: BleCameraDevice): void {
    if (this.linkMode !== CameraLinkMode.BLE) return;
    if (this.bleConnecting || this.bleConnected) return;
    if (this.bleScanEpoch !== this.linkEpoch) return;
    const store = SavedCameraStore.getInstance();
    const rec = store.findReal(cameraSerialFromBleName(device.name), device.name);
    if (rec === null || rec.identityDevice === 0) return;
    this.log.add(`BLE 扫描命中已配对相机（${device.name}），按保存的身份直接连接`);
    store.activate(rec.key);
    // `connectBle()` 自己会停掉扫描，同时把 `bleConnecting` 置上，
    // 同一次广播里重复进来的回调因此不会并发连两遍。
    // 蓝牙模式只是待机（校时 / 定位），不写 0x2005：相机一旦被推到 Wi-Fi 模式，
    // 刚建立的 BLE 链路立刻就掉了。
    this.connectBle(device.deviceId, device.name, false, false).catch((err: Error) => {
      this.log.add(`BLE 连接失败: ${err.message}`);
    });
  }

  /** 停止 BLE 扫描。 */
  stopBleScan(): void {
    if (this.bleScanner !== null) this.bleScanner.stop();
    if (this.bleScanTimer >= 0) {
      clearTimeout(this.bleScanTimer);
      this.bleScanTimer = -1;
    }
    this.bleScanEpoch = -1;
    this.bleScanning = false;
  }

  /** 连接一台 BLE 相机并列出 GATT 服务（验证 BLE 通道用）。 */
  /**
   * @param handOver 连上 BLE 之后要不要把相机推到 Wi-Fi 模式（写 `0x2005=0x01`）。
   *   用户主动选相机时为 true；App 冷启动的自动连接为 false —— 只做 BLE 待机，
   *   把「切无线」留给用户明确要照片的那一刻。
   */
  /**
   * 连 BLE 并走完配对。
   *
   * [handOver] 决定配对收口时是否把相机推到 Wi-Fi；[silent] 决定失败时要不要
   * 往页面写红色错误 + 弹 toast。冷启动的自动连接是后台行为，用户没点任何东西，
   * 失败只记日志——以前每次开机都红着一行「蓝牙连接相机失败」。
   */
  /**
   * @param armWatch 失败后要不要转入「等相机回来」的后台循环。默认要；
   *   `autoConnectBle()` 自己还要接着扫一轮时会传 false，扫完统一开——两边同时
   *   开扫描会互相 `stopBLEScan()`，白扫一整窗（2026-11-14 实测）。
   */
  async connectBle(deviceId: string, deviceName: string = '',
                   handOver: boolean = true, silent: boolean = false,
                   armWatch: boolean = true): Promise<boolean> {
    if (this.bleConnecting) {
      this.log.add('BLE 正在连接中，忽略重复点击');
      return false;
    }
    const epoch = this.linkEpoch;
    this.bleConnectSeq = this.bleConnectSeq + 1;
    const seq = this.bleConnectSeq;
    this.stopBleScan();
    // 主动连接期间先停掉「等相机回来」的循环：两条路同时建链路会撞在同一个
    // BLE 特征上（17:47 实测：两条「BLE 直连」各连了一次，第二次订阅被拒）。
    if (this.bleLink !== null) this.bleLink.pauseReconnectWatch();
    this.bleConnecting = true;
    this.bleConnected = false;
    this.bleAsleep = false;
    this.bleServices = [];
    try {
      if (this.bleLink === null) {
        this.bleLink = new BleCameraLink(
          (msg: string) => { this.log.add(msg); },
          (connected: boolean) => {
            this.bleConnected = connected;
            if (!connected) {
              this.bleServices = [];
              this.bleSerial = '';
              // **不要在这里停位置注入**：相机半睡时链路十几秒就断一次，一断就
              // 退订的话，连续定位永远等不到第一拍（1.66.18 真机日志：整段会话
              // 只有一次 0x2007，之后每次重连都从零开始）。注入的生命周期跟着
              // 「用户还连着这台相机」，由 disconnectBle / 交接 Wi-Fi 去收。
            }
            // 后台时蓝牙链路的断/连会影响「要不要保活」。
            this.syncBackgroundTask();
          });
        // 重连节奏按当前前后台状态起算：冷启动时一般在前台。
        this.bleLink.setForeground(this.appForeground);
      }
      this.bleCameraName = deviceName;
      const ok = await this.bleLink.connect(deviceId);
      // 连接期间切了模式：这次 BLE 连接属于上一模式，立刻收掉。
      if (!this.epochCurrent(epoch)) {
        this.log.add('BLE 连接已被切模式取消（连接阶段）');
        await this.dropCancelledBleLink();
        return false;
      }
      if (this.bleConnectSeq !== seq) {
        // 用户取消：不给红色失败、不开「等相机回来」，界面已经回到未连接。
        this.log.add('BLE 连接已取消（用户）');
        return false;
      }
      if (!ok) {
        this.bleServices = [];
        if (silent) {
          this.log.add('BLE 自动连接失败（静默，不打扰页面）');
        } else {
          this.reportScanFailure(L10n.tr('camera_status_ble_connect_failed'));
        }
        if (armWatch) this.keepWaitingForCamera();
        return false;
      }
      this.bleConnected = true;
      // **不在这里枚举服务表**（1.66.7）：它纯粹是日志用的，而相机半睡时
      // `getServices()` 能挂 10 秒并卡住 JS 主线程（2026-11-14 17:41 的
      // THREAD_BLOCK_3S 闪退）。握手里有 `ensureServices()`，需要时它自己查一次。
      // 服务枚举完直接走两段式配对（相机需停在「开始配对」页）。
      // 广播名要传给配对层：经典蓝牙绑定时靠它匹配相机。
      // 三个条件缺一不可：
      // 1. 这次调用真的要交接（用户主动选相机，不是冷启动/自动重连）；
      // 2. 无线会话没在跑（跑了再推一次会把正在传的 PTP 掐断）；
      // 3. 不在冷却期内（BLE/Wi-Fi 互斥，来回推会让相机在两个模式间乒乓）。
      const wantHandover = handOver && !(this.connected && this.wireless);
      const canHandover = wantHandover && this.handoverAllowed();
      if (wantHandover && !canHandover) {
        this.log.add('BLE 待机：交接冷却中，这次不把相机推到 Wi-Fi 模式');
      }
      // 没有落盘身份 = 这一次走的是「首配」。相机端如果还记着这台手机，
      // 全新的 stage1 会被 `Remote device has an error` 秒拒，那时必须让用户
      // 先去相机菜单里删掉本机——这不是重试能解决的。
      const freshPairing = !BleIdentityStore.getInstance().hasIdentity();
      const serial = await this.bleLink.pair(deviceName, canHandover);
      // 配对期间切了模式：相机那边可能已经认了这台手机，但这次流程到此为止，
      // 不再继续交接、也不把「配对成功」写进新模式。
      if (!this.epochCurrent(epoch)) {
        this.log.add('BLE 配对已被切模式取消');
        await this.dropCancelledBleLink();
        return false;
      }
      if (this.bleConnectSeq !== seq) {
        this.log.add('BLE 配对已取消（用户）');
        return false;
      }
      if (canHandover) {
        this.lastHandoverAt = Date.now();
      }
      if (serial === null) {
        this.bleSerial = '';
        if (freshPairing) this.bleHint = L10n.tr('camera_ble_hint_repair');
        this.log.add('BLE 配对失败（相机可能不在「开始配对」页，或已配对过）');
        if (armWatch) this.keepWaitingForCamera();
        return false;
      }
      this.bleSerial = serial;
      this.bleHint = '';
      this.bleAsleep = false;
      this.bleRecovering = false;
      // 待机连上了：上一次按需浏览的失败结论（比如交接冷却）不再适用于当前状态。
      if (this.linkMode === CameraLinkMode.BLE) this.wirelessFailed = '';
      // 已经连上了，之前「搜到的那几台」不再有意义：留着会在状态头下面
      // 一直挂一张相机列表（用户反馈 1.66.3）。
      this.bleCameras = [];
      SavedCameraStore.getInstance().rememberActive();
      this.log.add(`BLE 配对成功，相机序列号 ${serial}`);

      // 断链自动重连：相机会休眠，链路断了自己爬起来（用保存的身份复用握手）。
      this.bleLink.onReconnected = (serial: string) => {
        this.bleSerial = serial;
        this.bleConnected = true;
        this.bleReconnecting = false;
        this.bleAsleep = false;
        this.syncBackgroundTask();
        SavedCameraStore.getInstance().rememberActive();
        this.log.add(`BLE 已自动重连（序列号 ${serial}）`);
        this.startBleKeepalive(0);
        // 重连只恢复待机（校时/GPS）。**不要**在这里补写 0x2005：
        // 相机刚从 Wi-Fi 回落才连得上，再推一次就又把它踢走（乒乓）。
      };
      this.bleLink.onReconnecting = (reconnecting: boolean) => {
        this.bleReconnecting = reconnecting;
        if (!reconnecting) this.bleAsleep = false;
        this.syncBackgroundTask();
      };
      this.bleLink.onReconnectStalled = () => {
        if (this.bleAsleep) return;
        this.bleAsleep = true;
        this.log.add('BLE 重连扫不到相机：判定相机已休眠（唤醒后会自动连回来）');
      };
      this.bleLink.enableAutoReconnect();
      // 配对成功后才允许写 0x2006/0x2007：先校时，再按 45s 保活（顺带持续校时）。
      // 首笔要等 2.5 秒（ZPill 的 writeGate）：相机刚收口时注入会话还没醒，
      // 立刻写会被拒收甚至被踢链。
      this.startBleKeepalive(2500);
      if (canHandover) {
        // 已经把相机推到 Wi-Fi 模式：按当前模式接着收口。
        this.afterHandover(epoch).catch((err: Error) => {
          this.log.add(`交接收口失败: ${err.message}`);
        });
      }
      return true;
    } finally {
      // 切模式时 `cancelInFlightLink()` 已经把标记清掉；用户取消后马上又重新
      // 连、或者新一轮已经开始时，旧流程不能把它的 `bleConnecting` 抹成 false。
      if (this.epochCurrent(epoch) && this.bleConnectSeq === seq) {
        this.bleConnecting = false;
      }
    }
  }

  /**
   * 一次被切模式取消的 BLE 连接，收掉自己那条链路。
   *
   * 不能无脑 `disconnect()`：`setLinkMode()` 会把 `bleConnecting` 放掉，用户
   * 可能已经在新模式里开始了下一轮连接；同一个 `bleLink` 被新一轮占用时，
   * 旧流程的收尾不能把它一起断掉。
   */
  private async dropCancelledBleLink(): Promise<void> {
    if (this.bleLink === null) return;
    if (this.bleConnecting) {
      this.log.add('BLE 旧连接收尾：新一轮已开始，不再动链路');
      return;
    }
    await this.bleLink.disconnect();
  }

  /**
   * 原地起保活 + 注入（首次连接延迟首写门，自动重连时立刻恢复）。
   *
   * 1.66.17 起位置不再直接读 `GpsRecorder.lastFix`：定位记录默认是关的，
   * `lastFix` 恒为 null，0x2007 一次都没发出去过（真机日志实证）。现在改由
   * [BleGeoFeed] 供位置——定位记录开着就借它的点，没开就自己订阅一个。
   */
  private startBleKeepalive(delayMs: number): void {
    const apply = (): void => {
      if (this.bleLink === null) return;
      this.geoReadbackDone = false;
      const injectPrefs = BleInjectStore.getInstance();
      const offsetMinutes = -new Date().getTimezoneOffset();
      const writeTime = injectPrefs.clockSync;
      const inject = injectPrefs.locationInject;
      if (inject) {
        BleGeoFeed.getInstance().start().then((ok: boolean) => {
          this.log.add(ok ? '蓝牙位置注入：定位源就绪'
            : '蓝牙位置注入：拿不到定位，只对时（先检查定位权限与系统定位开关）');
          // 定位源起来了：后台长时任务要从「蓝牙」换成「定位」，后台才能继续定位。
          if (ok) this.refreshBackgroundTaskMode();
        }).catch((_e: Error) => {
          // start() 内部已经把原因写进日志
        });
      }
      try {
        this.bleLink.startKeepalive({
          intervalMs: BLE_KEEPALIVE_MS,
          offsetMinutes: offsetMinutes,
          writeTime: writeTime,
          fixProvider: (): BleGeoFix | null =>
            inject ? BleGeoFeed.getInstance().lastFix() : null,
          onLog: (message: string) => { this.log.add(message); },
          onGeoWritten: () => {
            if (this.geoReadbackDone) return;
            this.geoReadbackDone = true;
            setTimeout(() => { this.verifyCameraGeo(); }, 1500);
          }
        });
        this.log.add(`BLE 保活已启动（${BLE_KEEPALIVE_MS / 1000}s 一拍，`
          + `对时${writeTime ? '开' : '关'}，位置注入${inject ? '开' : '关'}）`);
      } catch (err) {
        this.log.add(`BLE 保活启动失败: ${(err as Error).message}`);
      }
      // 对时到底成没成：写完之后读回相机自己的 0x2006，结论写进日志。
      if (writeTime) {
        setTimeout(() => { this.probeCameraLss(); }, 4000);
      }
    };
    if (delayMs <= 0) {
      apply();
      return;
    }
    setTimeout(apply, delayMs);
  }

  /**
   * 读回相机侧的 LSS 数据（诊断用，失败不影响对时/注入）。
   *
   * 三读一组：0x200b 序列号证明「读这条通道是通的」，0x2006 是相机时钟，
   * 0x2007 是相机保存的位置。三个结果一起看就能分清「相机不给读」还是
   * 「我们没写进去」——1.66.17 只打了一句「读不到」，判断不了。
   */
  private async probeCameraLss(): Promise<void> {
    const link = this.bleLink;
    if (link === null) return;
    const serial = await link.readSerial();
    this.log.add(serial.value === null
      ? `LSS 诊断：0x200b 读失败（${serial.error}）`
      : `LSS 诊断：0x200b = ${BleCameraLink.describeBytes(serial.value)}`);
    if (serial.value === null) return;
    const time = await link.readTime();
    this.log.add(time.value === null
      ? `LSS 诊断：0x2006 读失败（${time.error}）`
      : `LSS 诊断：相机时钟 ${BleTimePayload.describe(time.value)}`);
  }

  /** 写完一帧位置后读回 0x2007：全 0 = 相机没记下来，跟我们一致 = 存住了。 */
  private async verifyCameraGeo(): Promise<void> {
    const link = this.bleLink;
    if (link === null) return;
    const geo = await link.readGeo();
    if (geo.value === null) {
      this.log.add(`LSS 诊断：0x2007 读失败（${geo.error}）`);
      return;
    }
    const v = geo.value;
    let nonZero = false;
    for (let i = 0; i < v.length; i++) {
      if (v[i] !== 0) {
        nonZero = true;
        break;
      }
    }
    this.log.add(`LSS 诊断：0x2007 回读 ${v.length}B`
      + (nonZero ? ` ${BleCameraLink.describeBytes(v.slice(0, 16))}` : ' 全 0（相机没存）'));
  }

  /** BLE 让位 / 断开时收掉位置注入，别陪着一条已经不存在的链路耗电。 */
  private stopBleGeoFeed(): void {
    const feed = BleGeoFeed.getInstance();
    if (feed.isRunning()) feed.stop();
  }

  /**
   * 一台**已配对**的相机这次没连上（多半是睡着了）：把「等它回来」的循环开起来。
   *
   * 没有这一步，失败路径就到此为止——用户看到的是「已配对 + 连接相机」，
   * 相机唤醒之后什么都不会发生，得自己再点一次。首配失败不走这里：
   * 那台相机还没有身份，等它也没用。
   */
  private keepWaitingForCamera(): void {
    if (this.bleLink === null) return;
    if (!BleIdentityStore.getInstance().hasIdentity()) return;
    this.log.add('BLE 没连上：转入后台等待相机重新广播');
    this.bleLink.wakeReconnectWatch();
  }

  /**
   * 把已配对相机的蓝牙身份装回「活动身份」。
   *
   * `BleIdentityStore` 只存**一台**的身份（底层很多代码直接读它），完整的多相机
   * 身份在 `SavedCameraStore` 里。身份被清掉不等于相机没配过对——只要仓库里还有
   * 这台相机的 device/nonce，装回来就能走复用握手，不用再让用户去相机上重新配对。
   *
   * 1.66.0 踩过：模拟相机的记录占用了真机序列号，冷启动 `activate()` 顺手清空了
   * 身份，于是「已配对」变「未连接」，重连只能首配，而相机那边还记着这台手机，
   * 首配被 `Remote device has an error` 秒拒。
   *
   * @returns 现在有可用身份就返回 true。
   */
  private adoptSavedBleIdentity(): boolean {
    const active = BleIdentityStore.getInstance();
    if (active.hasIdentity()) return true;
    const store = SavedCameraStore.getInstance();
    const rec = store.pickReal();
    if (rec === null || rec.identityDevice === 0) return false;
    store.activate(rec.key);
    this.log.add(`蓝牙身份: 从已配对相机的记录装回（${rec.cameraName}）`);
    return BleIdentityStore.getInstance().hasIdentity();
  }

  /**
   * App 启动 / 回前台时自动接上已配对的相机。
   *
   * 相机休眠时 BLE 仍可连，握手阶段的 stage1 重发负责把它唤醒。
   *
   * @param silent 连不上时不往页面上报失败。
   * @param quiet **冷启动那一次**专用的「完全不留痕」：失败后回到未连接——不报错、
   *   不进「等相机回来」、不留「正在重连/已休眠」。这次连接不是用户发起的，他
   *   想连的时候自己会点「连接相机」；把失败摆到屏幕上只会让人以为要处理什么。
   */
  async autoConnectBle(silent: boolean = true, quiet: boolean = false): Promise<boolean> {
    if (this.bleConnected || this.bleConnecting) return this.bleConnected;
    const epoch = this.linkEpoch;
    this.adoptSavedBleIdentity();
    const store = BleIdentityStore.getInstance();
    if (!store.hasIdentity() || store.deviceId.length === 0) {
      // 没有 BLE 身份不代表无线也连不上：上次连过的无线地址还在，值得先试
      // 一次（用户可能只想要相册，不需要蓝牙保活/地理标记）。
      if (await this.autoLinkWifi('cold-start-no-ble', false)) return false;
      if (quiet) await this.resetColdStartTraces();
      return false;
    }
    this.log.add(`BLE 自动连接已配对相机（${store.cameraName}）（仅待机，不切无线）`);
    if (await this.connectBle(store.deviceId, store.cameraName, false, silent, false)) {
      return this.epochCurrent(epoch);
    }
    if (!this.epochCurrent(epoch)) return false;
    // 相机每轮广播都换随机地址，上次存的地址可能已经失效；按尼康 deviceId
    // 重扫一次（休眠相机的广播没有名字，只能靠厂商数据认）。
    this.log.add('BLE 直连未成，按设备号重扫相机');
    const devices = await this.scanForNikonDeviceId(store.identityDevice, 6000);
    if (!this.epochCurrent(epoch)) return false;
    for (const dev of devices) {
      if (await this.connectBle(dev.deviceId, dev.name, false, silent, false)) {
        return this.epochCurrent(epoch);
      }
      if (!this.epochCurrent(epoch)) return false;
    }
    // BLE 这条路彻底不通时，无线这半条仍单独试一次（比如蓝牙被系统关了、
    // 但手机还挂在相机所在的热点上）。
    if (await this.autoLinkWifi('cold-start-ble-failed', false)) return false;
    if (!this.epochCurrent(epoch)) return false;
    if (quiet) {
      // 冷启动的自动连接不是用户发起的：失败就彻底安静地回到未连接。
      await this.resetColdStartTraces();
      this.log.add('BLE 自动连接未成：安静回到未连接（不进入重连等待）');
      return false;
    }
    // 这一轮全都没成：现在才开「等相机回来」的循环，避免和上面的扫描抢射频。
    this.keepWaitingForCamera();
    return false;
  }

  /**
   * 把一次「冷启动自动连接」失败留下的痕迹清干净（1.66.13）。
   *
   * 页面的状态头、提示行、错误行全部由这些字段派生：只要它们还在，一次用户
   * 根本没发起的尝试就会在屏幕上留下「连接失败 / 正在重新连接 / 相机可能已休眠」。
   * 这里统一清掉，并关掉可能已经建了一半的 GATT 链路，让页面回到「未连接」。
   */
  private async resetColdStartTraces(): Promise<void> {
    // **先清页面状态，再去收链路**：链路收尾可能要等服务发现落地（几秒），
    // 让它先跑就等于把「安静回到未连接」拖到几秒之后。
    this.bleConnecting = false;
    this.bleConnected = false;
    this.bleReconnecting = false;
    this.bleAsleep = false;
    this.bleCameras = [];
    this.bleServices = [];
    this.bleHint = '';
    this.bleSerial = '';
    this.lastScanError = '';
    this.wirelessFailed = '';
    this.wifiHint = '';
    this.wirelessStage = '';
    this.wifiAutoConnecting = false;
    this.wifiReconnecting = false;
    this.syncBackgroundTask();
    if (this.bleLink === null) return;
    try {
      await this.bleLink.disconnect();
    } catch (_e) {
      // 关不掉也不影响页面
    }
  }

  /** 按尼康 deviceId 扫一段时间的相机（会自己停）。 */
  private async scanForNikonDeviceId(nikonDeviceId: number,
                                     durationMs: number): Promise<BleCameraDevice[]> {
    return new Promise<BleCameraDevice[]>((resolve: (v: BleCameraDevice[]) => void) => {
      const found: BleCameraDevice[] = [];
      const scanner = new BleScanner(
        (dev: BleCameraDevice) => { found.push(dev); },
        (msg: string) => this.log.add(msg),
        nikonDeviceId,
        true);
      scanner.start();
      setTimeout(() => {
        scanner.stop();
        resolve(found);
      }, durationMs);
    });
  }

  /** 断开 BLE（连接还在进行中时等同「取消连接」）。 */
  async disconnectBle(): Promise<void> {
    if (this.bleConnecting) {
      await this.cancelBleConnect();
      return;
    }
    this.disconnecting = true;
    try {
      await this.disconnectBleInternal();
    } finally {
      this.disconnecting = false;
    }
  }

  /**
   * 用户取消正在进行的 BLE 连接（含首配的两段式握手）。
   *
   * **点一下就必须有反应**：先把界面放掉（`bleConnecting` 立刻归位），再去收
   * 链路。链路自己超时要 10 秒以上，等它等于让用户对着一个没反应的按钮干看。
   * 在途的 `connectBle()` 会在下一个 await 之后看到取消标记，安静退出。
   */
  async cancelBleConnect(): Promise<void> {
    if (!this.bleConnecting) return;
    // 让在途的那一轮看到序号对不上，安静退出（不报失败、不再写状态）。
    this.bleConnectSeq = this.bleConnectSeq + 1;
    this.log.add('BLE 连接已取消（用户）');
    this.bleConnecting = false;
    this.bleConnected = false;
    this.bleReconnecting = false;
    this.bleAsleep = false;
    this.bleCameras = [];
    this.bleHint = '';
    this.bleServices = [];
    this.bleSerial = '';
    this.syncBackgroundTask();
    if (this.bleLink === null) return;
    try {
      await this.bleLink.disconnect();
    } catch (_e) {
      // 取消本来就是收尾，链路关不掉也不影响界面
    }
  }

  private async disconnectBleInternal(): Promise<void> {
    // 用户显式断开：先撤掉无线侧的自动重连，免得刚点完「断开」又被接回来。
    this.wifiAutoReconnectArmed = false;
    this.cancelWifiReconnect();
    if (this.bleLink !== null) {
      // 无线会话还在用的时候不能写 0x2005=0x80：STA 模式下这一笔会让相机
      // 退出网络，顺手把正在用的 PTP 会话也断掉。只在「只连着蓝牙」时关。
      // 还没配对成功（`bleSerial` 为空）时也不写：那时相机根本不认这个会话，
      // 这一笔只会白等 5 秒超时。
      if (!this.wireless && this.bleSerial !== '') {
        await this.bleLink.closeCameraWifi();
      }
      await this.bleLink.disconnect();
    }
    this.bleConnected = false;
    this.bleReconnecting = false;
    this.bleAsleep = false;
    this.bleServices = [];
    this.bleSerial = '';
    this.stopBleGeoFeed();
    // 用户主动断开：后台不必再为蓝牙保活。
    this.syncBackgroundTask();
    // 取消连接/配对失败留下的提示不再成立
    this.bleHint = '';
    this.bleCameras = [];
    this.wirelessFailed = '';
  }

  /** 只取网络快照，不做搜索；进 STA 模式时用。 */
  private async refreshNetworkSnapshot(): Promise<void> {
    try {
      const nets = await collectLocalNetworks();
        this.wifiHint = networkHint(nets);
      this.log.add(`本机网络: ${nets.summary}`);
    } catch (_e) {
      // 拿不到网络信息不影响页面，后续搜索时会再试一次
    }
  }

  /**
   * 启动时把上次认出的机型读回来，立牌先摆上再等连接。
   *
   * 没连过 PTP 也要能摆：BLE 首配时已经把广播名（`Z50_2_8079350`）与序列号
   * 存进 `BleIdentityStore` 了，这里直接拿来做一次兜底识别。
   */
  initCameraModel(): void {
    const store = CameraModelStore.getInstance();
    // `camera_model` 是「上次认出过的机型」，属于展示缓存，不是身份。仓库里一台
    // 相机都没有时不能拿它当标题：页面上会一边写「未连接 + 搜索相机」，一边把
    // 一台已不存在的相机型号和序列号挂在标题栏（1.66.1 用户指出）。
    // `MainScreen` 已先初始化过 `SavedCameraStore`，这里的 `current()` 是迁移之后的结果。
    if (SavedCameraStore.getInstance().current() === null) {
      store.clear();
      this.cameraModel = '';
      return;
    }
    if (store.key !== '') {
      this.cameraModel = store.key;
    }
    const ble = BleIdentityStore.getInstance();
    if (this.cameraModel === '') {
      const key = cameraStandeeKey(ble.cameraName);
      if (key !== '') {
        this.cameraModel = key;
        store.set(key);
      }
    }
    // 广播名尾段就是官方那串序列号；早先版本误存过 BLE stage4 的另一串，这里覆盖
    const sn = cameraSerialFromBleName(ble.cameraName);
    if (sn !== '') store.setSerial(sn);
    // 迁移时 CameraModelStore 可能还没恢复完；这里补一次当前保存相机的机型/序列号。
    SavedCameraStore.getInstance().updateCurrentMeta(this.cameraModel, store.serial);
  }

  /**
   * 认机型：PTP 的 `cameraName` 优先，没有就退回 BLE 广播名。
   *
   * 两者格式不同但都带型号：PTP 是 `Z50_2`，BLE 是 `Z50_2_8079350`
   * （`<型号>_<序号>`），归一化后都是 `Z502…`，同一个 needle 就能命中。
   * 只有蓝牙在连、还没走 PTP 时也能立刻把立牌摆出来。
   *
   * 断开时两个字段都会被清成 `''`，这里刻意不在那种情况下清 `cameraModel`：
   * 立牌要留着（变暗），否则每次断开页面都要塌一块。
   *
   * 但**连着却认不出机型**（Z fc / ZR 这类没有商品图的机器，或调试包选的
   * 「未知型号」）必须把上一台的立牌清掉：继续摆另一台相机的图和型号名，等于
   * 告诉用户「连的是那台」，比没有立牌更糟。判断边界是 `raw !== ''`——断开时
   * raw 为空，走的是上面「保留」那条。
   */
  @Monitor('cameraName', 'bleCameraName')
  onCameraIdentified(): void {
    const raw = this.cameraName !== '' ? this.cameraName : this.bleCameraName;
    const key = cameraStandeeKey(raw);
    if (key === '') {
      if (raw !== '' && this.cameraModel !== '') {
        this.cameraModel = '';
        CameraModelStore.getInstance().set('');
        this.log.add(`相机立牌: ${raw} → 认不出机型，清掉立牌`);
      }
      return;
    }
    if (key === this.cameraModel) return;
    this.cameraModel = key;
    CameraModelStore.getInstance().set(key);
    // 模拟相机自己那条记录由 `rememberMockCamera()` 写：走 `updateCurrentMeta()`
    // 会把模拟相机的机型/序列号写进**上一台**（当前选中的）真机记录里。
    if (!this.sessionIsMock) {
      SavedCameraStore.getInstance().updateCurrentMeta(this.cameraModel,
        CameraModelStore.getInstance().serial);
    }
    this.rememberMockCamera();
    this.log.add(`相机立牌: ${raw} → ${key}`);
  }

  /**
   * 记住机身序列号，喂给标题栏型号右下角的角标。
   *
   * 优先用 BLE 广播名尾段（`Z50_2_8079350` → `8079350`，和相机菜单、官方
   * SnapBridge 显示的一致）；没有就把 PTP 的 32 位序列号去掉前导零
   * （同一台机器是 `000…08079350`）。
   */
  @Monitor('deviceSerialNumber', 'bleCameraName')
  onCameraSerialChanged(): void {
    if (this.cameraModel === '') return;
    // 模拟相机（调试包）只认自己上报的 `MOCK-0001`。`bleCameraName` 是上一台
    // 真机蓝牙连接留下的（断开时不清），拿它的尾段当序列号会把模拟相机记成
    // 真机的 8079350，进而顶掉那条真机记录（1.66.1 修的串号污染）。
    const fromName = this.sessionIsMock ? '' : cameraSerialFromBleName(this.bleCameraName);
    const serial = fromName !== '' ? fromName : this.deviceSerialNumber.replace(/^0+/, '');
    if (serial === '') return;
    CameraModelStore.getInstance().setSerial(serial);
    // 同上：模拟相机别把序列号写进当前选中的真机记录。
    if (!this.sessionIsMock) {
      SavedCameraStore.getInstance().updateCurrentMeta(this.cameraModel, serial);
    }
    this.rememberMockCamera();
    this.log.add(`机身序列号: ${serial}`);
  }

  /**
   * 切换到一台已保存的相机（不主动连接）。
   *
   * 只改展示与活动身份：标题栏立牌、序列号、BLE 复用身份都指向它；真正的
   * 连接仍由用户点「连接相机」触发。清掉上一台的无线快速地址与扫描残留，
   * 避免切过去后先连回旧相机。
   */
  applySavedCamera(record: SavedCamera): void {
    this.stopBleScan();
    this.stopWifiScan();
    this.bleCameras = [];
    this.wifiCameras = [];
    this.bleHint = '';
    this.wirelessFailed = '';
    this.lastScanError = '';
    this.bleSerial = '';
    this.bleCameraName = record.cameraName;
    this.cameraModel = record.modelKey;
    this.wifiHost = '';
    this.wifiPort = 15740;
    const model = CameraModelStore.getInstance();
    model.clear();
    if (record.modelKey !== '') model.set(record.modelKey);
    if (record.serial !== '') model.setSerial(record.serial);
    WifiLinkStore.getInstance().clear();
  }

  /** 准备连接一台新相机：清掉当前展示与活动身份，已保存记录仍由仓库保留。 */
  applyNewCameraSelection(): void {
    this.stopBleScan();
    this.stopWifiScan();
    this.bleCameras = [];
    this.wifiCameras = [];
    this.bleHint = '';
    this.wirelessFailed = '';
    this.lastScanError = '';
    this.bleSerial = '';
    this.bleCameraName = '';
    this.cameraModel = '';
    this.wifiHost = '';
    this.wifiPort = 15740;
    CameraModelStore.getInstance().clear();
    WifiLinkStore.getInstance().clear();
  }

  /** 启动时把落盘的模式读回来。 */
  initLinkMode(): void {
    this.linkMode = CameraLinkModeStore.getInstance().mode;
    // 上次停在 STA：先把网络快照摸好，点搜索时 `wifiHint` 才有依据
    if (this.linkMode === CameraLinkMode.STA) {
      this.refreshNetworkSnapshot().catch((_e: Error) => { /* 快照失败不影响主流程 */ });
    }
  }

  /** 用户切换模式。切模式不做自动连接，等用户点「搜索相机」。 */
  setLinkMode(mode: number): void {
    if (mode === this.linkMode) return;
    const label = ['USB', '蓝牙', 'Wi-Fi AP', 'Wi-Fi STA'][mode] ?? `${mode}`;
    this.log.add(`链路模式切到 ${label}`);
    this.linkMode = mode;
    CameraLinkModeStore.getInstance().set(mode);
    // 切模式 = 取消在途的一切搜索与自动连接。先换代次再收尾：旧流程在所有
    // await 点都会看到「已经不是当前链路选择」，于是静默退出（1.64.1）。
    this.linkEpoch++;
    this.cancelInFlightLink();
    // 上一轮的失败原因、网络快照都属于上一模式，留着会让人以为当前模式也失败了
    // （以前切到 USB 还挂着「蓝牙连接失败」，AP 模式下还显示手机当前 Wi-Fi）。
    this.lastScanError = '';
    this.bleHint = '';
    this.wifiHint = '';
    this.wirelessStage = '';
    this.wirelessFailed = '';
    // 「等相机回蓝牙」只属于上一条无线链路，切模式后不该再自动接回来。
    this.bleRecovering = false;
    // 配对列表属于上一模式：切过去还留着几台旧设备，看起来像当前模式也扫到了
    this.bleCameras = [];
    // Wi-Fi 发现的相机同理；STA 的「网络里发现的相机」列表不该跨模式残留。
    this.wifiCameras = [];
    // 上一模式的扫描统计也一起清：切模式是显式断连，留着「照片 38 张 | 扫描完成」
    // 会让新模式的空态看起来像刚扫完（1.64.0 加锁定切换时发现）。
    this.scanStatsText = '';
    this.scanPhaseText = '';
    this.scanProgress = 0;
    this.scanTotal = 0;
    // STA 一进模式就先摸一遍本机网络：搜索或失败时 `wifiHint` 才有依据。
    if (mode === CameraLinkMode.STA) {
      this.refreshNetworkSnapshot().catch((_e: Error) => { /* 快照失败不影响主流程 */ });
    }
  }

  /**
   * 切模式时取消所有在途的发现 / 自动连接。
   *
   * 只清「正在做」的标记与计时器，**不碰已配对的 BLE 身份**：切到 AP / STA
   * 后蓝牙仍要用来唤醒相机。正在首配的 BLE 连接是例外——那是上一模式的
   * 动作，直接取消（`BleCameraLink` 会在关键 await 后看到取消标记）。
   *
   * 自动无线 / AP 交接无法从外面 await 掉，它们靠 `linkEpoch` 在下一个
   * 检查点收手；这里先把进行中标记放掉，页面才不会继续显示上一模式的
   * 「正在连接」。
   */
  private cancelInFlightLink(): void {
    this.stopBleScan();
    this.stopWifiScan();
    this.cancelWifiReconnect();
    const wasApJoining = this.apJoining;
    this.wifiAutoConnecting = false;
    this.apJoining = false;
    this.wifiReconnecting = false;
    this.wirelessStage = '';
    // 手动 IP / 自动链路的 `connectWifi()` 可能在途：让它的 finally 失效，
    // 页面立刻回到新模式的空闲态（在途会话由 `abortWifiConnect()` 收掉）。
    this.wifiConnectSeq++;
    this.wifiConnecting = false;
    // USB 扫描不在这里把 `scanning` 置 false：那会让页面看起来已经空闲，
    // 用户可以再点一次搜索，两轮扫描同时动同一个 PTP 会话。让旧扫描在
    // `ensureUsbSession()` 之后看到代次变化、自己收尾（通常一瞬间）。
    if (wasApJoining && this.apJoiner !== null) {
      // `join()` 的轮询会被 leave() 里的取消标记终止；已经上了热点的话
      // 这一步同时把手机从没有外网的相机热点上撤下来。
      this.apJoiner.leave().catch((_e: Error) => { /* 已经不在热点上 */ });
    }
    if (this.bleConnecting && this.bleLink !== null) {
      this.log.add('切模式：取消在途的蓝牙连接');
      this.bleLink.disconnect().catch((_e: Error) => { /* 取消失败不影响切模式 */ });
    }
    this.bleConnecting = false;
  }

  /**
   * 记一条无线失败结论。
   *
   * 失败后不能再占着「进行中」的进度位，否则界面会把一句已经结束的文案当成
   * 还在跑；结论留在 `wirelessFailed`，等下一次尝试或切模式时清掉。
   */
  private failWireless(message: string): void {
    this.wirelessFailed = message;
    this.wirelessStage = '';
  }

  /**
   * 「搜索相机」的统一入口：按当前模式分派。
   *
   * 四种模式共用同一个按钮位置，用户不需要记「哪个按钮属于哪个模式」；
   * 模式本身在页面顶部的胶囊里选。
   */
  async searchByMode(): Promise<void> {
    this.log.add(`按模式搜索：${this.linkMode}`);
    // 这一轮搜索属于当前链路选择；中途切模式后，后续 await 回来的步骤不能再
    // 接着跑（否则会在新模式里开一轮旧模式的搜索）。
    const epoch = this.linkEpoch;
    switch (this.linkMode) {
      case CameraLinkMode.USB:
        await this.scanForCamera(false, true);
        break;
      case CameraLinkMode.BLE:
        // 用户按的按钮，失败要说出来
        if (!await this.autoConnectBle(false)) {
          if (this.epochCurrent(epoch)) await this.scanBleCameras();
        }
        break;
      case CameraLinkMode.AP:
      case CameraLinkMode.STA:
        await this.searchWireless();
        break;
      default:
        break;
    }
  }

  /**
   * 无线两模式的搜索。
   *
   * AP 必须走「配对 → 相机热点」，没有身份就先扫蓝牙；
   * STA 的相机已经在手机所在的网络里，**先走网络发现**——没配对也能用，
   * 这也是两种模式在入口上最直观的区别。配对过的话先借蓝牙唤一下相机，
   * 醒来仍然走网络发现。
   */
  private async searchWireless(): Promise<void> {
    if (this.connected && this.wireless) return;
    this.wirelessFailed = '';
    const epoch = this.linkEpoch;
    // 身份可能只是没装回活动位（多相机 / 上次是模拟相机），先补一次再判断
    // 「配没配过对」，否则会把一台已配对的相机当成新相机去扫蓝牙。
    this.adoptSavedBleIdentity();
    const store = BleIdentityStore.getInstance();
    const paired = store.hasIdentity() && store.deviceId.length > 0;
    if (this.linkMode === CameraLinkMode.AP) {
      if (paired) {
        await this.connectWirelessNow();
      } else {
        await this.scanBleCameras();
      }
      return;
    }
    // STA：蓝牙只做唤醒，不改变「照片走网络」这条主线。
    // 主要操作就是「自动搜索并连接」：先试记住的地址，再 mDNS / 网段发现，
    // 命中一台就直接连，不像 AP 那样停下来让用户从列表里挑（STA 的相机
    // 本来就在手机的网络里，用户点「搜索相机」要的是连上，不是一张列表）。
    if (paired) {
      if (await this.connectBle(store.deviceId, store.cameraName, false)) {
        // BLE 握手期间切了模式：这次唤醒属于上一模式，不能继续连无线。
        if (!this.epochCurrent(epoch)) return;
        if (!await this.autoLinkWifi('search-sta')) {
          if (this.epochCurrent(epoch)) this.failStaAutoLink();
        }
        return;
      }
      // 蓝牙没连上不是终点；但切了模式就没有「改为网络发现」这一步了。
      if (!this.epochCurrent(epoch)) return;
      this.log.add('STA: 蓝牙待机没连上，改为网络发现');
    }
    if (!await this.autoLinkWifi('search-sta')) {
      if (this.epochCurrent(epoch)) this.failStaAutoLink();
    }
  }

  /**
   * STA 自动发现失败：留下结论，页面才能显示「没能连上相机 + 原因」。
   *
   * 区分「一台都没发现」和「发现了但连不上」——后者给出具体地址，比笼统的
   * 「没有发现相机」更接近现场。
   */
  private failStaAutoLink(): void {
    const found = this.pickWifiCamera();
    if (found !== null) {
      this.failWireless(L10n.tr('camera_status_wifi_connect_failed', found.host));
      return;
    }
    this.failWireless(this.wifiHint !== ''
      ? this.wifiHint : L10n.tr('camera_status_wifi_not_found'));
  }

  private getApJoiner(): WifiApJoiner {
    if (this.apJoiner === null) {
      this.apJoiner = new WifiApJoiner((msg: string) => this.log.add(msg));
    }
    return this.apJoiner;
  }

  /**
   * 蓝牙模式按需浏览（1.67.0）：BLE 待机不变，用户要照片时才把相机推到热点。
   *
   * 为什么不加第五种模式：Z50II 的 BLE 与 Wi-Fi 互斥（见 SERVICES.md「BLE 与
   * Wi-Fi 互斥」），任何传图都必然走 Wi-Fi；用户真正要的是「蓝牙连着的状态下
   * 也能看图」，而不是再多一个连接方式。所以链路选择仍是蓝牙，只在需要时临时
   * 借用一下相机热点，收口与 AP 模式完全同一条 `connectWirelessNow()`。
   *
   * 进入要显式点一下（拉起热点会让手机断网，不该悄悄发生），回程是自动的：
   * `disconnect()` → `exitWirelessToBle()` 离开热点，相机约 40 秒回落蓝牙，
   * 期间 `startBleRecoveryScan()` 每 6 秒找一次、最多 3 分钟，连回来就恢复
   * 校时与位置注入。
   */
  async browsePhotosOverWifi(): Promise<boolean> {
    if (this.linkMode !== CameraLinkMode.BLE) return false;
    if (this.connected && this.wireless) return true;
    // 身份可能只是没装回活动位（多相机 / 上次连的是别的机身）：入口是按
    // `bleKnown()` 显示的，这里必须先把身份装回去，否则会误报「还没有配对过相机」。
    this.adoptSavedBleIdentity();
    this.log.add('蓝牙模式：用户要看照片，开始交接相机热点');
    const ok = await this.connectWirelessNow();
    if (!ok) this.log.add('蓝牙模式：交接相机热点没有完成');
    return ok;
  }

  /**
   * 用户要照片：BLE → 相机热点 → PTP，一条龙。
   *
   * 顺序是刻意排的：
   * 1. 先确认 BLE 在线并握手 —— `0x2004` 的凭据是在握手收口时读到的，
   *    这一笔必须在把相机推去 Wi-Fi **之前**拿到；
   * 2. 再写 `0x2005=0x01` 让相机把热点起起来（写完 BLE 就会断）；
   * 3. 手机程序化加入相机热点；
   * 4. 逐个试候选地址连 PTP，都不行再退到网段扫描。
   *
   * 全程写 `wirelessStage`，UI 按步显示，不转无意义的圈。
   */
  async connectWirelessNow(): Promise<boolean> {
    if (this.connected && this.wireless) return true;
    if (this.apJoining || this.wifiAutoConnecting) return false;
    if (!this.handoverAllowed()) {
      this.log.add('交接冷却中：相机刚被推过 Wi-Fi，稍后再试');
      this.failWireless('相机刚切换过无线，请稍等一会再试');
      return false;
    }
    const epoch = this.linkEpoch;
    this.apJoining = true;
    this.wirelessFailed = '';
    this.wirelessStage = '';
    try {
      // BLE 待机握手（AP 模式要靠它拿 0x2004 凭据）
      if (!this.bleConnected) {
        const store = BleIdentityStore.getInstance();
        if (!store.hasIdentity() || store.deviceId.length === 0) {
          this.failWireless('还没有配对过相机');
          return false;
        }
        this.wirelessStage = '正在唤醒相机';
        if (!await this.connectBle(store.deviceId, store.cameraName, false)) {
          if (this.epochCurrent(epoch)) {
            this.failWireless('连不上相机，请确认相机已开机且在附近');
          }
          return false;
        }
      }
      // BLE 握手中途切了模式：不能继续把相机推到 Wi-Fi。
      if (!this.epochCurrent(epoch)) {
        this.log.add('无线交接已被切模式取消');
        return false;
      }
      // 把相机推到 Wi-Fi（AP 模式 = 起热点；STA 模式 = 入网）
      this.wirelessStage = '正在唤醒相机无线';
      try {
        if (this.bleLink !== null) {
          await this.bleLink.wakeCameraWifi();
        }
        this.lastHandoverAt = Date.now();
        if (this.bleLink !== null) {
          this.bleLink.stopKeepalive();
        }
      } catch (err) {
        if (this.epochCurrent(epoch)) this.failWireless('唤醒相机无线失败');
        this.log.add(`0x2005 写入失败: ${(err as Error).message}`);
        return false;
      }
      if (!this.epochCurrent(epoch)) {
        this.log.add('无线交接已被切模式取消');
        return false;
      }
      return await this.afterHandover(epoch);
    } finally {
      // 切模式时 `cancelInFlightLink()` 已经清过；新一轮可能已把它置回 true，
      // 旧流程不能把新流程的标记抹掉。
      if (this.epochCurrent(epoch)) {
        this.apJoining = false;
        if (this.connected) this.wirelessStage = '';
      }
    }
  }

  /** 交接完成（相机已被推到 Wi-Fi）：按模式接着收口。 */
  private async afterHandover(epoch: number): Promise<boolean> {
    if (!this.epochCurrent(epoch)) return false;
    // 蓝牙模式按需看图（1.67.0）走的也是相机热点：相机被 0x2005 推到 Wi-Fi 后
    // 只有它自己开的热点可连，凭据同样来自 0x2004。
    if (this.linkMode === CameraLinkMode.AP || this.linkMode === CameraLinkMode.BLE) {
      return await this.joinApAndConnect(epoch);
    }
    return await this.autoLinkWifi('ble-paired');
  }

  /**
   * AP 模式收口：加入相机热点 → 连 PTP → 扫照片。
   *
   * 凭据来自 BLE 握手时读到的 `0x2004`（已解密），所以这一步不需要用户
   * 输入任何东西。地址先试网关（两种字节序），再用网段扫描兜底。
   */
  private async joinApAndConnect(epoch: number): Promise<boolean> {
    if (!this.epochCurrent(epoch)) return false;
    const creds = this.bleLink === null ? null : this.bleLink.getCredentials();
    if (creds === null) {
      this.failWireless('没拿到相机热点凭据（相机可能没认这次配对）');
      this.log.add('AP: 0x2004 凭据为空，放弃');
      return false;
    }
    this.wirelessStage = '正在连接相机热点';
    const joiner = this.getApJoiner();
    const outcome: ApJoinOutcome = await joiner.join(creds.ssid, creds.password, creds.security);
    // 加入热点期间切了模式：`cancelInFlightLink()` 已经让 joiner 取消并退出，
    // 这里不能再写失败文案；手机若已上热点，也把候选配置撤掉。
    if (!this.epochCurrent(epoch)) {
      this.leaveCameraHotspot('加入热点期间切了模式');
      return false;
    }
    if (!outcome.ok) {
      this.failWireless(outcome.reason);
      this.log.add(`AP: 加入相机热点失败 —— ${outcome.reason}`);
      return false;
    }
    this.wirelessStage = '正在连接照相机';
    for (const host of joiner.candidateHosts()) {
      if (!this.epochCurrent(epoch)) {
        this.leaveCameraHotspot('连接照相机期间切了模式');
        return false;
      }
      this.log.add(`AP: 试 ${host}:15740`);
      if (await this.connectWifi(host, 15740, true)) {
        if (!this.epochCurrent(epoch)) {
          this.leaveCameraHotspot('连接照相机期间切了模式');
          return false;
        }
        await this.finishAutoLink();
        return this.connected;
      }
      if (!this.epochCurrent(epoch)) {
        this.leaveCameraHotspot('连接照相机期间切了模式');
        return false;
      }
    }
    this.log.add('AP: 候选地址都不通，改用网段扫描');
    this.wirelessStage = '正在搜索照相机';
    await this.scanWifiCameras(5000);
    // `scanWifiCameras()` 在切模式时会提前返回；这里不要再拿旧结果去连。
    if (!this.epochCurrent(epoch)) {
      this.leaveCameraHotspot('搜索照相机期间切了模式');
      return false;
    }
    const camera = this.pickWifiCamera();
    if (camera === null) {
      this.failWireless(this.wifiHint !== '' ? this.wifiHint : '没有找到照相机');
      return false;
    }
    if (await this.connectWifi(camera.host, camera.port, true)) {
      if (!this.epochCurrent(epoch)) {
        this.leaveCameraHotspot('连接照相机期间切了模式');
        return false;
      }
      await this.finishAutoLink();
      return this.connected;
    }
    // 这次连接也可能是被切模式取消的：不能把「连不上照相机」写进新模式。
    if (!this.epochCurrent(epoch)) {
      this.leaveCameraHotspot('连接照相机期间切了模式');
      return false;
    }
    this.failWireless('连上相机热点，但连不上照相机');
    return false;
  }

  /**
   * 切模式时把手机从相机热点上撤下来。
   *
   * AP 交接的 `join()` 一旦成功，手机就挂在相机热点上（没有外网）；如果
   * 这时用户切到 STA 或别的模式而不管它，手机就再也看不到自己的网络了。
   * `WifiApJoiner.leave()` 会删掉候选配置并等系统切回原网络。
   */
  private leaveCameraHotspot(reason: string): void {
    this.log.add(`AP: ${reason}，退出相机热点`);
    if (this.apJoiner !== null) {
      this.apJoiner.leave().catch((_e: Error) => {
        // 已经不在热点 / 系统切换慢：交给相机侧的 Wi-Fi 待机计时，不影响切模式
      });
    }
  }

  /** 交接冷却是否已过（BLE/Wi-Fi 互斥，不能连着推）。 */
  private handoverAllowed(): boolean {
    return Date.now() - this.lastHandoverAt > this.handoverCooldownMs;
  }

  /**
   * Wi-Fi 会话起来了：BLE 侧进入「静默」。
   *
   * 相机 BLE 与 Wi-Fi 互斥（Z50II 实测），Wi-Fi 一开 BLE 就没了。此时保活
   * 写必然失败、自动重连只会把相机从 Wi-Fi 拽回来再推回去。所以停保活、
   * 关自动重连，把这个窗口完整让给 Wi-Fi。
   */
  private suspendBleForWifi(): void {
    if (this.bleLink === null) return;
    this.bleLink.stopKeepalive();
    this.stopBleGeoFeed();
    this.bleLink.disableAutoReconnect();
    this.bleReconnecting = false;
    this.log.add('BLE 已让位给 Wi-Fi（相机两个无线模式互斥，期间不再重连/保活）');
  }

  /**
   * 探针：Wi-Fi 会话期间相机是否还在发 BLE 广播？
   *
   * Z50II 实测：**不发**（5s/20s/30s 三轮全空），两个射频不能共存。
   * 保留作回归诊断：换机身/固件后先看它，判断「BLE 秒退」这条路是否可用。
   */
  private startBleVisibilityProbe(): void {
    this.stopBleVisibilityProbe();
    const store = BleIdentityStore.getInstance();
    if (!store.hasIdentity()) return;
    this.bleProbeIndex = 0;
    this.scheduleBleProbe(store.identityDevice);
  }

  private scheduleBleProbe(nikonDeviceId: number): void {
    if (this.bleProbeIndex >= this.bleProbeDelays.length) {
      this.log.add('探针: 三轮都没看到 BLE 广播 —— 相机在 Wi-Fi 期间不发蓝牙');
      return;
    }
    const delay = this.bleProbeDelays[this.bleProbeIndex];
    this.bleProbeIndex++;
    this.bleProbeTimer = setTimeout(() => {
      this.bleProbeTimer = -1;
      this.scanForNikonDeviceId(nikonDeviceId, 3000).then((devices: BleCameraDevice[]) => {
        if (devices.length > 0) {
          this.log.add(`探针: Wi-Fi 会话期间相机仍在 BLE 广播（${devices[0].deviceId}）`);
          return;
        }
        this.log.add('探针: 本轮没看到 BLE 广播');
        this.scheduleBleProbe(nikonDeviceId);
      }).catch((err: Error) => {
        this.log.add(`探针扫描失败: ${err.message}`);
      });
    }, delay);
  }

  private stopBleVisibilityProbe(): void {
    if (this.bleProbeTimer >= 0) {
      clearTimeout(this.bleProbeTimer);
      this.bleProbeTimer = -1;
    }
    this.bleProbeIndex = this.bleProbeDelays.length;
  }

  /**
   * 蓝牙模式的临时浏览会话收掉（1.67.0）。
   *
   * 与「用户点断开」走同一条 `disconnect()`：离开相机热点 → 排一轮 BLE 重扫。
   * 用于链路自己断掉（心跳 / 重连退避用尽 / 回前台恢复失败）时——蓝牙模式要的是
   * 「回到待机」，而不是停在一个连不上的 Wi-Fi 失败态、手机还挂在没有外网的热点上。
   * AP / STA 仍保留各自的失败态与重试入口，不受影响。
   */
  private endBleBrowsing(reason: string): void {
    if (this.linkMode !== CameraLinkMode.BLE) return;
    if (this.disconnecting) return;
    this.log.add(`蓝牙模式：${reason}，结束浏览回蓝牙待机`);
    this.disconnect().catch((err: Error) => {
      this.log.add(`退出浏览会话失败: ${err.message}`);
    });
  }

  /**
   * 退出无线：**离开相机热点**，让相机自己回落到蓝牙。
   *
   * 这是选 AP 模式的核心理由：AP 下手机是唯一客户端，手机一撤，相机看到
   * 零客户端，按自己的待机计时回落（实测约 40 秒）。STA 撤不掉也回不来。
   */
  async exitWirelessToBle(): Promise<void> {
    this.wifiAutoReconnectArmed = false;
    this.cancelWifiReconnect();
    this.stopBleVisibilityProbe();
    const store = BleIdentityStore.getInstance();

    if (this.bleConnected && this.bleLink !== null) {
      await this.bleLink.closeCameraWifi();
      this.bleHint = '';
      this.wirelessStage = '';
      this.log.add('退出无线: BLE 仍在，已写 0x2005=0x80');
      return;
    }

    if (this.apJoiner !== null) {
      this.wirelessStage = '正在退出相机热点';
      await this.apJoiner.leave();
    }
    this.wirelessStage = '正在等相机切回蓝牙';
    this.log.add('退出无线: 已离开相机热点，等相机回落蓝牙');
    this.startBleRecoveryScan(store, Date.now());
  }

  /** 退出无线后的兜底：每 6 秒重扫一次 BLE，最多 3 分钟。 */
  private startBleRecoveryScan(store: BleIdentityStore, startedAt: number = Date.now()): void {
    if (this.bleRecoveryTimer >= 0) {
      clearTimeout(this.bleRecoveryTimer);
      this.bleRecoveryTimer = -1;
    }
    const deadline = Date.now() + 180000;
    this.bleRecovering = true;
    const tick = (): void => {
      this.bleRecoveryTimer = -1;
      // 用户切了模式 / 手动断开：这一轮「等相机回来」作废。
      if (!this.bleRecovering) return;
      if (this.bleConnected || this.bleConnecting) {
        this.bleRecovering = false;
        return;
      }
      if (Date.now() > deadline) {
        this.log.add(`退出无线: 3 分钟内相机没有回到 BLE（已等 ${Date.now() - startedAt}ms）`);
        this.bleHint = '相机仍停在 Wi-Fi 模式。可检查相机的「Wi-Fi 待机时间」设定，或关机再开。';
        this.wirelessStage = '';
        this.bleRecovering = false;
        return;
      }
      this.scanForNikonDeviceId(store.identityDevice, 4000).then(async (devices: BleCameraDevice[]) => {
        if (devices.length > 0) {
          this.log.add(`退出无线: 相机回到 BLE（${devices[0].deviceId}，共等 ${Date.now() - startedAt}ms）`);
          this.bleHint = '';
          if (await this.connectBle(devices[0].deviceId, devices[0].name, false)) {
            this.wirelessStage = '';
            this.bleRecovering = false;
            return;
          }
        }
        if (this.bleConnected || this.bleConnecting) {
          this.bleRecovering = false;
          return;
        }
        this.bleRecoveryTimer = setTimeout(tick, 6000);
      }).catch(() => {
        this.bleRecoveryTimer = setTimeout(tick, 6000);
      });
    };
    this.bleRecoveryTimer = setTimeout(tick, 2000);
  }

  /** 取消排队中的无线自动重连。 */
  private cancelWifiReconnect(): void {
    if (this.wifiReconnectTimer >= 0) {
      clearTimeout(this.wifiReconnectTimer);
      this.wifiReconnectTimer = -1;
    }
    this.wifiReconnecting = false;
    this.wifiReconnectIndex = 0;
  }

  // ------------------------------------------------------------------
  // 相机在线检测（1.66.0）
  //
  // 两条链路各用最合适的手段，都不靠「下一次操作失败」去发现：
  // - USB：系统公共事件 `USB_DEVICE_DETACHED`——拔线/断电都会立刻发，零轮询；
  // - Wi-Fi：TCP 半开时没有任何事件，只能自己发心跳（前台、15 秒、一条 GetDeviceInfo）。
  // BLE 的 GATT 断链事件本来就管用，`BleCameraLink` 的保活失败再兜一层底。
  // ------------------------------------------------------------------

  /** 应用前后台切换：后台停心跳，回前台先补一次（不用等满一个周期）。 */
  setAppForeground(foreground: boolean): void {
    this.appForeground = foreground;
    // 蓝牙自动重连的节奏也跟着前台/后台走：前台压到 8 秒以内，用户抬眼时
    // 链路已经回来了；后台没必要一直扫（1.66.3）。
    if (this.bleLink !== null) this.bleLink.setForeground(foreground);
    if (!foreground) {
      this.stopWatchdog();
      return;
    }
    this.startWatchdog();
    this.watchdogTick();
  }

  /**
   * 启动无线心跳。
   *
   * 一个常驻的 15 秒定时器，每一拍自己判断「现在该不该探」——比在每条连接 /
   * 断开 / 切模式的路径上成对 start/stop 更难漏（漏一处就会一直探一条已经
   * 不存在的链路）。
   */
  startWatchdog(): void {
    if (this.watchdogTimer >= 0) return;
    this.watchdogTimer = setInterval(() => { this.watchdogTick(); }, WIRELESS_HEARTBEAT_MS);
    this.log.add(`无线心跳已启动（每 ${WIRELESS_HEARTBEAT_MS / 1000} 秒一次）`);
  }

  stopWatchdog(): void {
    if (this.watchdogTimer < 0) return;
    clearInterval(this.watchdogTimer);
    this.watchdogTimer = -1;
    this.watchdogBusy = false;
    this.log.add('无线心跳已停止（应用退到后台）');
  }

  private watchdogTick(): void {
    if (!this.appForeground || this.watchdogBusy) return;
    // USB 有拔出事件，不需要轮询；扫描 / 连接 / 重连本身就在跑流量，
    // 失败会从它们自己的路径里报上来。
    if (!this.connected || !this.wireless) return;
    if (this.scanning || this.wifiConnecting || this.wifiAutoConnecting
      || this.wifiReconnecting || this.pairingRequired) {
      return;
    }
    this.watchdogBusy = true;
    this.pingWireless().then((alive: boolean) => {
      this.watchdogBusy = false;
      if (alive || !this.connected || !this.wireless) return;
      this.log.add('无线心跳无响应：判定链路已断开');
      this.onWifiBroken('心跳超时');
    }).catch((err: Error) => {
      this.watchdogBusy = false;
      this.log.add(`无线心跳异常: ${err.message}`);
    });
  }

  /** 一条 `GetDeviceInfo`，超过 [WIRELESS_HEARTBEAT_TIMEOUT_MS] 没回来就算断了。 */
  private pingWireless(): Promise<boolean> {
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        resolve(false);
      }, WIRELESS_HEARTBEAT_TIMEOUT_MS);
      this.session.getDeviceInfo(PtpPriority.SCAN).then(() => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(true);
      }).catch(() => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(false);
      });
    });
  }

  /**
   * USB 相机拔出（`UsbAttachWatcher` 订阅系统公共事件后调进来）。
   *
   * 拔线不会让正在跑的命令立刻报错：PTP 的 bulk 端点要等下一次传输才知道对端
   * 没了，所以**空闲时**页面会一直停在「已连接」。这里用系统事件主动确认一次：
   * 会话那台设备确实不在枚举列表里，就按「相机没了」收尾——回到未连接 + 一条
   * toast，抽屉自己变回「用数据线连接相机」的引导。
   */
  async onUsbDeviceDetached(): Promise<void> {
    if (!this.connected || this.wireless) return;
    if (this.disconnecting) return;
    const deviceName = this.session.connectedDeviceName;
    if (deviceName === '') return;
    const cameras: usbManager.USBDevice[] = this.sessionIsMock
      ? MockPtpDevice.findCameras() : PtpSession.findCameras();
    const stillThere = cameras.some((c: usbManager.USBDevice) => c.name === deviceName);
    if (stillThere) {
      this.log.add(`USB 拔出事件：会话设备 ${deviceName} 仍在，忽略`);
      return;
    }
    this.log.add(`USB 相机已拔出（会话设备 ${deviceName}），收掉会话`);
    const wasScanning = this.scanning;
    await this.disconnectInternal();
    if (!wasScanning) {
      // 扫描中就让扫描自己的失败路径说话（「USB 通信失败…」更准确，
      // 也不会连着弹两条 toast）。
      this.notify(L10n.tr('camera_status_usb_lost'));
    }
  }

  /** 轻量提示：只弹一次 toast，不动页面状态。 */
  notify(text: string): void {
    this.noticeText = text;
    this.noticeVersion++;
    this.log.add(`[提示] ${text}`);
  }

  private makeWifiSession(): WifiPtpSession {
    const s = new WifiPtpSession();
    s.setLog((m: string) => this.log.add(m));
    // 链路意外断开（相机休眠、热点掉了、相机主动收线）时排一次自动重连。
    // 以前这里没有任何上报口：断链之后 App 还停在「已连接」，点什么都失败。
    s.setBrokenHandler((reason: string) => { this.onWifiBroken(reason); });
    return s;
  }

  /**
   * 无线链路掉线：清会话状态并按退避重连。
   *
   * 与 BLE 侧同节奏：先试记住的地址（快），连不上再重扫（相机换网段/DHCP
   * 重发地址的情况）。用户显式断开后 `wifiAutoReconnectArmed` 为 false，
   * 自动重连不会启动。
   */
  private onWifiBroken(reason: string): void {
    if (this.wifiReconnecting) return;
    this.connected = false;
    this.usable = false;
    // 会话已经死了：把旧 socket 收掉。`closeSessionAndPipe()` 会先试 CloseSession，
    // 半开链路上要等满事务超时，所以不等它——只是别再拿着这条链路。
    this.dropBrokenWifiSession();
    if (!this.wifiAutoReconnectArmed) {
      // 用户刚断开 / 还在建链：不自动重连，但结论要留在页面上，否则页面会
      // 悄悄退回「未连接」，用户不知道相机是怎么没的。
      this.log.add(`无线链路断开（未启用自动重连）: ${reason}`);
      this.failWireless(L10n.tr('camera_status_wifi_disconnected'));
      return;
    }
    this.log.add(`无线链路断开，准备自动重连: ${reason}`);
    this.wifiReconnecting = true;
    this.wifiReconnectIndex = 0;
    this.scheduleWifiReconnect();
  }

  /** 把已经判定断开的无线会话收掉（best effort，不阻塞重连）。 */
  private dropBrokenWifiSession(): void {
    const wifi = this.wifiSession;
    this.wifiSession = null;
    this.pairingRequired = false;
    this.pairingCode = '';
    if (wifi === null) return;
    wifi.closeSessionAndPipe().catch((err: Error) => {
      this.log.add(`关闭断开的无线会话失败: ${err.message}`);
    });
  }

  private scheduleWifiReconnect(): void {
    if (this.wifiReconnectTimer >= 0) {
      clearTimeout(this.wifiReconnectTimer);
      this.wifiReconnectTimer = -1;
    }
    if (!this.wifiAutoReconnectArmed) {
      this.wifiReconnecting = false;
      return;
    }
    const delay = this.wifiBackoffMs[Math.min(this.wifiReconnectIndex,
      this.wifiBackoffMs.length - 1)];
    this.statusText = L10n.tr('camera_status_wifi_reconnecting', this.wifiReconnectIndex + 1);
    this.wifiReconnectTimer = setTimeout(() => {
      this.wifiReconnectTimer = -1;
      this.tryWifiReconnect().catch((err: Error) => {
        this.log.add(`无线自动重连异常: ${err.message}`);
      });
    }, delay);
  }

  private async tryWifiReconnect(): Promise<void> {
    if (!this.wifiAutoReconnectArmed) {
      this.wifiReconnecting = false;
      return;
    }
    this.wifiReconnectIndex++;
    const ok = await this.autoLinkWifi('reconnect');
    if (ok) {
      this.wifiReconnecting = false;
      this.wifiReconnectIndex = 0;
      this.log.add('无线自动重连成功');
      return;
    }
    if (this.wifiReconnectIndex >= this.wifiBackoffMs.length) {
      this.wifiReconnecting = false;
      this.wifiReconnectIndex = 0;
      this.log.add('无线自动重连放弃（退避用尽）');
      // 以前只写 statusText：重连一停页面就退回「未连接」，用户不知道相机是
      // 怎么没的。改成把结论写进 `wirelessFailed`（状态头显示「没能连上相机 +
      // 原因 + 重试」），再补一条 toast（1.66.0）。
      this.failWireless(L10n.tr('camera_status_wifi_connect_failed', this.wifiHost));
      this.notify(L10n.tr('camera_status_wifi_disconnected'));
      // 蓝牙模式的按需浏览接不回来：收掉临时会话，手机离开热点、回蓝牙待机。
      this.endBleBrowsing('浏览会话接不回来');
      return;
    }
    this.scheduleWifiReconnect();
  }

  /**
   * 把无线链路接起来（自动路径的唯一入口）。
   *
   * 顺序刻意是「记得的地址 → mDNS/网段扫描」：
   * 1. 地址几乎从不变化，先直连能把冷启动从十几秒压到一两秒；
   * 2. 直连失败才扫，避免每次都跑 254 个地址的端口探测。
   *
   * 成功后顺带把照片扫一遍，让「蓝牙连上 → 无线连上 → 相册出来」是一条
   * 连续的链路，而不是要用户再点一次「搜索相机」。
   */
  async autoLinkWifi(source: string, allowScan: boolean = true): Promise<boolean> {
    if (this.connected && this.wireless) return true;
    if (this.wifiAutoConnecting) {
      this.log.add(`自动无线已在进行中，忽略 ${source} 的重复触发`);
      return false;
    }
    const epoch = this.linkEpoch;
    this.wifiAutoConnecting = true;
    this.wirelessFailed = '';
    try {
      const store = WifiLinkStore.getInstance();
      if (store.hasHost()) {
        this.log.add(`自动无线: 先试上次地址 ${store.host}:${store.port}`);
        if (await this.connectWifi(store.host, store.port, true)) {
          if (!this.epochCurrent(epoch)) return false;
          await this.finishAutoLink();
          return true;
        }
        if (!this.epochCurrent(epoch)) return false;
        this.log.add('自动无线: 上次地址不通，改为扫描');
      }
      if (!allowScan) {
        this.log.add(`自动无线（${source}）: 本次不走网段扫描（只试记住的地址）`);
        return false;
      }
      // **网络快照要等到真要扫描时再取**（1.66.14）：`connection.getAllNets()`
      // 的实现在系统网络服务忙的时候会在主线程上跑好几秒（2026-11-14 19:01 实测
      // 7.5 秒，EventHandler 队列被它堵住 → THREAD_BLOCK_6S 闪退）。冷启动只试
      // 记住的地址，根本用不到这份快照，就不该为它冒卡死的险。
      const nets = await collectLocalNetworks();
      // 等网络快照期间切了模式：这一轮直接作废，不写网络快照、不继续连。
      if (!this.epochCurrent(epoch)) {
        this.log.add(`自动无线（${source}）已被切模式取消`);
        return false;
      }
      this.log.add(`自动无线（${source}）: ${nets.summary}`);

      // 上限比一整轮网段扫描还长：命中就提前收工，没命中就让它跑完，
      // 不人为截断搜索（截断会把「慢但能找到」变成「找不到」）。
      const camera = await this.scanUntilCamera(45000);
      // 搜索途中切了模式：`stopWifiScan()` 已经让这一轮提前收工，不要再拿
      // 旧模式的结果去连相机、更不要给新模式留一条失败结论。
      if (!this.epochCurrent(epoch)) {
        this.log.add(`自动无线（${source}）已被切模式取消`);
        return false;
      }
      if (camera === null) {
        this.log.add(`自动无线: 没有发现相机。${this.wifiHint}`);
        return false;
      }
      this.log.add(`自动无线: 命中 ${camera.name} @ ${camera.host}`);
      if (await this.connectWifi(camera.host, camera.port, true)) {
        if (!this.epochCurrent(epoch)) return false;
        await this.finishAutoLink();
        return true;
      }
      return false;
    } finally {
      // 只有仍属于当前链路选择时才清标记：切模式时 `cancelInFlightLink()`
      // 已经清过，而新一轮可能已经把它置回 true，旧流程不能把它抹掉。
      if (this.epochCurrent(epoch)) this.wifiAutoConnecting = false;
    }
  }

  /** 自动连上之后的收口：相机要注册就先注册，然后直接扫照片。 */
  private async finishAutoLink(): Promise<void> {
    this.wifiAutoReconnectArmed = true;
    this.wifiHint = '';
    this.wirelessFailed = '';
    this.wirelessStage = '';
    if (this.pairingRequired) {
      await this.completeWifiPairing();
      return;
    }
    if (!this.connected) return;
    await this.scanForCamera(true, true);
  }

  /**
   * 从扫描结果里挑一台。
   *
   * mDNS 的实例名就是相机名，比「网段扫描得到的裸 IP」可信得多，所以优先；
   * 同类里优先名字像尼康机身的（`Z50_2_...`），再不行才取第一台。
   */
  private pickWifiCamera(): WifiCameraInfo | null {
    if (this.wifiCameras.length === 0) return null;
    const byName = this.wifiCameras.filter((c: WifiCameraInfo) => !this.isRawIpName(c.name));
    const named = byName.find((c: WifiCameraInfo) => /^[A-Za-z]/.test(c.name));
    if (named !== undefined) return named;
    if (byName.length > 0) return byName[0];
    return this.wifiCameras[0];
  }

  /** 网段扫描的候选名就是 IP 本身，用它区分「有名字的 mDNS 结果」。 */
  private isRawIpName(name: string): boolean {
    return /^\d{1,3}(\.\d{1,3}){3}$/.test(name);
  }

  private buildWifiCameraIdentity(info: DeviceInfo, host: string): string {
    const sanitize = (s: string): string => s.replace(/[^a-zA-Z0-9_.-]/g, '_').substring(0, 64);
    const manu = (info.manufacturer || '').trim();
    const model = (info.model || '').trim();
    const serial = (info.serialNumber || '').trim();
    if (serial) {
      return sanitize(`${manu}_${model}_${serial}`);
    }
    return sanitize(`${manu}_${model}_wifi_${host}`);
  }

  /**
   * 建立/复用 USB 会话。无线模式不走这里，直接复用 `connectWifi()` 建好的会话。
   * 返回 false 时由调用方收尾（清 scanning / 已在内部报过错）。
   *
   * [epoch] 是这次扫描所属的链路代次：建立会话的每个 await 之后都比一次，
   * 切了模式就悄悄关掉刚建的会话、不往新模式写任何失败文案。
   */
  private async ensureUsbSession(epoch: number): Promise<boolean> {
    const cameras = this.sessionIsMock ? MockPtpDevice.findCameras() : PtpSession.findCameras();
    if (cameras.length === 0) {
      // 枚举本身很快；如果这期间切了模式，不要把「没有相机」写进新模式。
      if (!this.epochCurrent(epoch)) return false;
      this.connected = false;
      this.cameraName = '';
      this.reportScanFailure(L10n.tr('camera_status_no_camera'));
      this.scanning = false;
      return false;
    }

    const sameDevice = this.connected &&
      this.session.connectedDeviceName === cameras[0].name;

    if (sameDevice) {
      // Same camera — keep USB session alive.
      // 不再清空 photos：一次失败的快速扫描不该让已经有内容的画廊先空一下
      // （ISSUE-005）。缩略图内存缓存仍然清掉，Phase 0 / Phase 2b 会重新填。
      this.thumbnailPixelMapMap.clear();
      this.thumbnailLoadedSet.clear();
      this.preloadedOrientations.clear();
      this.exifOrigDims.clear();
      this.orientationMap.clear();
      this.orientedDisplaySizes.clear();
      this.clearFullCache();
      this.statusText = L10n.tr('camera_status_connected');

      // Refresh camera identity from PTP if not already set
      if (!this.cameraIdentity) {
        const deviceInfo = await this.session.getDeviceInfo();
        if (deviceInfo) {
          this.cameraIdentity = this.buildCameraIdentity(deviceInfo, cameras[0]);
          this.cameraName = deviceInfo.model || deviceInfo.manufacturer || this.cameraName;
          this.log.add(`相机身份(刷新): ${this.cameraIdentity}`);
        }
      }
      // Re-check caching state (user may have changed prefs in settings)
      this.checkCachingState();

    } else {
      // Different camera or first connect
      if (this.connected) {
        await this.disconnect();
        if (!this.epochCurrent(epoch)) return false;
      }

      this.statusText = L10n.tr('camera_status_found_camera', cameras[0].productName);

      const usbEndpoint: PtpEndpoint = {
        kind: PtpEndpointKind.USB,
        device: cameras[0],
        label: cameras[0].name
      };
      const session = this.session;
      const ok = await session.connect(usbEndpoint);
      if (!this.epochCurrent(epoch)) {
        await this.abortStaleUsbSession(session);
        this.log.add('USB 连接已被切模式取消');
        return false;
      }
      if (!ok) {
        this.connected = false;
        // 0x201E：相机里还留着上一次崩溃时的会话，光重试没有用，要用户拔插一次线。
        this.reportScanFailure(L10n.tr(this.session.sessionConflict === true
          ? 'camera_status_session_conflict' : 'camera_status_connect_failed'));
        this.scanning = false;
        return false;
      }

      this.cameraName = cameras[0].productName || cameras[0].manufacturerName ||
                        cameras[0].name;
      this.statusText = L10n.tr('camera_status_connected');
      this.connected = true;
      this.usable = false;

      // Fetch PTP device identity for unique camera identification
      const deviceInfo = await session.getDeviceInfo();
      if (!this.epochCurrent(epoch)) {
        await this.abortStaleUsbSession(session);
        this.log.add('USB 连接已被切模式取消（取设备信息后）');
        return false;
      }
      this.deviceManufacturer = deviceInfo?.manufacturer || cameras[0].manufacturerName || '';
      this.deviceSerialNumber = deviceInfo?.serialNumber || cameras[0].serial || '';
      this.deviceVersion = deviceInfo?.deviceVersion || '';
      this.usbVidPid = `VID_${cameras[0].vendorId.toString(16).padStart(4,'0')}_PID_${cameras[0].productId.toString(16).padStart(4,'0')}`;
      this.usbSerialNumber = cameras[0].serial || '';
      if (deviceInfo) {
        this.log.add(`PTP DeviceInfo: manu="${deviceInfo.manufacturer}" model="${deviceInfo.model}" serial="${deviceInfo.serialNumber}" ver="${deviceInfo.deviceVersion}"`);
        this.deviceOps = deviceInfo.operationsSupported ?? [];
        this.log.add(`PTP 支持操作 ${this.deviceOps.length} 个` +
          `${this.deviceOps.includes(0x9805) ? '（含 GetObjectPropList）' : '（无 GetObjectPropList）'}`);
        this.cameraIdentity = this.buildCameraIdentity(deviceInfo, cameras[0]);
        this.cameraName = deviceInfo.model || deviceInfo.manufacturer || this.cameraName;
      } else {
        // Fallback: use USB-level info
        this.cameraIdentity = `vid_${cameras[0].vendorId.toString(16).padStart(4,'0')}_pid_${cameras[0].productId.toString(16).padStart(4,'0')}`;
        this.log.add(`USB fallback identity: ${this.cameraIdentity}`);
      }
      this.log.add(`相机身份: ${this.cameraIdentity}`);

      // Check caching preference for this camera
      this.checkCachingState();
    }
    // 模拟相机（调试包）：把它记进「已配对相机」，重启后能回到同一台。
    // 放在这里而不是只放在机型识别里：认不出机型的模拟机（「未知型号」）
    // 走不到那条分支。
    this.rememberMockCamera();
    return true;
  }

  /**
   * 切换模式时收起一次刚建立、但已不属于当前模式的 USB 会话。
   *
   * 只在 `this.session` 仍是这一个会话时才复位：新一轮扫描可能已经建了
   * 自己的会话，不能把它的状态清掉。
   */
  private async abortStaleUsbSession(session: PtpTransport): Promise<void> {
    try {
      await session.closeSessionAndPipe();
    } catch (_e) {
      // 还没连上 / 已经被下一次断开收掉，忽略
    }
    if (this.session === session) {
      this.session = new PtpScheduler(new PtpSession());
      this.connected = false;
      this.usable = false;
    }
  }

  async scanForCamera(quickMode: boolean = true, bypassThrottle: boolean = false): Promise<void> {
    const startedAt = Date.now();
    if (this.scanning || this.pendingCachingResolve !== null) {
      this.log.add('[节流] 已有扫描在进行中，忽略本次请求');
      return;
    }
    if (!bypassThrottle && this.lastScanStartMs > 0 &&
        startedAt - this.lastScanStartMs < SCAN_MIN_INTERVAL_MS) {
      this.log.add(`[节流] 距上次扫描 ${startedAt - this.lastScanStartMs}ms，忽略本次请求`);
      return;
    }
    this.lastScanStartMs = startedAt;
    this.scanning = true;
    this.log.add('=== 开始扫描 ===');
    // 这次扫描属于当前链路选择；切模式后 USB 会话不再建立/保留。
    const epoch = this.linkEpoch;
    // 扫描全程（元数据 + 缩略图）都是 USB 传输，退后台要继续，先申请长时任务
    await this.beginTransferTask();

    // Debug builds only: swap in the virtual camera before searching.
    this.syncSessionMode();

    this.statusText = L10n.tr('camera_status_searching');


    try {
      if (this.wireless) {
        // 无线会话已在 connectWifi() 里建立；这里只确认它还在。
        if (!this.connected) {
          this.reportScanFailure(L10n.tr('camera_status_wifi_disconnected'));
          this.scanning = false;
          return;
        }
        this.statusText = L10n.tr('camera_status_connected');
      } else {
        const ready = await this.ensureUsbSession(epoch);
        if (!ready) {
          this.scanning = false;
          return;
        }
        // 会话建立期间切了模式：这次扫描属于上一模式，收尾交给 finally。
        if (!this.epochCurrent(epoch)) {
          this.log.add('USB 扫描已被切模式取消');
          return;
        }
      }

      // 新相机：连接成功后立刻问「要不要缓存」，问完再扫。
      // 早前是「先按启用缓存扫完，再弹窗追问」，弹窗要等元数据 + 全部缩略图都传完
      // （1288 张要好几分钟）才出现，时机完全错位。
      if (this.pendingCachingPrompt) {
        this.statusText = L10n.tr('camera_status_choose_cache');
        this.scanning = false;
        const cacheChosen = await this.askCachingPreference();
        this.pendingCachingPrompt = false;
        this.log.add(`缓存询问结果: ${cacheChosen ? '启用' : '不启用'}，继续扫描`);
        this.scanning = true;
        this.statusText = L10n.tr('camera_status_connected');
      }

      // Phase 0: deploy cached snapshot (quick mode only, caching enabled, known camera)
      if (quickMode && this.cachingEnabled && this.cameraIdentity &&
          this.cachePrefs.hasCamera(this.cameraIdentity)) {
        this.log.add('[快速扫描] 部署缓存快照...');
        this.statusText = L10n.tr('camera_status_loading_cache');
        // Manifest must be loaded before findCached() can hit anything.
        this.thumbCache.init(this.filesDir, this.cameraIdentity);
        await this.thumbCache.loadManifest();
        await this.deployCacheSnapshot();
        this.log.add(`[快速扫描] 缓存快照就绪: ${this.photoCount} 张`);
      }

      // scanning stays true for the entire scan (Phase 1 → 2a → 2b)
      this.scanning = true;
      this.statusText = L10n.tr('camera_status_scanning');

      // Phase 1 + 2a + 2b (replaces old loadPhotosAndThumbnails)
      const scanOk = await this.loadPhotosAndThumbnails(quickMode);
      if (scanOk) {
        this.lastScanError = '';
      }

      // Defer registry validation so UI becomes responsive immediately
      this.validateRegistry().catch((_e: Error) => { /* best effort */ });
    } catch (err) {
      hilog.error(DOMAIN, TAG, `scan error: ${JSON.stringify(err)}`);
      this.reportScanFailure(this.describeScanError(err as Object));
      this.connected = false;
    } finally {
      this.scanning = false;
      await this.endTransferTask();
    }
  }

  /** 把扫描失败统一落到状态文案 + toast 计数上（ISSUE-001）。 */
  private reportScanFailure(message: string): void {
    this.statusText = message;
    this.lastScanError = message;
    this.scanErrorVersion++;
    this.usable = false;
    this.log.add(`扫描失败: ${message}`);
  }

  /** `PtpError` → 用户能看懂、且指得出下一步动作的文案（ISSUE-002）。 */
  private describeScanError(err: Object): string {
    if (err instanceof PtpError) {
      switch (err.code) {
        case 0x200F:
          return L10n.tr('camera_status_access_denied');
        case 0x200E:
          return L10n.tr('camera_status_store_readonly');
        case 0x2008:
          return L10n.tr('camera_status_invalid_storage');
        case PTP_ERR_NOT_OPEN:
          return L10n.tr('camera_status_session_lost');
        default:
          if (err.code < 0) return L10n.tr('camera_status_usb_error');
          return L10n.tr('camera_status_ptp_error', `0x${err.code.toString(16)}`);
      }
    }
    return L10n.tr('camera_status_scan_error');
  }

  /**
   * Recursively collect all photo handles by traversing the directory tree.
   * Uses GetObjectHandles format filtering (0x0000 vs 0x3001) to separate
   * files from directories with just 2 USB calls per directory level.
   * Detects format filter support once (via JPEG 0x3801 test) and caches
   * the result across all recursive levels.
   */
  private async collectPhotoHandles(
    storageIDs: number[], parent: number, depth: number,
    onBatchFound: (count: number) => void
  ): Promise<number[]> {
    if (depth > 10) return [];

    const result: number[] = [];
    for (const sid of storageIDs) {
      const allHandles = await this.session.getObjectHandles(sid, parent, 0);
      if (allHandles.length === 0) continue;

      // Detect format filter support once (only at first directory level)
      if (this.formatFilterWorks === null) {
        const jpegHandles = await this.session.getObjectHandles(sid, parent, 0x3801);
        this.formatFilterWorks = jpegHandles.length < allHandles.length;
      }

      if (this.formatFilterWorks) {
        const dirHandles = await this.session.getObjectHandles(sid, parent, 0x3001);
        const dirSet = new Set(dirHandles);
        const files: number[] = [];
        const dirs: number[] = [];
        for (const h of allHandles) {
          if (dirSet.has(h)) {
            dirs.push(h);
          } else {
            files.push(h);
          }
        }
        if (files.length > 0) {
          result.push(...files);
          onBatchFound(files.length);
        }
        for (const dh of dirs) {
          const sub = await this.collectPhotoHandles(storageIDs, dh, depth + 1, onBatchFound);
          result.push(...sub);
        }
      } else {
        // Camera doesn't support format filtering — per-handle getObjectInfo
        const dirs: number[] = [];
        for (const h of allHandles) {
          let info: ObjectInfo | null = null;
          try {
            info = await this.session.getObjectInfo(h);
          } catch (err) {
            this.log.add(`目录判定失败 handle=0x${h.toString(16)}: ${(err as Error).message}`);
            continue;
          }
          if (!info) continue;
          if (info.objectFormat === 0x3001) {
            dirs.push(h);
            hilog.info(DOMAIN, TAG,
              `Dir 0x${h.toString(16)}: ${info.filename}`);
          } else {
            result.push(h);
            onBatchFound(1);
          }
        }
        for (const dh of dirs) {
          const sub = await this.collectPhotoHandles(storageIDs, dh, depth + 1, onBatchFound);
          result.push(...sub);
        }
      }

      break;
    }
    return result;
  }

  /**
   * 试一次 GetObjectPropList（MTP 0x9805），判断能不能用一次事务拿回全部对象属性。
   *
   * 扫描的瓶颈是「每张一次 USB 往返」：Nikon 上 GetObjectInfo 约 30ms，
   * 1288 张就是 40s。若相机支持这个 MTP 扩展，同样 1288 张只要一笔事务。
   * 相机不支持是正常情况（返回 0x2005），这里只记录，不改变扫描流程。
   */
  private async probeObjectPropList(): Promise<void> {
    if (this.propListProbed) return;
    this.propListProbed = true;
    const advertised = this.deviceOps.includes(0x9805);
    // Nikon Z50_2 实测：不支持时 0x9805 不回响应，IN 端点在 10s 超时后才放弃，
    // 而且之后 3 条命令各失败一次、丢了 3 张照片（2026-11-09 真机）。
    // 所以“先试一下”只对自报支持的相机做，别再拿真实相机赌。
    if (!advertised) {
      this.log.add('[PROP_LIST] 相机未列出 GetObjectPropList，跳过探测');
      return;
    }
    const t0 = Date.now();
    try {
      const list = await this.session.getObjectPropList(0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF);
      const ms = Date.now() - t0;
      this.log.add(`[PROP_LIST] 耗时 ${ms}ms，声明 ${list.declared} / 解析 ${list.objects.length} 条 ` +
        `/ ${list.bytes}B / 完整=${list.complete ? '是' : '否'}（相机自报=${advertised ? '支持' : '未列出'}）`);
      const codes: string[] = [];
      for (const c of list.codes) {
        codes.push('0x' + c.toString(16));
      }
      this.log.add(`[PROP_LIST] 属性码 ${codes.length} 个: ${codes.join(',')}`);
      this.log.add(`[PROP_LIST] 数据头: ${list.head}`);
      if (list.objects.length > 0) {
        const f = list.objects[0];
        this.log.add(`[PROP_LIST] 样例 ${f.filename} size=${f.size} ` +
          `fmt=0x${f.format.toString(16)} date=${f.dateCreated || '(空)'} parent=0x${f.parent.toString(16)}`);
        const withName = list.objects.filter((o) => o.filename.length > 0).length;
        const withSize = list.objects.filter((o) => o.size > 0).length;
        const withDate = list.objects.filter((o) => o.dateCreated.length > 0).length;
        this.log.add(`[PROP_LIST] 字段覆盖: 文件名 ${withName} / 体积 ${withSize} / 日期 ${withDate}`);
      }
    } catch (err) {
      const ms = Date.now() - t0;
      this.log.add(`[PROP_LIST] 不可用（${ms}ms）: ${(err as Error).message}` +
        `（相机自报=${advertised ? '支持' : '未列出'}）`);
    }
  }

  /**
   * Traverse directories (instant with format filtering), then load photo
   * metadata and thumbnails in a single pass with a progress bar.
   *
   * 返回 true 表示存储可读、整轮扫描没有被中断。失败原因写进
   * `statusText` / `lastScanError`，并且**不清空已有照片**（ISSUE-005）。
   */
  private async loadPhotosAndThumbnails(quickMode: boolean): Promise<boolean> {
    this.statusText = L10n.tr('camera_status_fetching_list');
    this.scanProgress = 0;
    this.scanTotal = 0;
    // 逐笔事务的流水日志在 1288 张时会把日志环形缓冲冲掉，也白花拼串时间。
    setPtpQuietOps(true);
    this.statWalkMs = 0;
    this.statInfoMs = 0;
    this.statInfoCount = 0;
    this.statThumbMs = 0;
    this.statThumbCount = 0;
    this.statExifMs = 0;
    this.statExifCount = 0;
    this.statSaveMs = 0;
    this.statDecodeMs = 0;
    this.thumbCacheHits = 0;
    this.thumbUsbLoads = 0;
    this.thumbCacheFallback = 0;
    this.thumbDecoded = 0;

    try {
      const storageIDs = await this.session.getStorageIDs();
      hilog.info(DOMAIN, TAG, `StorageIDs count: ${storageIDs.length}`);

      if (storageIDs.length === 0) {
        // 相机明确返回空列表：这才是“没有存储”。与 0x200F“拒绝访问”区分开。
        this.reportScanFailure(L10n.tr('camera_status_no_storage'));
        return false;
      }
      // 存储读得到才算“可用”；`connected` 只表示 PTP 会话建立（ISSUE-003）。
      this.usable = true;

      // ---- Phase 1: traverse directories (2 getObjectHandles per level) ----
      this.statusText = L10n.tr('camera_status_walking_dirs');
      this.formatFilterWorks = null; // re-detect for this connection

      let foundCount = 0;
      const walkStart = Date.now();
      const allHandles = await this.collectPhotoHandles(storageIDs, 0xFFFFFFFF, 0,
        (count: number) => {
          foundCount += count;
          this.photoCount = foundCount;
        });
      this.statWalkMs = Date.now() - walkStart;
      const handles = allHandles;
      hilog.info(DOMAIN, TAG, `ObjectHandles total: ${allHandles.length}`);

      // ---- Phase 2a: metadata (reuse disk cache on quick scans) ----
      this.log.add(`开始加载 ${handles.length} 张照片元数据...`);
      this.scanProgress = 0;
      this.scanTotal = handles.length;
      this.scanPhaseText = L10n.tr('camera_phase_metadata');
      this.statusText = L10n.tr('camera_phase_loading_metadata');

      // Initialize thumbnail cache if enabled
      if (this.cameraIdentity) {
        this.thumbCache.init(this.filesDir, this.cameraIdentity);
        if (this.cachingEnabled) {
          await this.thumbCache.loadManifest();
          this.log.add('缩略图缓存已加载');
        }
        hilog.info(DOMAIN, TAG, '[CACHE] init done en=%{public}s id=%{public}s', this.cachingEnabled.toString(), this.cameraIdentity);
      }

      // 快速扫描的增量路径：handle 集合是相机的真话，缓存里有同 handle 的条目就直接复用，
      // 只对新增照片调 GetObjectInfo。抽样校验防止卡被格式化后 handle 被重用（ISSUE-009）。
      const cachedMeta = this.prepareMetadataReuse(quickMode);
      const canReuse = cachedMeta.size > 0 && await this.verifyMetadataSample(cachedMeta, handles);
      const reuseMeta = canReuse ? cachedMeta : new Map<number, PhotoEntry>();
      // 续扫时缓存只覆盖一部分 handle，仍需逐张读剩下的。
      const fullReuse = canReuse && reuseMeta.size >= handles.length;

      // 只有本轮真的要逐张读元数据时才值得探测合批能力（复用缓存时探测纯属浪费）。
      if (!canReuse) {
        await this.probeObjectPropList();
      }

      const photoList: PhotoEntry[] = [];
      const validCacheKeys: Set<string> = new Set();
      let reused = 0;
      let fetched = 0;
      let infoFailed = 0;

      // 交织只在“真的要读相机”时有意义：整份复用缓存时元数据是瞬时的，
      // 先一次读完再统一取缩略图更省事。断点续扫要读剩下的几千张，必须交织，
      // 否则用户要盯着旧快照一动不动地等到元数据读完。
      // 反过来 `!interleave` 就等价于「整份命中缓存」，循环里不会有 USB 调用。
      const interleave = !fullReuse;
      const chunkSize = interleave ? SCAN_CHUNK : handles.length;
      if (interleave) {
        // 相机 handle 基本按拍摄顺序递增，从后往前读：画廊顶部（最新）那几行最先有图。
        handles.reverse();
        this.scanPhaseText = L10n.tr('camera_phase_loading_photos');
      }

      let processed = 0;
      let lastPersisted = 0;
      while (processed < handles.length) {
        const chunkEnd = Math.min(processed + chunkSize, handles.length);
        for (; processed < chunkEnd; processed++) {
          const h = handles[processed];
          let entry: PhotoEntry | null = null;
          const cached = reuseMeta.get(h);
          if (cached) {
            entry = cached;
            reused++;
          } else {
            try {
              const infoStart = Date.now();
              const info = await this.session.getObjectInfo(h);
              this.statInfoMs += Date.now() - infoStart;
              this.statInfoCount++;
              if (info) {
                entry = {
                  handle: h,
                  filename: info.filename,
                  size: info.objectCompressedSize,
                  objectFormat: info.objectFormat,
                  captureDate: info.captureDate || '',
                  modificationDate: info.modificationDate || '',
                  imagePixWidth: info.imagePixWidth || 0,
                  imagePixHeight: info.imagePixHeight || 0,
                  storageId: info.storageId || 0
                };
                fetched++;
              }
            } catch (err) {
              // 单张失败（相机可能在扫描途中删了文件）不打断整轮扫描。
              infoFailed++;
              if (infoFailed <= 3) {
                this.log.add(`元数据失败 handle=0x${h.toString(16)}: ${(err as Error).message}`);
              }
            }
          }
          if (entry) {
            photoList.push(entry);
            validCacheKeys.add(`${entry.filename}::${entry.size}`);
          }
          this.scanProgress = processed + 1;
        }

        if (interleave) {
          // 已有缓存快照时列表「只增不减」：否则画廊会先缩到 64 张再慢慢长回去。
          // 冷启动（photos 为空）时这条恒成立，行为与之前一致。
          if (photoList.length >= this.photos.length) {
            this.publishPhotoList(photoList);
          }
          // 先把这一批的缩略图取回来，再读下一批元数据。总时长不变，
          // 但首屏不用等 1285 张元数据全部读完（真机实测那要 28s）。
          await this.loadThumbnailsRowByRow(validCacheKeys, false, false);
          this.scanTotal = handles.length;
          this.scanProgress = processed;

          // 断点续扫：每读 256 张就把已完成的条目落盘（complete=false）。
          // 应用被杀 / 退后台被回收 / 扫描失败时，下次全量扫描能从这里接着走。
          if (this.cameraIdentity && this.cachingEnabled &&
              fetched > 0 && processed - lastPersisted >= SCAN_PERSIST_EVERY) {
            this.saveMetadataCache(photoList, false);
            lastPersisted = processed;
          }
        }
      }

      this.publishPhotoList(photoList);

      // cleanupStaleMemoryCache: remove entries for deleted photos
      const validHandles = new Set<number>();
      for (const p of photoList) {
        validHandles.add(p.handle);
      }
      this.cleanupStaleMemoryCache(validHandles);

      // 元数据读完了，但缩略图可能还没取完：先按“未完成”落盘，
      // 缩略图全取完再改成 complete=true。整份复用缓存时不重写（内容没变）。
      if (this.cameraIdentity && this.cachingEnabled && fetched > 0) {
        this.saveMetadataCache(photoList, false);
      }

      this.log.add(`元数据获取完成: ${photoList.length} 张` +
        `（复用 ${reused} / 读取 ${fetched} / 失败 ${infoFailed}）`);

      // ---- Phase 2b: 缩略图 ----
      if (interleave) {
        // 交织模式下每批都已取过图，这里只做最后的发布与缓存收尾。
        await this.loadThumbnailsRowByRow(validCacheKeys, true, false);
        this.scanProgress = handles.length;
      } else {
        this.scanPhaseText = L10n.tr('camera_phase_thumbnails');
        this.statusText = L10n.tr('camera_phase_loading_thumbnails');
        await this.loadThumbnailsRowByRow(validCacheKeys);
      }

      // 缩略图阶段才拿到的方向/尺寸回写元数据缓存：下次快速扫描连 16KB EXIF 头都不用读。
      // 这一步同时把缓存标记为 complete=true，下一次全量扫描就不会误走断点续扫。
      if (this.cameraIdentity && this.cachingEnabled) {
        this.saveMetadataCache(this.photos, true);
      }

      // Compute scan stats for UI display
      {
        const total = this.photoCount;
        this.scanStatsText = L10n.tr('camera_scan_stats',
          L10n.plural('photo_count', total, total));
        this.log.add(this.scanStatsText);
      }

      this.log.add('缩略图加载完成');
      this.logScanTiming();

      this.statusText = L10n.tr('camera_status_photo_count',
        L10n.plural('photo_count', this.photoCount, this.photoCount));
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `loadPhotos error: ${JSON.stringify(err)}`);
      // 相机休眠/线松动后 USB pipe 已经死了。不主动关会话的话，下一次扫描
      // 仍会走进 sameDevice 分支复用这个死 pipe，表现为反复“USB 通信失败”。
      if (err instanceof PtpError && err.code === PTP_ERR_USB) {
        this.connected = false;
        this.usable = false;
        await this.session.closeSessionAndPipe();
      }
      // 不清空 photos / photoCount：失败时保留上一轮内容（ISSUE-005）。
      this.reportScanFailure(this.describeScanError(err as Object));
      this.scanStatsText = '';
      return false;
    } finally {
      setPtpQuietOps(false);
      this.scanProgress = 0;
      this.scanTotal = 0;
    }
  }

  /** 排序（拍摄时间 → 修改时间 → handle 降序）后整体替换 photos，触发画廊刷新。 */
  private publishPhotoList(photoList: PhotoEntry[]): void {
    photoList.sort((a: PhotoEntry, b: PhotoEntry): number => {
      const da = a.captureDate || '';
      const db = b.captureDate || '';
      if (da !== db) return db.localeCompare(da);
      const ma = a.modificationDate || '';
      const mb = b.modificationDate || '';
      if (ma !== mb) return mb.localeCompare(ma);
      return b.handle - a.handle;
    });
    this.photos = photoList.slice();
    this.photoCount = this.photos.length;
    this.photosVersion++;
  }

  /**
   * 可复用的元数据。返回空 Map 表示这次必须逐张读。
   *
   * 两条路径：
   * - **快速扫描**：缓存（7 天有效期）整份复用，只对新增 handle 读；
   * - **全量扫描**：只有当上一轮扫描**没跑完**（`complete=false`，24 小时内）才断点续扫，
   *   复用已读到的条目。跑完过的缓存不参与全量扫描，保持“全量＝重读一遍”的语义。
   */
  private prepareMetadataReuse(quickMode: boolean): Map<number, PhotoEntry> {
    if (!this.cachingEnabled || !this.cameraIdentity) {
      return new Map<number, PhotoEntry>();
    }
    const entries = this.loadMetadataCache();
    if (!entries || entries.length === 0) {
      return new Map<number, PhotoEntry>();
    }
    if (!quickMode && this.metadataCacheComplete) {
      // 上一次扫描完整跑完：全量扫描就是要重读，不复用。
      return new Map<number, PhotoEntry>();
    }
    const maxAge = quickMode ? METADATA_REUSE_MAX_AGE_MS : RESUME_MAX_AGE_MS;
    if (this.metadataCacheSavedAt <= 0 ||
        Date.now() - this.metadataCacheSavedAt > maxAge) {
      this.log.add('元数据缓存超过有效期，本次重新读取');
      return new Map<number, PhotoEntry>();
    }
    if (!this.metadataCacheComplete) {
      // 断点续扫：快速扫描也会走这条路（半份缓存），所以不能按扫描模式判断。
      const minutes = Math.max(1, Math.round((Date.now() - this.metadataCacheSavedAt) / 60000));
      this.log.add(`断点续扫: 上次扫描未完成，复用 ${entries.length} 条元数据（${minutes} 分钟前保存）`);
    }
    return this.metadataCacheByHandle;
  }

  /**
   * 抽样校验缓存与相机是否仍然一致。
   *
   * 只靠 handle 复用有风险：存储卡被格式化后，新文件可能拿到与旧缓存相同的 handle，
   * 于是界面会显示错误的文件名/日期，甚至会下载到“张冠李戴”的文件。
   * 这里对均匀抽取的少量 handle 重新调 GetObjectInfo 比对文件名与体积，
   * 不一致就放弃复用。代价约 8 × 31ms，远小于全量 39s。
   */
  private async verifyMetadataSample(
    cachedMeta: Map<number, PhotoEntry>,
    handles: number[]
  ): Promise<boolean> {
    if (cachedMeta.size === 0 || handles.length === 0) {
      return false;
    }
    // 从「缓存里真的有」的 handle 中均匀抽样。断点续扫时缓存只覆盖一部分 handle，
    // 若按全部 handle 抽样，命中率可能低到 1 个甚至 0 个（0 个会直接放弃复用，
    // 白白丢掉续扫进度）。
    const present: number[] = [];
    for (const h of handles) {
      if (cachedMeta.has(h)) {
        present.push(h);
      }
    }
    if (present.length === 0) {
      this.log.add('元数据缓存与相机不匹配：缓存里的 handle 都不在相机上，本次全量重读');
      return false;
    }
    const probed: number[] = [];
    const step = Math.max(1, Math.floor(present.length / METADATA_REUSE_PROBE));
    for (let i = 0; i < present.length && probed.length < METADATA_REUSE_PROBE; i += step) {
      probed.push(present[i]);
    }
    for (const h of probed) {
      const cached = cachedMeta.get(h)!;
      try {
        const info = await this.session.getObjectInfo(h);
        if (!info) {
          return false;
        }
        if (info.filename !== cached.filename ||
            info.objectCompressedSize !== cached.size) {
          this.log.add(`元数据缓存与相机不一致(handle=0x${h.toString(16)})，本次全量重读`);
          return false;
        }
      } catch (_e) {
        return false;
      }
    }
    this.log.add(`元数据复用校验通过: ${probed.length} 个样本一致，复用 ${cachedMeta.size} 条`);
    return true;
  }

  /**
   * Phase 2b: load thumbnails row by row (row width ≈ column count).
   * After each row is fully loaded, bump thumbnailVersion so GalleryPage
   * re-evaluates row completeness and shows the row all at once.
   */
  /**
   * Phase 2b: 缩略图流水线。
   *
   * 旧实现每行 4 张 `await Promise.all`：USB 串行，行内 3 张要等 200ms 轮询，
   * 行末还要等 4 张全部解码完才放下一行，USB 与解码互相卡。
   * 现在改成固定并发的工作池：取图（USB，调度器串行）与解码（TaskPool）重叠，
   * 每行在自己的 4 张都完成后才递增 `thumbnailVersion`，所以视觉上仍是整行出现。
   */
  private async loadThumbnailsRowByRow(
    validCacheKeys: Set<string>,
    finalize: boolean = true,
    manageProgress: boolean = true
  ): Promise<void> {
    const photos = this.photos;
    if (photos.length === 0) return;

    const rowWidth = 4;
    const rowCount = Math.ceil(photos.length / rowWidth);
    const rowRemaining: number[] = [];
    for (let r = 0; r < rowCount; r++) {
      rowRemaining.push(0);
    }

    // 先判定每张的路径，worker 里不再重复查缓存。
    const skip: boolean[] = [];
    const cachedEntries: Array<CacheEntry | null> = [];
    let cacheHits = 0;
    let usbLoads = 0;
    for (let i = 0; i < photos.length; i++) {
      const photo = photos[i];
      skip.push(false);
      cachedEntries.push(null);
      // 两个集合要同时命中才算真的“已有图”，否则会漏加载、单元格永远停在占位符。
      if (this.thumbnailLoadedSet.has(photo.handle)
        && this.thumbnailPixelMapMap.has(photo.handle)) {
        skip[i] = true;
        continue;
      }
      const key = `${photo.filename}::${photo.size}`;
      const modDate = photo.modificationDate || '';
      if (this.cachingEnabled && key) {
        const cachedEntry = this.thumbCache.findCached(key, modDate);
        if (cachedEntry) {
          cachedEntries[i] = cachedEntry;
          cacheHits++;
          rowRemaining[Math.floor(i / rowWidth)]++;
          continue;
        }
      }
      usbLoads++;
      rowRemaining[Math.floor(i / rowWidth)]++;
    }

    if (manageProgress) {
      this.scanProgress = 0;
      this.scanTotal = photos.length;
      this.lastDecodedHandle = -1;
    }

    let completed = 0;
    let lastProgressAt = Date.now();
    const bumpProgress = (): void => {
      const now = Date.now();
      if (now - lastProgressAt >= 100 || completed >= photos.length) {
        this.scanProgress = completed;
        lastProgressAt = now;
      }
    };

    // 8 个 worker 会让第 N+1 行先于第 N 行完成；这里按行号顺序发布，
    // 只把「从最上面开始连续完成的行」一次性刷给画廊，视觉上仍然是自上而下整行出现。
    const rowDone: boolean[] = [];
    for (let r = 0; r < rowCount; r++) {
      rowDone.push(rowRemaining[r] === 0);
    }
    let publishedRow = 0;
    const publishCompletedRows = (): void => {
      let advanced = false;
      while (publishedRow < rowCount && rowDone[publishedRow]) {
        publishedRow++;
        advanced = true;
      }
      if (!advanced) return;
      this.thumbnailVersion++;
      this.thumbCache.maybePersist();
      // 预览器刷新用：取刚发布区域最后一行的最后一个已有图 handle。
      const rowStart = (publishedRow - 1) * rowWidth;
      const rowEnd = Math.min(rowStart + rowWidth, photos.length);
      for (let j = rowEnd - 1; j >= rowStart; j--) {
        if (this.thumbnailLoadedSet.has(photos[j].handle)) {
          this.lastDecodedHandle = photos[j].handle;
          break;
        }
      }
    };

    const finishOne = (index: number): void => {
      completed++;
      const row = Math.floor(index / rowWidth);
      rowRemaining[row]--;
      if (rowRemaining[row] === 0) {
        rowDone[row] = true;
        publishCompletedRows();
      }
      bumpProgress();
    };

    let next = 0;
    const worker = async (): Promise<void> => {
      while (this.connected) {
        const i = next++;
        if (i >= photos.length) return;
        if (skip[i]) {
          completed++;
          bumpProgress();
          continue;
        }
        const photo = photos[i];
        const cached = cachedEntries[i];
        const cacheKey = `${photo.filename}::${photo.size}`;
        try {
          if (cached) {
            const ok = await this.loadCachedThumbnail(photo.handle, cacheKey, cached);
            if (!ok) {
              // manifest 里的条目指向的文件已经不在了（例如「缓存管理」刚清过缓存）。
              // 必须回退到 USB，否则这张会永远停在占位符。
              this.thumbCacheFallback++;
              await this.loadSingleThumbnail(photo, cacheKey, photo.modificationDate || '');
            }
          } else {
            await this.loadSingleThumbnail(photo, cacheKey,
              photo.modificationDate || '');
          }
        } finally {
          finishOne(i);
        }
      }
    };

    const workerCount = Math.min(THUMB_PIPELINE, photos.length);
    const workers: Promise<void>[] = [];
    for (let w = 0; w < workerCount; w++) {
      workers.push(worker());
    }
    await Promise.all(workers);

    // 断连时 worker 会提前退出，不要把进度条补满成“已完成”。
    if (manageProgress) {
      this.scanProgress = this.connected ? photos.length : completed;
    }

    this.thumbCacheHits += cacheHits;
    this.thumbUsbLoads += usbLoads;
    if (finalize) {
      this.log.add(`缩略图阶段: 磁盘命中 ${this.thumbCacheHits} / USB 读取 ${this.thumbUsbLoads}` +
        ` / 解码成功 ${this.thumbDecoded}` +
        `${this.thumbCacheFallback > 0 ? ` / 缓存失效回退 ${this.thumbCacheFallback}` : ''}`);
    }

    // Phase 2b complete: final cleanup（交织模式下每批都调，收尾只做一次）
    if (finalize && this.cachingEnabled) {
      await this.thumbCache.flush();
      if (validCacheKeys.size > 0) {
        const purged = await this.thumbCache.purgeStale(validCacheKeys);
        if (purged > 0) {
          this.log.add(`缓存清理: 移除了 ${purged} 个过期条目`);
        }
      }
      this.thumbCache.close();
    }
  }

  /**
   * Load a single photo's thumbnail via USB: getThumb + EXIF + decode + cache save.
   *
   * 三处省时（ISSUE-007）：
   * 1. 方向已缓存在 metadata_cache.json 时不再读 16KB EXIF 头；
   * 2. 原始尺寸优先用 PTP ObjectInfo 的 imagePixWidth/Height（NEF 也拿得到），
   *    只有 PTP 给 0 时才回退到 EXIF；
   * 3. 只落一次盘：原始 JPEG + manifest 里的变换参数，解码时再裁剪，
   *    不再“先存原始、解码后再编码覆盖同一文件”。
   */
  private async loadSingleThumbnail(
    photo: PhotoEntry,
    cacheKey: string,
    modDate: string
  ): Promise<void> {
    try {
      const h = photo.handle;
      const thumbStart = Date.now();
      const thumbData = await this.session.getThumb(h);
      this.statThumbMs += Date.now() - thumbStart;
      this.statThumbCount++;
      if (!thumbData || thumbData.length === 0) {
        this.log.add(`[NO_THUMB] handle=0x${h.toString(16)} ${photo.filename}`);
        return;
      }

      // 方向：元数据缓存 → 本次扫描已解析 → 缩略图自带 EXIF → 读原图 EXIF 头
      let orient: OrientationTransform | null = null;
      if (photo.exifRotate !== undefined && photo.exifFlipH !== undefined &&
          photo.exifFlipV !== undefined) {
        orient = new OrientationTransform(photo.exifRotate, photo.exifFlipH, photo.exifFlipV);
      } else if (this.orientationMap.has(h)) {
        orient = this.orientationMap.get(h)!;
      }

      // 原始尺寸：PTP 元数据优先（NEF 的 EXIF 尺寸在 SubIFD，16KB 窗口读不到）
      let dim: OrientedSize | null = null;
      if (photo.imagePixWidth !== undefined && photo.imagePixWidth > 0 &&
          photo.imagePixHeight !== undefined && photo.imagePixHeight > 0) {
        dim = new OrientedSize(photo.imagePixWidth, photo.imagePixHeight);
      }

      // 缩略图 JPEG 常常原样带着原图的 EXIF，能直接读到方向。
      // 省掉一次 GetPartialObject 就是省掉每张一次 USB 往返（实测 15–30ms）。
      let thumbOrient: OrientationTransform | null = null;
      if (orient === null && this.thumbExifTrust !== 0) {
        thumbOrient = await CameraService.readThumbOrientation(thumbData);
        if (thumbOrient === null) {
          this.thumbExifMissing++;
          if (this.thumbExifSamples === 0 && this.thumbExifMissing >= 8) {
            this.thumbExifTrust = 0;
            this.log.add('缩略图不带 EXIF 方向，继续逐张读原图 EXIF 头');
          }
        } else if (this.thumbExifTrust === 1) {
          orient = thumbOrient;
        }
      }

      // 还要不要读原图 16KB：
      //   尺寸未知 → 必须读（读不到原始比例，缩略图的黑边就裁不掉）
      //   方向未知 → 必须读
      //   验证期且缩略图给了方向 → 也要读一次，用原图方向做真值比对
      const verifying = thumbOrient !== null && this.thumbExifTrust === null;
      const needPartial = dim === null || orient === null || verifying;

      if (needPartial) {
        const exifStart = Date.now();
        let partial: Uint8Array | null = null;
        try {
          partial = await this.session.getPartialObject(h, 0, 16384);
        } catch (err) {
          // 相机不支持 GetPartialObject 时不该让整张缩略图失败
          this.log.add(`[EXIF] handle=0x${h.toString(16)} 读取失败: ${(err as Error).message}`);
        }
        this.statExifMs += Date.now() - exifStart;
        this.statExifCount++;
        if (partial && partial.length > 0) {
          try {
            if (orient === null) {
              const origOrient = await this.getOrientation(h, partial.buffer as ArrayBuffer);
              orient = origOrient;
              if (verifying) {
                this.trackThumbExif(origOrient, thumbOrient!);
              }
            }
            if (dim === null) {
              dim = CameraService.parseExifDims(partial.buffer as ArrayBuffer);
            }
          } catch (_e) { /* best effort */ }
        }
      }

      if (orient !== null) {
        this.preloadedOrientations.set(h, orient);
        // 回写到 PhotoEntry，扫描结束时随 metadata_cache.json 落盘
        photo.exifRotate = orient.rotate;
        photo.exifFlipH = orient.flipH;
        photo.exifFlipV = orient.flipV;
      }
      if (dim !== null) {
        this.exifOrigDims.set(h, dim);
      }

      await this.decodeThumbnail(h, thumbData, cacheKey, modDate);
    } catch (err) {
      this.log.add(`缩略图加载失败: ${photo.filename} ${(err as Error).message}`);
    }
  }

  /** Deploy cached metadata + thumbnails for instant gallery rendering (Phase 0). */
  async deployCacheSnapshot(): Promise<void> {
    const entries = this.loadMetadataCache();
    if (!entries || entries.length === 0) return;

    // Sort cached entries newest-first (same as Phase 2a sorting)
    entries.sort((a: PhotoEntry, b: PhotoEntry): number => {
      const da = a.captureDate || '';
      const db = b.captureDate || '';
      if (da !== db) return db.localeCompare(da);
      const ma = a.modificationDate || '';
      const mb = b.modificationDate || '';
      if (ma !== mb) return mb.localeCompare(ma);
      return b.handle - a.handle;
    });

    // Populate photos (triggers gallery to show dates + placeholders)
    this.photos = entries;
    this.photoCount = entries.length;
    this.photosVersion++;

    // Load all cached thumbnails from disk
    const cacheLoads: Promise<void>[] = [];
    for (const entry of entries) {
      const key = `${entry.filename}::${entry.size}`;
      const modDate = entry.modificationDate || '';
      const cached = this.thumbCache.findCached(key, modDate);
      if (cached) {
        cacheLoads.push(this.loadCachedThumbnail(entry.handle, key, cached)
          .then(() => {}).catch(() => {}));
      }
    }

    if (cacheLoads.length > 0) {
      await Promise.all(cacheLoads);
    }
    this.thumbnailVersion++;
    this.log.add(`缓存快照: ${entries.length} 张照片, ${cacheLoads.length} 个缩略图`);
  }

  /** Load cached PhotoEntry[] from metadata_cache.json */
  private loadMetadataCache(): PhotoEntry[] | null {
    if (!this.cameraIdentity) return null;
    const path = this.thumbCache.getCacheDir() + '/metadata_cache.json';
    const text = AtomicFile.readText(path);
    if (text === null || text === '') return null;
    try {
      const raw: Record<string, Object> = JSON.parse(text);
      const rawEntries = raw['entries'] as PhotoEntry[] | undefined;
      const savedAt = raw['savedAt'] as number;
      this.metadataCacheSavedAt = typeof savedAt === 'number' ? savedAt : 0;
      // 旧文件没有 complete 字段，按“已完成”处理。
      this.metadataCacheComplete = raw['complete'] !== false;
      this.metadataCacheByHandle = new Map<number, PhotoEntry>();
      if (rawEntries) {
        for (const entry of rawEntries) {
          this.metadataCacheByHandle.set(entry.handle, entry);
        }
      }
      if (rawEntries && rawEntries.length > 0) {
        this.log.add(`元数据缓存加载: ${rawEntries.length} 条`);
        return rawEntries;
      }
    } catch (_e) {
      this.log.add('元数据缓存损坏，忽略');
    }
    return null;
  }

  /** Persist PhotoEntry[] to metadata_cache.json */
  private saveMetadataCache(entries: PhotoEntry[], complete: boolean = true): void {
    if (!this.cameraIdentity) return;
    try {
      fileIo.mkdirSync(this.thumbCache.getCacheDir(), true);
    } catch (_e) { /* best effort */ }
    try {
      const path = this.thumbCache.getCacheDir() + '/metadata_cache.json';
      // `complete=false` 表示这轮扫描还没跑完：下次全量扫描据它决定是否断点续扫。
      // 扫描结束时再写一次 `complete=true`，从此刻起缓存只用于快速扫描的复用。
      const text = JSON.stringify({ version: 2, savedAt: Date.now(), complete: complete, entries: entries });
      AtomicFile.writeText(path, text);
      this.metadataCacheComplete = complete;
      // 同步内存索引，让同一进程内下一次快速扫描也能复用。
      this.metadataCacheByHandle = new Map<number, PhotoEntry>();
      for (const entry of entries) {
        this.metadataCacheByHandle.set(entry.handle, entry);
      }
      this.metadataCacheSavedAt = Date.now();
      this.log.add(`元数据缓存已保存: ${entries.length} 条` +
        `${complete ? '' : '（扫描未完成，可续扫）'}`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'saveMetadataCache failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Clean up stale in-memory caches for handles no longer in the photo list. */
  private cleanupStaleMemoryCache(validHandles: Set<number>): void {
    const stale: number[] = [];
    this.thumbnailPixelMapMap.forEach((_pm: image.PixelMap, h: number) => {
      if (!validHandles.has(h)) {
        stale.push(h);
      }
    });
    for (const h of stale) {
      const pm = this.thumbnailPixelMapMap.get(h);
      if (pm) { try { pm.release(); } catch (_e) { /* best effort */ } }
      this.thumbnailPixelMapMap.delete(h);
      this.thumbnailLoadedSet.delete(h);
      this.preloadedOrientations.delete(h);
      this.exifOrigDims.delete(h);
      this.orientationMap.delete(h);
      this.orientedDisplaySizes.delete(h);
    }
    if (stale.length > 0) {
      this.log.add(`内存缓存清理: 移除了 ${stale.length} 个失效条目`);
    }
  }

  /**
   * 从 GetThumb 返回的 JPEG 里读 EXIF 方向。
   *
   * 相机没写 EXIF、或属性为空时返回 `null`，调用方回退到「读原图 16KB」。
   * 这里只解析元数据、不解码像素，单张约 1ms。
   */
  private static async readThumbOrientation(data: Uint8Array): Promise<OrientationTransform | null> {
    try {
      const buf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const src = image.createImageSource(buf);
      try {
        const raw = await src.getImageProperty(image.PropertyKey.ORIENTATION);
        if (!raw) return null;
        return CameraService.mapExifOrientation(raw);
      } finally {
        try { src.release(); } catch (_e) { /* best effort */ }
      }
    } catch (_e) {
      return null;
    }
  }

  /**
   * 缩略图 EXIF 方向的取样比对。
   *
   * 只要出现一次不一致，就永久判为不可信（本会话），后续继续逐张读原图；
   * 样本够多且包含竖拍（rotate≠0 或 flip）才敢切换，否则“全是横拍”的
   * 全部一致无法证明什么。
   */
  private trackThumbExif(orig: OrientationTransform, thumb: OrientationTransform): void {
    const same = orig.rotate === thumb.rotate && orig.flipH === thumb.flipH &&
      orig.flipV === thumb.flipV;
    this.thumbExifSamples++;
    if (!same) {
      this.thumbExifMismatch++;
      if (this.thumbExifTrust !== 0) {
        this.thumbExifTrust = 0;
        this.log.add(`缩略图EXIF方向与原图不一致（原图 ${orig.rotate}/${orig.flipH}/${orig.flipV}，` +
          `缩略图 ${thumb.rotate}/${thumb.flipH}/${thumb.flipV}），继续读原图 EXIF`);
      }
      return;
    }
    if (orig.rotate !== 0 || orig.flipH || orig.flipV) {
      this.thumbExifPortrait++;
    }
    if (this.thumbExifTrust === null && this.thumbExifSamples >= 12 && this.thumbExifPortrait >= 3) {
      this.thumbExifTrust = 1;
      this.log.add(`缩略图EXIF方向可信：${this.thumbExifSamples} 个样本（竖拍 ${this.thumbExifPortrait}）` +
        `全部一致，后续跳过 GetPartialObject`);
    }
  }

  /** 把本轮的阶段耗时汇总成一行日志，用来判断下一次该优化哪一段。 */
  private logScanTiming(): void {
    const avg = (ms: number, n: number): string => n > 0 ? `${Math.round(ms / n)}` : '-';
    this.log.add(`扫描耗时: 遍历 ${this.statWalkMs}ms | ` +
      `元数据 ${this.statInfoMs}ms/${this.statInfoCount}张(均${avg(this.statInfoMs, this.statInfoCount)}ms) | ` +
      `缩略图USB ${this.statThumbMs}ms/${this.statThumbCount}张(均${avg(this.statThumbMs, this.statThumbCount)}ms) | ` +
      `EXIF头 ${this.statExifMs}ms/${this.statExifCount}次(均${avg(this.statExifMs, this.statExifCount)}ms) | ` +
      `落盘 ${this.statSaveMs}ms | 解码 ${this.statDecodeMs}ms`);
    const trustText = this.thumbExifTrust === 1 ? '可信（已跳过读原图）'
      : this.thumbExifTrust === 0 ? '不可信（继续读原图）' : '样本不足';
    this.log.add(`缩略图EXIF方向: ${trustText} / 样本 ${this.thumbExifSamples} ` +
      `/ 竖拍 ${this.thumbExifPortrait} / 不一致 ${this.thumbExifMismatch} / 无EXIF ${this.thumbExifMissing}`);
  }

  private async decodeThumbnail(
    handle: number,
    data: Uint8Array,
    cacheKey?: string,
    modDate?: string
  ): Promise<void> {
    try {
      const orient = this.preloadedOrientations.get(handle);
      const exifDim = this.exifOrigDims.get(handle);

      // 1) Persist the raw JPEG together with the EXIF transform. 缓存里不再
      //    存“纠正后重新编码”的第二份文件：解码时本来就要裁剪，缓存命中时
      //    按 manifest 里的 rotate/flip/origWidth/origHeight 再裁一次即可。
      //    这样就少了每张一次的 ImagePacker 编码 + 覆盖写（ISSUE-007）。
      if (this.cachingEnabled && cacheKey && modDate) {
        const saveStart = Date.now();
        await this.thumbCache.saveRawThumbnail(cacheKey, modDate, data, handle,
          orient?.rotate ?? 0, orient?.flipH ?? false, orient?.flipV ?? false,
          exifDim?.w, exifDim?.h);
        this.statSaveMs += Date.now() - saveStart;
      }

      // 为 TaskPool 复制一份 ArrayBuffer（源数据不会被缓存，直接转移所有权）
      const decodeBuf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);

      const task = new taskpool.Task(
        decodeThumbnailTask,
        decodeBuf,
        orient?.rotate ?? 0,
        orient?.flipH ?? false,
        orient?.flipV ?? false,
        exifDim?.w ?? 0,
        exifDim?.h ?? 0
      );

      try {
        const decodeStart = Date.now();
        const pixelMap = await taskpool.execute(task) as image.PixelMap;
        this.statDecodeMs += Date.now() - decodeStart;
        const info = await pixelMap.getImageInfo();
        this.thumbnailPixelMapMap.set(handle, pixelMap);
        this.orientedDisplaySizes.set(handle, new OrientedSize(info.size.width, info.size.height));
        this.thumbnailLoadedSet.add(handle);
        // Notify PhotoViewer of fresh thumbnail
        this.lastDecodedHandle = handle;
        this.thumbDecoded++;
        // 逐张日志只进 hilog：1288 张写进 AppLog 会把有用的摘要顶出 500 条环形缓冲。
        hilog.info(DOMAIN, TAG, '[TASKPOOL_THUMB] handle=0x%{public}s done %{public}dx%{public}d',
          handle.toString(16), info.size.width, info.size.height);
      } catch (err) {
        hilog.error(DOMAIN, TAG, `[TASKPOOL_THUMB] FAIL handle=0x%{public}s err=%{public}s`,
          handle.toString(16), JSON.stringify(err));
        this.log.add(`缩略图解码失败(worker): handle=0x${handle.toString(16)}`);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `[THUMB_SUBMIT] FAIL handle=0x%{public}s err=%{public}s`,
        handle.toString(16), JSON.stringify(err));
      this.log.add(`缩略图提交失败: handle=0x${handle.toString(16)}`);
    }
  }

  // (redecodeThumbnailWithOrientation removed — orientation is now applied
  // at initial thumbnail decode via preloadedOrientations)

  /**
   * 前台取一张原图并放进缓存。
   *
   * `preloadingSet` 用来阻止同一张被邻近预加载重复下载；调度器会把这次
   * `getObject` 排到 PRELOAD/SCAN 前面，用户不用等整条扫描队列。
   */
  private async fetchFullPhotoForeground(handle: number, startedAt: number,
    waited: boolean, priority: PtpPriority): Promise<Uint8Array | null> {
    this.preloadingSet.add(handle);
    try {
      const data = await this.session.getObject(handle, priority);
      if (!data || data.length === 0) return null;
      const t1 = Date.now();
      const sizeMB = (data.length / 1048576).toFixed(1);
      const usbSec = ((t1 - startedAt) / 1000).toFixed(1);
      this.log.add(`USB下载${waited ? '(等超时)' : ''}: ${sizeMB}MB ${usbSec}s`);
      this.addToCache(handle, data);
      return data;
    } finally {
      this.preloadingSet.delete(handle);
    }
  }

  /** PTP 元数据里的原图长边；未知返回 0。 */
  private photoLongEdge(handle: number): number {
    for (const p of this.photos) {
      if (p.handle === handle) {
        const w = p.imagePixWidth ?? 0;
        const h = p.imagePixHeight ?? 0;
        return Math.max(w, h);
      }
    }
    return 0;
  }

  /**
   * 取一张照片的**原始压缩字节**（相机返回的 JPEG，不重新编码）。
   *
   * 预览器「分享原图」用：优先命中 compressedCache（查看原图时已经取过）；
   * 未命中时复用串行 USB 取图，结果也放进缓存。扫描中直接返回 null，
   * 避免和扫描队列抢同一条 USB 管道。
   */
  async getOriginalBytes(handle: number,
    priority: PtpPriority = PtpPriority.FOREGROUND): Promise<Uint8Array | null> {
    if (this.scanning) return null;
    if (this.compressedCache.has(handle)) {
      return this.compressedCache.get(handle)!;
    }
    if (this.preloadingSet.has(handle)) {
      await this.waitForPreload(handle, 5000);
      if (this.compressedCache.has(handle)) {
        return this.compressedCache.get(handle)!;
      }
    }
    return this.fetchFullPhotoForeground(handle, Date.now(), false, priority);
  }

  async loadFullPhoto(handle: number,
    priority: PtpPriority = PtpPriority.FOREGROUND,
    onPreview?: (pm: image.PixelMap, w: number, h: number) => void): Promise<DecodedPhotoResult | null> {
    try {
      const t0 = Date.now();
      let data: Uint8Array | null = null;
      let hit = false;

      if (this.compressedCache.has(handle)) {
        data = this.compressedCache.get(handle)!;
        hit = true;
      } else if (this.preloadingSet.has(handle)) {
        // 邻居预加载正在传这张：等完成通知，不再 200ms 轮询。
        await this.waitForPreload(handle, 5000);
        if (this.compressedCache.has(handle)) {
          data = this.compressedCache.get(handle)!;
          hit = true;
        } else {
          data = await this.fetchFullPhotoForeground(handle, t0, true, priority);
          if (!data) return null;
        }
      } else {
        data = await this.fetchFullPhotoForeground(handle, t0, false, priority);
        if (!data) return null;
      }

      // 取图结束（含等待邻近预加载的时间）
      const tData = Date.now();

      // 读取 EXIF 方向（主线程读取元数据，很快）
      const orient = await this.getPhotoOrientation(handle, data.buffer as ArrayBuffer);
      const tOrient = Date.now();

      // 为 TaskPool 克隆一份 ArrayBuffer，主线程保留原始数据用于缓存
      const decodeBuf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const tCopy = Date.now();

      // 先解一张屏幕级预览：用户很快看到可用的图，3072 全尺寸在后台继续解。
      const srcEdge = this.photoLongEdge(handle);
      const previewUseful = srcEdge <= 0 || srcEdge > PREVIEW_DECODE_MAX_EDGE;
      if (onPreview !== undefined && priority === PtpPriority.FOREGROUND && previewUseful) {
        try {
          const previewBuf = decodeBuf.slice(0);
          const previewTask = new taskpool.Task(
            decodeFullPhotoTask,
            previewBuf,
            orient.rotate,
            orient.flipH,
            orient.flipV,
            PREVIEW_DECODE_MAX_EDGE
          );
          const preview = await taskpool.execute(previewTask) as image.PixelMap;
          const previewInfo = await preview.getImageInfo();
          onPreview(preview, previewInfo.size.width, previewInfo.size.height);
        } catch (_e) {
          // 预览失败不阻塞全尺寸解码
        }
      }

      const task = new taskpool.Task(
        decodeFullPhotoTask,
        decodeBuf,
        orient.rotate,
        orient.flipH,
        orient.flipV,
        FULL_DECODE_MAX_EDGE
      );

      let pixelMap: image.PixelMap;
      try {
        pixelMap = await taskpool.execute(task) as image.PixelMap;
      } catch (err) {
        this.log.add(`全尺寸解码失败(worker): handle=0x${handle.toString(16)}`);
        return null;
      }

      const t2 = Date.now();
      const tag = hit ? '缓存命中' : '下载完成';
      // 分开记「取图 / 方向 / 拷贝 / 解码」四段：真机上这几段里哪一段占大头，
      // 直接决定「第一次打开照片卡一下」该从哪下手（USB 串行管道 vs 主线程拷贝）。
      this.log.add(`${tag}: ${((t2 - t0) / 1000).toFixed(1)}s` +
        ` (取图 ${tData - t0}ms / 方向 ${tOrient - tData}ms` +
        ` / 拷贝 ${tCopy - tOrient}ms / 解码 ${t2 - tCopy}ms)`);

      // 读取旋转后的实际尺寸
      const info = await pixelMap.getImageInfo();
      const displayW = info.size.width;
      const displayH = info.size.height;
      this.orientedDisplaySizes.set(handle, new OrientedSize(displayW, displayH));

      return new DecodedPhotoResult(pixelMap, displayW, displayH);
    } catch (err) {
      this.log.add(`全尺寸加载失败: handle=0x${handle.toString(16)} ` +
        `${(err as Error).message}`);
      if (err instanceof PtpError && err.code === PTP_ERR_USB) {
        // 取图过程中 USB 链路已经死了：关会话，下一次搜索重新连接，
        // 避免后续每张图都继续打这条死管道。
        this.connected = false;
        this.usable = false;
        await this.session.closeSessionAndPipe();
      }
      return null;
    }
  }

  /**
   * Read EXIF orientation from full photo data. Unlike thumbnails, full-resolution
   * camera files (JPEG/RAW) contain EXIF metadata with the Orientation tag.
   * Falls back to cached orientation (from a prior thumbnail decode) if available.
   */
  private async getPhotoOrientation(handle: number, data: ArrayBuffer): Promise<OrientationTransform> {
    // Check cache first (might have been populated by a prior full decode)
    if (this.orientationMap.has(handle)) {
      const cached = this.orientationMap.get(handle)!;
      if (cached.rotate !== 0 || cached.flipH || cached.flipV) {
        return cached;
      }
    }
    try {
      const imgSrc = image.createImageSource(data);
      const orientation = await imgSrc.getImageProperty(image.PropertyKey.ORIENTATION);
      imgSrc.release();
      hilog.info(DOMAIN, TAG, `[ORIENT] full res handle=0x%{public}s raw="%{public}s"`,
        handle.toString(16), orientation);
      const result = CameraService.mapExifOrientation(orientation);
      this.orientationMap.set(handle, result);
      return result;
    } catch (err) {
      hilog.error(DOMAIN, TAG, `[ORIENT] full res FAIL handle=0x%{public}s err=%{public}s`,
        handle.toString(16), JSON.stringify(err));
      // Fallback: use cached value or default
      const result = new OrientationTransform(0, false, false);
      this.orientationMap.set(handle, result);
      return result;
    }
  }

  private addToCache(handle: number, data: Uint8Array): void {
    if (this.compressedCache.has(handle)) return;
    // Evict if needed
    while (this.cacheTotalBytes + data.length > this.cacheMaxBytes && this.compressedCache.size > 0) {
      this.evictFurthest();
    }
    this.compressedCache.set(handle, data);
    this.cacheTotalBytes += data.length;
  }

  private evictFurthest(): void {
    // Map each cached handle to its position in the viewer's photo list.
    // (Comparing handles directly against a list index evicted the wrong photo.)
    const order: Map<number, number> = new Map();
    for (let i = 0; i < this.preloadPhotos.length; i++) {
      order.set(this.preloadPhotos[i].handle, i);
    }
    let furthestHandle = -1;
    let maxDist = -1;
    this.compressedCache.forEach((_v: Uint8Array, k: number) => {
      const idx = order.get(k);
      const dist = idx === undefined ? Number.MAX_SAFE_INTEGER : Math.abs(idx - this.detailIndex);
      if (dist > maxDist) { maxDist = dist; furthestHandle = k; }
    });
    if (furthestHandle >= 0) {
      const removed = this.compressedCache.get(furthestHandle);
      if (removed) {
        this.cacheTotalBytes -= removed.length;
        this.compressedCache.delete(furthestHandle);
      }
    }
  }

  private preloadPhotos: PhotoEntry[] = [];

  setDetailIndex(idx: number, photos: PhotoEntry[]): void {
    if (this.detailIndex === idx) return;
    this.prevDetailIndex = this.detailIndex;
    this.detailIndex = idx;
    this.preloadPhotos = photos;
    this.schedulePreload(photos.length);
  }

  private preloadTimer: number = -1;

  private schedulePreload(total: number): void {
    if (this.preloadTimer >= 0) clearTimeout(this.preloadTimer);
    this.preloadTimer = setTimeout(() => { this.preloadAdjacent(total); }, 200);
  }

  private detectSwipeDirection(): number {
    if (this.prevDetailIndex < 0) return 1; // initial, assume right
    return this.detailIndex - this.prevDetailIndex;
  }

  private async preloadAdjacent(total: number): Promise<void> {
    if (this.preloading) return;
    // 预览器打开时整体让路：它自己的队列会按需取图，两边同时下载只会
    // 在串行的 USB 管道上互相插队，把「正在看的这张」拖慢。
    if (this.neighborPreloadSuspended) return;
    this.preloading = true;

    const direction = this.detectSwipeDirection();
    // Build priority queue: photos ordered by distance from current, biased by direction
    const queue: number[] = [];
    for (let d = 1; d <= this.preloadRadius; d++) {
      const ahead = this.detailIndex + d * direction;
      const behind = this.detailIndex - d * direction;
      if (ahead >= 0 && ahead < total) queue.push(ahead);
      if (behind >= 0 && behind < total) queue.push(behind);
    }

    for (const qi of queue) {
      if (!this.preloading) break;
      if (this.neighborPreloadSuspended) break;
      const photo = this.preloadPhotos[qi];
      if (!photo) continue;
      if (this.compressedCache.has(photo.handle)) continue;
      if (this.preloadingSet.has(photo.handle)) continue;
      this.preloadingSet.add(photo.handle);
      let loaded = false;
      try {
        // PRELOAD 低于前台取图，但高于扫描：用户在看的那张永远先走。
        const data = await this.session.getObject(photo.handle, PtpPriority.PRELOAD);
        if (data && data.length > 0) {
          this.addToCache(photo.handle, data);
          loaded = true;
          const sizeMB = (data.length / 1048576).toFixed(1);
          this.log.add(`预加载[${qi}]: ${sizeMB}MB (缓存${this.compressedCache.size}张/${(this.cacheTotalBytes/1048576).toFixed(0)}MB)`);
        }
      } catch (_e) {
        // preload failure is non-critical
      } finally {
        this.preloadingSet.delete(photo.handle);
        this.notifyPreloadWaiters(photo.handle, loaded);
      }
    }
    this.preloading = false;
  }

  /**
   * 等某张原图的预加载完成。超时返回 false，由调用方前台直取。
   * 以前这里是 25 次 200ms 轮询；现在由 `notifyPreloadWaiters` 立即唤醒。
   */
  private waitForPreload(handle: number, timeoutMs: number): Promise<boolean> {
    if (this.compressedCache.has(handle)) return Promise.resolve(true);
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      let settled = false;
      let timer: number = -1;
      const finish = (ok: boolean): void => {
        if (settled) return;
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        const waiters = this.preloadWaiters.get(handle);
        if (waiters) {
          const idx = waiters.indexOf(finish);
          if (idx >= 0) waiters.splice(idx, 1);
          if (waiters.length === 0) this.preloadWaiters.delete(handle);
        }
        resolve(ok);
      };
      timer = setTimeout(() => { finish(this.compressedCache.has(handle)); }, timeoutMs);
      let waiters = this.preloadWaiters.get(handle);
      if (!waiters) {
        waiters = [];
        this.preloadWaiters.set(handle, waiters);
      }
      waiters.push(finish);
    });
  }

  /** 唤醒所有等这张照片的调用方。 */
  private notifyPreloadWaiters(handle: number, ok: boolean): void {
    const waiters = this.preloadWaiters.get(handle);
    if (!waiters) return;
    this.preloadWaiters.delete(handle);
    for (const cb of waiters) {
      cb(ok);
    }
  }

  cancelPreload(): void {
    if (this.preloadTimer >= 0) {
      clearTimeout(this.preloadTimer);
      this.preloadTimer = -1;
    }
    this.preloading = false;
    // 刻意不清 `preloadingSet`：里面可能有正在传的 handle，清掉会让别的路径
    // 误以为它没在传，从而在串行的 USB 管道上再开一个并发传输。
    // 循环自己会在每张结束后 delete。
  }

  /**
   * 挂起邻近照片的字节预加载（预览器打开时调用）。
   * 只阻止「开始新的下载」，已经在传的那一张会正常结束，不会打断 USB 事务。
   */
  suspendNeighborPreload(): void {
    this.neighborPreloadSuspended = true;
    if (this.preloadTimer >= 0) {
      clearTimeout(this.preloadTimer);
      this.preloadTimer = -1;
    }
  }

  /** 恢复邻近预加载（预览器关闭时调用）。 */
  resumeNeighborPreload(): void {
    this.neighborPreloadSuspended = false;
    if (this.preloadPhotos.length > 0) {
      this.schedulePreload(this.preloadPhotos.length);
    }
  }

  clearFullCache(): void {
    // 清缓存时唤醒等待者，让它们改走前台直取，不要干等到 5s 超时。
    const waiting: number[] = [];
    this.preloadWaiters.forEach((_v: Array<(ok: boolean) => void>, k: number) => waiting.push(k));
    for (const h of waiting) {
      this.notifyPreloadWaiters(h, false);
    }
    this.compressedCache.clear();
    this.preloadingSet.clear();
    this.cacheTotalBytes = 0;
    this.detailIndex = -1;
    this.prevDetailIndex = -1;
    this.preloadPhotos = [];
  }

  /**
   * 当前会话是不是调试包的模拟相机。
   *
   * 界面据此显示「模拟」标记：模拟设备走的是与真机完全相同的流程，光看标题和
   * 设备信息是分不出来的，不标出来容易把测试结果当成真机结论。
   */
  mockSession(): boolean {
    return this.sessionIsMock;
  }

  /**
   * 把模拟相机记进「已配对相机」（仅调试包）。
   *
   * 模拟相机走 USB/PTP，没有蓝牙配对那一步，`rememberActive()` 永远不会被它触发；
   * 不补这一条，重启之后标题、立牌、当前相机都退回「相机」，每轮测试都要重新
   * 搜一次，和真机流程对不上。机型认不出来时也记——那时 modelKey 是空串，
   * 记录里仍然有序列号。
   */
  private rememberMockCamera(): void {
    if (!this.sessionIsMock) return;
    // 只用模拟相机自己上报的序列号。`CameraModelStore.serial` 可能还是上一台
    // 真机留下的，拿它当 key 会把真机那条记录顶掉（1.66.1）。
    const serial = this.deviceSerialNumber.replace(/^0+/, '');
    const name = this.cameraName !== '' ? this.cameraName : 'MOCK-PTP-CAMERA';
    const rec = SavedCameraStore.getInstance().rememberMock(this.cameraModel, serial, name);
    if (rec === null) return;
    // 连接过程中机型/序列号是分几步到位的，同一个状态会被调好几次；只在
    // 「写进去的东西变了」时留一行日志，别刷屏。
    const signature = `${rec.key}|${this.cameraModel}|${name}`;
    if (signature === this.mockLogged) return;
    this.mockLogged = signature;
    this.log.add(`[Mock] 模拟相机已记入已配对相机: ${rec.key}`);
  }

  /**
   * 调试开关变化后调用：断开当前相机，让下一次「搜索相机」重新挑选传输实现。
   * 注意不要在这里改 `sessionIsMock`，否则 `syncSessionMode()` 会以为已经切换过
   * 而跳过真正的替换。
   */
  onMockCameraToggled(): void {
    if (this.connected) {
      this.disconnect().catch((_e: Error) => { /* best effort */ });
    }
  }

  /**
   * 按调试开关选择传输实现。真实 USB 与虚拟相机实现同一个 `PtpTransport`，
   * 上层扫描流程完全一致。
   */
  private syncSessionMode(): void {
    // 无线会话由 connectWifi() 自己装配，调试开关不应该把它换回 USB/虚拟相机。
    if (this.wireless) return;
    const wantMock = MockPtpDevice.isEnabled();
    if (wantMock === this.sessionIsMock) return;
    const previous: PtpTransport = this.session;
    if (this.connected) {
      previous.closeSessionAndPipe().catch((_e: Error) => { /* best effort */ });
      this.connected = false;
    }
    this.session = new PtpScheduler(wantMock ? new MockPtpSession() : new PtpSession());
    this.sessionIsMock = wantMock;
    this.log.add(wantMock ? '[Mock] 使用虚拟相机' : '[Mock] 使用真实 USB 相机');
  }

  async disconnect(): Promise<void> {
    this.disconnecting = true;
    try {
      await this.disconnectInternal();
    } finally {
      this.disconnecting = false;
    }
  }

  private async disconnectInternal(): Promise<void> {
    // 用户主动断开：撤掉自动重连，避免刚断开就被自己接回来。
    const wasWireless = this.wireless;
    if (wasWireless) {
      // 先把「退出无线」的动作跑完：能秒退就秒退，退不了才排密集重扫。
      await this.exitWirelessToBle();
    }
    this.wifiAutoReconnectArmed = false;
    this.cancelWifiReconnect();
    await this.session.closeSessionAndPipe();
    if (this.wireless) {
      // 回到 USB 默认实现，下一次「搜索相机」才不会把 USB 端点喂给 Wi-Fi 会话。
      this.session = new PtpScheduler(new PtpSession());
      this.wireless = false;
    }
    this.wifiSession = null;
    this.pairingCode = '';
    this.pairingRequired = false;
    this.connected = false;
    this.usable = false;
    this.lastScanError = '';
    // 上一轮的进度、统计、失败结论都属于「已结束的那次连接」：断开后还挂着
    // 「正在连接相机热点」或「照片 38 张 | 扫描完成」，看起来像没断开。
    this.wirelessStage = '';
    this.wirelessFailed = '';
    this.bleHint = '';
    this.scanStatsText = '';
    this.scanPhaseText = '';
    this.scanProgress = 0;
    this.scanTotal = 0;
    this.cameraName = '';
    this.cameraIdentity = '';
    this.deviceManufacturer = '';
    this.deviceSerialNumber = '';
    this.deviceVersion = '';
    this.usbVidPid = '';
    this.usbSerialNumber = '';
    // Flush BEFORE clearing the flag — the old order made this branch dead and
    // silently dropped pending thumbnail writes on disconnect.
    if (this.cachingEnabled) {
      await this.thumbCache.flush();
    }
    this.cachingEnabled = false;
    this.cachingDialogRequired = false;
    this.pendingCamIdForDialog = '';
    this.pendingCamNameForDialog = '';
    this.pendingCachingPrompt = false;
    this.photoCount = 0;
    this.photos = [];
    this.thumbnailPixelMapMap.clear();
    this.thumbnailLoadedSet.clear();
    this.preloadedOrientations.clear();
    this.exifOrigDims.clear();
    this.orientationMap.clear();
    this.orientedDisplaySizes.clear();
    this.scanPhaseText = '';
    this.lastDecodedHandle = -1;
    this.metadataCacheByHandle.clear();
    this.metadataCacheSavedAt = 0;
    this.resetSessionCapabilities();
    this.clearFullCache();
    this.thumbCache.close();
    this.statusText = L10n.tr('camera_status_disconnected');
    this.log.add('已断开连接');
    if (wasWireless) {
      // BLE 的回接已经由 exitWirelessToBle() 里的密集重扫接手，这里不再排。
      this.stopBleVisibilityProbe();
    }
    // 会话已经断开，后台保活不再需要；传输自己的引用仍会把任务留住。
    if (this.sessionKeepAlive) {
      this.sessionKeepAlive = false;
      this.endTransferTask().catch((_e: Error) => { /* 释放失败不影响断开 */ });
    }
  }

  /**
   * 换相机/断线时清掉「这台相机学到的能力」：换一台相机后，
   * 上一台的 GetObjectPropList 支持情况、缩略图 EXIF 可信度都不再成立。
   */
  private resetSessionCapabilities(): void {
    this.deviceOps = [];
    this.propListProbed = false;
    this.thumbExifTrust = null;
    this.thumbExifSamples = 0;
    this.thumbExifPortrait = 0;
    this.thumbExifMismatch = 0;
    this.thumbExifMissing = 0;
  }

  /**
   * Build a unique, filesystem-safe camera identity string from PTP DeviceInfo.
   * Priority: serialNumber > model+manufacturer > USB vid/pid fallback.
   */
  private buildCameraIdentity(info: DeviceInfo, usbDevice: usbManager.USBDevice): string {
    const sanitize = (s: string): string => s.replace(/[^a-zA-Z0-9_.-]/g, '_').substring(0, 64);
    const manu = (info.manufacturer || '').trim();
    const model = (info.model || '').trim();
    const version = (info.deviceVersion || '').trim();

    // Priority 1: PTP serialNumber — unique per camera body
    const serial = (info.serialNumber || '').trim();
    if (serial) {
      return sanitize(`${manu}_${model}_${serial}`);
    }

    // Priority 2: USB serial number (from USB device descriptor)
    if (usbDevice.serial) {
      const usbSerial = usbDevice.serial.trim();
      if (usbSerial) {
        return sanitize(`${manu}_${model}_usb_${usbSerial}`);
      }
    }

    // Priority 3: model + version + vid + pid — identifies model/firmware
    const vid = usbDevice.vendorId.toString(16).padStart(4, '0');
    const pid = usbDevice.productId.toString(16).padStart(4, '0');
    if (manu || model) {
      return sanitize(`${manu}_${model}_${version}_${vid}_${pid}`);
    }

    // Last resort
    return `vid_${vid}_pid_${pid}`;
  }

  /**
   * Check caching preference for the current camera.
   * If the camera has never been seen, sets cachingDialogRequired=true.
   * If previously rejected (cachingEnabled=false), keeps it false.
   * If previously accepted, initializes the thumbnail cache.
   */
  /** 新相机还没问过「要不要缓存」：`scanForCamera()` 会先问再扫。 */
  private pendingCachingPrompt: boolean = false;

  /** 等用户点按钮的 resolver，`setCachingPreference()` 里唤醒。 */
  private pendingCachingResolve: ((enabled: boolean) => void) | null = null;

  private checkCachingState(): void {
    if (!this.cameraIdentity) {
      this.cachingEnabled = false;
      this.cachingDialogRequired = false;
      return;
    }
    const pref = this.cachePrefs.get(this.cameraIdentity);
    if (!pref) {
      // 新相机：**连上就问，问完再扫**。答案直接决定这轮扫描是否落盘缓存。
      // 早前是「先缓存、扫完再问」，图片多时弹窗会被拖到整轮扫描（元数据 + 全部缩略图，
      // 1288 张要好几分钟）之后才出现，用户早就不在看相机页了。
      this.pendingCamIdForDialog = this.cameraIdentity;
      this.pendingCamNameForDialog = this.cameraName;
      // 还没回答之前不知道要不要写缓存，别提前按“启用”处理。
      this.cachingEnabled = false;
      this.cachingDialogRequired = false;
      this.pendingCachingPrompt = true;
      this.log.add(`新相机 ${this.cameraName}，扫描前询问是否启用缓存`);
      return;
    }
    // 已登记过的相机每次连接都刷新 lastSeen / 名称，缓存管理页的“上次连接”才准确。
    this.cachePrefs.touch(this.cameraIdentity, this.cameraName);
    if (pref.cachingEnabled) {
      this.cachingEnabled = true;
      this.cachingDialogRequired = false;
      this.thumbCache.init(this.filesDir, this.cameraIdentity);
      this.log.add(`缓存已启用: ${this.cameraName}`);
    } else {
      this.cachingEnabled = false;
      this.cachingDialogRequired = false;
      this.log.add(`缓存已禁用(用户设置): ${this.cameraName}`);
    }
  }

  /**
   * 弹出「是否启用缩略图缓存」询问，并等用户选择。
   *
   * 由 `scanForCamera()` 在连接成功、还没开始扫的时候调用：`cachingDialogRequired`
   * 置 true 后 MainScreen 的 `@Monitor` 弹对话框，用户点按钮走
   * `setCachingPreference()`，在那里 resolve 本 Promise，扫描接着往下走。
   * 超时兜底：万一对话框没弹出来（页面未挂载等），不能让扫描永远卡住。
   */
  private askCachingPreference(): Promise<boolean> {
    this.pendingCamIdForDialog = this.cameraIdentity;
    this.pendingCamNameForDialog = this.cameraName;
    return new Promise<boolean>((resolve: (enabled: boolean) => void) => {
      this.pendingCachingResolve = resolve;
      this.cachingDialogRequired = true;
      setTimeout(() => {
        if (this.pendingCachingResolve !== resolve) return;
        this.pendingCachingResolve = null;
        this.pendingCachingPrompt = false;
        this.cachingDialogRequired = false;
        this.cachingEnabled = true;
        this.log.add('缓存询问超时（对话框未响应），本轮按启用缓存处理');
        resolve(true);
      }, CACHING_PROMPT_TIMEOUT_MS);
    });
  }

  /**
   * Called from MainScreen after the user responds to the caching dialog.
   * 回答“不启用”时要把可能已经写下的缩略图与元数据快照删掉。
   */
  async setCachingPreference(cameraId: string, enabled: boolean): Promise<void> {
    const camName = this.pendingCamNameForDialog !== ''
      ? this.pendingCamNameForDialog : this.cameraName;
    this.cachePrefs.set(cameraId, camName, enabled);
    this.cachingDialogRequired = false;
    this.cachingEnabled = enabled;
    this.pendingCachingPrompt = false;
    this.log.add(enabled ? `用户已启用缓存: ${this.cameraName}` : `用户拒绝缓存: ${this.cameraName}`);
    if (enabled) {
      // 扫描紧接着就要落盘缩略图，先按这台相机初始化缓存目录。
      this.thumbCache.init(this.filesDir, cameraId);
    } else {
      if (cameraId === this.cameraIdentity) {
        this.thumbCache.reset();
      }
      await ThumbnailCache.deleteCameraCache(this.filesDir, cameraId);
      this.log.add(`已删除相机缓存: ${cameraId}`);
    }
    this.pendingCamIdForDialog = '';
    this.pendingCamNameForDialog = '';
    // 唤醒 scanForCamera() 里等选择的 await：扫描在弹窗之前就暂停了，这里只放行，不重扫。
    const resolve = this.pendingCachingResolve;
    this.pendingCachingResolve = null;
    if (resolve !== null) resolve(enabled);
  }

  /**
   * Load a thumbnail from the disk-based ThumbnailCache.
   * Used instead of USB GetThumb when a valid cache entry exists.
   *
   * @returns true 表示已经从磁盘画出缩略图；false 表示这条缓存已失效
   *          （文件被删/读不出来），调用方必须回退到 USB 取图。
   */
  private async loadCachedThumbnail(handle: number, key: string,
    entry: CacheEntry): Promise<boolean> {
    try {
      const filePath = this.thumbCache.getCacheDir() + '/' + entry.cacheFileName;
      const fileBuf: ArrayBuffer | null = await this.thumbCache.readFileToBuffer(filePath);
      if (!fileBuf) {
        // manifest 说命中、磁盘上却没有：把这条记录摘掉，避免下次扫描继续“命中”它。
        this.thumbCache.invalidate(key);
        hilog.info(DOMAIN, TAG, '[CACHE_HIT] stale entry handle=0x%{public}s',
          handle.toString(16));
        return false;
      }

      // A `corrected` entry already has rotate/flip/crop baked into the JPEG.
      // Anything else is the raw camera thumbnail: apply the recorded EXIF
      // transform now, otherwise rotated photos show sideways after a restart.
      const corrected = entry.corrected === true;
      const rotate = corrected ? 0 : (entry.exifRotate ?? 0);
      const flipH = corrected ? false : (entry.exifFlipH ?? false);
      const flipV = corrected ? false : (entry.exifFlipV ?? false);
      const origW = corrected ? 0 : (entry.origWidth ?? 0);
      const origH = corrected ? 0 : (entry.origHeight ?? 0);

      const decodeBuf = fileBuf.slice(0);
      const task = new taskpool.Task(decodeThumbnailTask, decodeBuf,
        rotate, flipH, flipV, origW, origH);
      const pixelMap = await taskpool.execute(task) as image.PixelMap;
      const info = await pixelMap.getImageInfo();
      this.orientedDisplaySizes.set(handle, new OrientedSize(info.size.width, info.size.height));
      this.thumbnailPixelMapMap.set(handle, pixelMap);
      this.thumbnailLoadedSet.add(handle);
      hilog.info(DOMAIN, TAG, '[CACHE_HIT] handle=0x%{public}s %{public}dx%{public}d',
        handle.toString(16), info.size.width, info.size.height);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[CACHE_HIT] FAIL handle=0x%{public}s err=%{public}s',
        handle.toString(16), JSON.stringify(err));
      this.log.add(`缓存加载失败: handle=0x${handle.toString(16)}`);
      this.thumbCache.invalidate(key);
      return false;
    }
  }

  formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }
}
