# TODO

2026-10-14 审视代码时发现、尚未解决的问题。修掉一项就删掉对应条目。行号对应当时的代码状态。

## 缺陷

| 位置 | 问题 | 影响 |
|---|---|---|
| `CameraService.disconnect()` `:1675` / `:1688` | 先把 `cachingEnabled` 置 false，之后的 `if (this.cachingEnabled) { this.thumbCache.flush() }` 永不执行 | 扫描途中断开连接时，正在写入的缓存条目可能没有记进 manifest，下次扫描按未命中处理，需要重新读 USB |
| `CameraService.loadSingleThumbnail()` `:1247` → `scheduleCacheSave()` `:1812` → `ThumbnailCache.saveRawThumbnail()` `:170` | 参数错位：`saveRawThumbnail` 的第 4 个形参是 `handle`，实际传进去的是原始宽度，于是缓存条目里 `handle` = 原始宽度、`origWidth` = 原始高度、`origHeight` 缺失 | 缓存清单里记录的原始尺寸是错的。改动时注意两处参数都是 `number`，编译器不会提示 |
| `CameraService.setDetailIndex()` `:1591` | 没有调用点，`detailIndex` 恒为 -1 | `evictFurthest()` 退化成“淘汰 handle 最大的一张”；`preloadAdjacent()` 从不运行，`AGENTS.md` 里描述的 radius=5 方向预加载实际未生效 |
| `MainScreen.ets:169` 起 | 点击缩略图时对全部照片逐张调用 `ComponentAttrUtils.getRectInfoById()`，该函数找不到组件就抛异常 | 屏幕外的每一张照片都会走一次异常分支，照片多时每次点按都是 O(n) 的异常分配。注释写的是“缓存当前可视区域的坐标”，与实际不符 |
| `MainScreen.ets:85` / `:88` | `syncDownloadedKeys()` 连续调用两次 | 无功能影响，清理即可 |
| `CameraService.ets:1013` | 遗留调试代码 `// TEST: only load first 300 photos` 与注释掉的 `slice` | 清理即可 |
| `PhotoViewer.ets:302` | `scanRefreshKey` 声明了 `@Param`、调用处传了值，组件内部从未读取 | 要么接上刷新逻辑，要么删掉参数 |
| `ThumbnailCache.CacheEntry` / `CameraService.loadCachedThumbnail()` | `handle`、`exifRotate`、`exifFlipH`、`exifFlipV`、`origWidth`、`origHeight` 六个字段只写不读；`loadCachedThumbnail()` 一律按“已经旋转裁剪过”解码，而 `saveRawThumbnail()` 写入的是原始 JPEG | 两次写入之间进程退出，下次启动会把未纠正的缩略图当成已纠正的版本显示（旋转照片方向错误、带黑边） |
| `PtpHost.PtpSession.close()` | 没有调用点，`connect()` 与 `disconnect()` 用的是 `closeSessionAndPipe()` | 清理即可 |
| `PhotoViewer.ZoomableImage.onEdgeChange` | 内部三处调用，父组件 `MainImageView` 从不传值 | 空转，清理即可 |

## 无用代码

以下都只有定义、没有调用，可以直接删除：

- `PhotoViewer.getDisplayPixelMap`
- `CameraService.getLogText` / `isPhotoDownloaded` / `loadThumbnail` / `cacheOrientedSize`
- `ThumbnailCache.loadThumbnail` / `getCacheSizeBytes` / `getEntryCount` / `getAllEntries` / `debugLookup` / `getCameraCacheSize`
- `AppLog.getEntries`
- `pages/SwiperSyncTestPage.ets` 整个文件，以及 `main_pages.json` 里的注册。这是生成 1000 个彩色色块的早期原型页，会随应用打包
- `entry/src/main/resources/base/element/float.json` 里模板遗留的 `page_text_font_size`

C++ 侧：`CMakeLists.txt` 只编译 `napi_init.cpp` 与 `ptp_engine.cpp`。`ptp.c`（356 KB）、`usb.c`、`ptp_client.cpp/h`、`gphoto2-port.h`、`device-flags.h`、`ptp-bugs.h`、`ptp-private.h` 都不参与构建；`ptp.h` 被 `ptp_engine.h` 引入，需要保留。可以移出源码目录或加说明，避免以后误改。

## 需要在真机上确认

- **GalleryPage 的按行刷新**：`PhotoCell` 是 `@Builder`，参数里带值类型的 `rowComplete`（`GalleryPage.ets:329` 定义，`:512` 调用）。仓库记忆里记录过“Repeat 与 `@Builder` 混用时传值类型参数不触发内部刷新”，当时的处理是把 `PhotoCell` 直接写进 `Repeat.each()` 回调；当前代码又是 `@Builder` 形式，`PhotoViewer` 里同类场景用的是独立 `@ComponentV2`。需要确认缩略图是否仍然整行同时出现。
- **主页顶部**：`MainScreen` 既没有设置 `title`，也没有 `hideTitleBar(true)`（`PhotoViewer` 隐藏了标题栏并自绘）。确认主页顶部是否存在一条空的系统标题栏。
- **GPS 匹配容错**：`GpsRecorder.findClosest()` 默认容忍 30 分钟，`parseCaptureDate()` 把相机拍摄时间当手机本地时间。相机时钟与手机不一致时匹配不到位置，需要一台时钟不同的相机验证，必要时加时钟差补偿。
- **缩略图缓存的方向纠正**：修掉上面那条 `exifRotate` 只写不读的缺陷之后，用旋转过的照片验证缓存命中时的显示方向与黑边裁剪。

## 工程质量

- **测试**：`entry/src/test`（32 行）与 `entry/src/ohosTest`（34 行）只有新建工程自带的模板用例。至少给 `CameraService` 的排序与清洗逻辑、`ThumbnailCache` 的键与过期判断、`PhotoGroupUtil` 的分组合并补上单元测试。
- **文件规模**：`CameraService.ets` 1825 行、`PhotoViewer.ets` 1409 行。`CameraService` 同时承担缩略图磁盘缓存、下载注册表、GPS 时间匹配、缓存设置与扫描统计，可以按职责分成几个类。
- **手工版本号驱动的刷新**：`GalleryPage` 用 `photosVersion`、`thumbnailVersion`、`displayMode`、`filterValue`、`galleryScale` 五个字段判断 `buildFlatItems()` 的缓存是否有效，另外 `allDisplayGroups()`、`buildFilterOptions()`、`_filteredIndexMap` 各有自己的一份。任何一处改动都要同时顾及所有递增点。
- **普通 `Map` 的状态追踪**：`thumbnailPixelMapMap`、`orientedDisplaySizes`、`compressedCache` 不是 `@Trace`，界面刷新依赖手工计数被 `build()` 读到。可以考虑换成 `@ObservedV2` 容器，减少漏改计数器导致的界面不刷新。
- **重复的等待循环**：`PtpHost` 的 `getThumb` / `getObject` / `getPartialObject` 各抄了一份 `usbBusy` 轮询（150 次 × 200ms），可以合并成一个方法。
- **日志策略**：`scanForCamera()` 开头的 `this.log.clear()` 会清掉扫描之前的记录，而扫描期间 200 条上限又会挤掉早期条目——排查 USB 问题时最想看的那部分恰好会被丢掉。`PtpHost.log()` 对每条 USB 命令输出十六进制片段。需要重新考虑保留策略。
- **静态检查的 5 条警告**：`PhotoViewer.ets:272` / `:276` 在手势回调链里打 `hilog.info`（`clampAndCheckEdge` 每次捏合与拖动更新都执行）；`GpsRecorder.ets:245` / `:263` / `:274` 在循环里新建 `Date`。
- **`README.md` 只有两行**，缺少环境变量、构建方式与设备要求。

## 界面与设计

- **颜色**：19 处颜色值直接写在组件里（`#4CAF50`、`#2196F3`、`#E84026`、`#0078D7`、`#E65100`、`rgba(...)`），深色模式下不跟随主题。应改用 `base/element/color.json` 与 `dark/element/color.json` 里的资源。
- **字号与圆角**：字号 15 种取值（8/9/11/12/13/14/15/16/17/18/20/22/36/48/72），圆角 7 种（3/4/8/12/14/16/18）。需要定一套取值表。缩略图角上的时间标签是 8fp，小于可读下限。
- **图标**：只有 `PhotoViewer.TitleBar` 用了 `SymbolGlyph`，其余是 `Text('←')`、`Text('🗑')`、`Text('📷')`。建议统一改用系统符号。
- **无障碍**：`accessibility*` 属性 0 处。圆形的返回键、删除键需要补 `accessibilityText`。
- **底部标签栏**：`Tabs(...).barHeight(0)` 加自绘的 56vp `Row`，三个纯文字项，缺少系统标签栏的图标、点击反馈、选中动效与无障碍角色。
- **页面头部**：`SettingsPage`、`CacheManagementPage`、`GpsManagementPage`、`GpsDayDetailPage` 各自手写“圆角按钮 + 标题 + 右侧文字”，`PhotoViewer` 另写一套带主副标题的头部。可以抽一个共用组件。
- **导航方式**：三个子页面仍在用已废弃的 `router.pushUrl` / `back` / `getParams`，建议迁到 `Navigation` + `route_map.json`。
- **文案与多语言**：界面文案全部写在组件内部，`string.json` 的 36 条资源没有任何引用。要支持多语言需要改成 `$r('app.string.*')`。
- **调试入口**：设置页有一个 300vp 高的日志面板（清除 / 复制）。正式发布前应移到隐藏入口。
