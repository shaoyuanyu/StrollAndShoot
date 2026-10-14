# StrollAndShoot (走走拍拍)

A HarmonyOS phone app for connecting to cameras over USB PTP, browsing and importing photos, and applying post-processing effects like GPS geotagging, borders, watermarks, LUTs, filters, and beautification.

## 交流语言

使用中文与我交流。

## Tech Stack

- **Platform**: HarmonyOS 6.1.0 (API 23, Stage Model)
- **Language**: ArkTS (TypeScript superset for HarmonyOS)
- **UI Framework**: ArkUI
- **Build System**: Hvigor (HarmonyOS native build system)
- **Native Bridge**: NAPI (C++ → ArkTS), compiled with BiSheng compiler
- **Native ABIs**: `arm64-v8a`, `x86_64`
- **Package Manager**: ohpm
- **Test Framework**: @ohos/hypium (unit + integration), @ohos/hamock (mocking)
- **Linter**: code-linter (ESLint-based, with security rules)

## Project Structure

```text
StrollAndShoot/
├── build-profile.json5          # Root build config (SDK 6.1.0, runtime OS: HarmonyOS)
├── oh-package.json5             # Root package manifest (devDeps: hypium, hamock)
├── hvigorfile.ts                # Root build entry (appTasks)
├── code-linter.json5            # Linter rules (performance + security)
├── deploy.sh                    # Build → sign → install → launch pipeline
├── AppScope/
│   └── app.json5                # App manifest (bundleName: io.github.shaoyuanyu.strollandshoot)
├── entry/                       # Main module
│   ├── build-profile.json5      # Module build (stageMode, CMake native build)
│   ├── src/main/
│   │   ├── module.json5         # Abilities, pages, device types (phone)
│   │   ├── ets/
│   │   │   ├── entryability/    # EntryAbility (UIAbility)
│   │   │   ├── entrybackupability/  # BackupExtensionAbility
│   │   │   ├── pages/           # Page components
│   │   │   ├── components/      # Reusable UI components
│   │   │   ├── services/        # Service layer (singletons)
│   │   │   └── model/           # Data models
│   │   ├── cpp/                 # NAPI native code (CMake, napi_init.cpp)
│   │   └── resources/           # Strings, colors, media, profiles
│   └── src/ohosTest/            # Device integration tests
└── hvigor/                      # Hvigor system config
```

## Build & Run

```bash
# Full pipeline (build → sign → install → launch)
bash deploy.sh full

# Skip build (sign → install → launch) — only use when code hasn't changed
bash deploy.sh run

# Build only
hvigorw assembleHap --no-daemon

# Build with DevEco CLI（推荐，输出更简洁，已验证）
devecocli build

# Clean build (required after reverting code to avoid stale cache bugs)
hvigorw clean --no-daemon

# Run tests
hvigorw test
```

## Architecture

### Navigation

- **Tabs + TabsController**: Three-tab bottom navigation ([Index.ets](entry/src/main/ets/pages/Index.ets)) with "画廊" (Gallery), "相机" (Camera), "设置" (Settings)
- **Page routing**: `router.pushUrl` for detail page navigation (deprecated API, to migrate)
- Pages declared in `src/main/resources/base/profile/main_pages.json`

### State Management

This project uses **ArkUI V2 state management exclusively**. V1 decorators (`@State`, `@Prop`, `@Link`, `@StorageLink`, `@StorageProp`, `@Provide`, `@Consume`, `@Observed`, `@ObjectLink`, `@Track`, `@Watch`) are **prohibited** in new code.

| V2 Decorator | Purpose |
|---|---|
| `@ComponentV2` | All components must use this instead of `@Component` |
| `@Local` | Component-local reactive state (replaces `@State`) |
| `@Param` | Read-only input from parent (replaces `@Prop`). Use with `@Once` for write-in-child scenarios |
| `@Param @Once` | Parent-initialized, locally writable (replaces `@State` with external init) |
| `@Event` | Callback from child to parent (replaces `@Link` for bidirectional sync) |
| `@Provider()` / `@Consumer()` | Cross-level data sharing (replaces `@Provide`/`@Consume`) |
| `@ObservedV2` | Marks a class as observable (replaces `@Observed`) |
| `@Trace` | Property-level precise tracking (replaces `@Track`) |
| `@Monitor` | Async change listener with before/after values (replaces `@Watch`；回调参数 `IMonitor`，通过 `monitor.value(path)?.before` / `?.now` 获取旧/新值) |
| `@SyncMonitor` | API 23+ 同步版 `@Monitor`（回调立即执行） |
| `@Computed` | Memoized computed property (no V1 equivalent) |
| `@Builder` | Retained from V1, compatible with V2 |
| `Repeat` | List rendering (replaces `ForEach`；`LazyForEach` 的 V2 对应物是 `RepeatForEach`，见官方迁移指南) |
| `AppStorageV2.connect()` | App-wide reactive state sharing (replaces `AppStorage` / `@StorageLink`) |
| `PersistenceV2.globalConnect()` | Persistent app-wide state (replaces `PersistentStorage.persistProp` + `@StorageLink`) |
| `!!` | Two-way binding syntax (replaces `$$`) |

**Pattern**: `Index.ets` owns all `@Local` state variables and syncs them from `CameraService` via `onChange` callback → `syncState()`. Child pages receive data via `@Param`. Persistent settings (dark mode, gallery column count, display mode) are stored in `SettingsStore` (`@ObservedV2` + `PersistenceV2.globalConnect()`), accessed directly via singleton in any component.

### NAPI Bridge

Native C++ functions exposed to ArkTS via `libentry.so`. Type declarations in [types/libentry/Index.d.ts](entry/src/main/cpp/types/libentry/Index.d.ts).
- **PTP command builders**: `buildOpenSession`, `buildGetDeviceInfo`, `buildGetObjectHandles`, `buildGetObject`, `buildGetThumb`, etc.
- **Response parsers**: `processResponse`, `parseDeviceInfo`, `parseObjectHandles`, `parseObjectInfo`
- **Key concept**: `processResponse` accumulates multi-packet USB data and returns action codes — `0` = data accumulating (keep reading), `1` = data packet ready, `2` = response packet ready (code `0x2001` = OK)

### Resource System

`$r('app.type.name')` references resolve from `src/main/resources/`. 颜色模式遵循系统（`COLOR_MODE_NOT_SET`，官方定义：值 -1，"未设置"，跟随系统渲染；`COLOR_MODE_LIGHT`/`COLOR_MODE_DARK` 为显式指定）。

## Pages

### Index.ets — Root Container
Entry point (`@Entry`). Owns `TabsController`, `CameraService` singleton reference, and all `@Local` state variables. Syncs state from service on every change. Uses `SettingsStore` singleton for persisted preferences. Routes to `PhotoDetailPage` on thumbnail tap.

### GalleryPage.ets — Photo Browser
Grid view of imported photos with:
- **Format filtering**: Dynamic filter chips built from file extensions present in photos (e.g., JPG, NEF, MOV). Filtered via `getFilteredPhotos()`.
- **Date grouping**: Photos grouped by capture date (YYYY-MM-DD), sorted newest-first. Photos without dates go to "未知日期" group.
- **Pinch-to-zoom**: `PinchGesture` scales the grid from 0.4x to 6.0x, dynamically recalculates column count and gap.
- **Selection mode**: Long-press enters multi-select with checkboxes. `SelectionActionBar` shows download button for selected photos.
- **Thumbnail display**: Shows decoded `PixelMap` if ready, fallback placeholder otherwise. Thumbnails loaded asynchronously via `CameraService.loadAllThumbnails()`.

### CameraPage.ets — Connection & Device Info
- Scan/connect/disconnect buttons
- Device info card (model name, photo count, connection type)
- `ConnectionStatusBar` in non-compact mode

### SettingsPage.ets — Preferences & Debug Log
- Dark mode toggle (follow system / light / dark) via `SettingsStore` singleton (`@ObservedV2` + `PersistenceV2`)
- Gallery column count and display mode persisted via `SettingsStore`
- Version info
- Debug log viewer with clear/copy actions, monospace font, scrollable

### PhotoDetailPage.ets — Full-Resolution Viewer
- `Swiper` for horizontal pagination through all photos (disabled when zoomed in)
- Loads full-resolution photo on display via `CameraService.loadFullPhoto()` with stale-request guard (`loadVersion`)
- Falls back to thumbnail while full-res loads
- **Pinch-to-zoom**: Two-finger pinch (1x–5x) + single-finger pan when zoomed + double-tap to toggle 1x/2.5x
- Gestures combined in single `GestureGroup(Parallel, PinchGesture, PanGesture, TapGesture)` — multiple `.gesture()` calls override each other
- Overlay with filename, date, size, resolution; tap to toggle
- Triggers adjacent preloading via `CameraService.setDetailIndex()`

### PtpHost.ets — PTP Session Layer
USB communication core (see "Key Modules" below).

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `ConnectionStatusBar` | [components/ConnectionStatusBar.ets](entry/src/main/ets/components/ConnectionStatusBar.ets) | Compact (gallery header) and full (camera page) connection status display |
| `SelectionActionBar` | [components/SelectionActionBar.ets](entry/src/main/ets/components/SelectionActionBar.ets) | Bottom bar with selected count, cancel, and download buttons |

## Services

### CameraService ([services/CameraService.ets](entry/src/main/ets/services/CameraService.ets))
Singleton service orchestrating all camera operations:
- **scanForCamera()**: Find USB cameras → connect → get device info → load photo list → load all thumbnails
- **loadPhotoList()**: Enumerate photos via recursive directory traversal (`collectPhotoHandles`), fetch `ObjectInfo` for each handle
- **loadAllThumbnails()**: Pipeline pattern — USB reads serial, `createPixelMap` decode jobs collected and awaited with `Promise.all`
- **loadFullPhoto(handle)**: Full-res download with compressed cache (200MB LRU eviction, distance-based)
- **Preloading**: Adjacent photos preloaded in swipe direction (radius=5), triggered after viewing a detail photo
- **Thumbnail cache**: `Map<number, PixelMap>` for decoded thumbnails, `Set<number>` for tracking loaded handles

### AppLog ([services/AppLog.ets](entry/src/main/ets/services/AppLog.ets))
In-memory ring buffer (200 entries) + file persistence (`app_log.txt`). Writes to `hilog` and saves to file on every add. Supports INFO/WARN/ERROR levels. Read from device via:
```bash
hdc shell cat /data/app/el2/100/base/io.github.shaoyuanyu.strollandshoot/haps/entry/files/app_log.txt
```

## Model

### PhotoEntry ([model/PhotoEntry.ets](entry/src/main/ets/model/PhotoEntry.ets))
```typescript
interface PhotoEntry {
  handle: number;        // PTP object handle (unique per storage)
  filename: string;      // e.g. "DSC_0001.JPG"
  size: number;          // Compressed size in bytes
  captureDate?: string;  // PTP date string (YYYYMMDDThhmmss)
  objectFormat?: number; // PTP format code (0x3801=JPEG, 0x3001=directory, etc.)
  imagePixWidth?: number;
  imagePixHeight?: number;
  storageId?: number;
}
```

## Key Modules & Terminology

### PTP (Picture Transfer Protocol)
Standard protocol for camera communication over USB. Key concepts:
- **Session**: Opened with `OpenSession(sessionId)` before any operations
- **Storage ID**: Logical storage unit (internal memory, SD card). Cameras typically have 1-2.
- **Object Handle**: Unique 32-bit identifier for each file/directory within a storage
- **Object Format Code**: `0x3801` = JPEG, `0x3001` = directory (DCIM), `0x3803` = TIFF, raw formats vary by vendor
- **Parent handle**: `0xFFFFFFFF` = root of storage; directory handle = children of that directory
- **Response code**: `0x2001` = OK; other codes indicate errors

### PTP Session Layer ([pages/PtpHost.ets](entry/src/main/ets/pages/PtpHost.ets))
Wraps `@ohos.usbManager` for USB host mode:
- **findCameras()**: Enumerate USB devices, filter by class `0x06` (Image), subclass `0x01` (SIC), protocol `0x01` (PTP)
- **connect()**: Request permission → `connectDevice` → `claimInterface` → drain interrupt EP → `OpenSession`
- **Three transaction helpers**:
  - `ptpCommand()` — command + response (no data phase)
  - `ptpCommandGetData()` — command + data + response (small data, 1KB buffer)
  - `ptpCommandGetLargeData()` — command + data + response (large data, 192KB buffer reused across loop)
- **USB constraint**: Single `bulkTransfer` call must be < 200KB total (including pipe, endpoint, buffer, timeout). Exceeding returns -1. Buffer is 192KB (196608 bytes) to leave headroom.

### Native PTP Engine ([cpp/](entry/src/main/cpp/))
Ported from libgphoto2:
- `ptp_engine.h/cpp` — PTP/MTP protocol container building, response parsing
- `ptp_client.h/cpp` — NAPI bindings exposing `build*` and `parse*` functions
- `usb.c` — USB I/O layer (not used at runtime; all USB I/O is in ArkTS)
- `ptp.h`, `ptp-private.h`, `ptp-bugs.h` — Protocol constants, structs, vendor bug workarounds

## Current State

### Completed
- PTP protocol engine (command building, response parsing, device info/storage/object queries)
- USB camera communication (session management, photo enumeration with recursive directory traversal)
- Five-page UI: Index (tabs), Gallery (grid with filters/zoom/selection), Camera (scan/connect), Settings (dark mode, debug log), PhotoDetail (full-res swiper with preloading)
- Service layer: CameraService singleton, AppLog with file persistence
- Thumbnail pipeline loading (USB read overlapped with async decode)
- Full-resolution photo cache with LRU eviction and directional preloading
- Format filter bar (dynamic from file extensions)
- Pinch-to-zoom gallery grid
- Dark mode toggle (system/light/dark)
- Deploy pipeline: `deploy.sh full` (build → sign → install → launch)
- **State management V2 migration**: All components migrated to `@ComponentV2`, `@Local`, `@Param`, `@Event`, `@Monitor`, `Repeat`. Persistent settings via `SettingsStore` (`@ObservedV2` + `PersistenceV2`). V1 decorators prohibited.

### In Progress
- GPS geotagging
- Photo post-processing (borders, watermarks)

## Debugging Lessons

### `deploy.sh run` skips build
`bash deploy.sh run` only signs, installs, and launches — it does **not** rebuild. After any code change, use `bash deploy.sh full` or the old HAP will be deployed with no code changes. This has caused false "bug not fixed" reports multiple times.

### Stale build cache can cause phantom regressions
When reverting code and rebuilding without cleaning, hvigorw may reuse cached build artifacts, making it appear as if the revert didn't work. Always run `hvigorw clean --no-daemon` before rebuilding after a revert.

### Always check for arbitrary limits
The old `loadPhotoList` had `const limit = Math.min(handles.length, 50)` that silently capped photos at 50 regardless of actual count. When a feature "mostly works but numbers don't add up", grep for `limit`, `min(`, `max(`, slice operations, and hardcoded small numbers.

### Directory traversal heuristics are fragile
The old traversal logic had `validCount <= 2` as a condition for recursing into directories — a heuristic that assumed "single-child container directories." This broke on cameras with:
- Multiple subdirectories at the same level (e.g., DCIM/100NCD90 + DCIM/101NCD90)
- Directories with more than 2 direct children
- Mixed file/directory contents at any level

The fix: recursively enter **all** directories (format `0x3001`), collect all non-directory handles as photos. No heuristics.

### HarmonyOS USB bulk transfer ≤ 200KB
Single `bulkTransfer` call total data must be under 200KB. Exceeding returns -1. Using 192KB (196608 bytes) as buffer size leaves safe headroom for USB container overhead. See memory file `hmos-usb-transfer-limit.md`.

> 注意：此限制为项目实测经验，官方 `usbManager` 文档未记载具体数值。修改传输缓冲区大小时务必在真机上验证。

### Phone USB connection is unstable during development
The phone frequently disconnects from `hdc` during development. Before any deploy or log check, verify with `hdc list targets`. If `[Empty]`, ask the user to reconnect the phone.

### 查询 HarmonyOS 官方文档 — 本地知识库 MCP（首选）+ DevEco CLI docs（备用）
需要 API 参考、开发指南、系统接口，或验证技术经验时，**优先使用本地 `developercomm` 知识库 MCP**，无需浏览器：

- `mcp_developercomm_searchDocuments` — 全文检索华为官方知识库（API 参考、开发指南、最佳实践、FAQ、版本说明等），传入自然语言 query
- `mcp_developercomm_getDocumentsById` — 用搜索结果的 `parent` 字段（文档 ID）拉取完整文档内容，一次最多 10 篇
- 注意：返回内容过长时会截断（标记 `[truncated]`），可换用更精确的关键词多次搜索
- 备用渠道：`devecocli docs` 提供同样的离线本地文档（开发指南/API参考/最佳实践/FAQ/版本说明/变更预告），输出为完整 markdown，无截断。用 MCP 结果不够时可交叉验证
- 已废弃 Playwright 浏览华为开发者文档站点的方式（此前需用 `#developer_search_input_pc` 搜索且页面为客户端渲染）

### Test workflow for camera-required features

After any code change that involves camera/USB interaction: build → deploy → tell user what changed → user disconnects phone from PC, connects to camera, tests → user reports results → user reconnects phone to PC → check hilog for debug info. Do NOT assume gestures or camera features work until confirmed on actual camera hardware.

## DevEco CLI (`devecocli`)

华为官方推出的 agent coding 工具包（npm 包 `@deveco/deveco-cli`），包装 hvigor/ohpm/hdc/模拟器工具链并内置本地离线文档与官方 skills。**本机已安装 `1.3.0`，可执行命令为 `devecocli`（不是 `deveco`）**。包内自带 `SKILL.md`（完整用法）与 `docs.zip`（离线文档）。

### 必需的环境变量（Linux 实测）

```bash
export DEVECO_CLI_CLT_PATH=/home/ysy/.hmos/command-line-tools   # CLT 不会被自动发现，必须显式指定
export DEVECO_CLI_SKIP_VERSION_CHECK=1                          # 本机 CLT 6.1.0.830 < CLI 要求的最低 26.0.0，必须跳过版本检查
```

> 注：`DEVECO_CLI_SKIP_VERSION_CHECK` 是 CLI 官方 postinstall 脚本自己使用的环境变量。跳过检查后所有核心功能在本机实测正常；若未来升级 CLT 到 26.0.0+ 可移除。CLT 位于 `~/.hmos/command-line-tools/`（内含 hvigor 6.23.5、codelinter 6.0.240、ohpm、HarmonyOS SDK API 23）。

### 已在本项目实测可用的命令

| 命令 | 用途 | 实测结果 |
|---|---|---|
| `devecocli build` | 构建项目（等同 `hvigorw assembleHap`） | ✅ 9.5s 构建成功，输出比 hvigorw 简洁；`build clean` 可清理 |
| `devecocli check lint [path]` | 运行 code-linter 检查（TS/ArkTS） | ✅ 本项目检出 5 个性能 warning（高频日志、Date 复用），支持 `--fix`/`--format json`/`--output-path` |
| `devecocli docs catalog` | 列出离线文档目录（6 类：开发指南/API参考/最佳实践/FAQ/版本说明/变更预告） | ✅ |
| `devecocli docs search <关键词...>` | 本地全文搜索，支持 `--catalog`/`--format json`/`--limit` | ✅ 搜 `usbManager` 可命中官方 FAQ |
| `devecocli docs read <documentId>` | 读取完整文档（输出 markdown，无截断） | ✅ documentId 为搜索结果的完整路径 |
| `devecocli device list` | 列出真机/模拟器 | ✅ 当前无设备时正常提示 |
| `devecocli skills list` | 列出官方 HarmonyOS skills（35 个：arkts 语法检查、状态管理迁移、崩溃分析等） | ✅ |
| `devecocli skills add --skill <name> --path <dir>` | 直装官方 skill 到指定目录（标准 `<name>/SKILL.md` 格式）| ✅ 全部 35 个官方 skills 已装入实体仓库 `/home/ysy/Projects/hmos/.skills/`，本项目经 `.agents/skills` 符号链接接入；`skills add --all --path <dir>` 可一键全装 |
| `devecocli init --skill` / `--mcp` | 将 skill 安装到 AI agents / 配置 deveco-mcp（.ets/C++ 语法检查） | 支持 `--agent`（opencode/cursor 等，**不含 VS Code Copilot**）、`--path` 直装、`--project` 项目级 |

### 需设备/登录或未验证的命令

- `devecocli run` / `--apply <file>` / `--hotreload` — 构建+安装+启动；`--apply` 为快速增量部署（改动文件列表写入 `.hvigor/` 下，需先完整 run 一次；要求 DevEco Studio ≥ 6.1.1）；`--hotreload` 需后台进程保活 watch session
- `devecocli log` — hilog/崩溃日志（`--crash`/`--level`/`--bundle-name`/`--follow`），需设备
- `devecocli ui` — UI 检视（`layout`/`screenshot`/`click`/`swipe`/`text` 等），需设备
- `devecocli emulator` — 模拟器管理（本机 Linux 无 DevEco Studio，未验证；要求 DevEco Studio ≥ 6.1.0）
- `devecocli signature generate` — 自动生成签名材料并写入 `build-profile.json5`，需先 `devecocli auth login` 且连接设备（可替代 deploy.sh 的手动签名流程）
- `devecocli check compat` — 两个 SDK 版本间的破坏性 API 变更扫描（`--source-version`/`--target-version`）
- `devecocli update` — 更新 CLI 自身

### 与现有流程的关系

- 构建：`devecocli build` 可直接替代 `hvigorw assembleHap --no-daemon`；但 `deploy.sh` 的完整签名部署流程仍保持不动
- 文档查询：`devecocli docs` 与 `developercomm` MCP 数据同源，可作为交叉验证渠道（MCP 输出截断时尤其有用）
- 代码检查：`devecocli check lint` 与 `hvigorw` 的 codelinter 同一引擎
- Skills：实体仓库在 `/home/ysy/Projects/hmos/.skills/`，本项目通过 `.agents/skills` 符号链接接入（VS Code 官方支持的项目级 skills 位置）。链接丢失时重建：`mkdir -p .agents && ln -s /home/ysy/Projects/hmos/.skills .agents/skills`

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


## 缩略图缓存系统

### CameraCachePrefs (`services/CameraCachePrefs.ets`)
管理每个相机的缓存偏好。持久化在 `{filesDir}/camera_cache_prefs.json`。
- 记录 `cameraId`、`friendlyName`、`cachingEnabled`、`firstAsked`、`lastSeen`
- `getAll()` 返回所有记录（按 `lastSeen` 降序）
- `isCachingEnabled(cameraId)` 检查是否允许缓存（默认 true）
- 在 `CameraService.initDownloadDir()` 中初始化

### ThumbnailCache (`services/ThumbnailCache.ets`)
缩略图磁盘缓存管理器。目录结构：
```
{filesDir}/thumb_cache/{cameraIdHash}/
  manifest.json       // {"filename::size": CacheEntry, ...}
  {hash}.jpg          // 编码缩略图 JPEG quality=85
```
- Key 格式：`filename::size`（同下载注册表）
- 缓存命中条件：key 存在于 manifest 且 `modificationDate` 匹配
- `saveRawThumbnail()` 直接存储 USB 原始 JPEG 字节（避免重新编码）
- `purgeStale(validKeys)` 扫描结束后清理失效条目
- `getCameraCacheSize()` 静态方法供管理页查询

### 相机身份识别
PTP `GetDeviceInfo` 提供唯一标识：
1. `serialNumber`（最可靠）
2. `manufacturer + model + deviceVersion`
3. USB `vendorId + productId`（降级）

`CameraService.cameraIdentity` 在 `scanForCamera()` 连接后设置。

### 缓存流程
1. `scanForCamera()` → `getDeviceInfo()` → `buildCameraIdentity()` → `checkCachingState()`
2. 未见过该相机 → `cachingDialogRequired=true` → `MainScreen` 弹 `AlertDialog`
3. 用户选择 → `setCachingPreference(id, enabled)` → 记入 `CameraCachePrefs`
4. 若启用 → 下次 `loadPhotosAndThumbnails()` 先走 `ThumbnailCache.findCached()`
5. 命中 → 跳过 USB `getThumb`，从文件加载 PixelMap
6. 未命中/过期 → USB 下载 + TaskPool 解码 + 异步保存到缓存
7. 扫描结束后 → `purgeStale(validKeys)` 删除不存在的文件缓存

### 缓存管理页面
`CacheManagementPage.ets`（`@Entry`，注册在 `main_pages.json`）
- 设置页 → "缩略图缓存" → `router.pushUrl({ url: 'pages/CacheManagementPage' })`
- 显示所有已知相机、缓存大小、开关、删除按钮
- 底部"清除所有缓存"按钮

### 调试
hilog 标签 `ThumbnailCache`、`CameraCachePrefs`。缓存命中日志格式：
```
[ThumbnailCache] loaded manifest with 42 entries
[ThumbnailCache] stale: modDate changed for DSC_0001.JPG::1234567
[CameraService] [CACHE_HIT] handle=0x1234 160x120
[CameraService] 缓存已启用: NIKON D850
```
