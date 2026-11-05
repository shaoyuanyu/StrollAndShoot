# TODO

2026-10-14 审视代码时发现、尚未解决的问题。修掉一项就删掉对应条目。行号对应当时的代码状态。

## 缺陷

2026-11-05 已清空。本轮修复：断开连接时的缓存 flush 顺序、`saveRawThumbnail` 参数错位与清单版本升级（manifest v2 + `corrected` 标记）、`setDetailIndex` 接线与 `evictFurthest` 按列表索引淘汰、遗留的 `TEST` 切片注释、`scanRefreshKey` 接入渲染、设置页亮色卡片描边、`MainScreen` 点击缩略图时的 O(n) 坐标查询。

## 无用代码

2026-11-05 已删除全部无调用点代码：`PhotoViewer.getDisplayPixelMap`、`CameraService.getLogText` / `isPhotoDownloaded` / `loadThumbnail` / `cacheOrientedSize`、`ThumbnailCache.loadThumbnail` / `getCacheSizeBytes` / `getEntryCount` / `getAllEntries` / `debugLookup` / `getCameraCacheSize`、`PtpSession.close`、`AppLog.getEntries`、`ZoomableImage.onEdgeChange`、`float.json`（资源数组不能为空，整文件删除）。

C++ 侧：`CMakeLists.txt` 只编译 `napi_init.cpp` 与 `ptp_engine.cpp`。`ptp.c`（356 KB）、`usb.c`、`ptp_client.cpp/h`、`gphoto2-port.h`、`device-flags.h`、`ptp-bugs.h`、`ptp-private.h` 都不参与构建；`ptp.h` 被 `ptp_engine.h` 引入，需要保留。可以移出源码目录或加说明，避免以后误改。


## 需要在真机上确认

- **GalleryPage 的按行刷新**：`PhotoCell` 是 `@Builder`，参数里带值类型的 `rowComplete`（`GalleryPage.ets:329` 定义，`:512` 调用）。仓库记忆里记录过“Repeat 与 `@Builder` 混用时传值类型参数不触发内部刷新”，当时的处理是把 `PhotoCell` 直接写进 `Repeat.each()` 回调；当前代码又是 `@Builder` 形式，`PhotoViewer` 里同类场景用的是独立 `@ComponentV2`。需要确认缩略图是否仍然整行同时出现。
- **主页顶部**：`MainScreen` 既没有设置 `title`，也没有 `hideTitleBar(true)`（`PhotoViewer` 隐藏了标题栏并自绘）。确认主页顶部是否存在一条空的系统标题栏。
- **GPS 匹配容错**：`GpsRecorder.findClosest()` 默认容忍 30 分钟，`parseCaptureDate()` 把相机拍摄时间当手机本地时间。相机时钟与手机不一致时匹配不到位置，需要一台时钟不同的相机验证，必要时加时钟差补偿。
- **缩略图缓存的方向纠正**：manifest 已升级到 v2 并记录 `corrected`/`exifRotate`/`exifFlip*`，缓存命中时按标记决定是否应用变换。仍需用旋转过的照片（EXIF Orientation ≠ 1）验证一次显示方向与黑边裁剪。

## 工程质量

- **测试**：`entry/src/test` 有 7 个用例全部通过（`PhotoGroupUtil.test.ets` 6 个 + 模板 1 个）；`entry/src/ohosTest` 仍是模板用例。下一步给 `CameraService` 的排序与清洗逻辑、`ThumbnailCache` 的键与过期判断补单测。
- **文件规模**：`CameraService.ets` 1825 行、`PhotoViewer.ets` 1409 行。`CameraService` 同时承担缩略图磁盘缓存、下载注册表、GPS 时间匹配、缓存设置与扫描统计，可以按职责分成几个类。
- **手工版本号驱动的刷新**：`GalleryPage` 用 `photosVersion`、`thumbnailVersion`、`displayMode`、`filterValue`、`galleryScale` 五个字段判断 `buildFlatItems()` 的缓存是否有效，另外 `allDisplayGroups()`、`buildFilterOptions()`、`_filteredIndexMap` 各有自己的一份。任何一处改动都要同时顾及所有递增点。
- **普通 `Map` 的状态追踪**：`thumbnailPixelMapMap`、`orientedDisplaySizes`、`compressedCache` 不是 `@Trace`，界面刷新依赖手工计数被 `build()` 读到。可以考虑换成 `@ObservedV2` 容器，减少漏改计数器导致的界面不刷新。
- **重复的等待循环**：`PtpHost` 的 `getThumb` / `getObject` / `getPartialObject` 各抄了一份 `usbBusy` 轮询（150 次 × 200ms），可以合并成一个方法。
- **日志策略**：`scanForCamera()` 开头的 `this.log.clear()` 会清掉扫描之前的记录，而扫描期间 200 条上限又会挤掉早期条目——排查 USB 问题时最想看的那部分恰好会被丢掉。`PtpHost.log()` 对每条 USB 命令输出十六进制片段。需要重新考虑保留策略。
- **`README.md` 只有两行**，缺少环境变量、构建方式与设备要求。

## 界面与设计

2026-11-05 按 HarmonyOS 沉浸光感风格重构了一轮 UI，下列条目已处理：

- **颜色**：新增 `bg_elevated`、`text_tertiary`、`card_border`、`primary_soft`、`scrim`、`nav_bg`，全部界面改用资源；仅 `PhotoViewer`（固定深色页）与 `WindowUtils`（系统栏）保留写定色值。
- **图标**：全项目改用 `SymbolGlyph`（`chevron_left` / `checkmark` / `xmark` / `trash` / `camera` / `square_grid_2x2` / `gearshape` / `chevron_right`），emoji 已清零。
- **底部标签栏**：改用系统 `Tabs` 原生标签栏（`barHeight(64)` + `barBackgroundBlurStyle(COMPONENT_THICK)`），带图标、选中态与系统无障碍角色。
- **页面头部**：新增 `components/PageHeader.ets`，三个二级页统一使用；一级页（画廊/相机/设置）自绘大标题 + 副标题。
- **调试入口**：日志面板收进「调试」分组，仅调试包渲染。

仍待处理：

- **字号与圆角**：字号仍有 9/11/12/13/14/15/17/20/24 多档，圆角有 3/8/12/16/19。可再收敛一档（正文 14、次要 12、标题 24/20）。
- **无障碍**：仅为返回、选择、删除按钮补了 `accessibilityText`，列表项与缩略图仍缺描述。
- **文案与多语言**：界面文案全部写在组件内部，`string.json` 的 36 条资源没有任何引用。要支持多语言需要改成 `$r('app.string.*')`。
- **沉浸光感系统材质**：当前用 `backgroundBlurStyle` + 半透明色实现材质感。若要使用 API 26 的 `systemMaterial` / HDS 组件，需要把 `targetSdkVersion` 提到 26.0.0，并处理低版本降级。

