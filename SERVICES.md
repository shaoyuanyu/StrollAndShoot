# 服务、缓存、数据模型与 PTP

> 本文覆盖相机/照片管线、缩略图缓存与扫描、数据模型、定位与地图服务，以及 PTP/USB 与 Native 层。页面设计见 [PAGES.md](PAGES.md)，ArkUI 规则见 [AGENTS.md](AGENTS.md)，构建发布见 [AGENTS.md](AGENTS.md)。

## 相机与照片管线

### CameraService（`services/CameraService.ets`，约 1800 行）

单例，`@ObservedV2`，相机相关操作的入口：

- `scanForCamera(quickMode)`：搜索相机 → 连接 → 取设备信息 → 判断缓存设置 → Phase 0 缓存快照 → Phase 1 目录遍历 → Phase 2a 元数据 → Phase 2b 缩略图
- `collectPhotoHandles()`：递归遍历目录，用 `GetObjectHandles` 的格式筛选（`0x0000` 与 `0x3001`）区分文件与目录，不使用启发式判断
- `loadThumbnailsRowByRow()`：每 4 张为一组加载，整组完成才递增 `thumbnailVersion`
- `loadFullPhoto(handle)`：优先读 `compressedCache`，未命中走 USB，解码在 TaskPool 里执行，返回 `DecodedPhotoResult`（PixelMap + 旋转后的尺寸）。完成时打一行四段耗时 `下载完成: 1.0s (取图 …ms / 方向 …ms / 拷贝 …ms / 解码 …ms)`：**「第一次打开照片卡一下」先看这行**——取图占大头是 USB/排队，拷贝占大头是主线程 30MB `ArrayBuffer.slice`，解码占大头才是 TaskPool。
- **邻近预加载半径是 2，且预览器打开期间整体挂起**（`suspendNeighborPreload` / `resumeNeighborPreload`）。以前是 5 且每翻一张就重新排队 10 张，与预览器自己的队列抢 USB。**解码按最长边降采样到 `FULL_DECODE_MAX_EDGE`（3072px）**：手机屏幕长边约 2700px、预览器最多 5x 捏合，3072 已够用；24MP 原图全尺寸是 96MB/张，预览器同时驻留 6-7 张会把内存与纹理带宽打满。降采样用 `DecodingOptions.desiredSize`（2026-11-07 在模拟器把上限压到 600 验证过，日志 `full decode done 600x400 scale=0.500`）。
- `downloadPhotos(handles, onProgress, ctx)`：批量下载到沙箱，按拍摄时间匹配 GPS 并写入 EXIF，最后经 `showAssetsCreationDialog` 保存到系统相册，同时维护 `download_registry.json`
- `disconnect()`：关闭会话，清空全部内存缓存

### 下载注册表与「最近删除」

- 键为 `${cameraIdentity}::${filename}::${size}`；旧版 `${filename}::${size}` 记录仍可兼容读取。
- 每条记录保存相册 URI 与 `downloadDate`；图库删除后不物理删除记录，只写 `missingSince` 时间戳。`getDownloadedKeys()` 只返回 `missingSince` 为空的记录，所以绿点会立即消失。
- `validateRegistry()` 在启动和每次扫描结束后执行：先 `fileIo.open` 相册 URI；失败且错误码像“已删除”（13900002 / media URI 的 13900001、13900012、201）时，再用 `photoAccessHelper.getAssets` 按 URI 查媒体库。查到资产就视为仍存在，查不到才标记 `missingSince`。
- 图库「最近删除」保留 30 天；`missingSince` 超过 30 天的记录自动清理。用户在系统图库恢复照片后，下一次校验会清掉 `missingSince`，绿点恢复。
- 重新下载同一张时 `addDownloadRecord()` 直接覆盖旧记录，清掉缺失状态。

### AppLog（`services/AppLog.ets`）

内存环形缓冲（最多 500 条）+ **追加写**文件 `app_log.txt`（1 秒节流，超过 512KB 轮转到 `app_log.txt.1`），同时写 hilog。进入后台/销毁时 `flushNow()` 强制补齐；`scanForCamera()` 不再清空日志，只写一条 `=== 开始扫描 ===` 分隔。从设备上读取：

```bash
hdc shell cat /data/app/el2/100/base/io.github.shaoyuanyu.strollandshoot/haps/entry/files/app_log.txt
```

`app_log.txt` 与 `.1` 已从系统备份中排除（见 `backup_config.json`）。

### ExifGeotagger（`services/ExifGeotagger.ets`）

用 `modifyImagePropertiesEnhanced` 一次性写入 `GPSLatitudeRef`、`GPSLatitude`、`GPSLongitudeRef`、`GPSLongitude`（有海拔时还有 `GPSAltitudeRef`、`GPSAltitude`），写完读回验证。经纬度写成逗号分隔的度分秒，例如 `43,49,23.16`；官方把这两个字段定义为三个 RATIONAL 值，典型写法是 `dd/1,mm/1,ss/1`，改动格式之前先在真机确认读回结果。

### CameraCachePrefs（`services/CameraCachePrefs.ets`）

按相机记录缓存设置，持久化在 `{filesDir}/camera_cache_prefs.json`。字段为 `cameraId`、`friendlyName`、`cachingEnabled`、`firstAsked`、`lastSeen`，`getAll()` 按 `lastSeen` 降序返回。在 `CameraService.initDownloadDir()` 里初始化。

### ThumbnailCache（`services/ThumbnailCache.ets`）

目录结构：

```text
{filesDir}/thumb_cache/{cameraIdentity}/
  manifest.json    // { "version": 2, "entries": { "filename::size": CacheEntry } }
  {hash}.jpg       // 缩略图 JPEG，quality 85
```

- manifest 带 `version`，旧版本会被整体丢弃重建（v1 无法区分原始与已纠正的 JPEG）
- 条目里的 `corrected` 表示磁盘上的 JPEG 是否已烘焙旋转/翻转/裁剪；为 false 时按 `exifRotate`/`exifFlipH`/`exifFlipV` 在解码时补上变换
- 首次扫描先写原始 JPEG（`corrected: false`），解码成功后再用纠正版覆盖（`corrected: true`），两次写入严格串行
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

### 缓存调试

hilog 标签为 `ThumbnailCache`、`CameraCachePrefs`。应用内日志的关键字样：

```text
[ThumbnailCache] loaded manifest with 42 entries
[ThumbnailCache] stale: modDate changed for DSC_0001.JPG::1234567
[CameraService] [CACHE_HIT] handle=0x1234 160x120
[CameraService] 缓存已启用: NIKON D850
```

### 数据模型（`model/PhotoEntry.ets`）

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

同文件还有：`DisplayGroup`（内容优先模式下把同名文件合成一组）、`DownloadRecord`（下载注册表条目，键为 `${cameraIdentity}::${filename}::${size}`，含 `missingSince` 表示暂时进了「最近删除」）、`DownloadProgress`、`DownloadResult`、`GpsRecord`、`GpsDailyGroup`。

`model/SettingsStore.ets` 存放持久化设置（深色模式、画廊列数、显示模式）；`model/UiStateStore.ets` 存放上次标签页、画廊筛选和握持手。

## 定位与地图

### GpsRecorder（`services/GpsRecorder.ets`）

连续定位记录。四种模式（精确 11 秒 / 出行 31 秒 / 日常 61 秒 / 省电 121 秒）对应 `TRANSPORT` 与 `DAILY_LIFE_SERVICE` 场景。启动时申请位置权限与后台长时任务（`backgroundMode: location`）。记录写入 `gps_records.jsonl`（每行一条），模式与运行状态写入 `gps_settings.json`，下次启动由 `autoStart()` 恢复。`findClosest(captureDate)` 用二分查找找时间最接近的记录，默认容忍 30 分钟。

- **内部模式码保持兼容**：`0=精确(11s)`、`1=日常(61s)`、`2=省电(121s)`、`3=出行(31s)`。设置页显示顺序是「精确 / 出行 / 日常 / 省电」，用 `GPS_MODE_UI_TO_CODE = [0, 3, 1, 2]` 做映射，不能把 `gpsMode` 直接当 `selectedIndex`；否则旧配置里的 `1=日常`、`2=省电` 会被改义。默认仍是省电（2），读取时允许 0–3。
- 每条定位先交给 `GpsTrack.append`：移动 < 5 米且距本轮静止起点 < 10 分钟就合并，否则新增；`runStart` 保存本轮静止起点，静止一整天也会每 10 分钟留一个心跳点。
- `GpsTrack.isImplausibleJump` 过滤 > 300 m/s 的跳点；`loadRecords` 用 `GpsTrack.compact` 整理旧版 31 秒重复点。
- `recordsVersion` 是 UI 依赖的计数；`getDailyStats` / `getGroupForDay` 内部按这个版本缓存按天聚合，页面不必每次遍历全部记录。
- `getDayRecords` 返回当天升序数组；`ensureDailyCache` 已把按天记录数组一起缓存，直接复用，不要在每个卡片的 build 里重复 filter+sort。轨迹聚合交给 `GpsTrackCache`，不要重复算距离。
- 调试包的模拟轨迹只放内存：`createMockTrack()` 生成 31 个 `mock: true` 的点，`getDayRecords`/`getDailyStats` 用它们覆盖当天显示；`clearMockTrack()` 恢复。真实记录不写盘、不参与 `findClosest`，应用重启时 `loadRecords` 会清掉。
- **记录落盘**：`gps_records.jsonl` 每行一条，定位回调里用 `AtomicFile.appendText()` 立即追加，进程被杀最多丢掉正在写的那一行；内存数组每 5 分钟用 `AtomicFile.writeText()` 压缩成快照（`.tmp` + rename，失败退回 copy），`stop()` / 删除 / 重载 / 进入后台时强制压缩。保留策略是 100000 条 / 365 天，超出后按整天丢弃最旧的一天，并通过 `trimmedRecords` 在设置页提示。`gps_settings.json` 同样原子写并带 `version`。不要在定位回调里直接重写整份 JSON。
- `displayRecordCount()` = 真实总数 − 当天真实数 + 模拟点数；页头和设置页的「已记录 N 条定位记录」都用它。模拟日的 `GpsDailyGroup.mock` 驱动「模拟」徽标。

### GpsTrack（`utils/GpsTrack.ets`）与 GpsTrackCache（`services/GpsTrackCache.ets`）

- `buildDayTrack(day, records)` 产出 `GpsDayTrack`：点集、`sketchPoints`（最多 160 点抽稀）、距离、时长、包围盒、首尾时间。首条时间用 `runStart` 并裁到当天 0 点。
- `GpsTrackCache.getDayTrack(day, records)` 用首尾时间/坐标指纹命中缓存，LRU 最多 32 天；删除某天要 `invalidate(day)`。
- 地图折线用 `map.convertCoordinateSync` 转 GCJ02，并按坐标（6 位小数）缓存结果：新增一个定位只多转一个点，不要每 11 秒重转 1200（预览）/4000（全屏）个点。转换逻辑不放进纯逻辑层，Local Test 不依赖 Map Kit。

### GpsMockTrack（`utils/GpsMockTrack.ets`）

- 调试包的模拟轨迹生成器：以当前位置为原点，生成约 300m × 210m 的相机图案（取景器 + 机身 + 镜头 + 快门），31 个点，时间铺在最近 4 分钟。
- 点带 `mock: true`、`runStart = timestamp`；只用 `GpsRecord`，不依赖设备/地图，Local Test 可验证点数、时间范围和包围盒。
- 获取当前位置优先 `geoLocationManager.getCurrentLocation`（ACCURACY / TRAJECTORY_TRACKING / 10s）；失败时用 5 分钟内的 `lastFix` 兜底；开关在 SettingsPage 的「调试」区，仅 debug 包可见。

### GpsGeocoder（`services/GpsGeocoder.ets`）

- 按坐标缓存中文地址（最多 400 条），`cachedText` 读 `@Trace version` 让列表行自动刷新；`resolve` 对同一坐标并发去重。
- 全屏页给可视分组标题和选中点按需解析（分组标题由 `prefetchGroupAnchors` 触发），地址缓存跨页面复用；失败/无网络返回 null，不阻塞列表。
- 逆地理编码需要 `SystemCapability.Location.Location.Geocoder`，没有能力时静默跳过。

### MapCapability（`utils/MapCapability.ets`）

- 用 `bundleManager.getBundleInfoForSelfSync(GET_BUNDLE_INFO_WITH_SIGNATURE_INFO)` 的 `signatureInfo.fingerprint` 判断 HAP 是否签名。
- **模拟器只装 unsigned HAP，没有 Profile 的 `com.huawei.service.mapkit` 能力，Map Kit 能初始化但瓦片请求 403**；此时代码自动降级为 Canvas 轨迹示意图。真机 signed HAP 的 Profile 已包含该能力，地图可正常加载。

### Map Kit（`@kit.MapKit`）

- `MapComponent({ mapOptions, mapCallback })` 初始化后拿 `map.MapComponentController`；折线/标记/相机都从这里走。
- `mapOptions` 的 `position.target` 必须是 GCJ02；`geoLocationManager` 给的是 WGS84，必须 `map.convertCoordinateSync(WGS84, GCJ02, p)` 转换。用 `map.newLatLngBounds(bounds, paddingPx)` + `moveCamera` 适配全程。
- `setPadding` / `setLogoPadding` / `newLatLngBounds` 的 padding 单位都是**像素**，用 `getUIContext().vp2px()` 换算；`setPadding` 要把顶部标题栏和底部面板算进去，`setLogoPadding` 的 bottom 要抬到面板上方。
- **`mapLoad` 事件可能早于 `mapCallback`**：回调里先把 `mapLoaded` 置 true 并立即 `moveCamera`，不要只等 `mapLoad`，否则相机永远停在初始 zoom。
- 地图需要 `ohos.permission.INTERNET`；AGC 的「地图服务」开关会写进 Profile 的 `app-services-capabilities.com.huawei.service.mapkit`。签名 HAP 才有瓦片权限，unsigned 模拟器包只会拿到 403。
- 预览图 `setAllGesturesEnabled(false)`，全屏图打开手势；地图加载失败/超时/未签名时切 Canvas 示意图，不做空白兜底。

## 设备服务

### HandednessService（`services/HandednessService.ets`）

握持手感知，决定下载进度浮岛贴左还是贴右。`@ObservedV2` 单例，只暴露一个 `leftHanded` 布尔（默认 `false`，即右侧）。

- 订阅 `motion.on('holdingHandChanged')`（`@kit.MultimodalAwarenessKit`），`LEFT_HAND_HELD` 切左、`RIGHT_HAND_HELD` 切右；`BOTH_HANDS_HELD` / `NOT_HELD` / `UNKNOWN_STATUS` **一律保持原位**，否则手机放桌上或换手途中浮岛会来回跳
- 由 `MainScreen.aboutToAppear` 启、`aboutToDisappear` 停
- 权限 `ohos.permission.DETECT_GESTURE`（normal / system_grant，声明即授予，不弹窗）
- 机型支持面窄：握持手识别自 API 20 起提供，只有系统设置里带「智感握姿」开关的机型可用，否则订阅抛 **801**。本项目全部走「失败即保持默认右侧」
- **模拟器一定返回 801**（`subscribe failed code=801`），只能验降级路径；握持切换必须真机验证
- 浮岛距屏幕边固定 12vp，不能更贴：官方写明「屏幕四周边缘 8mm 范围内不支持触控响应」，再贴边取消按钮会点不动

## PTP 与 Native 层

### PTP 关键概念

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

**旧实现的教训**：旧逻辑用 `validCount <= 2` 作为是否继续进入子目录的条件，遇到同一层有多个子目录（如 `DCIM/100NCD90` 与 `DCIM/101NCD90`）、一个目录下超过 2 个直接子项、或者同一层文件与目录混排的相机就会漏照片。现在的写法是进入全部目录，把所有非目录 handle 当作照片。

### 相机身份

`GetDeviceInfo` 提供的标识，用来区分相机、隔离各自的缓存目录。优先级：`serialNumber` → USB `serial` → `manufacturer + model + deviceVersion + vid + pid` → `vid + pid`。

### Native bridge

`libentry.so` 暴露的函数，类型声明在 `entry/src/main/cpp/types/libentry/Index.d.ts`：

- 命令构造：`buildOpenSession`、`buildCloseSession`、`buildGetDeviceInfo`、`buildGetStorageIDs`、`buildGetObjectHandles`、`buildGetObjectInfo`、`buildGetThumb`、`buildGetObject`、`buildGetPartialObject`
- 响应解析：`processResponse`、`parseDeviceInfo`、`parseStorageIDs`、`parseObjectHandles`、`parseObjectInfo`

`processResponse(data, expectData)` 负责累积多包 USB 数据，返回动作码：`0` 数据还在累积（继续读），`1` 拿到数据包，`2` 拿到响应包（`responseCode` 为 `0x2001` 表示成功）。

### Native PTP 引擎（`cpp/`）

从 libgphoto2 移植：

- `ptp_engine.h/cpp`：PTP/MTP 容器构造与响应解析，参与构建
- `napi_init.cpp`：NAPI 导出层，参与构建
- `ptp.h`：协议常量与结构体，只作为头文件被 `ptp_engine.h` 引入
- `ptp.c`、`usb.c`、`ptp_client.cpp/h`、`gphoto2-port.h`、`device-flags.h`、`ptp-bugs.h`、`ptp-private.h`：不参与构建

相关：Local Test 用的 NAPI mock 见 [AGENTS.md](AGENTS.md) 的「测试」；真机 USB 验证与 hdc 日志见 [AGENTS.md](AGENTS.md) 的「无线调试（Wi-Fi）」。

## 相关

- 页面设计与交互：[PAGES.md](PAGES.md)
- 调试、真机验证与工具链：[AGENTS.md](AGENTS.md)
- 全局约定与构建发布：[AGENTS.md](AGENTS.md)