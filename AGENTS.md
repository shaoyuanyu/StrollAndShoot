# StrollAndShoot（走走拍拍）

HarmonyOS 手机应用。通过 USB PTP 连接相机，浏览并导入照片，写入 GPS 地理标记。

**交流语言：中文。**

## 运行环境

| 项 | 值 |
|---|---|
| 平台 | HarmonyOS 6.1.0（API 23，Stage model） |
| 语言 | ArkTS |
| UI | ArkUI，状态管理只用 V2 |
| 构建 | Hvigor；命令行用 DevEco CLI（`devecocli`） |
| Native | NAPI（C++），产物 `libentry.so`，ABI 为 `arm64-v8a` 与 `x86_64` |
| 依赖管理 | ohpm。运行时没有第三方依赖，devDeps 只有 `@ohos/hypium`、`@ohos/hamock` |
| 静态检查 | code-linter，规则见 `code-linter.json5`（performance + security） |
| 设备类型 | 仅 `phone`，见 `module.json5` 的 `deviceTypes` |
| 版本号 | 定义在 `AppScope/app.json5`，写作时为 1.3.1 / 1003001 |

## 目录结构

```text
StrollAndShoot/
├── AppScope/app.json5              # bundleName、版本号、图标
├── build-profile.json5             # SDK 6.1.0、products
├── code-linter.json5               # lint 规则
├── deploy.sh                       # 构建→签名→安装→启动（本地文件，未纳入版本控制）
├── entry/
│   ├── build-profile.json5         # 模块构建；CMake 配置在 externalNativeOptions
│   ├── src/main/
│   │   ├── module.json5            # ability、权限（LOCATION、APPROXIMATELY_LOCATION、KEEP_BACKGROUND_RUNNING）
│   │   ├── ets/
│   │   │   ├── entryability/       # EntryAbility：窗口尺寸、避让区监听、加载 pages/Index
│   │   │   ├── pages/              # 页面、PTP 会话层、早期原型页
│   │   │   ├── components/         # 复用组件
│   │   │   ├── services/           # 单例服务
│   │   │   ├── model/              # 数据结构与持久化设置
│   │   │   ├── utils/              # 分组、组件坐标、窗口信息
│   │   │   ├── workers/            # ImageDecoder：TaskPool 并发函数（不是 Worker 线程）
│   │   │   ├── CustomTransition/   # 一镜到底转场的动画参数与注册表
│   │   │   └── NodeContainer/      # BuilderNode 单例，承载共享元素
│   │   ├── cpp/                    # NAPI 代码与 libentry.so 的类型声明
│   │   └── resources/              # base 为浅色，dark 为深色
│   ├── src/test/                   # 本地单元测试（模板用例）
│   └── src/ohosTest/               # 设备集成测试（模板用例）
└── hvigor/
```

## 构建与部署

```bash
# 环境变量（devecocli 必需）
export DEVECO_CLI_CLT_PATH=~/.hmos/command-line-tools
export DEVECO_CLI_SKIP_VERSION_CHECK=1

# 构建。输出比 hvigorw 简洁，clean 之后完整构建约 9 秒
devecocli build

# 等价命令
hvigorw assembleHap --no-daemon

# 清理。改动回退之后必须清理，否则可能命中旧产物
hvigorw clean --no-daemon

# 完整流程：构建 → 签名 → 安装 → 启动
bash deploy.sh full

# 只签名、安装、启动。代码有改动时不要用
bash deploy.sh run

# 静态检查
devecocli check lint entry/src/main/ets
```

- 产物是 `entry/build/default/outputs/default/entry-default-unsigned.hap`，约 3.9 MB。
- `hvigorw` 会提示 `No signingConfig found for product default`，签名由 `deploy.sh` 单独完成。
- `deploy.sh` 被 `.gitignore` 忽略，只存在于开发机，里面写着签名材料的路径与口令。
- `entry/src/test`、`entry/src/ohosTest` 只有新建工程自带的模板用例，`hvigorw test` 不会检查项目逻辑。

## 架构

### 导航

- `pages/Index.ets` 是唯一入口（`@Entry`），内部用 `Navigation` + `NavPathStack`，隐藏系统导航栏（`hideNavBar(true)`），并注册自定义转场 `customNavContentTransition`。
- `route_map.json` 注册两个 NavDestination：`MainScreen` 与 `PhotoViewerScreen`。
- `MainScreen` 承载三个标签页（画廊 / 相机 / 设置）。底部标签栏是自绘的 `Row`，`Tabs` 用 `barHeight(0)` 关掉了系统标签栏。
- `CacheManagementPage`、`GpsManagementPage`、`GpsDayDetailPage` 是 `@Entry` 页面，用已废弃的 `router.pushUrl` / `router.back` / `router.getParams` 跳转。
- `SwiperSyncTestPage` 是早期原型页，仍注册在 `main_pages.json`，没有任何入口。

### 状态管理

只用 ArkUI V2。V1 装饰器（`@State`、`@Prop`、`@Link`、`@StorageLink`、`@StorageProp`、`@Provide`、`@Consume`、`@Observed`、`@ObjectLink`、`@Track`、`@Watch`）禁止出现在新代码里。

| V2 写法 | 说明 |
|---|---|
| `@ComponentV2` | 所有组件都用它，替代 `@Component` |
| `@Local` | 组件内部状态，替代 `@State` |
| `@Param` | 父组件传入的只读参数，替代 `@Prop` |
| `@Param @Once` | 父组件初始化、子组件可改写 |
| `@Event` | 子组件向父组件回调 |
| `@Provider()` / `@Consumer()` | 跨层数据共享，替代 `@Provide` / `@Consume` |
| `@ObservedV2` | 类可观测，替代 `@Observed` |
| `@Trace` | 属性级跟踪，替代 `@Track` |
| `@Monitor` | 异步变更监听，回调参数是 `IMonitor`，用 `monitor.value(path)?.before` / `?.now` 取旧值和新值 |
| `@SyncMonitor` | API 23 起的同步版 `@Monitor` |
| `@Computed` | 记忆化计算属性 |
| `@Builder` | 保留自 V1，与 V2 兼容 |
| `Repeat` | 列表渲染，替代 `ForEach`。需要懒加载时用 `Repeat(data).virtualScroll()`，这是 `LazyForEach` 的官方迁移写法 |
| `AppStorageV2.connect()` | 应用级响应式共享，替代 `AppStorage` / `@StorageLink` |
| `PersistenceV2.globalConnect()` | 应用级持久化状态，替代 `PersistentStorage.persistProp` + `@StorageLink` |
| `!!` | 双向绑定，替代 `$$` |

**数据流**：`CameraService` 是 `@ObservedV2` 单例，`photos`、`photosVersion`、`thumbnailVersion`、`scanning`、`connected`、`statusText`、`lastDecodedHandle` 等字段带 `@Trace`。页面用 `@Local svc: CameraService = CameraService.getInstance()` 直接持有，读到 `@Trace` 字段就会自动刷新。跨页面传递的状态（下载进度、已下载集合、GPS 状态）由 `MainScreen` 用 `@Param` 下发，子页面用 `@Event` 上报。持久化设置放在 `SettingsStore`（`@ObservedV2` + `PersistenceV2.globalConnect()`），任何组件直接取单例。

**注意**：`thumbnailPixelMapMap`、`orientedDisplaySizes`、`compressedCache` 是普通 `Map`，不参与自动追踪。界面能刷新依靠 `thumbnailVersion`、`lastDecodedHandle`、`photosVersion` 这类手工计数被 `build()` 读到。改动缩略图与原图加载逻辑时，必须同时维护这些计数。

### Native bridge

`libentry.so` 暴露的函数，类型声明在 `entry/src/main/cpp/types/libentry/Index.d.ts`：

- 命令构造：`buildOpenSession`、`buildCloseSession`、`buildGetDeviceInfo`、`buildGetStorageIDs`、`buildGetObjectHandles`、`buildGetObjectInfo`、`buildGetThumb`、`buildGetObject`、`buildGetPartialObject`
- 响应解析：`processResponse`、`parseDeviceInfo`、`parseStorageIDs`、`parseObjectHandles`、`parseObjectInfo`

`processResponse(data, expectData)` 负责累积多包 USB 数据，返回动作码：`0` 数据还在累积（继续读），`1` 拿到数据包，`2` 拿到响应包（`responseCode` 为 `0x2001` 表示成功）。

### 资源

- `$r('app.type.name')` 从 `entry/src/main/resources/` 解析。浅色在 `base/element/`，深色在 `dark/element/`。
- 颜色资源成体系，共 25 条，命名如 `primary`、`bg_surface`、`text_primary`、`divider`。部分组件里仍有直接写定的颜色值，不随深色模式变化。
- `base/element/string.json` 有 36 条字符串，代码里没有任何引用，界面文案直接写在组件内部。
- 颜色模式跟随系统：`COLOR_MODE_NOT_SET`（值为 -1）表示不设置，`COLOR_MODE_LIGHT` / `COLOR_MODE_DARK` 为显式指定。

## 页面

### Index.ets
导航根与初始化。设置日志路径与下载目录、初始化 `GpsRecorder`、把 `AppLog` 交给 `PtpHost` 与 `ExifGeotagger`、监听深色模式设置并调用 `setColorMode`，最后把 `MainScreen` 作为首个目的地压入 `NavPathStack`。

### MainScreen.ets
NavDestination，标签页容器。持有标签状态、下载进度、已下载集合、GPS 开关状态、选择模式。订阅 `cachingDialogRequired` 弹出“发现新相机”对话框。点击缩略图时收集该缩略图的屏幕坐标与 PixelMap 交给 BuilderNode，再 `pushPath('PhotoViewerScreen')` 触发一镜到底转场。返回键在选择模式下先退出选择模式。

### GalleryPage.ets
- 按拍摄日期分组（`YYYY-MM-DD`，最新在前，没有日期的归入“未知日期”）
- 格式筛选 chip，按照片里出现过的扩展名动态生成，只在“文件优先”模式下出现
- 两指缩放网格（0.4x–6.0x），列数随缩放手势与设置里的默认列数重新计算
- 长按进入多选，`SelectionActionBar` 显示已选数量、全选、取消、下载
- 缩略图按整行显示：一行（宽度 4）全部解码完成才同时出现，否则该行显示占位
- `buildFlatItems()` 把日期标题与行拍平成一个数组交给 `Repeat` + `.virtualScroll()`，结果按 `photosVersion`、`thumbnailVersion`、显示模式、筛选值、缩放比例做缓存

### CameraPage.ets
未连接时只有一个“搜索相机”按钮；已连接时显示“快速扫描”、“全量扫描”、“断开连接”，以及设备信息卡（品牌、型号、PTP 序列号、固件版本、USB 识别码、USB 序列号、缓存标识、照片数量）。

### SettingsPage.ets
深色模式（跟随系统 / 浅色 / 深色）、画廊默认列数、显示模式（内容优先 / 文件优先）、GPS 定位开关、定位模式（精确 31 秒 / 日常 61 秒 / 省电 121 秒）、版本号、缩略图缓存入口、调试日志面板（清除 / 复制，等宽字体，高 300vp）。

### PhotoViewer.ets
预览器，一个文件里有四个结构：

- `ZoomableImage`：单张图片的缩放与拖动。捏合用 `pinchCenterX/Y`（屏幕绝对坐标）计算锚点；拖动位移要乘 `scaleVal` 换算回屏幕空间；捏合期间 `PanGesture` 会持续累计位移，必须记录并在捏合结束后扣除，否则松手时会跳变。缩放范围 1x–5x，双击在 1x 与 2.5x 之间切换。
- `MainImageView`：主图容器，叠加加载指示与扫描进度横幅。
- `ThumbCellView`：底部缩略图条的单元。
- `PhotoViewerScreen`：NavDestination。主 `Swiper` 与缩略图 `Swiper` 双向联动（`startFakeDrag` / `fakeDragBy` 同步），主图滑动带惯性，缩略图中心项放大到 1.3x。原图按“当前照片优先，前后各 3 张”排队串行加载，手势期间暂停。返回时用当前照片的缩略图更新共享元素，保证转场起点正确。

### CacheManagementPage.ets / GpsManagementPage.ets / GpsDayDetailPage.ets
- 缓存管理：列出每个相机的缓存体积、条目数、开关、删除、清空全部
- GPS 管理：按天分组列出记录条数，可删除某一天
- 单日明细：逐条显示时间、坐标、海拔，以及反地理编码得到的地址（需要网络）

### PtpHost.ets
PTP 会话层，封装 `@ohos.usbManager`，见“关键概念”。

## 组件

| 组件 | 位置 | 用途 |
|---|---|---|
| `ConnectionStatusBar` | `components/ConnectionStatusBar.ets` | 连接状态。`compact` 模式用于画廊顶部，完整模式用于相机页，带扫描进度条 |
| `SelectionActionBar` | `components/SelectionActionBar.ets` | 多选底部栏：全选、已选数量、取消、下载 |
| `DownloadProgressBar` | `components/DownloadProgressBar.ets` | 下载进度条：阶段、当前文件、进度百分比、错误数、取消 |

## 服务

### CameraService（`services/CameraService.ets`，约 1800 行）
单例，`@ObservedV2`，相机相关操作的入口：

- `scanForCamera(quickMode)`：搜索相机 → 连接 → 取设备信息 → 判断缓存设置 → Phase 0 缓存快照 → Phase 1 目录遍历 → Phase 2a 元数据 → Phase 2b 缩略图
- `collectPhotoHandles()`：递归遍历目录，用 `GetObjectHandles` 的格式筛选（`0x0000` 与 `0x3001`）区分文件与目录，不使用启发式判断
- `loadThumbnailsRowByRow()`：每 4 张为一组加载，整组完成才递增 `thumbnailVersion`
- `loadFullPhoto(handle)`：优先读 `compressedCache`，未命中走 USB，解码在 TaskPool 里执行，返回 `DecodedPhotoResult`（PixelMap + 旋转后的尺寸）
- `downloadPhotos(handles, onProgress, ctx)`：批量下载到沙箱，按拍摄时间匹配 GPS 并写入 EXIF，最后经 `showAssetsCreationDialog` 保存到系统相册，同时维护 `download_registry.json`
- `disconnect()`：关闭会话，清空全部内存缓存

### AppLog（`services/AppLog.ets`）
内存环形缓冲（最多 200 条）+ 文件 `app_log.txt`，同时写 hilog。文件写入按 1 秒节流。从设备上读取：

```bash
hdc shell cat /data/app/el2/100/base/io.github.shaoyuanyu.strollandshoot/haps/entry/files/app_log.txt
```

注意：`scanForCamera()` 开头会调用 `log.clear()`，扫描之前的日志会被清掉。

### GpsRecorder（`services/GpsRecorder.ets`）
连续定位记录。三种模式（精确 31 秒 / 日常 61 秒 / 省电 121 秒）对应 `TRANSPORT` 与 `DAILY_LIFE_SERVICE` 场景。启动时申请位置权限与后台长时任务（`backgroundMode: location`）。记录写入 `gps_records.json`，模式与运行状态写入 `gps_settings.json`，下次启动由 `autoStart()` 恢复。`findClosest(captureDate)` 用二分查找找时间最接近的记录，默认容忍 30 分钟。

### ExifGeotagger（`services/ExifGeotagger.ets`）
用 `modifyImagePropertiesEnhanced` 一次性写入 `GPSLatitudeRef`、`GPSLatitude`、`GPSLongitudeRef`、`GPSLongitude`（有海拔时还有 `GPSAltitudeRef`、`GPSAltitude`），写完读回验证。经纬度写成逗号分隔的度分秒，例如 `43,49,23.16`；官方把这两个字段定义为三个 RATIONAL 值，典型写法是 `dd/1,mm/1,ss/1`，改动格式之前先在真机确认读回结果。

## 缩略图缓存与快速扫描

### CameraCachePrefs（`services/CameraCachePrefs.ets`）
按相机记录缓存设置，持久化在 `{filesDir}/camera_cache_prefs.json`。字段为 `cameraId`、`friendlyName`、`cachingEnabled`、`firstAsked`、`lastSeen`，`getAll()` 按 `lastSeen` 降序返回。在 `CameraService.initDownloadDir()` 里初始化。

### ThumbnailCache（`services/ThumbnailCache.ets`）
目录结构：

```text
{filesDir}/thumb_cache/{cameraIdentity}/
  manifest.json    // {"filename::size": CacheEntry}
  {hash}.jpg       // 缩略图 JPEG，quality 85
```

- 键为 `filename::size`，与下载注册表一致
- 命中条件：键存在且 `modificationDate` 相同，否则视为过期
- `saveRawThumbnail()` 直接写入 USB 取回的原始 JPEG 字节，避免重新编码
- `saveEncodedThumbnail()` 在解码裁掉黑边后用编码结果覆盖缓存文件
- 扫描结束调用 `purgeStale(validKeys)` 删除已经不在相机上的条目

### 扫描的四个阶段（`scanForCamera(quickMode)`）

- **Phase 0**（仅快速扫描，且相机之前同意过缓存）：从 `metadata_cache.json` 读出上一次的 `PhotoEntry[]`，同时从磁盘并行加载缩略图，画廊立刻有内容
- **Phase 1**：递归遍历目录，收集 handle
- **Phase 2a**：逐个 `getObjectInfo` 取元数据，按 `captureDate` → `modificationDate` → `handle` 降序排序，替换 `photos` 并递增 `photosVersion`，同时写出新的 `metadata_cache.json`
- **Phase 2b**：按 4 张一行加载缩略图，每行完成递增一次 `thumbnailVersion`，结束时 `purgeStale`

新相机第一次连接时先按“启用缓存”处理，扫描完成后再弹对话框询问（`cachingDialogRequired`），用户选择写入 `CameraCachePrefs`。

### 调试

hilog 标签为 `ThumbnailCache`、`CameraCachePrefs`。应用内日志的关键字样：

```text
[ThumbnailCache] loaded manifest with 42 entries
[ThumbnailCache] stale: modDate changed for DSC_0001.JPG::1234567
[CameraService] [CACHE_HIT] handle=0x1234 160x120
[CameraService] 缓存已启用: NIKON D850
```

## 数据模型（`model/PhotoEntry.ets`）

```typescript
interface PhotoEntry {
  handle: number;        // PTP object handle，在同一个 storage 内唯一
  filename: string;      // 例如 "DSC_0001.JPG"
  size: number;          // 压缩后体积（字节）
  captureDate?: string;  // PTP 时间串 YYYYMMDDThhmmss
  modificationDate?: string;
  objectFormat?: number; // PTP 格式码，0x3801 = JPEG，0x3001 = 目录
  imagePixWidth?: number;
  imagePixHeight?: number;
  storageId?: number;
}
```

同文件还有：`DisplayGroup`（内容优先模式下把同名文件合成一组）、`DownloadRecord`（下载注册表条目，键为 `filename::size`）、`DownloadProgress`、`DownloadResult`、`GpsRecord`、`GpsDailyGroup`。

`model/SettingsStore.ets` 存放持久化设置（深色模式、画廊列数、显示模式）。

## 关键概念

### PTP（Picture Transfer Protocol）
相机与主机之间通过 USB 通信的协议。

- **Session**：任何操作之前先 `OpenSession(sessionId)`
- **Storage ID**：逻辑存储单元，通常是机身内存与存储卡
- **Object Handle**：每个文件或目录在同一个 storage 内的 32 位标识
- **Object Format Code**：`0x3801` = JPEG，`0x3001` = 目录（DCIM），`0x3803` = TIFF，RAW 各家不同
- **Parent handle**：`0xFFFFFFFF` 表示 storage 根目录
- **Response code**：`0x2001` 表示成功

### PTP 会话层（`pages/PtpHost.ets`）
封装 `@ohos.usbManager` 的主机模式：

- `findCameras()`：枚举 USB 设备，筛选 class `0x06`（Image）、subclass `0x01`（SIC）、protocol `0x01`（PTP）
- `connect()`：申请权限 → `connectDevice` → `claimInterface` → 清空中断端点 → `OpenSession`
- 三个事务方法：`ptpCommand()`（命令 + 响应）、`ptpCommandGetData()`（命令 + 数据 + 响应，1KB 缓冲）、`ptpCommandGetLargeData()`（命令 + 数据 + 响应，192KB 缓冲循环复用）
- `getThumb` / `getObject` / `getPartialObject` 各自维护 `usbBusy` 标记，靠 200ms 轮询等待通道空闲

### USB 传输上限
单次 `bulkTransfer` 的总数据必须小于 200KB，超出会返回 -1。缓冲区取 192KB（196608 字节）留出余量。

> 此限制是本项目的实测经验，官方 `usbManager` 文档没有记载具体数值。改动缓冲区大小必须在真机验证。

### 目录遍历
递归进入所有目录（format `0x3001`），把所有非目录 handle 当作照片。相机支持格式筛选时，每层目录只需 2 次 `GetObjectHandles`；不支持时退化为逐个 `GetObjectInfo` 判断。不使用任何启发式判断。

### 相机身份
`GetDeviceInfo` 提供的标识，用来区分相机、隔离各自的缓存目录。优先级：`serialNumber` → USB `serial` → `manufacturer + model + deviceVersion + vid + pid` → `vid + pid`。

### Native PTP 引擎（`cpp/`）
从 libgphoto2 移植：

- `ptp_engine.h/cpp`：PTP/MTP 容器构造与响应解析，参与构建
- `napi_init.cpp`：NAPI 导出层，参与构建
- `ptp.h`：协议常量与结构体，只作为头文件被 `ptp_engine.h` 引入
- `ptp.c`、`usb.c`、`ptp_client.cpp/h`、`gphoto2-port.h`、`device-flags.h`、`ptp-bugs.h`、`ptp-private.h`：不参与构建

## 当前进度

### 已完成
- PTP 协议引擎（命令构造、响应解析、设备信息 / 存储 / 对象查询）
- USB 相机通信（会话管理、递归目录遍历的照片枚举）
- 画廊：日期分组、格式筛选、两指缩放、多选下载、按行显示缩略图
- 预览器：主图与缩略图条联动、缩放拖动、串行预加载、一镜到底转场
- 缩略图磁盘缓存 + 元数据快照 + 快速扫描
- 批量下载到系统相册，下载注册表校验
- EXIF 方向纠正（1–8 全部支持），缩略图与原图都按方向解码
- GPS 连续定位、后台长时任务、按天管理、反地理编码
- 导出时把 GPS 信息写入 JPEG 的 EXIF
- 深色模式、缓存管理页
- 状态管理全部迁移到 V2

### 未实现
- 边框、水印、LUT、滤镜、美颜。只有 `string.json` 里留着 `btn_process_border`、`btn_process_watermark` 两条字符串，其余没有代码。

## 已知问题

2026-10-14 审视代码时定位到的问题。修掉一处就删一条。

| 位置 | 问题 |
|---|---|
| `CameraService.ets:1675` / `:1688` | `disconnect()` 先把 `cachingEnabled` 置 false，之后的 `if (this.cachingEnabled) { thumbCache.flush() }` 永远不会执行 |
| `CameraService.ets:1247` → `:1812` → `ThumbnailCache.ets:170` | 参数错位：`saveRawThumbnail` 的第 4 个形参是 `handle`，实际传进去的是原始宽度，于是缓存条目里 `handle` 变成原始宽度、`origWidth` 变成原始高度、`origHeight` 缺失 |
| `CameraService.ets:1591` | `setDetailIndex()` 没有调用点，`detailIndex` 恒为 -1，导致 `evictFurthest()` 退化成“淘汰 handle 最大的一张”，`preloadAdjacent()` 从不运行 |
| `MainScreen.ets:169` 起 | 点击缩略图时对全部照片逐张调用 `ComponentAttrUtils.getRectInfoById()`，该函数找不到组件就抛异常，屏幕外的照片全部走异常分支 |
| `MainScreen.ets:85` / `:88` | `syncDownloadedKeys()` 重复调用两次 |
| `CameraService.ets:1013` | 遗留调试代码 `// TEST: only load first 300 photos` 与注释掉的 slice |
| `PhotoViewer.ets:302` | `scanRefreshKey` 参数传入后从未被读取 |
| `pages/SwiperSyncTestPage.ets` | 早期原型页，仍注册在 `main_pages.json`，会随应用打包 |
| `services/ThumbnailCache.ets` | `CacheEntry` 的 `handle`、`exifRotate`、`exifFlipH`、`exifFlipV`、`origWidth`、`origHeight` 只写不读；`CameraService.loadCachedThumbnail()` 一律按“已经旋转裁剪过”解码，而 `saveRawThumbnail()` 写入的是原始 JPEG，两次写入之间进程退出，下次启动就会把未纠正的缩略图当成已纠正的版本显示 |

没有调用点的代码，可以直接删除：`PhotoViewer.getDisplayPixelMap`、`CameraService.getLogText` / `isPhotoDownloaded` / `loadThumbnail` / `cacheOrientedSize`、`ThumbnailCache.loadThumbnail` / `getCacheSizeBytes` / `getEntryCount` / `getAllEntries` / `debugLookup` / `getCameraCacheSize`、`PtpSession.close`、`AppLog.getEntries`、`ZoomableImage.onEdgeChange`。

## 调试经验

### `deploy.sh run` 不会重新构建
`bash deploy.sh run` 只做签名、安装、启动。代码有改动时用 `bash deploy.sh full`，否则安装的还是旧 HAP。这个坑已经造成过多次“bug 没有修复”的误判。

### 构建缓存会造成假象
改动回退之后直接重新构建，hvigorw 可能复用旧的构建产物，看起来像是回退没有生效。回退代码之后先执行 `hvigorw clean --no-daemon`。

### 留意写定的上限
旧的 `loadPhotoList` 里有 `const limit = Math.min(handles.length, 50)`，照片数量被悄悄限制在 50 张。遇到“功能大体正常但数字对不上”时，检索 `limit`、`min(`、`max(`、`slice` 以及写定的小数字。

### 目录遍历不用启发式判断
旧逻辑用 `validCount <= 2` 作为是否继续进入子目录的条件，遇到同一层有多个子目录（如 DCIM/100NCD90 与 DCIM/101NCD90）、一个目录下超过 2 个直接子项、或者同一层文件与目录混排的相机就会漏照片。现在的写法是进入全部目录，把所有非目录 handle 当作照片。

### 手机 USB 连接不稳定
开发过程中手机经常与 `hdc` 断开。部署或查日志之前先用 `hdc list targets` 确认，返回 `[Empty]` 就让用户重新插线。

### 统计计数器要与条件分支同步
`statsPartialSkips` 曾经声明了、也用在统计公式里，但没有任何地方递增，导致 USB 调用次数统计翻倍。新增计数变量后，检查每个对应的条件分支是否都做了递增。

### 涉及相机与 USB 的改动要在真机上确认
流程：构建 → 部署 → 告诉用户改了什么 → 用户把手机从电脑拔开、接上相机测试 → 用户反馈结果 → 用户把手机接回电脑 → 查看 hilog。手势与相机相关功能在没有真机确认之前，不要当成已经可用。

### 查 HarmonyOS 官方资料
需要 API 参考、开发指南、系统接口，或者要核对项目里积累的技术结论时，优先用本地 `developercomm` 知识库 MCP：

- `mcp_developercomm_searchDocuments` — 用自然语言检索官方知识库（API 参考、开发指南、最佳实践、FAQ、版本说明）
- `mcp_developercomm_getDocumentsById` — 用搜索结果的 `parent` 字段（文档 ID）取完整内容，一次最多 10 篇
- 返回内容过长会被截断（标记 `[truncated]`），改用更精确的关键词分多次检索
- 备用渠道：`devecocli docs`（`catalog` / `search` / `read`）提供同一份离线文档，输出完整 markdown 且不截断
- 本机 SDK 的类型声明在 `~/.hmos/command-line-tools/sdk/default/openharmony/ets/api/`，接口名、参数类型与起始版本以那里的 `.d.ts` 为准

### 已经对照官方资料核对过的结论

- USB 单次 `bulkTransfer` 小于 200KB：官方 `usbManager` 参考里没有写这个数值，属于本项目实测，改动缓冲区必须在真机验证
- `@SyncMonitor`：官方文档写明从 API 23 开始支持，`@Monitor` 从 API 12 开始支持
- `Repeat`：`LazyForEach` 的官方迁移写法是 `Repeat(data).virtualScroll()`，没有 `RepeatForEach` 这个组件
- EXIF Orientation：官方 FAQ 给出 8 个取值与字符串表示的对应关系（1 = `Top-left`，……，8 = `Left-bottom`），读取时返回字符串，未写入该字段的图片按不旋转处理
- GPS 经纬度：官方把 `GPSLatitude` / `GPSLongitude` 定义为三个 RATIONAL 值（度、分、秒），典型写法是 `dd/1,mm/1,ss/1`；本项目写入的是逗号分隔的度分秒（如 `43,49,23.16`），写完读回验证
- 图片编码默认不保留 EXIF：`PackingOption.needsPackProperties` 默认 false。缩略图缓存里保存的编码结果因此没有 EXIF，方向信息另外记在 manifest 里

## DevEco CLI（`devecocli`）

华为官方的 agent coding 工具包（npm 包 `@deveco/deveco-cli`），包装 hvigor、ohpm、hdc、模拟器工具链，内置离线文档与官方 skills。本机装的是 1.3.0，命令名是 `devecocli`。包内自带 `SKILL.md` 与 `docs.zip`。

### 环境变量（Linux 实测必需）

```bash
export DEVECO_CLI_CLT_PATH=~/.hmos/command-line-tools   # CLT 不会被自动发现
export DEVECO_CLI_SKIP_VERSION_CHECK=1                  # 本机 CLT 6.1.0.830 低于 CLI 要求的最低版本
```

CLT 位于 `~/.hmos/command-line-tools/`，内含 hvigor 6.23.5、codelinter 6.0.240、ohpm 与 HarmonyOS SDK API 23。升级 CLT 之后可以去掉第二个变量。

### 本项目实测可用

| 命令 | 用途 |
|---|---|
| `devecocli build` | 构建，等同 `hvigorw assembleHap`，输出更简洁；`build clean` 可清理 |
| `devecocli check lint [path]` | 运行 code-linter，支持 `--fix`、`--format json`、`--output-path` |
| `devecocli docs catalog` / `search` / `read` | 离线文档目录、全文检索、读取完整文档 |
| `devecocli device list` | 列出真机与模拟器 |
| `devecocli skills list` / `skills add --skill <name> --path <dir>` | 官方 skills（35 个）的列出与安装，`--all` 可全装 |

官方 skills 的实体仓库在 `/home/ysy/Projects/hmos/.skills/`，本项目通过 `.agents/skills` 符号链接接入。链接丢失时重建：

```bash
mkdir -p .agents && ln -s /home/ysy/Projects/hmos/.skills .agents/skills
```

### 需要设备、登录或尚未验证

- `run` / `--apply <file>`（快速增量部署，要求 DevEco Studio ≥ 6.1.1）/ `--hotreload`（需要后台进程保活）
- `log`（hilog 与崩溃日志）、`ui`（界面检视与操作），两者都需要设备
- `emulator`（模拟器管理，本机 Linux 没有 DevEco Studio，未验证）
- `signature generate`（生成签名材料，需先 `devecocli auth login` 且连接设备）
- `check compat`（两个 SDK 版本之间的破坏性变更扫描）、`update`（更新 CLI 自身）

`deploy.sh` 的签名与安装流程保持不变，`devecocli` 只用来构建、静态检查与查文档。

## 版本管理

agent 在完成每次功能开发或 bug 修复后，**必须**自动更新版本号。版本号定义在 `AppScope/app.json5` 中：

```json5
{
  "app": {
    "versionName": "1.1.0",  // 语义化版本字符串
    "versionCode": 1001000,   // 整数编码，用于程序化比较
  }
}
```

### 版本号规则

采用语义化版本（SemVer）：`MAJOR.MINOR.PATCH`

| 分段 | 何时递增 | 示例 |
|------|----------|------|
| **MAJOR** | 不兼容的 API / 行为变更（极少发生） | `1.1.0` → `2.0.0` |
| **MINOR** | 新增功能（向后兼容） | `1.1.0` → `1.2.0` |
| **PATCH** | Bug 修复（向后兼容） | `1.1.0` → `1.1.1` |

### versionCode 编码规则

`versionCode = MAJOR * 1_000_000 + MINOR * 1_000 + PATCH`

例如 `1.2.3` → `1_002_003` → `1002003`。

### 操作步骤

每次 agent 完成代码变更后，在最终确认前必须执行：

1. **判断变更类型**：新增功能 → MINOR；修复 bug → PATCH；破坏性变更 → MAJOR（极少）
2. **读取** `AppScope/app.json5` 中的当前 `versionName` 和 `versionCode`
3. **解析**当前 `versionName` 得到 `MAJOR.MINOR.PATCH`
4. **递增**对应分段，低分段归零（如 MINOR+1 则 PATCH 归零）
5. **计算**新的 `versionCode`
6. **更新** `AppScope/app.json5` 中的 `versionName` 和 `versionCode`

### 重要约束

- 不允许同时递增多个分段。一次变更只递增一个分段。
- 如果一次提交同时包含新功能和 bug 修复，按 MINOR 处理。
- 纯文档/注释/重构（无行为变化）不更新版本号。
- 版本更新与代码变更在同一轮编辑中完成，不需要额外的提交或沟通。
