# StrollAndShoot (走走拍拍)

A HarmonyOS phone app for connecting to cameras, importing photos, and applying post-processing effects like GPS geotagging, borders, watermarks, LUTs, filters, and beautification.

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
├── AppScope/
│   └── app.json5                # App manifest (bundleName: io.github.shaoyuanyu.strollandshoot)
├── entry/                       # Main module
│   ├── build-profile.json5      # Module build (stageMode, CMake native build)
│   ├── src/main/
│   │   ├── module.json5         # Abilities, pages, device types (phone)
│   │   ├── ets/
│   │   │   ├── entryability/    # EntryAbility (UIAbility)
│   │   │   ├── entrybackupability/  # BackupExtensionAbility
│   │   │   └── pages/           # Page components (Index.ets)
│   │   ├── cpp/                 # NAPI native code (CMake, napi_init.cpp)
│   │   └── resources/           # Strings, colors, media, profiles
│   └── src/ohosTest/            # Device integration tests
└── hvigor/                      # Hvigor system config
```

## Build & Run

```bash
# Build the app (HAP)
hvigorw assembleHap

# Build with module target
hvigorw -p module=entry@default assembleHap

# Run tests
hvigorw test

# Clean build outputs
hvigorw clean
```

## Architecture

- **Stage Model**: Single UIAbility (`EntryAbility`) as the app entry point
- **Page routing**: Pages declared in `src/main/resources/base/profile/main_pages.json`
- **NAPI bridge**: Native C++ functions exposed to ArkTS via `libentry.so`. Declare types in `src/main/cpp/types/libentry/Index.d.ts`
- **Resource system**: `$r('app.type.name')` references resolve from `src/main/resources/`
- **Mock system**: Native modules mocked via `src/mock/mock-config.json5` for testing without device

## Conventions

- Use ArkTS strict mode (enforced by build-profile.json5 `useNormalizedOHMUrl: true`, `caseSensitiveCheck: true`)
- All `.ets` files are linted with `@performance/recommended` and `@typescript-eslint/recommended` rules
- Security lint rules ban unsafe crypto algorithms (3DES, weak AES modes, SHA1, etc.)
- Color mode defaults to following system (`COLOR_MODE_NOT_SET`)
- Logging uses `hilog` with domain `0x0000`

## Current State

### Completed

- **PTP Protocol Engine** (`entry/src/main/cpp/ptp_engine.h/cpp`) — Full PTP/MTP protocol implementation ported from libgphoto2, with USB container building, response parsing, device info/storage/object handle queries. NAPI bindings exposed via `libentry.so`.
- **USB Camera Communication** (`entry/src/main/ets/pages/PtpHost.ets`) — Wraps `@ohos.usbManager` for USB host mode, PTP session management, photo enumeration (with 6-level directory traversal). Tested with Nikon Z50.
- **Three-page UI** — Gallery (`GalleryPage.ets`), Camera (`CameraPage.ets`), Settings (`SettingsPage.ets`) as separate `@Component` files inside `Tabs` + `TabsController`. Bottom nav bar with click switching. Dark mode toggle (system/light/dark) with `$r()` color resources.
- **Service Layer** — `CameraService` singleton, `AppLog` with log levels, `PhotoEntry` model
- **Deploy Pipeline** — `deploy.sh` for build → sign → install → launch

### In Progress

- Photo file download from camera (object handles enumerated but file data not yet read)
- GPS geotagging
- Photo post-processing (borders, watermarks)
