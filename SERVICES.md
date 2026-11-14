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
- **相机连着时退到后台也会持有同一任务**（1.64.1 二轮）：`EntryAbility.onBackground()` 调 `CameraService.onAppBackground()`，若 `connected` 且还没持有，就加一份 `sessionKeepAlive` 引用并申请长时任务；`onForeground()` 释放。这样进程不会被挂起，USB PTP / Wi-Fi TCP 会话能继续活着。官方指南建议把申请推迟到 `onBackground`，前台就不会常驻一条长时任务通知；`disconnectInternal()` 也会释放这份引用。
- 申请 / 释放与传输共用引用计数，但 `beginTransferTask()` 用 `transferTaskStarting` 防并发重复申请，并在申请完成后再查一次引用数（退后台后马上回前台时，任务可能刚申请完就已经没有引用了，需要立刻收掉）；`stopTransferTask()` 先把 `transferTaskOn` 置 false 再停，避免并发 stop 同一任务。
- **系统限制**：一个 UIAbility 同时只允许一个长时任务（API 20 及以前）。定位长时任务在跑时，传输任务会申请失败（日志 `后台传输长时任务申请失败`），此时退后台会被挂起；要并存需改用 API 21+ 的 `startBackgroundRunning(context, ContinuousTaskRequest)` 多任务接口。相机保活与定位同时需要时同样受这条限制；定位任务本身已经在保进程，所以相机连接一般不会因此丢。

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

### 相机掉线检测与心跳（1.66.0）

「连上之后相机被拔掉 / 断电 / 链路断掉，页面还停在『已连接』」是三条链路各自的
盲区，处理方式也不同：

| 链路 | 手段 | 时效 | 为什么 |
|---|---|---|---|
| USB | 订阅 `usual.event.hardware.usb.action.USB_DEVICE_DETACHED` | 立即（+400ms 枚举确认） | 拔线 / 断电时系统会发事件；PTP 的 bulk 端点要等下一次传输才报错，空闲时永远不会自己发现 |
| Wi-Fi | 应用层心跳：`GetDeviceInfo`，15 秒一拍、6 秒超时 | ≤ 21 秒 | PTP/IP 跑在 TCP 上，对端断电时没有 FIN，socket 不会报错（半开连接）。`TCPExtraOptions.keepAlive` 只能开关、不能配 keepidle，系统默认几小时才探一次 |
| 蓝牙 | GATT `BLEConnectionStateChange` + 保活连续失败兜底 | 立即 / ≤ 90 秒 | 断链事件本来就管用；保活写入（45 秒一拍）连续两次失败同样按断链处理 |

- **USB**：`UsbAttachWatcher` 订阅拔出事件后延时 400ms 调
  `CameraService.onUsbDeviceDetached()`；服务端拿会话的 `connectedDeviceName`
  和设备列表对一次（事件对任何 USB 设备都会发，鼠标、U 盘也会触发）。
  确认是我们这台 → `disconnectInternal()` 收尾（等价一次主动断开：清照片、关会话、
  撤长时任务）→ `notify('USB 相机已断开连接')` 弹一条 toast。扫描中不弹这条，
  让扫描自己的失败路径说话（「USB 通信失败…」更准确）。
- **Wi-Fi 心跳**（`startWatchdog()` / `watchdogTick()` / `pingWireless()`）：
  常驻一个 15 秒定时器，每拍自己判断「该不该探」——比在每条连接 / 断开 / 切模式
  路径上成对 start/stop 更难漏。跳过条件：应用在后台、没连上、无线扫描/连接/
  重连/配对中（这些本身就在跑流量，失败会自己报上来）。
  一次心跳超时 → `onWifiBroken('心跳超时')` → 关掉旧 socket、按退避自动重连；
  重连退避用尽 → `failWireless(...)`（状态头显示「没能连上相机 + 原因 + 重试」）
  + toast「无线连接已断开」。
- **蓝牙**：`BleCameraLink.handleKeepaliveFailure()`，保活连续失败 2 次（约 90 秒）
  才判死；一次不判——相机忙时偶尔会拒收一笔。判定后 `disconnectInner()` +
  `scheduleReconnect()`，页面走既有的「正在重新连接相机…」。
- **提示通道**：`CameraService.notify(text)` 只递增 `noticeVersion` 并弹 toast，
  **不写 `lastScanError`**——那不是「连不上」，不该把页面切成失败态。
  `MainScreen.@Monitor('svc.noticeVersion')` 负责弹。

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

`model/SettingsStore.ets` 存放持久化设置（深色模式、画廊列数、显示模式）；`model/UiStateStore.ets` 存放上次标签页、画廊筛选和握持手；`model/StandeePreferenceStore.ets` 单独存「默认相机立牌」的 `defaultKey`（PersistenceV2 key `standee_preference`），空串表示不显示。相机页在真实型号为空时回退到它，真实型号优先；设置页提供「不显示」+ 10 个立牌型号的 `Select`。

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
- `CameraService.scanWifiCameras(8000)` 浏览 8 秒，结果进 `wifiCameras`；相机页 STA 的「搜索相机」走 `autoLinkWifi()`，命中第一台就直接连，不要求用户手填 IP。
- 解析失败（2204006 超时）属正常，下轮广播会再报；`serviceLost` 会从列表移除。

**/24 网段扫描兜底（1.33.0）**

mDNS 被客户端隔离/访客网络挡掉时一个广播都收不到，所以 STA 的自动发现会**同时**跑一遍 `services/SubnetScanner.ets`：

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

**段 1 之后的断链必须用 `disconnectInner()`，不能用 `disconnect()`**（2026-11-14
真机定位）：`disconnect()` 是「取消连接」按钮的入口，它会置上用户取消标记
（`cancelled`），而首配正好要主动断一次链让相机暴露经典蓝牙。用了它，断链 3 秒后
流程自己就判定「用户已取消（经典绑定未做）」直接退出——首配永远走不到经典绑定。
现象是日志里 `配对: 段 1 完成，断开 BLE…` → `BLE 连接状态: 3` → `配对: 用户已取消
（经典绑定未做）` 三行连着出现，页面上只看到「配对失败」。`4b5bd97` 引入取消标记时
踩进这个坑，从 2026-11-11 18:02 起首配一直是坏的；`reconnectForResume()` 与保活
兜底用的也是 `disconnectInner()`，同一个道理。

第 2 步的让位窗不能省：ZPill 记录过「零缓冲直发配对把相机射频楔死，杀应用才解」。

*身份持久化与复用（必须做，否则只能配一次）*

相机**只认 stage1 里那份 device/nonce**。之后每次连接再发全新 stage1，相机会直接
回 `write 2900099: Remote device has an error` 秒拒。

`services/BleIdentityStore.ets`（`PersistenceV2.globalConnect`）落盘
`deviceId / cameraName / identityDevice / identityNonce / serial`。`pair()` 的分支：

- `store.hasIdentity()` 为真 → 直接复用握手，不碰相机配对页
- 否则走两段式首配

段 2 复用握手失败时**不落盘**身份，避免下次拿一份相机不认的身份去复用。

*多相机（1.64.0）*：`services/SavedCameraStore.ets` 用新的
`PersistenceV2` key `saved_cameras` 保存多台已配对相机（型号、展示序列号、
`identityDevice` / `identityNonce`、BLE 地址与上次连接时间）。`BleIdentityStore`
仍是底层唯一的「活动身份」：切换相机时把对应记录载入它，`pair()` 的分支逻辑
完全不变。首次启动从旧 `ble_identity` 迁移一条；冷启动把 current 归位到
`lastConnectedKey`。连新相机只清活动身份和 Wi-Fi 快速地址，不清相机列表。

展示序列号和身份序列号**不是同一个数**：`SavedCamera.serial` 是标题栏/菜单用的
展示序列号（BLE 名尾段），`SavedCamera.identitySerial` 是 `BleIdentityStore.serial`
那份 stage4 身份序列号；`activate()` 时不要把展示序列号写进活动身份。

*模拟相机的记录与删除（1.65.0）*

- `SavedCamera.isMock?: boolean` 标出调试包的虚拟相机。它走 USB/PTP，**没有蓝牙配对
  那一步**，`rememberActive()` 永远不会被它触发；不补一条记录的话，冷启动后标题、
  立牌、当前相机都退回「相机」，每轮测试都要重新搜一次。
- `SavedCameraStore.rememberMock(modelKey, serial, name)` 建/更新这条记录，key 是
  **`mock:<modelKey>`**（1.66.1 之前用序列号，见下文「模拟记录不能占真机的身份」），
  由 `CameraService.rememberMockCamera()` 在 USB 会话建立（`ensureUsbSession` 末尾）
  与机型/序列号识别时调用；`sessionIsMock` 为假时直接返回。同一个「key|机型|广播名」
  只记一行日志，连接过程中机型分几步到位不会刷屏。
- `activate()` 遇到 `isMock` **不写 `BleIdentityStore`，反而把它清掉**：留着上一台真机
  的身份，相机页会把这台模拟机显示成「已配对」的蓝牙相机。
- `updateCurrentMeta()` 重建记录时必须带上传入记录的 `isMock`，否则一次机型/序列号
  更新就会把标记丢掉。
- `remove(key)` 删除一条记录：删的是当前那台就清活动身份，并回退到
  `defaultRecord()`（真机优先，见下文）。相机侧不知道自己被忘了，重新配对即可再用。
- 界面上的「显式区分」：`CameraService.mockSession()` 供相机页在设备信息里写
  「设备来源 = 模拟相机（调试包）」，`PairedCamerasPage` 用 `isMock` 画「模拟」胶囊。

*蓝牙：相机待机、重连与「幽灵链路」（1.66.3）*

- **相机会在待机时收掉 BLE**：两份真机日志（11-11 17:36、11-14 16:19）都是「保活
  写入成功后 11 秒 / 只有连接动作时 29–56 秒」就断链，**加频保活没用**——那是相机自己
  的待机计时，不看有没有流量。所以 45 秒保活保持不变，别为了「保持在线」去调它。
- 断链后 `tryAutoReconnect()` 一直重试（不设上限：用户唤醒相机之后要靠它自动接回来）。
  节奏见下面「重连要多快」。
- **连扫描都扫不到相机**时调 `onReconnectStalled()`，
  `CameraService.bleAsleep` 置真，相机页的 `detail()` 换成「相机可能已休眠，按快门唤醒」；
  重连成功 / 主动断开 / 重新发起连接都会清掉这个标记。
- **`connectGatt()` 10 秒超时必须关掉这个 GATT 客户端**：不关的话它会在 App 已经转去
  扫描之后才连上，留下「系统连着、`this.connected === false`」的幽灵链路（11-14 16:20
  实测：16:20:02 超时 → 16:20:05 仍上报 CONNECTED → 16:20:11 上报 MTU）。现在超时分支
  `gatt.close()` 并让该客户端的后到事件直接返回。
- **连上之后清空 `bleCameras`**：那是「搜索出来的候选」，留着会在状态头下面挂一张
  相机列表；页面侧 `ModeControls()` 在 `blePaired()` 时也不再渲染它。

*重连要多快（1.66.4）*

出门拍摄就是一拍一停：相机待机二十几秒、半按快门又醒。重连这条路上原来全是「等很久」——
每轮先直连旧地址等满 10 秒、再扫 6 秒、握手 15 秒，退避还是 2/3/5/8/12/20/30 秒，最坏
四十多秒才回到「已配对」。现在按「相机随时会醒」来配：

| 环节 | 原来 | 现在 |
|---|---|---|
| 重试间隔 | 2/3/5/8/12/20/30 秒退避 | **不退避**：前台固定 1 秒，后台 15 秒 |
| 监听窗口 | 6 秒，扫满才走 | **20 秒上限、扫到第一台立刻结束**（150ms 轮询）→ 实际上一直在听 |
| 直连上次地址 | 10 秒超时 | **5 秒**，失败一次后置 `staleAddress`，后续轮次跳过它（地址每轮都换） |
| 复用握手 | 15 秒 | **6 秒**（相机醒着是毫秒级） |
| 服务表枚举 | 每笔 `getServices()` 可能挂 10 秒，`ensureServices` 试 5 次 | 单次 **4 秒超时**；重连期间只试 **1 次 / 2.5 秒**——叫醒相机靠 stage1 重发，不是服务表 |
| 回前台 | 等上一轮排的 30 秒 | **500ms 内补一轮** |

**为什么不退避**：退避是给「对端可能永远不回来」的轮询用的。这里的对端是用户手上的
相机，半按快门就回来，退避只会把「几秒能接上」拖成几十秒。代价用**扫描档位**控制，
不走等待——官方《蓝牙重连最佳实践》的「两阶段」正是这个思路：

| 场景 | 扫描档位 | 依据 |
|---|---|---|
| 手动搜索、冷启动接回、刚断链的前 2 分钟 | `SCAN_MODE_LOW_LATENCY` | 「阶段一：低延迟快速发现」 |
| 断链超过 2 分钟仍不在（相机大概关机了） | `SCAN_MODE_LOW_POWER` | 「阶段二：省电监控」 |
| 退到后台 | 一律 `SCAN_MODE_LOW_POWER` | 「长时间后台扫描用 LOW_LATENCY 会导致功耗和发热严重」 |
| 按尼康 deviceId 重连时的广播过滤 | 芯片层 `manufactureId = 0x0399` | 「系统层过滤优先…大幅降低功耗和回调频率」 |

结果：相机唤醒后**典型 2–4 秒**回到「已配对」，最坏（刚好处在 1 秒间隔的那一下）约 8 秒。

**2026-11-14 真机定位到的三个「重连根本不发生」**（都在这一版修掉）：

1. **循环第一轮之后就死了**：`tryAutoReconnect()` 的 `catch` 里调 `scheduleReconnect()`，
   而那时 `reconnecting` 还是 `true`，`scheduleReconnect()` 的守卫直接 return；`finally`
   再把标记放下，从此再没人排下一轮。日志特征：`BLE 自动重连失败` 之后再无声息。
   现在把重排放在 `finally` **之后**。
2. **启动时连不上就没人管**：`enableAutoReconnect()` 只在配对成功后调用，冷启动那次
   连不上就停在「已配对 + 连接相机」，相机醒了也不会自动连。现在失败路径调
   `keepWaitingForCamera()` → `wakeReconnectWatch()`（已配对才开；首配失败不开）。
3. **两处扫描互相掐**：`ble.stopBLEScan()` 是全局的。`autoConnectBle()` 的「按设备号重扫」
   和重连监听同时开着时，一个先停就把另一个的射频也停了，对方还以为自己在扫（白扫一整窗）。
   现在 `connectBle(..., armWatch=false)`：先把这一轮扫完，最后才开监听。
4. 连接超时从 5 秒改回 **12 秒**：相机半睡时实测建链要 **8 秒**（16:51:33→41、16:57:25→33），
   5 秒等于每次都在成功前一秒放弃。超时分支还会先 `gatt.disconnect()` 再 `close()`，
   让相机早点放掉它唯一的连接槽。

**闪退（freeze）一次，也是它**：17:41:06 连上相机后，`getServices()` 卡了 10 秒，
JS 主线程被一起拖住，系统判 `THREAD_BLOCK_3S/6S` 把进程杀了（hilog 里紧跟着
`bt_fwk_gatt_client (GetServices:550)timeout`）。根因是**超时之后又发了第二笔**：
`listServices()` 原来 3 次重试、我们自己的 4 秒超时只是不再等，但第一笔 native 调用
还挂在蓝牙栈里，第二笔排它后面，这一等就卡在主线程上。现在：

- `servicesOrTimeout()` 返回 `{ services, timedOut }`，**超时就 break，绝不再发第二笔**；
- `listServices()` 只查一次，而且**从 `connectBle()` 里删掉了**——它纯粹给日志用，
  没有任何界面读 `bleServices`（1.66.7）。握手需要的服务表由 `ensureServices()` 自己查；
- `ensureServices()` 在重连/复用握手时只试一次、2.5 秒，超时同样收手。

*后台时连接与重连还能不能跑（2026-11-14 实测）*

- **BLE 重连在后台继续跑**，但系统会节流定时器、并把扫描降档。真机日志（17:54:20
  退后台之后）：设计 20 秒的扫描窗口实际跑了 35–59 秒、15 秒的间隔跑了 27 秒，
  扫描档位自动降到 `SCAN_MODE_LOW_POWER`。结果就是「后台也能自己连回来，只是从
  几秒变成几十秒」。
- **长时任务按原因分两种模式（1.66.11）**：通知栏那句「正在运行 XXX 任务」是系统按
  `BackgroundMode` 生成的、应用改不了。传照片用 `DATA_TRANSFER`（「数据传输任务」），
  只是蓝牙长连/等重连用 `BLUETOOTH_INTERACTION`（真机实测通知变成「正在运行蓝牙相关
  任务」）。两者切换时先停再起（同一 UIAbility 只能有一个任务），`module.json5` 的
  `backgroundModes` 必须同时声明 `dataTransfer` 和 `bluetoothInteraction`。
  决策只在 `CameraService.applyBackgroundTask()` 一处，`beginTransferTask()` /
  `endTransferTask()` 退化成引用计数。
- **后台保活（1.66.10，用户选的方案 2）**：`CameraService.syncBackgroundTask()` 把
  「PTP 会话 / 蓝牙已连 / 正在重连 / 等待循环还开着（`watchArmed()`）」都算作需要保活，
  退后台时申请 `dataTransfer` 长时任务，BLE 状态一变再同步一次；回前台或用户主动断开
  时释放。**代价是后台期间通知栏常驻一条系统长时任务通知，文案应用改不了**；相机一直
  关着时这条会一直挂着（低功耗扫描 + 15 秒间隔）。
  - 判断条件必须带上 `watchArmed()`：只看 `bleReconnecting` 的话，断链那一瞬间它还没
    置上，会让任务「释放 → 立刻重申请」（真机日志 18:04:56 那种抖动）。
  - 真机实测（18:07:27 退后台 → 18:07:37 相机睡 → 18:07:52 重连 → 18:08:36 连上），
    全程在后台完成。
  - 传照片（`dataTransfer`）与蓝牙待机共用 CameraService 的同一个引用计数；GPS 轨迹是
    另一处 `startBackgroundRunning(LOCATION)`，两者并存的系统行为尚未专门验证。
- **无线心跳后台是关的**（`setAppForeground(false)` → `stopWatchdog()`）：没有界面要
  更新，也没必要陪相机跑流量。断链由回前台的第一拍（6 秒超时）发现，而不是后台。
  真要让后台也探测，就得持续发 PTP/IP 心跳 + 可能持有任务，收益不大。
- 后台扫描**不要**提档到 `LOW_LATENCY`：官方《蓝牙重连最佳实践》明确「长时间后台
  扫描用 LOW_LATENCY 会导致功耗和发热严重」。

**长时任务类型是固定枚举：没有「Wi-Fi 连接」这一种（1.66.17）**

用户问「两个 Wi-Fi 模式退后台还能不能保持连接」，查文档 + 枚举后的结论：

- `BackgroundMode` 只有 `DATA_TRANSFER` / `AUDIO_PLAYBACK` / `AUDIO_RECORDING` /
  `LOCATION` / `BLUETOOTH_INTERACTION` / `MULTI_DEVICE_CONNECTION` / `VOIP` /
  `TASK_KEEPING`（加 22/26 新增的 `AV_PLAYBACK_AND_RECORD`、`SPECIAL_SCENARIO_PROCESSING`、
  `NEARLINK`）。**没有 Wi-Fi 连接**。`MULTI_DEVICE_CONNECTION` 的官方场景是「分布式业务
  连接、投播」，相机不是分布式设备；`NEARLINK` 是星闪。能用语义装下相机会话的只有
  `DATA_TRANSFER`，而它要求「真的有数据传输 + 进度更新（首次超过 10 分钟未更新会被取消）」，
  空闲长连不满足。
- 官方的运行限制写得很直白：**申请长时任务后应用未执行相应业务，退至后台会被挂起**；
  API 20 起还有 `SYSTEM_SUSPEND_BLUETOOTH_NOT_USED`、API 26 有
  `SYSTEM_CANCEL_NOT_USE_BLUETOOTH` 这种原因码。所以「借蓝牙类型保 Wi-Fi 会话」不是
  能不能跑通的问题，是会被一致性校验判掉的。
- 官方《应用网络重连》另有一条：应用切到后台 2 秒后网络资源冻结、**12 秒后释放**，
  冻结时会清空 TCP 连接对象的本地 IP 与端口，回前台重新分配 → 对端看到的连接不可信。
  它给的对策就是「前后台切换时关掉再重连」。

因此 1.66.17 起的行为（方案 A，用户选定）：

- `syncBackgroundTask()` **不再把「只有 Wi-Fi PTP 会话」当作保活理由**（`wifiSessionOnly`），
  USB 会话与蓝牙待机不变；传照片仍走 `DATA_TRANSFER` 引用计数。
- `onAppBackground()` 记下 `backgroundedAt`；`onAppForeground()` 若离开超过
  `WIRELESS_BG_GRACE_MS`（12 秒）就调 `resumeWirelessAfterBackground()`：先
  `autoLinkWifi('foreground', false)` 只用记住的地址快连（1–2 秒），失败再
  `connectWirelessNow()` 走完整唤醒（0x2005 + 入热点/发现）。传输或扫描进行中不动会话。
- 12 秒以内回前台（切出去看一眼微信）会话还是活的，不重建。

**两条路不能同时建链路（1.66.8）**：`autoConnectBle()` 的主动连接和「等相机回来」的
自动重连会同一秒各建一条 GATT 链路（日志：17:47 两条 `BLE 直连`、两次 `连接状态: 2`、
两次 `已连接`），第二个 `setCharacteristicChangeIndication` 被拒
（`Please call the interface only after the previous callback has been completed`），
其中一条握手白跑。现在 `connectBle()` 一进来先 `pauseReconnectWatch()`，
`tryAutoReconnect()` 也认 `explicitBusy` 标记；失败后统一由 `keepWaitingForCamera()`
重新开循环。
`onReconnectStalled()` 仍负责「相机根本没广播」的判断——那时页面写「相机可能已休眠」。

*模拟记录不能占真机的身份（1.66.1）*

1.66.0 真机上出过一次「已配对变未连接、重连只能首配、首配被秒拒」。链条：

1. `rememberMockCamera()` 用 `CameraModelStore.serial` 当 key，而那个值常常是上一台
   真机留下的（`bleCameraName` 断开时不清，`onCameraSerialChanged` 又优先取它尾段）；
2. 于是模拟相机的记录 key 就是真机的序列号 `8079350`，`indexOf()` 按序列号匹配，
   把真机那条记录**整个覆盖**成 `isMock: true`；
3. 下次冷启动 `bootstrap()` → `activate()` 看到 `isMock` → 清空 `BleIdentityStore`；
4. 蓝牙页从「已配对」退回「未连接」，用户只能重新搜索、走首配，而相机端还记着
   这台手机，首配会被 `Remote device has an error` 秒拒——身份回不来了。

现在四条一起兜：

- **key 带前缀**：`rememberMock()` 的 key 是 `mock:<modelKey>`，且只在 `isMock` 记录里
  找同一条，不可能再按序列号撞上真机。
- **序列号只认自己的**：`rememberMockCamera()` 用 `deviceSerialNumber`（模拟相机上报
  `MOCK-0001`）；`onCameraSerialChanged()` 在 `sessionIsMock` 时**不看** `bleCameraName`。
- **模拟会话不写当前记录**：`updateCurrentMeta()` 在 `sessionIsMock` 时整段跳过——它写的
  是「当前选中的那条记录」，模拟会话写进去就会把机型/序列号灌进上一台真机记录。
  `updateCurrentMeta()` 自己也要带上传入记录的 `isMock`（以前整个漏掉；真机记录上
  不要写 `isMock: undefined`）。
- **冷启动真机优先**：`bootstrap()` 先 `normalizeMockRecords()`（纯数字序列号的模拟记录
  直接丢、其余改 `mock:` 前缀并去重），再按 `defaultRecord()` 选默认相机——有真机就
  是真机，模拟记录只有在调试开关打开、且一台真机都没有时才当默认。

- **身份只是没装回活动位**：`CameraService.adoptSavedBleIdentity()` 在自动连接 / 按模式
  搜索 / 无线搜索之前调用，缺身份就从 `SavedCameraStore.pickReal()`（当前记录是真机就用
  它，当前是模拟记录就退回最近连接过的那台真机）`activate()` 回来。`currentKey` 为空
  （用户点了「连接新相机」）时返回 null，不装回。
- **扫到就直连**：`connectIfPaired()` 在蓝牙模式下把扫描命中的已保存相机按身份直接连上
  （`handOver=false`），不再让用户从列表里点、更不走首配。
- **标题栏不挂「已不存在的相机」**：`CameraModelStore` 只是展示缓存，身份在
  `saved_cameras`。`initCameraModel()` 发现 `current()` 为空就把 `CameraModelStore`
  一起清掉（标题退回「相机」），`remove()` 删到一台不剩时同样清；否则相机页会一边
  写「未连接 + 搜索相机」，一边把上次那台的型号与序列号挂在标题栏。

*容易踩的四个坑*

- **回链后必须先拉服务表**：`bond` 之后 GATT 服务缓存是空的，不先 `getServices()`
  就订阅特征会报 `401 Invalid parameter`（本项目段 2 第一次就这么断的）。
  `handshake()` 开头的 `ensureServices()` 负责这件事。
- **订阅特征会在主线程里同步做服务发现**（1.66.12）：`setCharacteristicChangeIndication()`
  的 napi 实现是 `setCharacteristicChangeInner → GetGattcCharacteristic →
  GattClient::GetService → GetServices()`，最后一步**在自己的线程上等**
  （`pthread_cond_timedwait`）。服务表不在缓存里时，这一段就是主线程被占住
  6 秒以上——2026-11-14 18:29:05 的 `THREAD_BLOCK_6S` 闪退正是它，栈顶三帧
  依次是 `__timedwait_cp → condition_variable::__do_timed_wait → GetServices()`，
  再往下才是 `BleScanner.ets` 的 `enableIndication`。所以：
  - `ensureServices()` 现在返回布尔值；拿不到服务表时 `handshake()` **直接放弃
    这一轮**，绝不再进订阅；
  - `enableIndication()` / `enableNotification()` 自己再挡一道：`servicesReady`
    为假就抛错（错误文案「服务表未就绪，跳过订阅」）；
  - `getServices()` 超时只是我们不等了，那一笔仍在蓝牙栈里跑（实测约 10 秒
    才报错）。`discoveryInFlight` 记住它，`waitDiscovery()` 等它落地后再补探
    一次；在它回来之前既不订阅也不发第二笔发现（第二笔会排在它后面，一样卡
    主线程——1.66.7 那次的成因）。
  - 教训通用化：**任何会「按 UUID 找特征」的 napi 调用都可能触发这次同步发现**，
    不只是 `getServices()`。判断标准是「服务表到底建好了没有」，不是「哪个接口」。
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

- **`0x2008` 是 notify，不是 indicate（1.66.18，2026-11-14 复核语义）**：两处社区
  实现（nsg Android、kotlin-poc）都对 NOT1 调 `setNotify`，只有 `0x2000` 用 indicate。
  我们之前订阅成 indicate，CCCD 位写错，相机从来不发通知——9 千行 AppLog 里
  `BLE 通知 00002008` 出现次数为 0，LSS 控制点这条通道等于不存在。语义按 ZPill 从
  SnapBridge smali 推出来的口径：2B 小端位域 `(Connection<<8)|(Location<<4)|Time`，
  `01 00` 是「要时间」而不是配对成功；ZPill 会写回清位值，nsg / kotlin-poc 不写。
  我们的相机一次都没发过这条通知，没有可应答的内容，所以保持「只记日志、不回写」。
  **自动传图与这条特征无关**（见下一节）。

**2MP 自动传图走的是蓝牙经典（BTC/SPP）+ PTP，不是 BLE（2026-11-14 查证）**

社区对官方 SnapBridge v2.13.3 的静态逆向（[MXWF0/SnapBridge-Enhanced] 的
`analysis.md`；仓库本体是同版本 apktool 工程 + 修改版 APK，不是协议库）给出的链路：

- 相机广播（AdvertiseCameraInfo）到达后，**蓝牙可用且满足条件就走 Bluetooth
  Classic + SPP → Nikon PTP**；否则才退回 BLE 控制通道。
- 自动传图：`GetAutoTransferListAction` 取对象句柄 → 按原图 / 8MP / 2MP 选
  `GetObject` / `GetPartialObject` / `GetLss` → 流式写入本地。
- BLE 只负责 LSS 认证、连接配置、控制点（`0x2008`）与状态。

三个推论：①「BLE 传 2MP」是误称，真正承载是经典蓝牙 SPP；②这解释了为什么
furble / nsg / kotlin-poc / ZPill / N-Link 都没做传图——它们根本没碰这条链路，
只逆到 BLE 的配对、校时、凭据与 GPS；③社区目前**没有**可用的独立实现或字节级
协议文档，只有官方 APK 的静态分析与打补丁工程。要做这条路，得自己在真机上探
SPP 服务 UUID 与 PTP 封装（鸿蒙有 `@ohos.bluetooth.socket`，首配也已经做过经典
蓝牙绑定），属于新的研究项，不能和「读图」混在一起估工期。

*SPP + PTP 可行性探针（1.68.1，仅调试包）*

`entry/src/main/ets/debug/BtSppProbe.ets`，由 `EntryAbility.onNewWant` 的
`--ps spp` 触发（`MockPtpDevice.isDebugBuild()` 为真才执行）：

```bash
hdc shell aa start -a EntryAbility -b <bundle> --ps spp usb        # PTP/USB 容器 + 标准 SPP
hdc shell aa start -a EntryAbility -b <bundle> --ps spp ip         # PTP/IP OperationRequest
hdc shell aa start -a EntryAbility -b <bundle> --ps spp usb-de00   # 换尼康 128 位 UUID 再试
```

`frame` = `usb`（默认，先 `buildOpenSession(1)` 再 `buildGetDeviceInfo()`）/
`ip` / `usb-noopen`；`uuidKey` = `1101`（标准 SPP，默认）/ `de00` / `de01`。
流程：从系统已配对列表按名字/序列号找相机的**经典地址**（经典地址没有落盘）→
`sppConnect`（RFCOMM、secure）→ 按 **492 字节**（`0x2004` 尾部的
`sppMaxDataLength`）切片写 PTP → 读 5–6 秒，原始 hex 落 AppLog（前缀 `[SPP]`）。

判读：

- 收到 `← nB xx xx …` → SPP 通道成立、封装有回应；按 hex 的长度/魔数继续解；
- 连不上 → 看日志里的 `code`：`2900099` 多为 UUID 不在 SDP 里或相机没进经典模式，
  `2900003` 是蓝牙总开关关着，超时多半是相机在休眠；
- 相机在 Wi-Fi 模式时 BLE 不在，经典 SPP 是否可用**未知**——探针建议在相机醒着的
  蓝牙待机态下跑（App 里连着或刚断开都行，日志会打印当前 BLE 状态）。

探针不写持久化、不改连接状态，跑完关 socket；release 包没有入口。

**2026-11-14 真机结果（Z50II）**

- 经典地址找到了：`E4:D0:64:4C:28:33`（名字 `Z50_2_8079350`），说明手机与相机
  的经典绑定还在；
- `sppConnect`（标准 SPP `1101`、尼康 `de00`）都失败：`2900099 Operation failed`。
  BLE 连着与断开各试一次，结果一样；
- 反向 `sppListen`（`1101`）能起来（server=0/1），但 30 秒内没有客户端连进来；
  先写 `0x2005=0x02`（BTC 位）再 listen 也没有客户端进来。

对照 COOLPIX A1000 的实测记录（lilting.ch，2026-04）：A1000 的 SDP 里确实有
`SPP Service / channel 1 / 0x1101`，macOS 上会出现 `/dev/tty.A1000_...`；
**但经 RFCOMM 发 PTP 相机不响应**，那篇的结论也是「卡在这里」。同一篇还记录：
经典绑定完成后相机会主动发起 RFCOMM，主机没有 SPP 服务端时相机会一直等
（甚至冻结）——所以相机可能是 RFCOMM 客户端，SnapBridge 在手机侧跑服务端。

Z50II 上目前既连不进去、也等不到它连出来；下一步要么找 SnapBridge 里实际用的
UUID / 触发时序，要么抓一次官方 App 与相机之间的 HCI 日志。

[MXWF0/SnapBridge-Enhanced]: https://github.com/MXWF0/SnapBridge-Enhanced
- 权限：`ohos.permission.ACCESS_BLUETOOTH`（user_grant），`CameraService.ensureBlePermission()` 在首次搜索时申请。
- **冷启动那一次连接不算用户操作**（1.66.13）：`autoConnectBle(silent, quiet)` 的第二个
  参数只给 `MainScreen.aboutToAppear` 用。`quiet` 时失败走 `resetColdStartTraces()`：
  关掉可能建了一半的 GATT，清 `bleHint / bleSerial / bleCameras / bleAsleep /
  bleReconnecting / lastScanError / wirelessFailed / wifiHint / wirelessStage /
  wifiAutoConnecting / wifiReconnecting`，再 `syncBackgroundTask()`。**不要**在这条路上
  调 `keepWaitingForCamera()`：那会让页面挂上「正在重新连接相机…」，而这次连接根本没
  人点过。无线那半条（`autoLinkWifi`）仍捎带试一次，成功就保留连接、失败才清痕迹。
- **取消连接要有立刻的反馈**（1.66.12）：连接/首配串了好几段 `await`，链路自己
  超时要 10 秒以上。`cancelBleConnect()` 先把 `bleConnecting` 放掉（界面马上回到
  「已配对 · 未连接」），再去关 GATT；`bleConnectSeq` 自增让在途那一轮在下一个
  `await` 回来后看到序号对不上、安静退出，**不报「蓝牙连接失败」**（明明是用户
  自己取消的）。在途流程的 `finally` 也按序号判断，不抹掉新一轮的 `bleConnecting`。
- 相机 2 分钟没有 BLE 流量会断链，45 秒一拍留足余量。
- 配对完成后**先等 2.5 秒**再写 `0x2006`（ZPill 的 writeGate）：相机刚收口时注入
  会话还没醒，立刻写会被拒甚至被踢链。

**校时与位置注入：真正的毛病是没人供位置（1.66.17）**

用户反馈「蓝牙模式下 GPS 注入和校时都没跑通、相机侧没效果」。查下来不是协议写错，
而是**位置一次都没发出去过**：

- `startBleKeepalive()` 的 `fixProvider` 直接读 `GpsRecorder.lastFix`，而「持续定位记录」
  默认是关的 → `lastFix` 恒为 null → `0x2007` 从未写入。真机 AppLog（2026-11-14，9 千行）
  里**没有任何一条定位启动记录**，只有一串「BLE 校时已写入」。
- `satellites` 还写死成 0：相机那边的卫星颗数（也算定位质量）永远是 0。

现在的结构：

| 件 | 职责 |
|---|---|
| `services/BleGeoFeed.ets` | 注入专用的轻量定位源。定位记录开着就借它的 `lastFix`（同一个点，照片匹配轨迹和相机注入口径一致）；没开就自己订阅 `locationChange`（31 秒一拍，`TRANSPORT`），只留最后一个点，**不落轨迹**；顺带订阅 `satelliteStatusChange` 拿真实卫星数 |
| `BleScanner.startKeepalive(BleKeepaliveConfig)` | 一拍里先写 `0x2006`（`writeTime` 开关控制），再写 `0x2007`；丢星时按「只发一条 valid=0」的规矩通知相机 |
| `CameraService.startBleKeepalive()` | 读设置（`SettingsStore.bleClockSync` / `bleLocationInject`，默认都开）→ 起 `BleGeoFeed` → 起保活；4 秒后**读回 `0x2006`** 校验相机到底收没收到（日志 `对时校验：相机时钟 …（与本机一致）`） |

协议细节（社区逆向 + nsg/ZPill 双源对拍，1.66.17 复核）：

- `0x2006` 写 10 字节：年（u16 LE）、月、日、时、分、秒、**均为 UTC**、夏令时标志、
  时区小时、时区分钟。相机自己只回 **7 字节**（不带时区），所以读回值按 7 字节解。
- 诊断三读（`probeCameraLss()`）：0x200b 序列号证明「读通道本身通」，0x2006 是相机
  时钟，写完一帧位置后 1.5 秒回读 0x2007。全 0 = 相机没存下来；与写出去的一致 =
  相机存住了但页面/EXIF 没体现，问题就不在我们的写入。首帧 TIME/GEO 的十六进制也
  会进日志（`0x2006 首帧` / `0x2007 首帧`），方便和参考实现对拍。
- `0x2007` 写 41 字节，`0x007F` 头 + 纬度（方向/度/分/百分位/余数）+ 经度 + 卫星数 +
  海拔（`P`/`M` + u16）+ UTC 时间（年..秒/厘秒）+ **valid 字节** + `WGS-84` + 10 字节 0。
- **丢星只能发一条 valid=0**：连发会被相机拒收；收到 valid=0 后相机会丢掉保存的位置，
  之后拍的照片不再带 GPS。`BleScanner` 用 `geoValidSent` 只做「有效 → 无效」那一次。
- **写位置之前必须先有对时**：相机时间差太大时会拒收 GEO（表现为写入失败）。

**真机验证通过（2026-11-14 21:00，Z50II）**：相机菜单「连接至智能设备 → 位置数据
（智能设备）」显示出纬度、经度与 UTC 时间，用户确认「GPS 和时间数据都推到相机上了」。
一路上修掉的三个真原因，按发现顺序：

1. **位置根本没发**：`fixProvider` 读 `GpsRecorder.lastFix`，而定位记录默认关 → `0x2007`
   从未写入（1.66.17）；
2. **0x2008 用错 CCCD 位**：订阅成 indicate，相机从不发通知（1.66.18 改 notify）；
3. **注入被链路抖动拖死**：它挂在「BLE 断开」上一起退订，而相机半睡时链路十几秒断一次，
   连续定位永远等不到第一拍（1.66.18 起只在用户主动断开/交接 Wi-Fi 时停，并补一次
   `getCurrentLocation()` 让首帧立刻有数据）。

已知限制（不是 bug，别再花时间）：

- **海拔多半是 0**：`Location.altitude` 是必填 `number`，但**系统只在拿到高程时才填**，
  否则就是 0——官方 API 参考只写「表示位置的海拔高度，单位为米」，《获取设备的位置信息
  开发指导》全文没提海拔，也没有 Android `hasAltitude()` 那种判断位，所以「0 = 没有」
  只能靠经验判断。证据取自本机 `gps_records.jsonl`（同一份 `Location` 回调落盘）：53 条
  里 50 条是 0，只有 2026-11-07 02:47–02:48 的 3 条有真实值（89.2 / 86.3 / 86.4 m），
  而它们与其余记录**是同一个坐标**——同一个地点、有时给有时不给，说明是「这次定位结果
  没有高程」，不是我们取错字段。注入走的是快速单次定位，命中网络定位时海拔就是 0。
  **2026-11-14 用户决定：按现状写 0（方案 A），不做「复用旧海拔」或
  `PRIORITY_ACCURACY` 改造**——相机菜单里海拔显示 0 是可接受的，别再当 bug 修。
- **注入启动后的第一帧卫星数可能是 0**（单次定位抢在卫星状态回报之前），下一拍起是真实值。
- **`0x2006` / `0x2007` 相机只写不读**：读会返回 `2901000 Gatt read forbiden`，所以 App
  侧没法自校验「相机收没收到」，只能看相机菜单；`0x200b` 可以读，用来证明读通道本身是通的。
- 相机半睡时 BLE 链路十几秒断一次是相机自己的待机行为（见上文），注入会跟着重连接续上。

后台定位：把长时任务从「蓝牙」换成「定位」（1.66.17）

`on('locationChange')` 想在后台继续上报，系统要求持有 **LOCATION 类型长时任务**；
而同一个 UIAbility 一次只能有一个长时任务（API 20 及以前）。BLE 写入本身不看任务
类型，**任何一条长时任务都能把进程留住**，所以只要位置注入在跑，就优先申请 LOCATION：

| 场景 | 任务类型（`applyBackgroundTask()` 的决策） |
|---|---|
| 正在传照片 | `DATA_TRANSFER`（最高优先，通知「数据传输任务」） |
| 蓝牙待机 + `BleGeoFeed.isRunning()` | **`LOCATION`**（通知「定位任务」，后台定位可用） |
| 只做蓝牙待机（位置注入关 / 没权限） | `BLUETOOTH_INTERACTION`（通知「蓝牙相关任务」） |

- 定位源起来是异步的，`refreshBackgroundTaskMode()` 专门负责「模式变了」时重算一次
  （`syncBackgroundTask()` 在「要不要保活」没变时会直接返回，走不到这里）。
- 定位记录自己也在申请 LOCATION 任务：两条请求撞在同一个槽上时后到的那条会报错，
  但先到的任务已经把进程留住了，两边的定位订阅也都还在，所以功能不受影响。
- 要彻底摆脱「一个任务」的限制（比如同时要蓝牙、定位、传输三条通知分开）需要
  API 21+ 的 `startBackgroundRunning(context, ContinuousTaskRequest)`，这一轮没动。

**主线程禁区：会同步等系统服务的接口（1.66.16 汇总）**

HarmonyOS 有一批 napi 是**同步**的：调用发生在 JS 线程上，内部一次 binder
往返或一把蓝牙栈的锁，慢起来就是 `THREAD_BLOCK_3S/6S`。2026-11-14 一天 10 次闪退
全部出在这张清单上（8 次订阅、2 次断开）。写新代码前先对一遍：

| 接口 | 危险点 | 现在的规矩 |
|---|---|---|
| `gatt.setCharacteristicChangeIndication()` / `…Notification()` | 内部按 UUID 找特征，服务表不在缓存里时**同步**做服务发现（`GetServices` 等 6 秒） | `servicesReady` 为假直接抛错；握手在 `ensureServices()` 失败时整轮放弃 |
| `gatt.writeCharacteristicValue()` / `readCharacteristicValue()` | 同上（`GetGattcCharacteristic → GetService → GetServices`） | 同样 `servicesReady` 门禁；链路断开事件里把 `servicesReady` 清掉 |
| `gatt.disconnect()` / `gatt.close()` | 要拿蓝牙栈里这个客户端的锁，发现还挂着时主线程跟着等（实测 7 秒） | `settleDiscovery()`：在途发现先等它落地再断；`resetColdStartTraces()` 先清页面状态再收链路 |
| `gatt.getServices()` | 相机半睡时能挂十秒；**超时后不能补发第二笔** | `servicesOrTimeout()` 自己带超时，`discoveryInFlight` 记在途的一笔，`waitDiscovery()` 等它落地再补探 |
| `connection.getAllNets()` | 会往主线程投任务，系统网络服务忙时几秒 | 冷启动不调；只有真要网段扫描才取，结果缓存 2 秒 |
| `connection.getConnectionPropertiesSync()` / `wifiManager.getLinkedInfoSync()` | 同步 binder，常出现在异步续体里 | 已换 `await getConnectionProperties()` / `await getLinkedInfo()` |
| `wifiManager.isConnected()` / `getIpInfo()` / `isHotspotActive()` | 只有同步版 | 保留，但**不要在轮询里高频调**；AP 上链轮询已改 async `getLinkedInfo()` |
| `fileIo.*Sync` | 大文件（原图/RAW）复制会按住主线程 | 日志/设置这类小文件可以用；照片复制改 `await fileIo.copyFile(fd, fd)` |

判断口径：**这个接口背后有没有系统服务/binder/蓝牙栈？** 有，就先想到「它可能同步等
锁」，再决定能不能在 UI 线程上直接调。

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

所以 1.42.0 起：**默认走 AP 模式**，STA 保留为「相机已配好 STA 时的手动入口」，
进入 STA 后再点「搜索相机」才自动发现并连接，不在启动时偷偷触发。

产品含义：**BLE 是常驻待机态，Wi-Fi 是「借来传照片」的态**。这也和 SnapBridge
一致 —— 拍摄期间靠 BLE 打 GPS，只有下载时才切 Wi-Fi。相机页因此在「蓝牙已配对、
无线未连接」时给一个明确的「连接相机（切到 Wi-Fi）」按钮，而不是偷偷自动切。
1.67.0 起蓝牙模式自己也有这条入口，见下一节「蓝牙模式的按需浏览」。

**蓝牙模式的按需浏览（1.67.0）**

1.66.x 及以前，「蓝牙模式」只有待机（校时 + 位置注入），想看照片必须切到 AP / STA。
1.67.0 起蓝牙模式自己也能看图，做法是把 AP 的交接原样借过来，**不新增模式**：

- **入口**：相机页模式选择器下面一行「浏览与下载照片」（`CameraActionRow`）。
  只在「已配对」或「配对过但没连上（Idle）」时出现；`bleRecovering` 期间不出现。
  副标题当场写清代价：「临时加入相机热点，手机会暂时没有外网」。
- **进入**：`browsePhotosOverWifi()` → `connectWirelessNow()`。顺序与 AP 完全一致：
  BLE 握手（`0x2004` 凭据从这里来）→ `0x2005=0x01` → 加入相机热点 →
  `joinApAndConnect()` 连 PTP → `finishAutoLink()` 扫照片。`afterHandover()` 现在
  把 BLE 与 AP 走同一个分支（`linkMode === AP || BLE`）。
- **会话期间**：`connected && wireless` 为真、`linkMode` 仍是 BLE。相机页据此显示
  「已连上相机热点」+ 照片数，下面照常渲染设备信息与快速 / 全量扫描；
  `linked()` 把这种状态也算「已连上」，模式选择器因此照旧上锁。
- **回程是自动的**：主操作仍是「断开连接」→ `disconnect()`（**不能**走
  `disconnectBle()`，那样手机就留在没有外网的相机热点上了）→
  `exitWirelessToBle()` 离开热点 → `startBleRecoveryScan()` 每 6 秒扫一次、
  最多 3 分钟。相机实测约 40 秒回落蓝牙，连回来就 `connectBle(handOver=false)`
  恢复校时与位置注入。等待期间 `bleRecovering = true`，状态头第二行写
  「相机正在切回蓝牙，约需 40 秒」——否则页面看着像断开失败了。
- **代价必须写在脸上**：加入热点期间手机没有外网；BLE 与 Wi-Fi 互斥，所以浏览期间
  校时 / 位置注入暂停。这两句在入口副标题和「连接说明 → 连接模式」里都写了。
- **失败不新增状态**：交接失败仍走 `failWireless()`，但蓝牙模式的状态头不认这个
  字段，所以 `ModeControls` 里单独渲染一行 12fp 红字（`wirelessFailed`）。
- **浏览中途断链**：心跳超时 / 重连退避用尽时，`tryWifiReconnect()` 放弃后会主动
  `disconnect()` 收掉这次临时会话——蓝牙模式要的是「回到待机」，而不是停在一个
  连不上的 Wi-Fi 失败态。AP / STA 仍是原来的失败态 + 重试，行为不变。
- **交接冷却照旧**：刚结束一次浏览就立刻再点，会被
  「相机刚切换过无线，请稍等一会再试」挡下。那是相机侧的状态机（官方口径：
  退出 Wi-Fi 后至少等 3 分钟再切 STA），不是我们能缩短的。
- **不自动切到画廊**：分步进度、失败原因都写在相机页的状态头里，跳走就看不见；
  连上之后状态头会显示「已连上相机热点 + 照片数」，用户自己切「画廊」页签。

*1.68.0：浏览不再依赖相机回落蓝牙*

相机侧没有「立即关 Wi-Fi」的通道（Wi-Fi 期间 BLE 不广播，PTP 侧也没有对应
opcode；0x9435 是应用模式，不是无线），所以「回蓝牙」只能等相机的 Wi-Fi
待机计时（实测约 40 秒，最长 90 秒；新固件还有「始终开启 Wi-Fi」，开了就永远
不回落）。1.68.0 的思路不是催相机，而是**让浏览不依赖这次回落**：

- **热点凭据落盘**（`services/WifiApCredStore.ets`，PersistenceV2 key
  `wifi_ap_creds`）：BLE 握手解出的 `0x2004`（SSID / 密码 / 安全类型）在 AP
  连上后按**相机序列号**存一条，外加这次真的连通的 `host`。最多留 8 台，
  同序列号覆盖、更新时挪到末尾。凭据属于本机设备资料，和 `ble_identity` /
  `saved_cameras` 同级，不上传。不往 `SavedCamera` 里加字段（旧记录恢复时不会
  补新字段，1.66.1 的教训）。
- **直连路径**（`browseViaCachedAp()`）：`join()` 增加 `ApJoinOptions`
  （`timeoutMs` / `escalate`），直连只等 12 秒、**不弹系统确认框**（用户只是
  点了一下浏览，不该被系统弹窗打断），失败就安静地改走 BLE。直连前有两个
  前置判断：`bleConnected` 为真直接放弃（相机握着 BLE 时热点起不来）；
  没有缓存凭据也放弃。
- **进入顺序**（`browsePhotosOverWifi()`）：
  1. `bleRecovering`（刚结束一次浏览）→ **先直连**：相机还在 Wi-Fi 模式，
     几秒就上链，完全不用等它回落；
  2. 其余 → BLE 唤醒（`connectWirelessNow`）；
  3. BLE 没走通、且这一轮还没试过直连、且 BLE 不在线 → 再直连一次。
     这样连「相机一直停在 Wi-Fi 模式」「交接冷却中」也有路可走。
- **回程窗口缩短**（`startBleRecoveryScan()`）：总窗口 3 分钟 → 90 秒；前 30 秒
  2.5 秒一扫 + 1.5 秒间隔，之后 4 秒扫 + 6 秒间隔。90 秒还没回来就把
  `bleHint` 写成可操作的下一步（再次浏览 / 到相机菜单关 Wi-Fi），并且**浏览
  入口在等待期间仍然可用**——用户不必干等。
- **进入新会话时取消回落扫描**（`suspendBleForWifi()`）：否则上一轮留下的
  2.5 秒/6 秒扫描会在浏览期间空转、偶尔去连一次正在开热点的相机。
- **失败语义**：直连失败**不写** `wirelessFailed`（后面还可能走 BLE 唤醒，
  不能先报一句失败）；直连成功才清掉旧失败。直连失败一定 `leaveCameraHotspot()`，
  不能把手机留在没有外网的相机网络上。

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

*网络枚举的调用点与「任务名会骗人」（1.66.14 / 1.66.15）*

- **冷启动不取网络快照**：`autoLinkWifi()` 先试 `WifiLinkStore` 里记住的地址，
  只有真要网段扫描（`allowScan=true`）时才调 `collectLocalNetworks()`。冷启动那条路
  （`allowScan=false`）根本用不到快照。
- `collectLocalNetworks()` 带 **2 秒结果缓存**：进 STA 页面取一次、紧接着开始扫描
  又要一次，第二次直接复用。
- **同步的伴随接口要换成异步**：`getConnectionPropertiesSync()` / `getLinkedInfoSync()`
  都是同步 napi，绑在 JS 线程上做 binder 往返。它们常在 `getAllNets()` 的 `.then`
  里执行，而那段续体就跑在主线程的 EventHandler 任务里——慢起来整段都算在主线程
  头上。现在已改成 `await connection.getConnectionProperties(net)` /
  `await wifiManager.getLinkedInfo()`（`WifiPtpLink.resolveNetworkBinding` 也改了）。
  `wifiManager.isConnected() / getIpInfo() / isHotspotActive()` 只有同步版本，保留。

**但 2026-11-14 19:01 那次闪退的真凶不是网络接口**：faultlog 的 EventHandler 段写着
`task name = getAllNets，执行 7.5s`，很容易据此认定是它——**任务名只是投递这段 JS 续体
的那个 napi 回调名**。3 秒采样的真实栈是：

```
#00 __timedwait_cp
#01 __pthread_mutex_timedlock_inner
#03 libbtframework GattClient::Disconnect()+208
#08 BleScanner.ets:1609 disconnect
#09 CameraService.ets:2418 resetColdStartTraces
#10 CameraService.ets:2399 autoConnectBle
```

即：冷启动自动连接失败后 `resetColdStartTraces()` 去 `bleLink.disconnect()`，
而 `gatt.disconnect()` 是同步 napi，要拿蓝牙栈里这个 GATT 客户端的锁——服务发现
还在跑，主线程跟着等 7 秒。现在的规矩：

- `BleCameraLink.disconnect()` / `disconnectInner()` 开头先 `settleDiscovery()`：
  在途发现没落地就**先等它**（最多 `SERVICE_LANDING_MS`）再断。
- `resetColdStartTraces()` **先清页面状态、再收链路**：收尾可能要等几秒，不能让
  「安静回到未连接」跟着拖。
- 排查时以**采样栈**为准；EventHandler 的任务名、`getAllNets` 这种 napi 名字都会把
  人带偏。

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
`wirelessStage` / `wirelessFailed` / `bleCameras` / `wifiCameras` / 扫描统计
（`scanStatsText` / `scanPhaseText` / `scanProgress` / `scanTotal`）——这些都描述
上一模式的现场，留着会串味（切到 USB 还挂着蓝牙失败、AP 模式还显示手机当前 Wi-Fi）。
进入 STA 时顺带调 `refreshNetworkSnapshot()` 摸一遍本机网络，为之后的搜索准备好
`wifiHint`；页面不显示网络摘要，快照只写日志。`initLinkMode()` 恢复的是 STA 时
同样补一次。

*切模式 = 取消在途搜索（1.64.1）*

`setLinkMode()` 先递增 `linkEpoch`，再调 `cancelInFlightLink()`：

- `stopBleScan()`：停 BLE 广播扫描、清计时器；
- `stopWifiScan()`：停 mDNS 浏览、取消网段扫描、兑现 mDNS 窗口 promise；
- `cancelWifiReconnect()`：撤掉排队中的无线自动重连；
- 正在进行的 AP 热点交接调 `apJoiner.leave()`：取消 `join()` 轮询，手机如果已经
  上了相机热点也一并退出（否则切到 STA 后手机还挂在没有外网的热点上）；
- 正在首配的 BLE 连接调 `bleLink.disconnect()`：配对层的取消标记会在关键 await
  后让流程停住；
- 自动无线 / AP 交接 / USB 会话的 `await` 链没法从外面打断，靠代次检查收尾。

这些流程在入口记下当时的 `linkEpoch`，在每个关键 `await` 之后用
`epochCurrent(epoch)` 对一次。代次变了就**静默返回**：不写 `statusText` /
`lastScanError` / `wirelessFailed` / `wirelessStage`，不把旧模式扫到的相机或失败
结论带进新模式；已经建立的会话由 `abortWifiConnect()`（关 TCP / PTP 会话、复位
`wireless` / `connected` / `wifiSession`）或 `abortStaleUsbSession()` 关掉。

两个扫描器的回调只创建一次、跨多轮复用，所以另存字段对代次：
`bleScanEpoch` / `wifiScanEpoch` 等于当前 `linkEpoch` 时才收结果；`wifiScanGen`
再区分「第几轮」，避免切模式后旧一轮的收尾把新一轮刚置上的 `wifiScanning`
清掉。`stopBleScan()` / `stopWifiScan()` 会把对应 epoch 置 -1。

这样用户手点的搜索、以及其它在途的自动连接，都可以在切模式时立刻中断，
页面停在新模式的空闲态。

*无线进度、失败与断开状态*

- `wirelessStage` 只表示**正在走到哪一步**（唤醒 / 热点 / 相机），成功或放弃就清；
  失败结论单独放 `wirelessFailed`，保留到下一次尝试或切模式。以前只有前者，
  `apJoining = false` 后失败原因随进度一起消失，页面只剩「未连接」。
- `connectWifi()` 成功时清掉 `wirelessFailed` / `wirelessStage` / `bleHint` /
  `lastScanError`：Wi-Fi 已经接管照片通道，上一轮的蓝牙失败/等待提示都属于过去时，
  否则会出现「已连接」旁边挂着「蓝牙连接失败」。
- `wifiConnecting` 覆盖 `connectWifi()` 的整个异步过程（`wifiAutoConnecting` 只
  覆盖自动链路）。手填 IP 直接调 `connectWifi()` 时，页面靠它显示「正在连接
  Wi-Fi 相机 <地址>…」并禁用主操作；`wifiConnectSeq` 让重叠连接请求的 finally
  不互相清掉这个标记。
- `disconnect()` / `disconnectBle()` 用 `disconnecting` 标志包住整个异步过程
  （try/finally），并在结束时清掉本模式的进度、统计与错误；`MainScreen`
  切换模式时另写 `switchingTo`，页面据此显示「正在断开 / 正在切换」。
- `searchWireless()` 按模式分派：AP 没有落盘身份就先扫蓝牙；STA **直接自动发现并
  连接**（先试记住的地址，再 mDNS / 网段扫描，命中就 `connectWifi`），有身份时只多
  一步「先借蓝牙唤醒相机」。STA 不需要配对就能用，这是两种模式在入口上最直观的
  区别；自动发现失败时用 `failWireless(wifiHint || camera_status_wifi_not_found)`
  留下结论，页面显示「没能连上相机 + 原因 + 重试」。

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
`scanWifiCameras()` 先摸一遍本机网络，把一句话摘要写进日志，再把
`networkHint()` 的结论写进 `wifiHint`；两台都为空时补一句「同一网络里没有
发现相机，确认相机已进入连接至智能设备」。摘要格式是「Wi-Fi「SSID」· 地址 1 /
地址 2 · 热点 …」——SSID 放最前，地址跟在后面，多个地址用 `/` 并排，没有地址时
写「无 IP」。**这个摘要只进日志与失败提示，不在相机页常驻**：STA 的自动发现
不需要用户先读懂本机 IP，网络名在系统控制中心就能看到。

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