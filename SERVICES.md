# 服务、缓存、数据模型与 PTP

> 本文覆盖相机/照片管线、缩略图缓存与扫描、数据模型、定位与地图服务，以及 PTP/USB 与 Native 层。页面设计见 [PAGES.md](PAGES.md)，ArkUI 规则见 [AGENTS.md](AGENTS.md)，构建发布见 [AGENTS.md](AGENTS.md)。

## 相机与照片管线

### CameraService（`services/CameraService.ets`，约 2200 行）

单例，`@ObservedV2`，相机相关操作的入口：

- `scanForCamera(quickMode)`：搜索相机 → 连接 → 取设备信息 → 判断缓存设置（**新相机在这里停下来问，问完再扫**）→ Phase 0 缓存快照 → Phase 1 目录遍历 → Phase 2a 元数据 → Phase 2b 缩略图。有 800ms 最小触发间隔（ISSUE-004），`bypassThrottle` 留给内部调用；失败时 `statusText` / `lastScanError` / `scanErrorVersion` 一起更新，界面据此显示原因并弹一次 toast
- `usable` 与 `connected` 分开：`connected` 只表示 PTP 会话建立，`usable` 表示 `GetStorageIDs` 成功。存储读不到时相机会话仍然是连着的，界面必须看 `usable`（ISSUE-003）
- `PtpError`（定义在 `PtpHost.ets`）：`code > 0` 是相机 PTP 响应码，`code < 0` 是传输层错误（`PTP_ERR_USB` / `PTP_ERR_NOT_OPEN`）。服务层用 `describeScanError()` 映射成可执行文案（`0x200F` 拒绝访问、`0x200E` 只读卡、`0x2008` 无效存储等）；**不要再把失败折叠成 `null` / `[]`**（ISSUE-002）
- `collectPhotoHandles()`：递归遍历目录，用 `GetObjectHandles` 的格式筛选（`0x0000` 与 `0x3001`）区分文件与目录，不使用启发式判断
- `loadThumbnailsRowByRow()`：每 4 张为一组加载，整组完成才递增 `thumbnailVersion`
- `getOriginalBytes(handle)`：给预览器「分享原图」用，返回相机原始压缩字节（优先读 `compressedCache`，未命中时串行取一次 USB 并缓存）；不重新编码、保留 EXIF。扫描中返回 null，避免和扫描队列抢 USB。
- `loadFullPhoto(handle)`：优先读 `compressedCache`，未命中走 USB，解码在 TaskPool 里执行，返回 `DecodedPhotoResult`（PixelMap + 旋转后的尺寸）。完成时打一行四段耗时 `下载完成: 1.0s (取图 …ms / 方向 …ms / 拷贝 …ms / 解码 …ms)`：**「第一次打开照片卡一下」先看这行**——取图占大头是 USB/排队，拷贝占大头是主线程 30MB `ArrayBuffer.slice`，解码占大头才是 TaskPool。
- **邻近预加载半径是 2，且预览器打开期间整体挂起**（`suspendNeighborPreload` / `resumeNeighborPreload`）。以前是 5 且每翻一张就重新排队 10 张，与预览器自己的队列抢 USB。**解码按最长边降采样到 `FULL_DECODE_MAX_EDGE`（3072px）**：手机屏幕长边约 2700px、预览器最多 5x 捏合，3072 已够用；24MP 原图全尺寸是 96MB/张，预览器同时驻留 6-7 张会把内存与纹理带宽打满。降采样用 `DecodingOptions.desiredSize`（2026-11-07 在模拟器把上限压到 600 验证过，日志 `full decode done 600x400 scale=0.500`）。
- `downloadPhotos(handles, onProgress, ctx)`：批量下载到沙箱，按拍摄时间匹配 GPS 并写入 EXIF，最后经 `showAssetsCreationDialog` 保存到系统相册，同时维护 `download_registry.json`
- `disconnect()`：关闭会话，清空全部内存缓存

### 传输期间的后台长时任务与通知进度环（2026-11-09）

传输（扫描的元数据/缩略图、批量下载）是用户可感知的长任务，退到后台必须继续：

- `module.json5` 的 `abilities[].backgroundModes` 已声明 `location` + `dataTransfer`；
- `CameraService.beginTransferTask()` / `endTransferTask()` 用**引用计数**申请 / 释放 `BackgroundMode.DATA_TRANSFER`（扫描与下载可能同时进行，最后一个结束才取消），日志 `后台传输长时任务已申请 / 已取消`；
- **系统限制**：一个 UIAbility 同时只允许一个长时任务（API 20 及以前）。定位长时任务在跑时，传输任务会申请失败（日志 `后台传输长时任务申请失败`），此时退后台会被挂起；要并存需改用 API 21+ 的 `startBackgroundRunning(context, ContinuousTaskRequest)` 多任务接口。

通知栏进度环走的是**系统预置通知模板**，不是自绘：

- `services/TransferNotice.ets`：`NotificationRequest.template = { name: 'downloadTemplate', data: { title, fileName, progressValue } }`，系统自己渲染进度环，`progressValue >= 100` 时环消失；
- 模板目前只覆盖上传/下载场景；需要用户授权（首次传输时 `requestEnableNotification`，拒绝则静默跳过，不影响传输）；
- `CameraService.tickTransferNotice()` 每 1 秒（800ms 节流）刷新，内容形如 `512/1288 · 正在加载缩略图`，传输结束 `cancel()`；
- 它与长时任务那条通知**并存**（系统长时任务通知的内容应用改不了，无法合并）。
- DATA_TRANSFER 的官方约束：进度首次更新超过 10 分钟未更新会被取消，且「更新进度的通知类型必须为实况窗」。单次扫描/下载在几分钟内结束，暂时不受影响；要做超长传输需要接实况窗。
- 实况窗（LiveView）的 `event` 只支持官方 13 类场景（打车/配送/取餐/航班/排队/比分/租赁/计时/运动/导航/打卡/快递/高铁），**照片导入不在其中**，不要硬套。

### USB 相机插入监听（`services/UsbAttachWatcher.ets`，2026-11-09）

原生三方应用**不能**像 Android 那样“插上相机自动拉起”：静态订阅公共事件仅系统应用开放，后台启动 UIAbility 需要 `ohos.permission.START_ABILITIES_FROM_BACKGROUND`（仅系统应用可申请）。所以只做运行期能做的两件事：

- `start()` 在 `EntryAbility.onCreate` 调用，动态订阅 `usual.event.hardware.usb.action.USB_DEVICE_ATTACHED`；`stop()` 在 `onDestroy` 调用，`onForeground` / `onBackground` 维护前后台标志。
- 相机插入后延时 800ms 再枚举（相机常重枚举 `2-2 → 2-3 → 2-4`），用 `utils/UsbAttachUtil.ets` 的 VID/PID/产品名做键，15 秒内只处理一次；`CameraService.scanning` 或 `connected && usable` 时跳过。
- **前台**：`@Trace attachVersion++`，`MainScreen.@Monitor('usbWatcher.attachVersion')` 切到相机页并弹「发现相机」对话框；「稍后」在左、「开始扫描」在右（右侧高亮），点「开始扫描」走 `scanForCamera(true, true)`：有缓存走快速扫描，首次/无缓存由服务自动退化为全量。预览器/二级页在栈顶时不抢前台。
- **后台（进程还活着）**：发普通通知（`id=4211`，与 `TransferNotice` 的 4210 错开），WantAgent 带 `usbCamera=1`；点通知回前台后由 `EntryAbility.onNewWant` → `setAppForeground(true)` 触发提示。通知未授权时静默跳过。
- **冷启动不变**：应用没运行就收不到事件；插着相机启动也不会主动弹，仍走用户手动「搜索相机」。

**不要**试图用静态订阅 / `START_ABILITIES_FROM_BACKGROUND` 做自动拉起：前者仅系统应用，后者仅系统应用可申请；真要系统级体验只能预置应用/系统应用。

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

- manifest 带 `version`，旧版本会被整体丢弃重建。当前 v3：v1 无法区分原始与已纠正的 JPEG；v2 的 NEF 缩略图是按「无原始尺寸 → 不裁剪」存的纠正版、带黑边且无法补救（ISSUE-012）
- 条目里的 `corrected` 表示磁盘上的 JPEG 是否已烘焙旋转/翻转/裁剪；为 false 时按 `exifRotate`/`exifFlipH`/`exifFlipV` 在解码时补上变换
- 首次扫描只写**原始 JPEG + 变换参数**（`corrected: false` + `exifRotate/exifFlipH/exifFlipV/origWidth/origHeight`），**不再**在解码后重新编码覆盖；缓存命中时按 manifest 里的参数重新应用旋转/翻转到原始尺寸的裁剪。少掉每张一次的 ImagePacker 编码 + 覆盖写（ISSUE-007）
- 键为 `filename::size`，与下载注册表一致
- 命中条件：键存在且 `modificationDate` 相同，否则视为过期
- `saveRawThumbnail()` 直接写入 USB 取回的原始 JPEG 字节，避免重新编码；这是**唯一**写入路径
- `saveEncodedThumbnail()` 仍保留但没有调用点（v2 时代的“解码后再编码覆盖”已被移除）
- 扫描结束调用 `purgeStale(validKeys)` 删除已经不在相机上的条目

**内存 manifest 必须与磁盘对得上（2026-11-09 真机 bug）**

症状：在「缓存管理」清掉一台相机的缓存后**不重启应用**直接扫描，画廊从头到尾只有占位符，
日志是 `磁盘命中 16016 / USB 读取 0 / 解码成功 0`（16016 = 1288 张 × 12 次重复尝试）。

根因：`ThumbnailCache` 是 `CameraService` 里的单例，manifest 和 `loaded` 都在内存里；
「缓存管理」调用的是**静态** `ThumbnailCache.deleteCameraCache()`，只删目录、不碰这个实例。
于是下一次扫描 `init()` 因同目录提前返回、`loadManifest()` 因 `loaded=true` 直接返回，
manifest 里 1288 条记录全部“命中”，但文件已经没了：`readFileToBuffer()` 返回 null，
旧代码 `if (!fileBuf) return;` 静默返回 → 这张永远没被标记为已加载 → 每个交织批次都重试一遍。

修法（三层）：
1. `loadManifest()` 每次扫描前用 `fileIo.accessSync(manifestPath)` 校验 manifest 还在，不在就清空内存状态重新按磁盘加载；
2. `loadCachedThumbnail()` 改为返回 `boolean`：读不出文件时 `invalidate(key)` 摘掉坏记录并**回退 USB 取图**，不再静默停在占位符；
3. `invalidate()` 只改 manifest（删条目、减 totalBytes、置 dirty），下次 `purgeStale` 会顺手清掉孤儿文件。

日志摘要新增 `缓存失效回退 N`，用来确认是否又出现了“命中但读不出”的情况。

### 断点续扫（2026-11-09，1.27.0；1.27.1 修正）

冷扫描一轮约 2 分钟，跑到一半被系统回收（退后台被杀、崩溃、用户强退）就全白跑。
现在元数据边读边落盘，下次扫描从断点继续：

- `metadata_cache.json` 的 envelope 增加 **`complete`**：扫描过程中写 `false`，整轮（含缩略图）跑完才写 `true`。
  旧文件没有该字段，按 `true` 处理。
- 交织扫描每读 **`SCAN_PERSIST_EVERY = 256` 张**落一次盘；元数据读完、缩略图未读完时也写一次 `false`。
  **本轮一张都没新读（整份复用缓存）时不重写**——内容没变，没必要在日志里制造“未完成”的假象。
- `prepareMetadataReuse(quickMode)` 两条路径：
  - 快速扫描：`complete=true` 也照样复用（7 天有效期）；
  - 全量扫描：**只有 `complete=false` 且 24 小时内**才复用（`RESUME_MAX_AGE_MS`）。跑完过的缓存不参与全量扫描，
    保持“全量＝重读一遍”的语义。
- 续扫复用的是**部分** handle 集合：`reuseMeta` 命中就跳过 `GetObjectInfo`，没命中的照常读；
  `fullReuse = 复用条数 ≥ handle 数`，`interleave = !fullReuse`。
- 复用前仍然跑 `verifyMetadataSample()`（最多 8 个样本比对文件名+体积），防止卡被格式化后 handle 重被使用。
  **样本从「缓存里真的存在的 handle」里均匀抽**：早期的写法按全部 handle 抽样，断点续扫只有 1/5 命中缓存时
  往往只抽到 1 个样本，运气差会抽到 0 个而直接放弃复用（真机日志：`复用校验通过: 1 个样本一致`）。
- 缩略图不需要单独记进度：JPEG + manifest 本身就是逐张持久的，续扫时命中就跳过 `GetThumb` + `GetPartialObject`。
- 日志：`断点续扫: 上次扫描未完成，复用 N 条元数据（M 分钟前保存）` / `元数据缓存已保存: N 条（扫描未完成，可续扫）`。
  前者按 `complete` 判断，**快速扫描同样会打**——真机上“杀进程后重新点快速扫描”才是最自然的验证路径。

**续扫的可见进度**：`interleave = !fullReuse` 意味着续扫一定交织——每读 64 张的元数据就把这一批连缩略图一起上屏。
同时发布加了「只增不减」的闸门（`photoList.length >= this.photos.length` 才 `publishPhotoList`），
否则已有 256 张快照的画廊会先缩到 64 张再长回来。冷启动时 `this.photos` 为空，闸门恒成立，行为与之前一致。

### 扫描的四个阶段（`scanForCamera(quickMode)`）

- **Phase 0**（仅快速扫描，且相机之前同意过缓存）：从 `metadata_cache.json` 读出上一次的 `PhotoEntry[]`，同时从磁盘并行加载缩略图，画廊立刻有内容
- **Phase 1**：递归遍历目录，收集 handle；单张 `getObjectInfo` 失败只跳过那一张，不打断整轮
- **Phase 2a**：逐个 `getObjectInfo` 取元数据；**快速扫描会复用 `metadata_cache.json`**（按 handle 命中，先抽样 8 个 `GetObjectInfo` 比对文件名/体积，7 天有效期），只对新增照片读取（ISSUE-009）。真要读相机时按 `SCAN_CHUNK = 64` 交织上屏（见下文「交织扫描」），整份命中缓存时才一次读完。结束后写 `metadata_cache.json`
- **Phase 2b**：按 4 张一行加载缩略图，每行完成递增一次 `thumbnailVersion`，结束时 `purgeStale` 并写一行摘要 `缩略图阶段: 已在内存 X / 磁盘命中 Y / USB 读取 Z / 解码成功 W`，然后再存一次元数据（把本阶段学到的 EXIF 方向写回去）
- 失败只更新状态文案，**不清空 `photos` / `photoCount`**（ISSUE-005）

新相机第一次连接时，**连接成功后立刻弹对话框问「是否启用缩略图缓存」，问完再扫**：`checkCachingState()` 只置 `pendingCachingPrompt`，`scanForCamera()` 在 Phase 0 之前 `await askCachingPreference()`，用户点按钮走 `setCachingPreference()` 并 resolve 这个 Promise，扫描带着答案继续（不重扫）。答案写入 `CameraCachePrefs`；选「不缓存」会顺手删掉这台相机的缓存目录。询问带 90s 超时兜底（按启用处理），避免对话框异常时把扫描卡死。

> 2026-11-09 修正：早前是「先按启用缓存扫完，再弹窗追问」，1288 张时弹窗要等元数据 + 全部缩略图传完（几分钟）才出现，时机完全错位。

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
- 四个事务方法：`ptpCommand()`（命令 + 响应）、`ptpCommandGetData()`（命令 + 数据 + 响应，1KB 缓冲）、`ptpCommandGetLargeData()`（命令 + 数据 + 响应，192KB 缓冲循环复用，用于 `GetThumb` / `GetPartialObject`）、`ptpCommandGetObjectData()`（命令 bulk，数据阶段 `usbSubmitTransfer` 1MB/包、预加载 256KB/包，响应 1KB bulk，仅用于 `GetObject`）
- 三个事务方法在相机返回非 `0x2001` 时抛 `PtpError(op, code)`，USB/通道失败抛 `PtpError(op, PTP_ERR_USB)`。`GetDeviceInfo` 例外：失败只记日志并返回 null（身份信息有 USB 级兜底，不该中断扫描）
- `closeSessionAndPipe()` 只在 `CloseSession` 真的发出后才打 `acknowledged`；发送失败会如实打 `NOT acknowledged`（ISSUE-006）
- **USB 链路失效后的自愈**：相机休眠或线松动后 `bulkTransfer` 返回 -1；旧逻辑把 `connected` 留在 true，下一次扫描继续复用死 pipe，表现为反复「USB 通信失败」。现在 `loadPhotosAndThumbnails` 捕获 `PTP_ERR_USB` 时置 `connected = false`、`usable = false` 并 `closeSessionAndPipe()`；下一次点「搜索相机」会重新走 `connect()`。相机端真正休眠时仍需先唤醒/重插，但应用不会再卡在死会话上（2026-11-09 真机实测）。
- `log()` 只走 `AppLog.add()`（它内部已写 hilog），没有 AppLog 时才直接写 hilog —— 以前两条都写，每条 PTP 报文在 hilog 里出现两遍（ISSUE-007）

- **崩溃后重连：`0x201E`（SessionAlreadyOpen）自愈**（2026-11-09 真机实测）。应用被系统杀掉时不会走 `closeSessionAndPipe()`，相机会一直保留那个 PTP 会话，之后每次 `OpenSession` 都返回 `0x201E`，表现为「相机明明连着却搜不到」。现在 `connect()` 里判断到 `0x201E` 会先补发一次 `CloseSession` 再重试 `OpenSession`，实测直接恢复（日志 `OpenSession: 相机仍挂着上一次的会话 (0x201E)，补发 CloseSession 后重试` → `补发 CloseSession 后 OpenSession 成功`）。补发仍失败时置 `sessionConflict = true`，由 `CameraService` 显示「相机还挂着上一次的连接：请拔插 USB 线，或重启相机后重试」。

### 主机侧没有 PTP 驱动（2026-11-09 核对）

- HarmonyOS 的公开 API 里没有主机侧（Host）PTP/MTP 类驱动或服务：`@ohos.usbManager` 的主机侧只提供设备枚举、权限、接口/配置管理与控制/批量/中断/异步传输，PTP 容器与事务必须应用自己实现。
- 系统里确实有 PTP/MTP 代码，但方向相反：OpenHarmony 的 [`IUsbfnMtpInterface`](https://gitcode.com/openharmony/docs/blob/e464cb7f67646bdd8b54da8267544a329bd916bc/zh-cn/device-dev/reference/hdi-apis/usb/interface_i_usbfn_mtp_interface.md) 是 **USB Function（从设备）** 侧的 MTP/PTP HDI（4.0 起，`Start`/`Stop`/`Read`/`Write`/`ReceiveFile`/`SendFile`/`SendEvent`），给手机插到电脑上被识别为相机/便携设备用，不对外提供主机侧接口。
- 「自己写驱动」只有三条路，手机上只有第一条可用：
  1. **应用层用户态协议栈**（本项目）：`usbManager` + 自研 PTP 编解码，`libentry.so` 只做容器解析。桌面系统同样如此——libgphoto2 就是用户态库直接跟相机讲 PTP。
  2. **用户态扩展外设驱动**：`DriverExtensionAbility` + `UsbDdk`。官方限定 PC/2in1——[`DriverExtensionAbility`](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-app-ability-driverextensionability) 全部标注 `2in1`，驱动错误码 26300001 写明「产品形态不正确，仅支持PC/2in1」，[`ohos.permission.ACCESS_DDK_USB`](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/restricted-permissions) 也只对 PC/2in1 应用开放；且 UsbDdk 只能在 DriverExtensionAbility 生命周期内使用。
  3. **内核 / HDF 驱动**：随系统镜像由设备厂商构建，三方应用没有加载内核模块的接口，也不能通过 AppGallery 分发。
- 补充：`usbManager` 没有设备插拔监听，只能轮询 `getDevices()`；大文件数据阶段已改用 API 18 的 `usbSubmitTransfer`，见下文 P3。

### Wi-Fi PTP/IP 链路（1.31.0）

USB 之外的第二条链路：相机与手机在同一网络时，走 TCP 15740 的 PTP/IP，命令集与 USB 完全相同，只是容器换成了 PTP/IP 帧。上层扫描、缩略图、下载流程一行没改。

**分层**

| 文件 | 职责 |
|---|---|
| `services/WifiPtpLink.ets` | 传输层：两条 TCP 通道、PTP/IP 帧切分、Init 握手、事务匹配、Ping/Pong |
| `services/WifiPtpSession.ets` | 语义层：实现 `PtpTransport`，把 `GetObjectInfo` 等 PTP 操作翻译成 PTP/IP 事务 |
| `pages/PtpHost.ets` | 新增 `PtpEndpoint`（`kind` + USB 设备或 `host/port`），`PtpTransport.connect()` 改为收端点 |
| `services/PtpScheduler.ets` | 不变，继续把事务排队串行；`CameraService` 用 `new PtpScheduler(new WifiPtpSession())` 装配 |

**协议要点**（官方 CIPA DC-X005 + ZPill / N-Link / Camera_Bridge 真机实证）

- 包头 8 字节小端：`length u32`（含头）+ `type u32`；包类型 1–14。
- 命令通道先 `InitCommand`，**再开第二条 TCP 连接**发 `InitEvent`（同一端口）。两条都要成功。
- 尼康方言：`InitCommand` 载荷是 `GUID(16B) + UTF-16LE 主机名(含 NUL) + 版本 0x00010000`，**没有**标准 PTP/IP 的主机名长度前缀。固定 GUID `00112233…EEFF` 与 SnapBridge 客户端一致。
- `CmdRequest` 的 DataOut 字段恒为 1。
- 大对象走 `StartData(9) → Data(10)* → EndData(12)`，随后才是 `CmdResponse(7)`。
- 保活 `Ping(13) / Pong(14)`。

**连接与扫描**

`CameraService.connectWifi(host, port)` 建会话、取 `GetDeviceInfo`、算相机身份；之后 `scanForCamera()` 发现 `wireless === true` 就跳过 USB 枚举，直接复用会话进入既有的缓存/扫描/缩略图流水线。断开时 `disconnect()` 把 session 换回 USB 实现，避免下一次 USB 扫描把 USB 端点喂给 Wi-Fi 会话。

**主机注册与自动重连（1.32.0）**

相机在「连接向导」页等主机注册时，会先开 15740 让 app 连上，再等 `0x952B`（取验证码）与 `0x935A`（确认）——不确认就 10 秒后收线，且 Wi-Fi 配置不落盘。

- `WifiPtpSession.getPairingCode()`：`0x952B` 的数据集是 `count(u32) + count 个字节`，每个字节的十进制值拼成验证码。
- `WifiPtpSession.completePairing()`：`0x935A` 参数 `0x2001`。**Z50II 实测相机在回响应前就收线**，所以链路异常按「已完成」处理。
- `CameraService.connectWifi()` 连上后自动探一次配对码；有码就进配对态，不扫描。
- `CameraService.completeWifiPairing()`：确认后按 **2/3/5/8/12 秒**退避自动重连。Z50II 实测相机重启 Wi-Fi 约 6–7 秒，第 3 次（约 10 秒）命中；不要改回「只等 1.5 秒试一次」，那样每次都要用户手动再点。
- 配对是**按本次连接**做的：Z50II 在 4:10 和 4:20 两次连接都重新要了验证码，说明相机没有持久记住这个固定 GUID。因此 app 侧做成**自动确认**（`MainScreen.onConnectWifi` 拿到 `pairingRequired` 就直接调 `completeWifiPairing`），用户不需要点「完成配对」。
- 验证码在 Z50II 的相机屏幕上**不显示**，核对没有意义；UI 文案只写「若相机显示同一组数字可顺便核对」。

**mDNS 发现（1.32.0）**

- `services/NsdScanner.ets` 浏览 Bonjour `_ptp._tcp`，实例名就是相机名（`Z50_2_8079350`），SRV 端口 15740。
- `serviceFound` 只保证 `serviceName`，IP/端口必须再 `resolveLocalService()` 补全；serviceType 在 HarmonyOS 上**不带尾点**。
- `CameraService.scanWifiCameras(8000)` 浏览 8 秒，结果进 `wifiCameras`；相机页的「搜索附近的相机」把它们列出来，点一下直接连，不用手填 IP。
- 解析失败（2204006 超时）属正常，下轮广播会再报；`serviceLost` 会从列表移除。

**/24 网段扫描兜底（1.33.0）**

mDNS 被客户端隔离/访客网络挡掉时一个广播都收不到，所以「搜索附近的相机」会**同时**跑一遍 `services/SubnetScanner.ets`：

- 取本机所有 IPv4 接口地址，各展开所在 /24 的 1..254（跳过本机、回环、169.254），候选上限 512；
- 并发 12 个 TCP connect（700ms 超时），**只连不发送任何字节**——相机是单连接服务器，乱发 Init 会踢掉正在配对的会话；
- 端口开放的主机作为候选并入 `wifiCameras`，用户点选后再走正式 PTP/IP。
- 结果按 host 去重，mDNS 和网段扫描谁先发现都只留一条。

**多网卡绑定（1.32.0）**

手机同时挂办公网和相机热点时，app 的 socket 默认绑在系统默认网络上，往热点网段发的 SYN 会从错误网卡出去，表现为 `2301115 Operation in progress`。`WifiPtpLink` 在 connect 前按目标 IP 的网段找对应网络，先 `bind` 本地地址、再 `net.bindSocket()`。注意 `connection.getAllNets()` 不保证包含没有 INTERNET 能力的热点网络，匹配失败时退回默认网络（日志会缺 `socket 绑定本地` 那行）。

**BLE：扫描、GATT 与两段式首配（1.38.x）**

`services/BleScanner.ets` 负责扫描、GATT 连接与配对；`services/NikonPairing.ets`
是四步握手的编解码，`services/NikonBlowfish.ets` 是定键 CBC-MAC。

*扫描*

- `BleScanner` 用 `ble.startBLEScan([{}, ...])` 空过滤扫描（传空数组会被拒：
  `401 Invalid parameter`），收到结果后按**广播名**筛（`Z50_2_8079350`、
  `Z_f_8014411` 这类以 `Z` 开头、含下划线的名字）。不能只按服务 UUID 过滤：
  相机在等待配对时广播里不带 `0x0399`，按服务过滤会一个都扫不到（ZPill 实测）。
- 相机每轮广播都会换随机地址（RPA），所以**不能把上一次的地址当稳定标识**，
  重连失败要重扫。

*四步握手（0x2000）*

帧固定 17 字节小端：`stage(u8) + timestamp(u64 LE) + device(u32 LE) + nonce(u32 LE)`。
**ArkTS 的 `number` 只有 53 位**，u64 时间戳必须拆成 `tsLo`/`tsHi` 两个 u32。

- stage1 的 `device` 低位字节必须是 `0x01`
- stage2 用 8 组固定 salt 逐一试 `hash(salt ‖ camLo ‖ camHi ‖ ourLo ‖ ourHi)`，
  命中后块序反过来算 stage3
- stage4 字节 9–16 是相机序列号 ASCII（NUL 截止）

*两段式首配（鸿蒙特有，2026-11-11 真机打通）*

这是整条 BLE 链路最容易走错的地方，**只做四步握手永远配不上**：相机侧会一直停在
「开始配对」页、`已配对设备` 为空，但 App 这边每一步都「成功」。完整剧本：

1. **段 1**（BLE 上）：四步握手 → 写 `0x2002` 控制器名（32B ASCII 零填充）
   → 写 `0x2005 = 0x01` 唤起相机无线
2. **断开 BLE**，等 3 秒让位窗
3. **经典蓝牙绑定**：`startBluetoothDiscovery` → 按名字（下划线归一后互含）或
   序列号匹配相机 → `pairDevice(经典地址)` → 等 `BOND_STATE_BONDED`
4. **重连 GATT**，**用同一份 device/nonce 复用握手**
5. 成功后把身份落盘

第 3 步的关键是**必须用经典蓝牙发现出来的地址**。直接拿 BLE 的 `deviceId`
调 `pairDevice` 会一直停在 `BOND_STATE_BONDING` 直到超时（本项目实测两次 12 秒
超时）。而且**必须先断开 BLE 再做发现**——相机要等 BLE 链路释放才在配对态暴露
经典蓝牙。

第 2 步的让位窗不能省：ZPill 记录过「零缓冲直发配对把相机射频楔死，杀应用才解」。

*身份持久化与复用（必须做，否则只能配一次）*

相机**只认 stage1 里那份 device/nonce**。之后每次连接再发全新 stage1，相机会直接
回 `write 2900099: Remote device has an error` 秒拒。

`services/BleIdentityStore.ets`（`PersistenceV2.globalConnect`）落盘
`deviceId / cameraName / identityDevice / identityNonce / serial`。`pair()` 的分支：

- `store.hasIdentity()` 为真 → 直接复用握手，不碰相机配对页
- 否则走两段式首配

段 2 复用握手失败时**不落盘**身份，避免下次拿一份相机不认的身份去复用。

*容易踩的三个坑*

- **回链后必须先拉服务表**：`bond` 之后 GATT 服务缓存是空的，不先 `getServices()`
  就订阅特征会报 `401 Invalid parameter`（本项目段 2 第一次就这么断的）。
  `handshake()` 开头的 `ensureServices()` 负责这件事。
- **读特征之间要留间隔**：连续 8 个 `readCharacteristicValue` 打出去会全部撞上
  `2900099`（官方对该错误码的解释之一就是「前一个非监听类 BLE 接口没回调完」）。
  现在每次读之间隔 150ms，失败退避重试 3 次。
- **`0x2008` 不是配对成功的标志**。ZPill 定案：它是 2B 位域
  `(Connection<<8)|(Location<<4)|Time`，`01 00` 是相机在「要时间」；而且相机是
  收到 `0x2002` 控制器名**之后**才发它。等它再写名字会双方互等到超时。
  另外配对事务内不要写 `0x2008`，会搅坏注册。

*特征速查*

| 特征 | 用途 |
|---|---|
| `0x2000` | 配对认证（indicate，17B 握手帧） |
| `0x2002` | 控制器名（写 32B ASCII 零填充） |
| `0x2004` | 相机 Wi-Fi 凭据（只读，102B；flag `0x03` = WiFi+蓝牙块齐全） |
| `0x2005` | 连接建立（写 1B，`0x01` 唤起相机无线，`0x80` 关闭） |
| `0x2006` | 校时（10B，兼 45s 保活心跳） |
| `0x2007` | 位置（41B） |
| `0x2008` | LSS 控制点（2B 位域，相机 notify 请求，ready 后才应答） |
| `0x2a19` | 电池（`de00` 服务下的 SIG 采纳特征） |

- 权限：`ohos.permission.ACCESS_BLUETOOTH`（user_grant），`CameraService.ensureBlePermission()` 在首次搜索时申请。
- 相机 2 分钟没有 BLE 流量会断链，45 秒一拍留足余量。
- 配对完成后**先等 2.5 秒**再写 `0x2006`（ZPill 的 writeGate）：相机刚收口时注入
  会话还没醒，立刻写会被拒甚至被踢链。

**BLE 与 Wi-Fi 互斥：把「交接」当成一次代价高的动作（1.41.1）**

Z50II 实测（2026-11-11 用户确认 + 本项目日志对拍）：**相机同一时间只能开蓝牙或
Wi-Fi**。写 `0x2005 = 0x01` 把相机推到 Wi-Fi 之后，BLE 立刻消失；Wi-Fi 空闲约
40 秒才回落到 BLE 广播。

日志原样：

```
6:18:48  写 0x2005=0x01
6:19:19  BLE 断开            ← 相机进 Wi-Fi 模式
6:19:26  相机又在广播了      ← Wi-Fi 空闲回落
6:19:32  BLE 重连上
6:19:35  又写 0x2005=0x01    ← 旧代码在 resume 路径上补写
6:19:42  BLE 又断开
```

1.40.x 把「复用握手后补写 `0x2005`」当成修复（确实修好了「休眠唤醒后相机无线
是关的」），但在互斥机型上它变成**乒乓**：每轮 BLE 自动重连都把相机重新推去
Wi-Fi，相机永远在两个模式之间被踢。现在的规则：

- `connectBle(deviceId, name, handOver)`：`handOver` 默认为 true（用户主动选
  相机）；**冷启动与自动重连一律传 false**，只做待机（校时 + GPS 注入）。
- 交接节流：`lastHandoverAt` + `handoverCooldownMs = 90s`。冷却期内的 BLE
  连接只待机，日志会写「交接冷却中」。
- `connectWirelessNow()` 是**用户明确要照片**时的唯一交接入口：BLE 在就写
  `0x2005=0x01` 再走发现；BLE 不在就按保存身份先连 BLE（带 handOver）。
- Wi-Fi 会话起来后 `suspendBleForWifi()`：停保活、关自动重连 —— 保活必然写
  失败，自动重连只会把相机从 Wi-Fi 拽回来再推回去。
- Wi-Fi 会话结束后 `resumeBleAfterWifi()`：按 `[6s, 15s, 30s, 60s]` 退避把
  相机接回 BLE 待机（相机回落要几十秒），四轮都失败就交给下一次用户动作。

**官方口径（SnapBridge 帮助，2026-11-11 核对）**

- SnapBridge 里有明确的「**退出 Wi-Fi STA 模式**」菜单项（`连接` 标签 → ⚙ → 退出），
  AP 模式对应「退出 Wi-Fi AP 模式」。所以"从 Wi-Fi 回到蓝牙"是官方支持的动作，
  只是被做成了 app 里的一个操作，不是相机菜单里的操作。它的效果等价于我们
  `disconnect()` 做的「CloseSession + 断开链路 + 让相机回落」。
- 官方原文：「完成或中断从照相机下载照片的进程后，无法立即切换至 Wi-Fi STA 模式。
  在下载照片或中断传送后，请等待至少 **3 分钟** 后再进行切换。」→ 相机侧退出
  Wi-Fi 后有一段状态机在走，交接冷却就按这个取 `180000ms`，原来的 90 秒太短。
- 官方原文：「Wi-Fi STA 模式下不可用：手动下载位置数据、昵称、**蓝牙遥控**、固件下载」
  —— 官方自己确认了 STA 模式下蓝牙那套功能不可用，与真机观察一致。
- 「轻触『Wi-Fi已连接』图标可暂时中止与照相机的 Wi-Fi 连接，从而减少智能设备电池的
  消耗」—— 这是**手机侧**断开（省手机电），不是让相机退出模式，别混为一谈。

**为什么最终选 AP 而不是 STA（2026-11-11 真机定案）**

两条路都实测过，结论很硬：

| | Wi-Fi AP 模式 | Wi-Fi STA 模式 |
|---|---|---|
| 相机侧配置 | 选一次 profile | 搜热点 + 输密码 |
| 进入 | 全自动（凭据来自 `0x2004`） | 全自动（但相机要先入网） |
| **退出** | **离开相机热点 → 零客户端 → 实测约 40 秒回落蓝牙** | **无解**：关会话 3 分钟后相机仍在 `192.168.43.5` 上应答 ping |
| 手机上网 | 断 | 保持 |

STA 的三条退出路都试过，全部不通：

1. **BLE**：探针实测，Wi-Fi 会话期间相机**完全不发** BLE 广播（5s/20s/30s 三轮全空），
   两个射频不能共存，`0x2005=0x80` 没有信道可走；
2. **`0x9435(0)` ChangeApplicationMode**：相机回 `0x2001`（OK）但毫无效果 ——
   假钥匙，和 ZPill 记录的「0x9435 回 OK 但是假钥匙」一致；
3. **关会话等超时**：`CloseSession` + 断两条 TCP 之后三分钟，相机仍挂在热点上
   （`ping 192.168.43.5` 通，199ms）。

AP 模式能成立的关键是**触发权在手**：手机是相机热点的唯一客户端，`removeCandidateConfig`
一撤，相机看到零客户端就按自己的待机计时回落。这就是「按需切换」需要的那把开关。

所以 1.42.0 起：**默认走 AP 模式**，STA 保留为「相机已配好 STA 时的手动入口」
（相机页的「搜索附近的相机」），不再自动触发。

产品含义：**BLE 是常驻待机态，Wi-Fi 是「借来传照片」的态**。这也和 SnapBridge
一致 —— 拍摄期间靠 BLE 打 GPS，只有下载时才切 Wi-Fi。相机页因此在「蓝牙已配对、
无线未连接」时给一个明确的「连接相机（切到 Wi-Fi）」按钮，而不是偷偷自动切。

**无线链路的自动接续（1.41.0）**

蓝牙配好只是半条链路。照片要走 Wi-Fi STA 上的 PTP/IP，所以在 BLE 配对落定之后
必须接着把无线那半条接起来，否则用户看到的是「蓝牙已连接 + 无线未连接」两张
互不相干的卡。

*网络枚举：`services/LocalNetworks.ets`*

只用 `connection.getAllNets()` 不够——它**不保证**列出没有 INTERNET 能力的
热点网络，而 STA 链路里最典型的网络恰好就是手机热点。三条来源并起来：

1. `getAllNets()` 的链路地址（权威，但可能漏热点）；
2. `wifiManager.getIpInfo()` 的 STA 地址（`getAllNets` 偶尔也漏 STA）；
3. 热点开着（`isHotspotActive()`）且前两条没覆盖时，补平台约定的
   `192.168.43`。三方应用没有任何接口能读热点接口自己的地址
   （`getHotspotConfig` 一类要系统权限），只能按约定猜，所以这一条是启发式、
   且只在必要时加。

`IpInfo.ipAddress` 的字节序没有官方文档背书（社区口径是 Android DhcpInfo 的
小端约定），所以做一次**自洽校验**：地址与网关同 /24 才采信小端，否则试大端，
都不自洽退回小端。这样即使口径反了也不会把整轮扫描打到错误网段。

`SubnetScanner` 用它的 `subnets` 展开 /24，并**把热点网段排在最前**：热点没有
外网、mDNS 常被挡，网段扫描往往是唯一出路，不能让它排在办公网后面等十几秒。

*自动接续的三个触发点*

| 触发点 | 行为 |
|---|---|
| `connectBle()` 配对成功 | `autoLinkWifi('ble-paired')` |
| BLE 断链自动重连成功 | 若无线没连上，`autoLinkWifi('ble-reconnected')` |
| App 冷启动 `autoConnectBle()` | 见下 |

冷启动分两种情况：有 BLE 身份就走 BLE，连上后由上面第一条接无线；**没有 BLE
身份或 BLE 彻底不通时，无线仍单独试一次**（`autoLinkWifi(..., allowScan=false)`）
——用户可能只想要相册，不需要蓝牙保活/地理标记。`allowScan=false` 表示只用
记住的地址，不在冷启动时空跑一轮 254 个地址的扫描。

冷启动还要看用户选的是哪种链路：`linkMode === USB` 时**根本不调**
`autoConnectBle()`（见 `MainScreen.aboutToAppear`）。用户选的是走线，不该再去
占相机的蓝牙链路。

*后台失败要静默*

`connectBle(deviceId, name, handOver, silent)`：`silent = true` 时失败只写日志，
不写 `lastScanError`、不触发 toast。冷启动的 `autoConnectBle(silent = true)`
全部走静默路径；用户主动点「搜索相机」的那次是 `autoConnectBle(false)`，失败要
说出来。以前每次开机都会红着一行「蓝牙连接相机失败」并弹一次 toast，相机不在
手边时尤其像故障。

*相机立牌用的机型 key 与机身信息*

`CameraService.cameraModel` 只存一个 key（`z50ii` 这类，见
`utils/CameraStandee.ets`），由 `@Monitor('cameraName', 'bleCameraName')` 识别
并落盘到 `CameraModelStore`（PersistenceV2，key `camera_model`）。断开时这两个
字段都会被清空，但这里不清 `cameraModel`：立牌要留着（变暗）。
`initCameraModel()` 在启动时把上次的 key 读回来；从没连过 PTP 也能认——BLE 首配
时 `BleIdentityStore` 已经存了广播名（`Z50_2_8079350`）与序列号。

**连着却认不出机型时要把立牌清掉**（1.48.0）：判断键是 `raw !== ''`，也就是
「有连接的机型串但 `cameraStandeeKey()` 返回空」（Z fc / ZR 这类没有商品图的机器，
或调试包选的「未知型号」）。继续摆上一台相机的图和型号名，比没有立牌更糟——那等于
告诉用户「连的是那台」。断开时 raw 为空，走的是保留那条，页面不会塌一块。

`camera_model` 里还存 `serial`，供标题栏型号右下角的角标用
（`MainScreen.cameraSerialBadge()`）：

- 优先取 BLE 广播名尾段（`cameraSerialFromBleName()`，`Z50_2_8079350` →
  `8079350`），它和相机菜单、官方 SnapBridge 显示的一致；
- `BleIdentityStore.serial` 是**另一个数**（本机实测 `1246090` vs `8079350`），
  不要混用；PTP 的 32 位序列号去前导零后才是 `8079350`。

*切换链路模式要清场*

`setLinkMode(mode)` 除了落盘，还会清空 `lastScanError` / `bleHint` / `wifiHint` /
`networkSummary` / `wirelessStage`——这些都描述上一模式的现场，留着会串味
（切到 USB 还挂着蓝牙失败、AP 模式还显示手机当前 Wi-Fi）。进入 STA 时顺带调
`refreshNetworkSnapshot()` 摸一遍本机网络，「本机网络」一行立刻可见；
`initLinkMode()` 恢复的是 STA 时同样补一次。

`autoLinkWifi()` 的顺序刻意是「记得的地址 → mDNS/网段扫描」：相机地址几乎不
变，先直连能把冷启动压到一两秒；直连失败才扫。连上之后 `finishAutoLink()`
直接 `scanForCamera()`，让「蓝牙连上 → 无线连上 → 相册出来」是一条连续的链路。

*地址持久化：`services/WifiLinkStore.ets`*

`PersistenceV2.globalConnect()`，key `wifi_link`，存 `host / port / cameraName`。
只存「上次连上过的地址」，不存身份与配对码。以前 `wifiHost` 是纯内存
`@Trace`，每次冷启动都得让用户重新找一次 IP。

*`0x2005` 必须两条路都写*

`0x2005 = 0x01` 唤起相机无线，`0x80` 关闭。以前只有首配（`pairFresh`）写
`0x01`，复用握手（`resumePairing`）不写——于是相机休眠/重开之后走 resume 的
路径上相机无线一直是关着的：BLE 日志全绿，PTP 永远连不上。现在两条路都写。

`0x80` 只在 `disconnectBle()` 且**无线会话不在用**时写：STA 模式下这一笔会让
相机退出网络，顺手把正在用的 PTP 会话也断掉。

*无线侧的自动重连*

`WifiPtpSession.setBrokenHandler()` 把「运行中断链」上报给 `CameraService`。
以前 `broken` 只是内部标志：断链之后 App 还停在「已连接」，点什么都失败。
注意 `connect()` 失败也走同一个 handler，所以只有**已经建立过会话**的断开才算
运行中断链（`wasOpen` 判断），否则会在连接失败瞬间排出重连、和用户正在点的
那次连接打架。

退避 `[2000, 3000, 5000, 8000, 12000, 20000, 30000]`，与 BLE 同节奏；每轮先试
记住的地址再重扫。用户显式断开（`disconnect()` / `disconnectBle()`）会把
`wifiAutoReconnectArmed` 置 false 并清掉计时器，避免刚点完断开又被接回来。

*扫不到时的原因（`networkHint()`）*

扫不到相机分两种：**网络前提不成立**（没有可用网络、Wi-Fi 与热点都没开）与
**相机那边的事**（没进 Wi-Fi 模式、被客户端隔离、上一个会话还挂在 15740 上）。
`scanWifiCameras()` 先摸一遍本机网络写进 `networkSummary`，再把
`networkHint()` 的结论写进 `wifiHint`；两台都为空时补一句「同一网络里没有
发现相机，确认相机已进入连接至智能设备」。相机页把这两行原样显示。

*`0x2004` 凭据解密：`services/NikonWifiCredentials.ets`*

blob 是 **97B 或 102B** 密文：`32B 加密 SSID + 64B 加密密码 + 1B 安全模式`
（97B，SnapBridge 口径），或前面多一个 flag 字节、安全字节后多一段 LSS 尾
（102B，LSS 口径）。两条解密路线：

1. **LSS 会话密钥派生**（主路）：`ctx = idx‖N_A[1..3]‖X[0..3]`，
   `K = MAC8(key1‖key2‖ctx)`（MAC 用与握手同一个定键 CBC-MAC），K 当标准
   Blowfish 密钥编排，SSID 与密码**各自独立 CBC、IV 全零**。ctx 字节序与 key1
   语义在还原报告里没定死，留 2×4 组候选，由**可打印性 oracle** 裁决。
2. **定键试探**（兜底，只在 97B 布局上）：直接拿握手定键 ECB / CBC 试解。

材料全部取**线上原样字节**：`key1` = stage4 帧字节 9..17（是 8B 身份字段，不是
「序列号字符串」）、`key2` = stage1 帧字节 9..17、`cameraNonce` = stage2 帧字节
1..9、`phoneNonce` = stage1 帧字节 1..9，加上命中的 `saltIndex`。全试未中如实
返回 `null`，**不臆造明文**。

真机日志形如 `配对: 相机热点「Z50_2_8079350」· 开放 · 密码 0 字符 · 来源 lss-kdf …`。
密码只打长度不打明文。

**当前边界（重要）**

- 只支持 STA/热点这种「手机与相机同网」的路径；AP 模式（手机连相机热点）没做。
  凭据解密已经落地（1.41.0），缺的是 `wifiManager` 候选配置族那一层接入。
- **「相机入网」这一步 App 代替不了**：三方应用没有任何接口能开热点
  （`enableHotspot` 要系统权限），相机也必须人工在菜单里选一次网络。所以 STA
  只能做成「一次性配置 + 之后自动接续」，相机页给了步骤引导。
- 连接失败的第一嫌疑仍是「相机不在『连接向导』页」——显示 IP/掩码的页面 15740 没开。
- `GetStorageIDs` 被拒时返回 `0xFFFFFFFF` 哨兵，由 `GetObjectHandles` 按「所有存储」枚举——这是 SnapBridge 会话的已知行为。
- 部分机型对同一台相机只保留一个 PTP/IP initiator；另一个设备的 `Init` 会踢掉前一个会话，甚至把相机踢出配对模式。调试时不要并发探测。
- PTP/IP 未认证、未加密，同网段任何设备都能连；只在可信网络使用。



### PTP 事务调度（PtpScheduler，2026-11-09）

`CameraService.session` 现在固定包一层 `services/PtpScheduler.ets`：所有 PTP 事务进一条 promise 队列，串行执行，按优先级插队（`FOREGROUND` 前台原图 > `PRELOAD` 邻近预加载 > `SCAN` 扫描）。

- **不要再在 `PtpSession` / 调用方里用 `usbBusy` 或 200ms 轮询做互斥**：旧实现每交接一次最多白等 200ms，真机上连续 `Getting thumb` 的起点是 204ms 一跳；1288 张缩略图耗时 227s（176ms/张）。
- 队列必须覆盖**所有** PTP 事务（含 `getObjectInfo` / `getObjectHandles`），否则会和取图交错。
- 每个事务的优先级由调用方传入。`PtpScheduler` 的默认值：`getObject` 前台、`getThumb` / `getObjectInfo` / `getObjectHandles` 扫描、`connect` / `closeSessionAndPipe` 前台；`preloadAdjacent` 显式传 `PRELOAD`。
- 队列只保证**事务**串行，不保证一个业务操作原子完成：取图、EXIF、解码之间会让出队列，正好用来重叠。
- `PtpScheduler` 不负责取消已提交的事务；`bulkTransfer` 本身不可取消。快速滑图时旧请求仍会跑完，要彻底解决得等 P3（`usbSubmitTransfer` + `usbCancelTransfer`）。

### 缩略图流水线与预加载等待（P1，2026-11-09）

- `loadThumbnailsRowByRow` 改成 8 个 worker 的工作池：每个 worker 跑「取图（USB）+ EXIF + 解码」，USB 由 `PtpScheduler` 串行、解码在 TaskPool 并行，不再按行 `await Promise.all` 卡住整条管道。
- **行仍然整行出现**：`rowDone` + `publishedRow` 按行号顺序发布，只有从最上面开始连续完成的行才 `thumbnailVersion++`，不会出现第 2 行先于第 1 行。
- `scanProgress` 按 100ms 节流，不再每张都触发一次 UI 重建。
- `loadFullPhoto` 等邻近预加载改成 `preloadWaiters` 完成通知（`waitForPreload`），不再 25 × 200ms 轮询；超时后前台 `getObject(FOREGROUND)` 直接插队。
- `entry/src/test/PtpScheduler.test.ets` 覆盖串行与优先级插队。

**实测（2026-11-09，Nikon Z50_2，1288 张，清空缓存后的全量扫描）**：

| 阶段 | 改造前 | 改造后 | 变化 |
|---|---|---|---|
| 元数据 1288 条 | 46.9 s | 43.0 s | 基本不变（相机事务中位 32 ms/条） |
| 缩略图 1288 张 | 239.6 s（186 ms/张） | 65.5 s（51 ms/张） | **3.7×** |
| 合计 | 286.9 s | 108.5 s | **2.6×** |

1288/1288 解码成功，无 `NO_THUMB` / `[TASKPOOL_THUMB] FAIL`。收益全部来自缩略图阶段：去掉 200ms 轮询 + 取图/解码流水线；元数据阶段仍是相机侧固定事务延迟，未继续优化。热扫描（缓存命中）不走 USB，约 2s 级。

### P3：GetObject 异步大块传输与零拷贝（2026-11-09）

扫描阶段保持原样，只改 `getObject`（原图下载）：

- 命令 OUT 仍用 `bulkTransfer`（24B）；数据 IN 用 `usbSubmitTransfer`，主图 1MB/包、邻近预加载 256KB/包；数据结束后响应包用 1KB `bulkTransfer` 读。
- `getThumb` / `getPartialObject` / `getObjectInfo` 仍走同步 bulk：小数据下 async 每次建 ashmem 的固定开销更大。
- `usbSubmitTransfer` 走 ashmem，不受 `bulkTransfer` 的 200KB 限制；官方文档对 `length` 只约束 [0, INT_MAX]。
- 缓冲区在事务内复用，顺序提交；`PtpScheduler` 仍然把整笔事务串行化。
- **自适应分块与回退**：按 `bulkIn.maxPacketSize` 设初始/上限（USB3 512KB→1MB、USB2 512KB、全速 64KB）；每笔记录 `processResponse` 峰值，>8ms 降一档，连续两笔 ≤4ms 升一档。`usbSubmitTransfer` 同步提交失败时，当前 GetObject 继续用 192KB bulk 把数据/响应读完，本会话后续都走 bulk；预加载分块固定不超过 256KB。
- 自适应参数目前只在 Nikon Z50_2 + 本机做过一轮设计验证，其他手机/相机/读卡器仍需真机矩阵确认。

**NAPI 零拷贝（关键修复）**：

- `ProcessResponse` 直接用 TypedArray 底层指针调用 `processIncoming`，不再先 `GetUint8Array` 拷进 `std::vector`；
- 数据阶段按 PTP 头里的总长度 `reserve`，避免每包 append 时反复扩容；
- 数据阶段结束的 6–16MB 结果用 `napi_create_external_arraybuffer` 交给 JS，去掉最后一次 `memcpy`。
- 之前 2MB/包在 `processResponse` 里单次 **50–200ms**，是预览器滑动掉帧的根因；零拷贝后 1MB 包峰值 **3–4ms**。

**分块实测（16.1MB NEF，同对象两轮，checksum 全部一致）**：

| 分块 | 两轮吞吐 | `processResponse` 峰值 |
|---|---|---|
| 256KB | 22.1 / 12.0 MB/s | 1–2ms |
| 512KB | 32.1 / 28.6 MB/s | 2ms |
| **1MB** | **38.4 / 42.0 MB/s** | **3–4ms** |
| 2MB | 18.9 / 51.1 MB/s | 2–3ms |
| 4MB | 52.0 / 15.1 MB/s | 7ms |
| 8MB | 45.8 / 38.5 MB/s | 14–17ms |

1MB 是稳定性与主线程开销的折中（约 40MB/s）；2MB 以上波动明显变大，8MB 峰值已接近一帧，会重新掉帧。

**多笔 in-flight 已排除**：512KB×2 直接返回 `async transfer status=6`（`TRANSFER_OVERFLOW`），同 endpoint 多笔在途时设备/主机不按请求边界切包，PTP 数据无法安全重组。

**UI 结果**：零拷贝后 6.3MB 的 JPEG `USB下载` 约 0.2–0.4s；`processResponse` 不再出现 50ms 级主线程阻塞。

**PC gphoto2 基线（2026-11-09，macOS）**：同一张 `DSC_3987.NEF`（15.7MB），gphoto2 2.5.32 两次下载 4.78s / 4.75s，约 **3.3MB/s**，比手机端 40MB/s 慢一个数量级。这说明 macOS 的 libusb/gphoto2 路径本身是瓶颈，不能拿来当相机上限；手机端 40MB/s 已经高于该基线，USB 链路不是当前瓶颈，继续压带宽的收益有限。


### 预览器加载感知（2026-11-09）

快速连滑多张后停住，曾出现「迟迟不显示转圈、迟迟不出原图」：

- 旧逻辑停稳 100ms 就启动全图下载，快速滑动时给中间页白下 6MB；
- 新当前页的 `loadFullRes` 被这个在途下载挡住，只记 `pendingFullResHandle` 就返回，**没有设置 spinner**，所以既没反馈也要等旧下载结束；
- `PtpScheduler.getObject` 只把 priority 用于排队，没传给 `PtpSession.getObject`，预加载其实仍按前台分块跑。

修复：

- 停稳延迟 100ms → **260ms**；手指一落下就取消「停稳下载」定时器；
- 被挡住的请求立即设置 `loading/spinnerOn`，不再等真正开始下载才转圈；
- 转圈延迟 420ms → **300ms**；
- `PtpScheduler.getObject` 把 priority 传给 `inner`；预览器预加载显式传 `PRELOAD`，并使用 256KB/包；
- 真正当前图仍 `FOREGROUND`、1MB/包，插到预加载前面。

实测体感：左右滑明显更顺，快速连滑后停住能立即看到加载提示并较快出图。

### 渐进预览与方向预加载（2026-11-09）

- `loadFullPhoto` 增加可选 `onPreview`：下载与方向读取完成后，先在 TaskPool 解一张 **最长边 2048** 的预览，立即上屏；3072 全尺寸继续在 TaskPool 解，完成后替换并释放预览。
- 只有**当前前台图**走两段解码；邻居预加载仍然只解全尺寸，避免后台双解抢 CPU。
- PTP 元数据已知原图长边 ≤2048 时跳过预览，避免“预览和全尺寸一样大”的重复解码。
- 预览解码失败不阻塞全尺寸；全尺寸解码失败时保留预览，用户至少能看到可用图。
- 预览器记录最近翻页方向，`preloadNeighbors` 同方向优先（距离 ×2，同方向再减 1），前进/后退时先准备下一张。
- 以上尚未在无设备环境下完成真机体感验收；行为与日志已就位，等下次真机确认。
- `onMainAnimationEnd` 忽略 `index !== mainIdx` 的过期回调，避免快速连滑时被上一段动画拉回旧页；取图过程中 USB 断开（`PTP_ERR_USB`）会主动关会话并置 `connected=false`，下一次搜索重新连接。

### 扫描阶段的测量与能力探测（P4，2026-11-09）

扫描的成本几乎全是「每张照片的 USB 往返次数 × 相机侧延迟」：冷扫描每张要 3 笔
（`GetObjectInfo` 元数据 → `GetThumb` 缩略图 → `GetPartialObject` 读原图 EXIF 方向），
Nikon Z50_2 上单笔约 30–40ms，1288 张就是分钟级。所以这一段只做两类事：少跑几笔、跑得早知道。

**1. 阶段计时（每轮扫描重置，结束写一行摘要）**

`扫描耗时: 遍历 Xms | 元数据 Yms/N张(均Zms) | 缩略图USB Ums/N张 | EXIF头 Vms/M次 | 落盘 Wms | 解码 Tms`
再加一行 `缩略图EXIF方向: 可信/不可信/样本不足 / 样本 / 竖拍 / 不一致 / 无EXIF`。

- `statWalkMs` / `statInfoMs`+`statInfoCount` / `statThumbMs`+`statThumbCount` / `statExifMs`+`statExifCount` / `statSaveMs` / `statDecodeMs`
- 有了这几个数才能分清瓶颈在 USB 往返、写盘还是解码，不要再凭“感觉慢”去改。

**2. `GetObjectPropList`（MTP 0x9805）探测**

- Native 新增 `buildGetObjectPropList` / `parseObjectPropList`；`parseDeviceInfo` 现在也把
  `operationsSupported` 交给 ArkTS（判断相机有没有自报 0x9805）。
- 只有本轮**确实要逐张读元数据**（元数据缓存没复用成功）**且相机自报支持 0x9805** 时才试一次，
  整会话一次（`propListProbed`）。
- 日志 `[PROP_LIST] ... 声明 N / 解析 M 条 / 字节数 / 完整与否`，另有属性码列表、字段覆盖率与数据头 hex。
- **2026-11-09 真机（Nikon Z50_2）实测：不支持，而且探测有副作用**。Op 未列入 `operationsSupported`，
  发过去后相机不回响应，IN 端点在 **10s 超时**后才放弃；紧接着的 3 条 `GetObjectInfo` 各失败一次
  （`command send failed (-1)`，各约 5s），**丢了 3 张照片**。所以现在只在相机自报支持时才探测，
  不再“先试一下”。
- 即便支持也**暂时只探测不使用**：MTP 属性里没有 `ImagePixWidth/Height`，而缩略图裁黑边必须知道
  原始比例，真要替代 `GetObjectInfo` 还得先解决尺寸来源。

**3. 缩略图自带 EXIF 方向（自适应，默认仍然读原图）**

- `loadSingleThumbnail` 先用 `readThumbOrientation(thumbData)` 从 GetThumb 返回的 JPEG 里读方向；
  读到了并且判定可信时，跳过这一次 `GetPartialObject`。
- 可信判定：与原图方向**逐个比对**，出现一次不一致就永久判为不可信；样本 ≥12 且其中竖拍 ≥3 才切换。
  早期照片里连续 8 张都没有 EXIF 时直接放弃探测。
- 之前实测 Nikon Z50_2 的缩略图 160×120 不含 APP1，所以这台相机上会走“无 EXIF → 继续读原图”的
  分支，行为与 1.25.1 一致；这条路径是给其它相机留的，判定逻辑保证不会把横竖拍搞错。

**4. 交织扫描（2026-11-09，1.26.0）**

冷扫描的时序原来是「28s 全量元数据 → 87s 全量缩略图」：首屏缩略图要等 55s 才出现，
而这段时间用户盯着占位符。现在按 `SCAN_CHUNK = 64` 分批：

```
读 64 张元数据 → 发布相册列表 → 取这 64 张的缩略图 → 下一批
```

- 总时长不变（USB 是一根管道，事务数没变），但**首屏缩略图从 55s 提前到 2–4s**。
- 判定条件是 `interleave = !fullReuse`：只要这一轮真的要逐张读相机（冷扫描、新照片、断点续扫）就交织；
  整份命中缓存时元数据是瞬时的，仍走“一次读完再统一取缩略图”的老路径。
  1.26.0 里这个条件是 `progressive && !canReuse`，导致**断点续扫时用户要盯着旧快照一动不动等到元数据读完**，1.27.1 改掉。
- 交织时把 handle 数组反过来遍历：相机 handle 基本按拍摄顺序递增，从后往前读，
  画廊顶部（最新）那几行最先有图。
- 每批发布前有个「只增不减」闸门（`photoList.length >= this.photos.length`）：
  已有缓存快照时不能让列表先缩到 64 张；冷启动 `this.photos` 为空，闸门恒成立。
- `loadThumbnailsRowByRow(validCacheKeys, finalize, manageProgress)` 新增两个开关：
  每批调用时 `finalize=false`（不 flush/purge/close 缓存）、`manageProgress=false`
  （进度由外层按“已处理张数”统一维护），收尾时再调一次 `finalize=true`。
- 相位文案改用 `camera_phase_loading_photos`（正在加载照片...），不再在元数据/缩略图之间来回切。

**真机实测（2026-11-09，Nikon Z50_2，1288 张，冷缓存）**：

| 阶段 | 耗时 | 说明 |
|---|---|---|
| 遍历目录 | 92 ms | 格式筛选可用，每层 2 笔 |
| 元数据 | 27.8 s / 1285 张 | 21.6 ms/笔（串行，无排队） |
| 缩略图阶段 | 87 s | 2570 笔（GetThumb + GetPartialObject）= **33.9 ms/笔** |
| ├ 落盘 | 7.5 s | 被 USB 等待完全盖住 |
| └ 解码 | 44.4 s | 8 worker 并行，同样被盖住 |

结论：**扫描时间 = 事务数 × 每笔的相机侧延迟**，写盘与解码都不是瓶颈。
每张照片冷扫描 3 笔（元数据 / 缩略图 / EXIF 方向），1288 张≈3855 笔≈130s。
prop list 不可用 → 元数据没法合批；缩略图是每个文件一次读；EXIF 方向**不能省**
（竖拍有 90°/270° 两种，缩略图又无 EXIF，靠黑边几何只能判断横竖、分不出方向，会有一半竖拍放倒）。

**5. 省掉的无效开销**

- `PtpSession.readBuf`：192KB 读缓冲整会话复用。旧代码在每次读取的循环里 `new Uint8Array(196608)`，
  1288 张缩略图约 240MB 垃圾。
- `setPtpQuietOps(true)`：扫描期间关掉逐笔流水日志（命令 hex、RAW IN、processResponse、Got data）。
  1288 张会有 6000 行，既刷掉 AppLog 环形缓冲里真正有用的摘要，也要花时间拼 hex。错误日志不受影响。

### 暂不做 / 以后做

- **P2（扫描期延后 EXIF 方向）不做**：先看到未旋转的照片与体验一致性冲突。改成上面的「缩略图自带 EXIF 才跳过」，宁可多花一笔 `GetPartialObject`，也不让方向错。
- **P3 的进一步优化**：同 endpoint 多笔 in-flight 已被 `TRANSFER_OVERFLOW` 证伪；PC gphoto2 基线已做（约 3.3MB/s，反而不如手机），说明手机端约 40MB/s 不是 USB 链路瓶颈，继续在传输层抠带宽的收益有限。
- **扫描阶段已做的都做了**：交织（首屏）+ 只对自报支持的相机探测 prop list + 缓冲复用 + 流水日志静音。
  剩下的 130s 是相机侧每笔 22–34ms 的固定延迟 × 3855 笔，宿主端已经没有可砍的东西。
- **还能再快，但要改产品行为**（需用户确认）：扫描只预先加载前 N 张（比如 200 张，约 15s），
  其余缩略图等用户滑到再按需取。扫描会“立刻结束”，但快速滑动时会先看到占位符——
  与之前修过的“很多缩略图无法显示”是同一类体验风险。

### USB 传输上限

单次 `bulkTransfer` 的总数据（含 pipe、endpoint、buffer、timeout）必须小于 200KB，官方 `usbManager` 参考明确写了，超出返回 -1。缓冲区取 192KB（196608 字节）留余量。

`usbSubmitTransfer` 的 `length` 官方只约束为 [0, INT_MAX]；它走 ashmem，开源实现还会拒绝 >= 512MB 的 ashmem 大小。实测 1MB / 8MB 均可完整传完，改动缓冲区仍必须真机验证。

### 目录遍历

递归进入所有目录（format `0x3001`），把所有非目录 handle 当作照片。相机支持格式筛选时，每层目录只需 2 次 `GetObjectHandles`；不支持时退化为逐个 `GetObjectInfo` 判断。不使用任何启发式判断。

**旧实现的教训**：旧逻辑用 `validCount <= 2` 作为是否继续进入子目录的条件，遇到同一层有多个子目录（如 `DCIM/100NCD90` 与 `DCIM/101NCD90`）、一个目录下超过 2 个直接子项、或者同一层文件与目录混排的相机就会漏照片。现在的写法是进入全部目录，把所有非目录 handle 当作照片。

### Native 解析要点

`GetStorageIDs` / `GetObjectHandles` 的数据阶段是「`UINT32 count` + count 个 `UINT32`」。`PTPEngine::parseCountedU32Array()` 会跳过 count 并按 `min(count, (len-4)/4)` 截断；NAPI 的 `parseStorageIDs` / `parseObjectHandles` 必须走它。旧的 `parseU32Array()` 只适用于协议明确没有 count 前缀的裸数组（当前无调用点）。

### 相机身份

`GetDeviceInfo` 提供的标识，用来区分相机、隔离各自的缓存目录。优先级：`serialNumber` → USB `serial` → `manufacturer + model + deviceVersion + vid + pid` → `vid + pid`。

### Native bridge

`libentry.so` 暴露的函数，类型声明在 `entry/src/main/cpp/types/libentry/Index.d.ts`：

- 命令构造：`buildOpenSession`、`buildCloseSession`、`buildGetDeviceInfo`、`buildGetStorageIDs`、`buildGetObjectHandles`、`buildGetObjectInfo`、`buildGetThumb`、`buildGetObject`、`buildGetPartialObject`、`buildGetObjectPropList`
- 响应解析：`processResponse`、`parseDeviceInfo`、`parseStorageIDs`、`parseObjectHandles`、`parseObjectInfo`、`parseObjectPropList`

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