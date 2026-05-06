# StrollAndShoot (走走拍拍)

A HarmonyOS phone app for connecting to cameras over USB PTP, browsing and importing photos, and applying post-processing effects like GPS geotagging, borders, watermarks, LUTs, filters, and beautification.

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

- `CameraService` singleton holds all shared state (connection, photos, thumbnails, cache)
- `Index.ets` syncs state via `onChange` callback → `syncState()` → `@State` variables
- Child pages receive data via `@Prop` (one-way binding from Index)
- `@StorageLink` used for dark mode preference (persisted across sessions)

### NAPI Bridge

Native C++ functions exposed to ArkTS via `libentry.so`. Type declarations in [types/libentry/Index.d.ts](entry/src/main/cpp/types/libentry/Index.d.ts).
- **PTP command builders**: `buildOpenSession`, `buildGetDeviceInfo`, `buildGetObjectHandles`, `buildGetObject`, `buildGetThumb`, etc.
- **Response parsers**: `processResponse`, `parseDeviceInfo`, `parseObjectHandles`, `parseObjectInfo`
- **Key concept**: `processResponse` accumulates multi-packet USB data and returns action codes — `0` = data accumulating (keep reading), `1` = data packet ready, `2` = response packet ready (code `0x2001` = OK)

### Resource System

`$r('app.type.name')` references resolve from `src/main/resources/`. Color mode defaults to following system (`COLOR_MODE_NOT_SET`).

## Pages

### Index.ets — Root Container
Entry point (`@Entry`). Owns `TabsController`, `CameraService` singleton reference, and all `@State` variables. Syncs state from service on every change. Routes to `PhotoDetailPage` on thumbnail tap.

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
- Dark mode toggle (follow system / light / dark) via `@StorageLink`
- Version info
- Debug log viewer with clear/copy actions, monospace font, scrollable

### PhotoDetailPage.ets — Full-Resolution Viewer
- `Swiper` for horizontal pagination through all photos
- Loads full-resolution photo on display via `CameraService.loadFullPhoto()` with stale-request guard (`loadVersion`)
- Falls back to thumbnail while full-res loads
- Overlay with filename, date, size, resolution; tap to toggle
- Triggers adjacent preloading via `CameraService.setDetailIndex()`

### PtpHost.ets — PTP Session Layer
USB communication core (see "Key Modules" below).

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `ConnectionStatusBar` | [components/ConnectionStatusBar.ets](entry/src/main/ets/components/ConnectionStatusBar.ets) | Compact (gallery header) and full (camera page) connection status display |
| `SelectionActionBar` | [components/SelectionActionBar.ets](entry/src/main/ets/components/SelectionActionBar.ets) | Bottom bar with selected count, cancel, and download buttons |
| `FilterBar` | components/FilterBar.ets | Format filter chip row (unused, logic inlined in GalleryPage) |
| `PhotoGridCell` | components/PhotoGridCell.ets | Individual photo cell (unused, logic inlined in GalleryPage) |
| `DebugLogPanel` | components/DebugLogPanel.ets | Debug log viewer (unused, logic inlined in SettingsPage) |

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

### Phone USB connection is unstable during development
The phone frequently disconnects from `hdc` during development. Before any deploy or log check, verify with `hdc list targets`. If `[Empty]`, ask the user to reconnect the phone.
