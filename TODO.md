# TODO

只列未完成事项，修掉一项删一项。最后同步：2026-11-08。

## 真机验证 / 潜在缺陷

- **UI 统一后的真机验收**：1.18.1{debug} 已通过无线调试推送到真机并启动；字号、圆角、颜色、行高、图标已全部收敛到 `utils/UiTokens.ets`，模拟器逐项验收通过，待真机确认标题栏字号、曲面屏边缘、手势与深色模式下的实际观感。
- **GPS 时间匹配**：`GpsRecorder.findClosest()` 默认容忍 30 分钟，拍摄时间按手机本地时间解析；相机时钟不准时会匹配不到轨迹。需用时钟不一致的相机验证，必要时补偿时钟差。
- **缩略图方向**：manifest v2 已记录 `corrected` / `exifRotate` / `exifFlip*`，命中时按标记补变换；仍需用 EXIF Orientation ≠ 1 的照片在真机确认方向与黑边裁剪。

## 功能

- 边框、水印、LUT、滤镜、美颜（均未实现，`string.json` 里只有占位文案）。

## 工程质量

- **单测覆盖**：现有 37 个用例，缺 `CameraService` 排序/清洗、`ThumbnailCache` 键与过期、下载注册表存在性校验。
- **拆分大文件**：`CameraService.ets` 2178 行、`PhotoViewer.ets` 2164 行、`GpsTrackViewerPage.ets` 1431 行。`CameraService` 同时管缩略图缓存、下载、GPS 匹配、缓存设置与扫描统计，可按职责拆分。
- **`GalleryPage` 手工缓存键**：全量分组、筛选、日期分组、行模型各有一份缓存与一组键，改动时容易漏。
- **普通 `Map` 不参与追踪**：`thumbnailPixelMapMap` / `orientedDisplaySizes` / `compressedCache` 靠手工版本号驱动刷新，可考虑换成 `@ObservedV2` 容器。
- **`PtpHost` 重复等待循环**：`getThumb` / `getObject` / `getPartialObject` 各有一份 `usbBusy` 轮询（150 × 200ms），合并成一个方法。
- **C++ 遗留文件**：`CMakeLists.txt` 只编译 `napi_init.cpp` 与 `ptp_engine.cpp`，但 `ptp.c`、`usb.c`、`ptp_client.*`、`gphoto2-port.h` 等仍在源码目录，移出或加说明，避免误改。
- **`README.md`**：只有 4 行，缺环境变量、构建方式、设备与真机要求。

## 界面 / 多语言

- **多语言**：界面文案写死在组件内，`string.json` 37 条资源零引用；要支持多语言需改用 `$r('app.string.*')`。
