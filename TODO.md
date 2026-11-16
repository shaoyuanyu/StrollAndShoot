# TODO

只列未完成事项，修掉一项删一项。最后同步：2026-11-16。

## 真机验证 / 潜在缺陷

- **Wi-Fi STA 实时取景与遥控**：1.81.4 继续记录每次 AF 框变化与对焦后请求点；1.81.3 修正 PTP FormFlag（1=Range、2=Enumeration），光圈/ISO 直接使用相机描述；自动区域 AF 会临时切到单点并在退出时恢复（2B/4B 两种布局都试，不合理就退回标准 1/3 档列表），并在首帧记录取景头 / 描述头十六进制，用于继续校准 AF 框。待真机确认：真实 AF 框位置（当前反馈不准确，需看 `实时取景: AF框` 与 `取景头` 日志）、光圈/ISO 面板是否已恢复为可用列表、四个参数写入与 P/A/S/M 可调项。待验证：录像（`0x920A/0x920B` 与 `0xD1A6` 切换）、手动变焦镜头下 W/T 的失败提示。未做：驱动模式、白平衡、录像文件导入与回放。

- **后台无线重连**：2026-11-16 真机日志显示应用在后台时 Wi-Fi 每 ~90 秒断一次，自动重连后还会重扫；1.76.1 已让重连跳过已加载的缩略图，但后台自动重连本身还没关。下一步在 `onWifiBroken()` 里判 `!appForeground`，回前台再重建。
- **STA 热点检查真机验收**：1.75.0 模拟器已验证开关、弹窗、「仍然搜索」与设置持久化；真机需确认热点开/关时 `isHotspotActive()` 的返回值、以及手动开热点后「已开启，继续」能继续搜索。
- **Wi-Fi 下载断点续传真机验收**：1.74.0 已实现 Wi-Fi 分块续传与失败重试；需在 Z50II 上验证 `GetPartialObject` 真实支持、断网 20 秒内自动重连后续传、跨应用重启从 `.part` 续传、以及弱网下 1 MB 分块不撞 30 秒事务超时。
- **UI 统一后的真机验收**：1.20.0{debug} 已通过无线调试安装并启动，相机/设置页中文界面正常；字号、圆角、颜色、行高、图标已全部收敛到 `utils/UiTokens.ets`，模拟器逐项验收通过，待真机确认标题栏字号、曲面屏边缘、手势与深色模式下的实际观感。
- **GPS 时间匹配**：`GpsRecorder.findClosest()` 默认容忍 30 分钟，拍摄时间按手机本地时间解析；相机时钟不准时会匹配不到轨迹。需用时钟不一致的相机验证，必要时补偿时钟差。
- **缩略图方向**：manifest v2 已记录 `corrected` / `exifRotate` / `exifFlip*`，命中时按标记补变换；仍需用 EXIF Orientation ≠ 1 的照片在真机确认方向与黑边裁剪。

## 功能

- 边框、水印、LUT、滤镜、美颜（均未实现）。

## 工程质量

- **单测覆盖**：现有 80 个用例，缺 `CameraService` 排序/清洗、`ThumbnailCache` 键与过期、下载注册表存在性校验。
- **拆分大文件**：`CameraService.ets` 2178 行、`PhotoViewer.ets` 2164 行、`GpsTrackViewerPage.ets` 1431 行。`CameraService` 同时管缩略图缓存、下载、GPS 匹配、缓存设置与扫描统计，可按职责拆分。
- **`GalleryPage` 手工缓存键**：全量分组、筛选、日期分组、行模型各有一份缓存与一组键，改动时容易漏。
- **普通 `Map` 不参与追踪**：`thumbnailPixelMapMap` / `orientedDisplaySizes` / `compressedCache` 靠手工版本号驱动刷新，可考虑换成 `@ObservedV2` 容器。
- **`PtpHost` 重复等待循环**：`getThumb` / `getObject` / `getPartialObject` 各有一份 `usbBusy` 轮询（150 × 200ms），合并成一个方法。
- **C++ 遗留文件**：`CMakeLists.txt` 只编译 `napi_init.cpp` 与 `ptp_engine.cpp`，但 `ptp.c`、`usb.c`、`ptp_client.*`、`gphoto2-port.h` 等仍在源码目录，移出或加说明，避免误改。
- **`README.md`**：只有 4 行，缺环境变量、构建方式、设备与真机要求。
