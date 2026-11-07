# StrollAndShoot（走走拍拍）

HarmonyOS 手机应用。通过 USB PTP 连接相机，浏览并导入照片，写入 GPS 地理标记。

**交流语言：中文。**

## 开发纪律（强制）

### 官方组件优先

- 任何 UI 都先使用官方 ArkUI / HarmonyOS 组件或系统能力（如 `bindSheet`、`List`、`Navigation`、`Tabs`、`Select`、`Toggle`、`Swiper` 等），按官方推荐方式实现。
- **不得**以“自己画更可控/更快”为理由自绘组件。
- 只有官方组件确实无法实现所需特殊效果时，才允许自绘；落地前必须先向用户说明：官方组件为什么不够、自绘范围、交互/无障碍/主题/性能风险、验证方式，并得到确认。
- 自绘也必须遵循系统设计语言，优先保留官方组件的壳、动画和材质；能用官方容器 + 自定义内容组合的，不要从零画。

## 运行环境

| 项 | 值 |
|---|---|
| 平台 | HarmonyOS 7.0.0（API 26，Stage model） |
| 语言 | ArkTS |
| UI | ArkUI，状态管理只用 V2 |
| 构建 | Hvigor；命令行用 DevEco CLI（`devecocli`） |
| Native | NAPI（C++），产物 `libentry.so`，ABI 为 `arm64-v8a` 与 `x86_64` |
| 依赖管理 | ohpm。运行时没有第三方依赖，devDeps 只有 `@ohos/hypium`、`@ohos/hamock` |
| 静态检查 | code-linter，规则见 `code-linter.json5`（performance + security） |
| 设备类型 | 仅 `phone`，见 `module.json5` 的 `deviceTypes` |
| 版本号 | 定义在 `AppScope/app.json5`，写作时为 1.17.1 / 1017001 |
| 开发机 | macOS + DevEco Studio（日常开发）；Linux + command-line-tools（完整构建、签名、部署）。见“macOS 开发环境” |

## macOS 开发环境

日常开发在 macOS 上，用 DevEco Studio 自带的工具链，**不需要** command-line-tools，**不要**设 `DEVECO_CLI_CLT_PATH`。

| 项 | 位置 / 值 |
|---|---|
| DevEco Studio | `/Applications/DevEco-Studio.app`，26.0.0 |
| SDK | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/`，apiVersion 26 |
| ArkTS 类型声明 | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/api/`，接口名、参数类型与起始版本以那里的 `.d.ts` 为准 |
| hdc | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`，**不在 PATH**，要写绝对路径 |
| hvigor | `/Applications/DevEco-Studio.app/Contents/tools/hvigor`，由 `devecocli` 自动发现 |
| devecocli | `~/.nvm/versions/node/v26.13.0/bin/devecocli`，1.3.0-stable |
| 模拟器镜像 | `~/Library/Huawei/Sdk/system-image/HarmonyOS-7.0.0`，实例 `Mate 80` 可用，见「模拟器」 |

`devecocli` 由 nvm 装的 node v26.13.0 提供。新开的 shell 若没加载 nvm，会出现 `command not found`，先 `source ~/.nvm/nvm.sh`。

### 与 Linux 开发机的差异

| 项 | macOS | Linux |
|---|---|---|
| `DEVECO_CLI_CLT_PATH` | 不设；设成 `Contents/tools` 会报 `Invalid DEVECO_CLI_CLT_PATH` | 必须设为 `~/.hmos/command-line-tools` |
| `DEVECO_CLI_SKIP_VERSION_CHECK` | 不需要 | 需要 |
| `hvigorw` 脚本 | 项目根目录**没有**，只能用 `devecocli` | 有（本地文件，未纳入版本控制） |
| `deploy.sh` | **不存在**（被 `.gitignore` 忽略，只在 Linux 上） | 有，内含签名材料路径与口令 |
| 签名材料 | **三套签名配置**：`default` 自动签名（`~/.ohos/config/`，备用）、`AgentDebug`、`AgentRelease`；手动材料在 `../KEYS/hmos_dev_key.p12`、`../CERTIFICATES/` 与 `.profile/` | `deploy.sh` 负责 |
| 安装到手机 | 真机走 Wi-Fi：`hdc -t IP:端口 install -r entry-default-signed.hap`，见「无线调试（Wi-Fi）」；模拟器只认 unsigned 包 | `bash deploy.sh full` |

### macOS 上的流程

```bash
# 1. 改代码后构建
devecocli build

# 2. 静态检查
devecocli check lint entry/src/main/ets

# 3. 回退改动后清理，避免命中旧产物
devecocli build clean

# 4. 查设备 / 查日志（hdc 不在 PATH）
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc list targets
```

- `devecocli build` 产出 `entry/build/<product>/outputs/default/` 下的两个 HAP：`entry-default-signed.hap`（AgentDebug 签名，已过 `hap-sign-tool verify-app`）与 `entry-default-unsigned.hap`。
- macOS 上签名材料分散在项目外：`.p12` 在 `../KEYS/hmos_dev_key.p12`，`.cer` 在 `../CERTIFICATES/`（`Agent_Debug.cer`、`Agent_RELEASE.cer`），Profile 在 `.profile/`。`build-profile.json5` 里已配好 `AgentDebug` / `AgentRelease` 两套手动签名：`default` product 用 AgentDebug，`dist` product 用 AgentRelease。
- **签好的 HAP 能装真机**（2026-11-06 实测）：Profile 的 `debug-info.device-ids` 里登记了真机 UDID，手机打开无线调试后 `hdc -t IP:端口 install -r entry-default-signed.hap` 1.4 秒装完并成功启动。真正装不进的是**模拟器**，它只接受 unsigned 包。详见「无线调试（Wi-Fi）」。
- `build-profile.json5` 里两个 product 都是 `targetSdkVersion: "26.0.0"`、`compatibleSdkVersion: "26.0.0"`：功能、行为变更与最低安装版本统一按 API 26，**只能安装到 7.0.0 及以上设备**，因此调用 API 26 接口不需要再包 `deviceInfo.apiAvailable('26.0.0')`。
- **API 26 起版本号写法变了**：26 及以上写成纯语义化字符串 `"26.0.0"`，不再是 `"6.1.0(23)"` 那种 `M.S.F(N)` 形式。
- 升级到 26 后已核过的行为变更：`shadow` 的 `radius: 0` 从“无阴影”变为“无模糊阴影”、Media Library `READ_IMAGEVIDEO` 只能读本地图库、`.kernel` 权限需 bin 显式声明——本项目均未触及（未用 `shadow`、未申请 `READ_IMAGEVIDEO`、手机应用无 bin 子进程）。
- 涉及相机与 USB 的验证仍然只能在真机上做。模拟器能跑界面，但 PTP、EXIF、相册保存这些必须真机确认，见「模拟器」。

## 目录结构

```text
StrollAndShoot/
├── AppScope/app.json5              # bundleName、版本号、图标
├── build-profile.json5             # SDK 6.1.0、products、signingConfigs（本地，未纳入版本控制）
├── code-linter.json5               # lint 规则
├── deploy.sh                       # 构建→签名→安装→启动（Linux 本地文件，未纳入版本控制）
├── entry/
│   ├── build-profile.json5         # 模块构建；CMake 配置在 externalNativeOptions
│   ├── src/main/
│   │   ├── module.json5            # ability、权限（INTERNET、LOCATION、APPROXIMATELY_LOCATION、KEEP_BACKGROUND_RUNNING、DETECT_GESTURE）
│   │   ├── ets/
│   │   │   ├── entryability/       # EntryAbility：窗口尺寸、避让区监听、加载 pages/Index
│   │   │   ├── pages/              # 页面、PTP 会话层、早期原型页
│   │   │   ├── components/         # 复用组件
│   │   │   ├── services/           # 单例服务
│   │   │   ├── model/              # 数据结构与持久化设置
│   │   │   ├── utils/              # 分组、画廊缩放的列数换算、组件坐标、窗口信息、标题栏尺寸
│   │   │   ├── workers/            # ImageDecoder：TaskPool 并发函数（不是 Worker 线程）
│   │   │   └── CustomTransition/   # 一镜到底转场：注册表 + PhotoMorph（共享照片层与几何换算）
│   │   ├── debug/                  # 仅调试包生效的虚拟 PTP 相机（MockPtpDevice / MockPtpSession）
│   │   ├── cpp/                    # NAPI 代码与 libentry.so 的类型声明
│   │   └── resources/              # base 为浅色，dark 为深色
│   ├── src/test/                   # Local Test：主机侧 ArkTS 单测，不需要设备
│   ├── src/ohosTest/               # Instrument Test：装到设备/模拟器上跑（仍是模板用例）
│   └── src/mock/                   # NAPI mock，让 Local Test 能跑依赖 libentry.so 的代码
└── hvigor/
```

## 构建与部署

### 测试

HarmonyOS 的测试分三层，本工程三层都已就位：

| 层 | 位置 | 运行位置 | 用途 |
|---|---|---|---|
| Local Test | `entry/src/test/` | 主机，**不需要设备** | 纯逻辑单测：分组、排序、键计算、时间解析 |
| Instrument Test | `entry/src/ohosTest/` | 设备/模拟器 | 真实 Ability、硬件与 UI 自动化（仍是模板用例） |
| NAPI mock | `entry/src/mock/` | 仅 Local Test | 用 ArkTS 假实现替换 `libentry.so` 的 13 个导出函数 |

框架是 Hypium（`describe` / `it` / `expect`）+ Hamock，都在根 `oh-package.json5` 的 `devDependencies` 里。

```bash
# macOS：根目录没有 hvigorw，用 DevEco 自带的那个，并且必须给 DEVECO_SDK_HOME
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw test -p module=entry -p coverage=false --no-daemon

# 只跑某个套件 / 某个用例
hvigorw test -p module=entry -p scope=PhotoGroupUtil
hvigorw test -p module=entry -p scope='PhotoGroupUtil#getExt 取最后一个点之后的部分并转大写'

# 带覆盖率
hvigorw test -p module=entry -p coverage=true
```

- `devecocli` **没有** `test` 子命令，测试只能走 hvigor。
- `hvigorw test` 在本机不要省 `--no-daemon`：不加时多次卡在 `Starting hvigor daemon`，只有后台 daemon 退出后才落结果；`--no-daemon` 通常十几秒完成。
- 结果文件：`entry/.test/default/intermediates/test/coverage_data/test_result.txt`，末尾一行是 `Tests run / Failure / Error / Pass`。
- `entry/src/mock/Libentry.mock.ets` 是模板生成的，曾经编译不过（三处无类型对象字面量，`arkts-no-untyped-obj-literals`），已改为先声明 `interface` 再返回。改动 mock 的返回值时必须保持这一点。
- Instrument Test 需要设备，且 `ohosTest` 的 HAP 要签名，本机模拟器装不了签名的包。

### 调试用的虚拟相机

模拟器没有 USB 主机，PTP 永远搜不到相机，画廊、预览器、共享元素转场这些纯 UI 功能因此无法验收。调试包内置了一台**虚拟 PTP 相机**，走的是与真机完全相同的流程：

| 文件 | 作用 |
|---|---|
| `debug/MockPtpDevice.ets` | 虚拟相机的“硬件”：USB 描述符、DeviceInfo、1 个 storage、`DCIM → 100MOCK / 101MOCK` 两层目录树、38 张照片的元数据，以及按 handle 现场编码出的 JPEG（缩略图 180×120，原图 1200×800） |
| `debug/MockPtpSession.ets` | `PtpTransport` 的第二个实现：`connect` / `getDeviceInfo` / `getStorageIDs` / `getObjectHandles` / `getObjectInfo` / `getThumb` / `getObject` / `getPartialObject`，每个调用带少量延迟让进度条可见。**`getObject` 固定 520ms/张**（靠近真实 USB 单张原图耗时）：之前 120ms 时 38 张几秒就传完，进度浮岛的下载中 / 保存中 / 完成三种状态根本来不及看 |

**`makeJpeg` 必须保持「一行渐变 + 逐行 memcpy」的写法**（2026-11-07 实测）：原先是 1200×800 逐像素写 RGBA，96 万次 JS 循环、每次 4 次写入，`hilog` 实测 **fill 就要 127–167ms，整张 130–175ms**，而且跑在 UI 线程上；打开一张照片会连续生成「当前 + 邻近预加载」好几张，真机上表现就是「一开图 / 一传输就卡」。改成先算一行（水平渐变）再 `u8.set(row, offset)` 复制后，fill 降到 **1–2ms**、整张 10–17ms（余下是原生的 `createPixelMap` + `packToData`）。日志里每次生成会打一行 `MockPtp: jpeg 1200x800 10ms (fill 1ms)`，改这块时先看这个数。

`PtpHost.ets` 里 `PtpSession` 与 `MockPtpSession` 共用 `PtpTransport` 接口，`CameraService.session` 声明为该接口，`scanForCamera()` 开头用 `syncSessionMode()` 按调试开关选实现。于是：

- 设置页最底部「调试（仅调试包可见）→ 模拟相机设备」打开开关；
- 到「相机」页点「搜索相机」，会走 **搜索 → 连接 → 取设备信息 → 首次连接询问是否启用缓存 → 遍历目录 → 取元数据 → 按行取缩略图** 的完整流程；
- 画廊里看到的是扫描结果，不是直接塞进去的数组；第二次点「快速扫描」会命中磁盘缩略图缓存（`[CACHE_HIT]`）；
- 预览器里的原图来自 `getObject()` 返回的真实 JPEG。

其它注意点：

- 是否调试包由 `bundleManager.getBundleInfoForSelfSync(...).appInfo.debug` 判定，release 包里设置项不渲染、`isEnabled()` 恒为 false。
- 未签名的 HAP 装到模拟器上同样返回 true，所以模拟器上可以正常用。
- 虚拟相机的身份是 `Mock_Virtual_PTP_Camera_MOCK-0001`，它的缩略图缓存会落到真实缓存目录里，可用于验证缓存与快速扫描。
- 开关状态持久化在 `SettingsStore.mockCameraEnabled`。改完开关或重装包后，需要重新到「相机」页点一次「搜索相机」。
- 验证完记得关掉开关，否则会与真实相机状态混淆。

### macOS

```bash
# 不需要环境变量，devecocli 自己找得到 DevEco Studio 里的 hvigor
devecocli build

# 清理。改动回退之后必须清理，否则可能命中旧产物
devecocli build clean

# 静态检查
devecocli check lint entry/src/main/ets
```

### Linux

```bash
# 环境变量（devecocli 必需）
export DEVECO_CLI_CLT_PATH=~/.hmos/command-line-tools
export DEVECO_CLI_SKIP_VERSION_CHECK=1

# 构建。输出比 hvigorw 简洁，clean 之后完整构建约 9 秒
devecocli build

# 等价命令
hvigorw assembleHap --no-daemon

# 清理。改动回退之后必须清理，否则可能命中旧产物
hvigorw clean --no-daemon

# 完整流程：构建 → 签名 → 安装 → 启动
bash deploy.sh full

# 只签名、安装、启动。代码有改动时不要用
bash deploy.sh run

# 静态检查
devecocli check lint entry/src/main/ets
```

### 通用

- 产物在 `entry/build/<product>/outputs/default/`：调试在 `entry/build/default/`，指定设备发布在 `entry/build/dist/`。`*-signed.hap` 已签名，`*-unsigned.hap` 未签名。
- macOS 上 `devecocli build` 会用 AgentDebug 签名；Linux 上仍由 `deploy.sh` 单独处理签名。
- `deploy.sh` 被 `.gitignore` 忽略，只存在于 Linux 开发机，里面写着签名材料的路径与口令。
- `entry/src/test` 已有真实单测（分组、键计算、GPS 合并/心跳/轨迹聚合/格式化/模拟图案等，共 29 个用例），`hvigorw test` 会实际执行；`entry/src/ohosTest` 仍是模板用例。

### 版本号

- `versionCode` / `versionName` 定义在 `AppScope/app.json5`：前者是整数（0~2147483647，只用于比较新旧，每次发布递增），后者是展示串，设置页「关于 → 版本」直接显示 `versionName`。
- **调试版必须在版本名里标明**：调试包用 `<版本>{debug}`（如 `1.17.1{debug}`），发布包用纯数字（`1.17.0`）。
- 只能这么写：`versionName` 只接受两种形态 —— ① 只有数字和点；② 同时包含 `{` 和 `}`、字符集为数字/字母/下划线/点/花括号。打包工具的校验正则是 `^[0-9.]+|(?=.*[{])(?=.*[}])[0-9a-zA-Z_.{}]+$`，所以 `1.17.0-beta`、`1.17.0 Debug`、`v1.17.0` 都不合法。`{debug}` 会**原样**显示在「关于」页，这是预期行为。
- 调试标记写在 **product 级** `build-profile.json5` 的 `products[]` 里，只配 `default`：

  ```json5
  { "name": "default", "signingConfig": "AgentDebug", "versionName": "1.17.1{debug}", ... }
  ```

  `AppScope/app.json5` 被两个 product 共用，写在那里会让发布包也带上 `{debug}`；`dist` 不要配 `versionName`，沿用 `app.json5` 的干净版本号。反过来（`app.json5` 写 `{debug}`、`dist` 覆盖）一旦忘了覆盖，发布包就会带调试标记，不要这么干。
- 升版本时改两处：`AppScope/app.json5` 的 `versionCode` / `versionName`，以及 `build-profile.json5` 里 `default` 的 `versionName`。Linux 上的 `build-profile.json5` 是另一份，别忘了同步。
- `versionCode` 不要拿来编码调试标记：它是整数，且每次升级必须严格递增。

### 签名与分发

- 签名材料分散在项目外，均不纳入版本控制：
  - 密钥库：`../KEYS/hmos_dev_key.p12`
  - 调试证书：`../CERTIFICATES/Agent_Debug.cer`
  - 发布证书：`../CERTIFICATES/Agent_RELEASE.cer`
  - 调试 Profile：`.profile/StrollAndShoot_DebugDebug.p7b`
  - 指定设备发布 Profile：`.profile/StrollAndShoot_Specific_ReleaseRelease.p7b`
- `.profile/` 已加入 `.gitignore`。
- 根目录 `build-profile.json5` 已从版本控制移除并加入 `.gitignore`；它只存在于各开发机本地，Linux 上需要单独维护一份（`deploy.sh` 依赖它）。
- 工程里有两个 product，签名与用途分开：
  - `default` → `AgentDebug`，日常调试。
  - `dist` → `AgentRelease`，指定设备发布。
- 构建命令：

  ```bash
  # 日常调试
  devecocli build

  # 指定设备发布
  devecocli build --product dist --build-mode release
  ```

- product 与 buildMode 是两个维度：只写 `--build-mode release` 仍会落到 `default`（AgentDebug），必须同时指定 `--product dist`。
- 已验证：debug 产物 Profile `type=debug`；dist 产物 `type=release`、`app-distribution-type=internaltesting`、`device-ids` 1 台。
- 当前开发阶段使用**调试证书 + 调试 Profile**。
- 正式上架 AppGallery 之前，个人使用阶段统一用**指定设备发布**方式分发：发布证书 + 指定设备发布 Profile。设备 UDID 必须在该 Profile 的 `device-ids` 列表内；可以 `hdc install` 直装，也可以把 HAP 与描述文件上传到自己的服务器后用 Deeplink 下载安装。
- 指定设备发布的版本有效期为 90 天，从设备首次安装算起；到期后递增 `versionCode` 重新打包部署。
- 正式上架 AppGallery 时改用**发布证书 + 发布 Profile**。
- 注意：`build-profile.json5` 里的签名密文与本机绑定，不要直接把带密文的配置提交给 Linux 使用，否则会报 `Unsupported state or unable to authenticate data`。

### 无线调试（Wi-Fi）

本项目最实用的部署通道：**手机的 USB 口要留给相机做 PTP**，只有 hdc 走 Wi-Fi 才能一边接相机一边部署看日志。2026-11-06 在真机 VYG-AL00 / 7.0.0.111 上完整跑通。

**手机端**：设置 > 系统 > 开发者选项 > **无线调试** 打开，页面上会显示 `IP:端口`。端口随开关变化，**每次重开会变，不要写死**。首次连接手机会弹「允许调试」，必须点允许，否则设备一直停在 `Unauthorized`。

**电脑端**：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
T=192.168.1.23:42135          # 换成手机上显示的 IP:端口

$HDC tconn $T                 # 返回 Connect OK
$HDC list targets -v          # 状态从 Unauthorized 变 Connected 才算通
$HDC tconn $T -remove         # 断开

devecocli build
$HDC -t $T install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC -t $T shell aa force-stop io.github.shaoyuanyu.strollandshoot
$HDC -t $T shell aa start -a EntryAbility -b io.github.shaoyuanyu.strollandshoot
```

- **必须带 `-t`**：`hdc list targets` 里常年挂着一个 `127.0.0.1:5555 Offline` 的模拟器残项，不带 `-t` 就报 `ExecuteCommand need connect-key`。
- **`hdc discover` 在本机所在办公网无效**：实测 `Broadcast find daemon, total:0`。ARP 表里大量 `0:0:5e:0:1:2` 是代理网关，说明开了客户端隔离，广播包过不去。只能手工 `tconn IP:端口`。
- 装包实测 **1.4 秒**，比 USB 慢但可接受；`-r` 覆盖安装保留数据。
- 锁屏、切网会让连接变 `Offline`，重新 `tconn` 一次即可。
- **`Unknown` / `Offline` 先怀疑 hdc server 残留，不要先改端口或配对方式**（2026-11-07 实测）：手机端口能 `nc` 通、`hdc tconn` 却返回 `Target is connected, repeat operation`，`list targets -v` 显示 `Unknown`/`Offline`；`lsof -nP -iTCP:<手机端口>` 能看到本机 hdc 的 TCP 连接停在 `SYN_SENT`。执行 `hdc kill -r` 重启 server，再 `tconn`，立即返回 `Connect OK`。官方《hdc》也把 `hdc kill -r`、等待通道建立（约 10 秒）列为首要排查手段。
  - 如果 `kill -r` + 重连仍停在 `SYN_SENT`，再怀疑办公网/路由器的客户端隔离或 VPN；换手机热点或 USB。`ping` 通不代表调试端口可达。
  - 安卓无线调试有独立的**配对端口**和**连接端口**（`adb pair` 与 `adb connect`），拿配对端口去 connect 会一直挂起；**鸿蒙 hdc 官方流程没有独立配对命令**，不要因为安卓经验去反复换端口，先重启 hdc server。
  - 参考：[hdc 官方指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hdc)、[华为开发者问答：hdc 连接设备失败排查](https://developer.huawei.com/consumer/cn/forum/topic/0208227365283665099?fid=0109140870620153026)。

**读日志 / 截图**：

```bash
# hilog 必须带 -x，否则会一直阻塞
$HDC -t $T shell "hilog -x -T AppLog"
$HDC -t $T shell "hilog -x -T ThumbnailCache"

# 应用自己的日志文件
$HDC -t $T file recv \
  /data/app/el2/100/base/io.github.shaoyuanyu.strollandshoot/haps/entry/files/app_log.txt \
  /tmp/app_log.txt

# 界面验收
$HDC -t $T shell snapshot_display -f /data/local/tmp/w.jpeg
$HDC -t $T file recv /data/local/tmp/w.jpeg /tmp/w.jpeg
```

**断点调试**：hdc 本身不带调试器。断点仍走 DevEco Studio 的 `Tools > IP Connection`（6.1.1 起）或设备下拉框里的 IP Connection，输入同一个 `IP:端口`，再用 Debug 启动。

**坑：首次启动可能被应用市场管控拦截**

装完第一次 `aa start` 可能报：

```text
error: failed to start ability.
Error Code:10106105  Error Message:The target application is under control.
Error cause: The application is suspected of malicious behavior and is restricted from launching by the appStore
```

而且此时 `bm dump -a` 里**查不到这个包**——安装返回了成功，但包被管控策略清掉了。重新 `install -r` 一次即可恢复。遇到启动被拒时先确认包还在不在，别急着怀疑代码：

```bash
$HDC -t $T shell "bm dump -a" | grep stroll
```

## 架构

### 导航

- `pages/Index.ets` 是唯一入口（`@Entry`），内部用 ArkUI 原生 **`Navigation`** + `NavPathStack`，隐藏系统导航栏（`hideNavBar(true)`），并注册自定义转场 `customNavContentTransition`。
- `route_map.json` 注册 NavDestination：`MainScreen`、`PhotoViewerScreen`、`GpsManagementPage`、`GpsTrackViewerPage`、`CacheManagementPage`。
- `MainScreen` 承载三个标签页（画廊 / 相机 / 设置）。底部是系统 `Tabs` 的**悬浮页签**：只设 `barOverlap(true)` + `barFloatingStyle({ barBottomMargin: this.navIndicatorVp(), maskColor: Color.Transparent, systemMaterial: new uiMaterial.ImmersiveMaterial({ style: REGULAR, interactive: true }) })`。**不要**再设 `barBackgroundColor` / `barBackgroundBlurStyle`（会盖住材质），也不要设 `barMode` / `scrollable`（会破坏悬浮样式的默认布局）。`barHeight` 只在多选态动态置 0。
- **不要用 HDS 的 `HdsNavigation` / `HdsNavDestination`**：2026-11-06 试过又全部退回。官方《沉浸光感》写明 HDS 的 `systemMaterialEffect` 只给**标题栏按钮**材质，背板永远拿不到沉浸光感，轻划时看着就是全透明。
- 一级页标题栏是 `.title({ builder: this.TitleBar, height: titleBarInsetVp() }, { barStyle: BarStyle.STACK })` 自定义 builder；缓存管理等轻量二级页仍用 `.hideTitleBar(true)` + `components/PageHeader.ets`（自己避让状态栏）；定位记录页与轨迹全屏页改用原生 `.title()` 标题栏，返回/选择/日期胶囊才能拿到真材质；预览器 `.hideTitleBar(true)` 自己全屏。
- 首屏内容避让用**滚动容器的 `contentStartOffset(titleBarInsetVp())`**（不是 `padding-top`），详见「沉浸光感 > 顶部标题栏」。
- **底部要给悬浮页签留空间，但不能用 `List.padding({ bottom })`**：那会收缩 List 的可视区域，内容在胶囊上方就被裁断、中间露出一条空带。正确做法是给 List 末尾加一个 104vp 占位项（`FlatItem.tail()`）；`Scroll` 页面（相机 / 设置）用内容末尾的 `padding-bottom` 即可。
- 二级页（缓存管理、定位记录、轨迹全屏）都走 `route_map.json` 的 NavDestination，用 `NavPathStack.pushPath` / `pop`，不是 `@Entry`，也不再用 `router.*`。
- 轨迹全屏页用 `BarStyle.STACK` 自定义标题栏，地图内容可以延伸到标题栏下方；`hideBackButton(true)`，否则系统返回键会和自定义返回键叠成两个。

### 状态管理

只用 ArkUI V2。V1 装饰器（`@State`、`@Prop`、`@Link`、`@StorageLink`、`@StorageProp`、`@Provide`、`@Consume`、`@Observed`、`@ObjectLink`、`@Track`、`@Watch`）禁止出现在新代码里。

| V2 写法 | 说明 |
|---|---|
| `@ComponentV2` | 所有组件都用它，替代 `@Component` |
| `@Local` | 组件内部状态，替代 `@State` |
| `@Param` | 父组件传入的只读参数，替代 `@Prop` |
| `@Param @Once` | 父组件初始化、子组件可改写 |
| `@Event` | 子组件向父组件回调 |
| `@Provider()` / `@Consumer()` | 跨层数据共享，替代 `@Provide` / `@Consume` |
| `@ObservedV2` | 类可观测，替代 `@Observed` |
| `@Trace` | 属性级跟踪，替代 `@Track` |
| `@Monitor` | 异步变更监听，回调参数是 `IMonitor`，用 `monitor.value(path)?.before` / `?.now` 取旧值和新值 |
| `@SyncMonitor` | API 23 起的同步版 `@Monitor` |
| `@Computed` | 记忆化计算属性 |
| `@Builder` | 保留自 V1，与 V2 兼容 |
| `Repeat` | 列表渲染，替代 `ForEach`。需要懒加载时用 `Repeat(data).virtualScroll()`，这是 `LazyForEach` 的官方迁移写法 |
| `AppStorageV2.connect()` | 应用级响应式共享，替代 `AppStorage` / `@StorageLink` |
| `PersistenceV2.globalConnect()` | 应用级持久化状态，替代 `PersistentStorage.persistProp` + `@StorageLink` |
| `!!` | 双向绑定，替代 `$$` |

**数据流**：`CameraService` 是 `@ObservedV2` 单例，`photos`、`photosVersion`、`thumbnailVersion`、`scanning`、`connected`、`statusText`、`lastDecodedHandle` 等字段带 `@Trace`。页面用 `@Local svc: CameraService = CameraService.getInstance()` 直接持有，读到 `@Trace` 字段就会自动刷新。跨页面传递的状态（下载进度、已下载集合、GPS 状态）由 `MainScreen` 用 `@Param` 下发，子页面用 `@Event` 上报。持久化设置放在 `SettingsStore`（`@ObservedV2` + `PersistenceV2.globalConnect()`），任何组件直接取单例。

**注意**：`thumbnailPixelMapMap`、`orientedDisplaySizes`、`compressedCache` 是普通 `Map`，不参与自动追踪。界面能刷新依靠 `thumbnailVersion`、`lastDecodedHandle`、`photosVersion` 这类手工计数被 `build()` 读到。改动缩略图与原图加载逻辑时，必须同时维护这些计数。

**两个必须记住的刷新坑**（2026-11-05 实测）：

1. `Repeat` 命中相同 key **不会重跑 `each`**。把 `Image(pm)` 直接写在 `@Builder` 里，缩略图解码完成后单元格会永远停在占位图。正确做法是把单元格内容抽成独立 `@ComponentV2`（见 `GalleryPage.ets` 末尾的 `ThumbImage`），并在 `build()` 里调 `svc.thumbForRender(handle)`——该方法内部先读一次 `thumbnailVersion`，从而让组件订阅材质变化（Map 本身不可观测）。
2. `@Builder` 的**值参数不会刷新**。例如 `WideChip(label, selected, onTap)` 这种写法，点击后 `selected` 变了但高亮不跟随。凡是会变化的状态，都要在构建期直接读（`this.settings.darkMode === ...`），不要经由 `@Builder` 形参传入。

### Native bridge

`libentry.so` 暴露的函数，类型声明在 `entry/src/main/cpp/types/libentry/Index.d.ts`：

- 命令构造：`buildOpenSession`、`buildCloseSession`、`buildGetDeviceInfo`、`buildGetStorageIDs`、`buildGetObjectHandles`、`buildGetObjectInfo`、`buildGetThumb`、`buildGetObject`、`buildGetPartialObject`
- 响应解析：`processResponse`、`parseDeviceInfo`、`parseStorageIDs`、`parseObjectHandles`、`parseObjectInfo`

`processResponse(data, expectData)` 负责累积多包 USB 数据，返回动作码：`0` 数据还在累积（继续读），`1` 拿到数据包，`2` 拿到响应包（`responseCode` 为 `0x2001` 表示成功）。

### 资源

- `$r('app.type.name')` 从 `entry/src/main/resources/` 解析。浅色在 `base/element/`，深色在 `dark/element/`。
- 颜色资源成体系，共 34 条（`base/element/color.json` 与 `dark/element/color.json` 各一份），命名如 `primary`、`bg_page`、`bg_surface`、`text_primary`、`text_secondary`、`text_tertiary`、`divider`、`card_border`、`primary_soft`、`scrim`、`nav_bg`、`tab_bar_bg`、`glass_bg`、`sheet_bg`、`progress_track`。设计语言为 HarmonyOS 沉浸光感：冷灰页面底、纯黑/白卡片、品牌蓝 `#0A59F7`（深色 `#4C91FF`）只用于主行动与选中态、底栏与预览器标题栏使用半透明模糊材质。新增界面一律引用资源，不要写定颜色值。
- `base/element/string.json` 有 36 条字符串，代码里没有任何引用，界面文案直接写在组件内部。
- 颜色模式跟随系统：`COLOR_MODE_NOT_SET`（值为 -1）表示不设置，`COLOR_MODE_LIGHT` / `COLOR_MODE_DARK` 为显式指定。

### 沉浸光感

- **应用级开关**在 `entry/src/main/module.json5` 的 `metadata`：`{ "name": "ohos.arkui.UIMaterial.state", "value": "enable" }`。开启后 `Toggle` / `Slider` / `Select` / 弹窗类组件在全页面生效，其余组件只在 Navigation/NavDestination 标题栏与底部 TabBar 生效。
- **`bindSheet` 不跟随应用级开关**：半模态的沉浸光感必须通过 `SheetOptions.systemMaterial` 显式设置（本项目用 `THICK`），设置后不要再设 `backgroundColor` / `blurStyle`，否则会盖住或重复处理材质。轨迹明细面板就是靠这一条拿到系统材质。
- **底部页签**：`Tabs.barFloatingStyle({ barBottomMargin: navIndicatorVp(), maskColor: Color.Transparent, systemMaterial })` + `barOverlap(true)`（`vertical(false)`、`barPosition: End` 为默认），不要同时设置 `barBackgroundColor` / `barBackgroundBlurStyle`，否则会遮挡材质。
  - **底边距必须自己算**：窗口是 `setWindowLayoutFullScreen(true)`，Tabs 是全屏的，`barFloatingStyle` 不会自动避让手势条。`barBottomMargin: this.navIndicatorVp()` 才让胶囊底边正好贴在手势条避让区上沿；写成固定的 10 会让胶囊压在手势条上（官方图库也是这么摆的）。
  - **实测（2026-11-06，模拟器 Mate 80 + 真机 VYG-AL00）**：只写 `systemMaterial` 时，两边都能正确呈现磨砂透明，内容从胶囊下面透出且带模糊与折射。
  - **踩过的坑**：一度以为"模拟器渲染不出材质"，其实是同时设了 `barBackgroundColor` + `barBackgroundBlurStyle`，把材质整个盖住了。**只要这两个属性还在，材质就一定看不到**——不是设备能力问题。排查时先确认没有别的东西压在上面。
- **顶部标题栏 = 大标题浮层 + 浮动玻璃控件 + 渐隐遮罩**（2026-11-06 对照官方「备忘录」逐帧校准）。官方形态**不是**一条通栏材质背板：
  1. 顶部只有**独立的浮动玻璃控件**（圆形钮 / 胶囊），它们之间是纯页面底色，看不到任何"条"；
  2. 大标题是**纯文字浮在内容上**，内容滑到标题后面时被**平滑压淡**——`linearGradient` 用 4 档压色（`nav_bg` 77% → `nav_bg_mid` 55% → `nav_bg_weak` 20% → `bg_page_fade` 0%）做缓出，衰减一直延伸到标题下方 28vp（`TITLE_FADE_EXTRA`）。**不要**做成「上不透明 → 下全透明」（内容被抹掉），也**不要**做成均匀一块压色（看着像一条带子）；标题要停在渐隐区**顶部**（状态栏下方），不要压在渐隐区底边；
  4. 压色之外还要一点点**磨砂**，但**不能用 `backdropBlur`**：它的边界是硬的，标题栏下边缘会留下一条泾渭分明的横线（2026-11-06 实测，用户一眼看出来）。正解是给**内容容器**加 `linearGradientBlur(96, { fractionStops: [[1, 0], [0.9, 0.06], [0, 0.18]], direction: GradientDirection.Bottom })`——模糊强度连续衰减到 0，天然没有边界；
  3. 玻璃控件用 `uiMaterial.ImmersiveMaterial`（`ULTRA_THIN` + `interactive: true`），与底部页签同一套材质，且与滚动无关、常驻。
  - 实现：`MainScreen.TitleBar` = `Stack` 里「一整块 `linearGradient` 渐隐层」+「底部 56vp 的一行：28fp 大标题 + 右���两颗玻璃胶囊」，`.title({ builder, height: titleBarInsetVp() }, { barStyle: BarStyle.STACK })`。
- **材质只在「Navigation/NavDestination 标题栏」或「横向 Tabs 且 barPosition: End 的底部 TabBar」里生效**（官方《组件适配沉浸光感》）。写在内容区不生效——所以胶囊必须画在 `title({ builder })` 里，不能挪到页面内容里。
  - 例外是官方「按钮与选择类」里明确列出全页面生效的 `Select` / `Toggle` / `Slider`：`Select`、`Toggle(Switch)`、`Slider` 在内容区也能拿到真材质（应用级开关已开时默认生效）。`Button`、`ChipGroup`、`SegmentButton` **不行**，内容区里只能写成普通胶囊。所以设置页的选项控件用 `Select` + `Toggle`，相机页的主操作用标题栏胶囊。
  - `Select` 的按钮文字只认 `value()`，`selected()` 只控制菜单里的选中态；只给 `selected()` 会渲染成一个**只有箭头、没有文字**的空胶囊。设置页的 `SettingSelectRow` 就是因此才单独取了 `selectedLabel()`。
- **内容区的浮动卡片拿真材质：挂进标题栏 builder，再用 `position` 画到目标位置**（2026-11-06 突破）。这是目前唯一同时满足「真材质 + 不挡交互」的做法，下载进度浮岛与多选底部操作栏都这么干：
  - 在 `MainScreen.TitleBar` 的 `Stack` 里加一层「浮岛层」，把组件写成它的子节点；
  - 外面包一层 `Column` 承载 `.position({ top, left/right })` 与 `.systemMaterial(this.floatMaterial)` —— **自定义组件不能直接链式挂通用属性**（会报 `does not meet UI component syntax`），必须包容器；
  - `position` 的原点是标题栏顶部（= 屏幕顶部，因为 `windowLayoutFullScreen`），所以可以直接用屏幕绝对 vp 坐标（`WindowUtils.windowHeightPx` 换算）；
  - **标题栏容器不裁剪超出边界的子节点**，所以能画到屏幕中部和底部；材质照样生效，且**不会拦截其他区域的点击**（实测点「全选」、点缩略图、滚列表都正常）。
- **不要试图用弹层（popup / tips / dialog）在内容区拿材质 —— 它会吞掉整页点击**（同日实测，试过又退回）。官方确实把 `Popup控制` / `Tips控制` / `菜单控制` / `半模态转场` / `PromptAction` 列为「沉浸光感可在全页面生效」的接口，`bindPopup` + `CustomPopupOptions.systemMaterial` 也真能渲染出材质（折射、高光都对）。但**弹层一显示就铺一层全屏遮罩**：点标题栏「全选」、点缩略图、滚动列表全部失效；`autoCancel: false` + `focusable: false` + `levelMode: LevelMode.EMBEDDED`（需 `import { LevelMode } from '@ohos.promptAction'`）都救不回来。
- **兜底方案**（万一标题栏壳子走不通）：`backgroundColor(glass_bg)`（55% 白/黑）+ `backgroundBlurStyle(BlurStyle.COMPONENT_THICK)`，官方 FAQ 的降级做法。但观感明显不如真材质，只在真材质不可用时用。判断依据看日志：`Material inactive: out of scope. Use component in navigation title bar or Tabbar.`
- **HDS 的 `HdsNavDestination.titleBar` 拿不到背板材质**：官方原文「可为**标题栏按钮**设置沉浸光感视效」，轻划时整条标题栏会变成全透明（踩过）。所以本项目用 ArkUI 原生 `Navigation` / `NavDestination`，不用 HDS 导航组件。
- **标题栏要延伸到状态栏**：`EntryAbility` 里 `setWindowLayoutFullScreen(true)`，`applyThemeSystemBars` 把 `statusBarColor` 设成透明；标题 builder 的渐隐层自然铺到最顶，标题文字靠 `Stack` 的底部对齐停在状态栏下方。
- **`Navigation` 上不要再加 `ignoreLayoutSafeArea(TOP)`**：加完 `NavDestination` 的标题栏会被整个推出可视区，直接消失（2026-11-06 实测）。
- **`NavDestination` 上不要再加 `bindToScrollable`**：它的语义是「上滑隐藏、下滑显示」标题栏，一滚标题栏就没了。
- **`enableComponentSafeArea` / `avoidLayoutSafeArea` / `titleBar(...)` / `systemMaterialEffect` 都是 HDS 专有**，ArkUI 的 `NavDestination` 没有这些，别混用。
- **材质可用性**：`uiMaterial.isImmersiveMaterialSupported()` 为 `true`、`getGlobalMaterialLevel()` 为 `EXQUISITE` 时材质可正常渲染（模拟器与真机均验证过）。判断依据是**胶囊背后有没有被模糊的内容**，不是胶囊的底色。
- **功耗约束**：不要在大面积容器上用材质，不要与 `backgroundBlurStyle` / `backgroundEffect` 叠加，同一子树只设一次；算力档位交给 `MaterialLevel.ADAPTIVE` 或系统自适应。

## 多选模式

2026-11-06 对照顶行官方图库（`com.huawei.hmos.photos`）逐像素校准过一轮，形态与实现要点如下。

**标题栏**（`MainScreen.SelectTitleRow`）：左叉 40vp 圆形玻璃钮（`sys.symbol.xmark` + `systemMaterial`）→ **左对齐** 22fp 粗体标题「已选择 N 项」（**不要居中**，那是上一版的错误做法）→ 右侧 40vp 高玻璃胶囊「全选 / 取消全选」。外层 `Row` 左右内边距 16vp，与浏览态大标题对齐。

**底部操作栏**（`components/SelectionActionBar.ets`）：悬浮胶囊，图标在上（24fp）、文字在下（10fp），与底部页签的 `TabItem` 尺寸一致；宿主 `MainScreen.TitleBar` 的浮岛层负责 `position` 与 `systemMaterial`。

**位置**：操作栏胶囊 **高 56vp**，`top = screenHeightVp() - navIndicatorVp() - 56`，宽 96vp 水平居中。页签栏是 `barBottomMargin: navIndicatorVp()`、高 56vp —— 两者在屏幕上完全同一矩形（实测都是 `[*,2538][*,2734]`），切换多选态时下沿不会跳。

**页签栏在多选时隐藏**：`.barHeight(this.gallerySelectMode ? 0 : 56)`。实测 `barHeight(0)` 对悬浮样式的页签栏有效，置 0 后 `barFloatingStyle` 的材质与圆角一并消失、操作栏可以占据同一位置；恢复 56 后悬浮样式正常。**这是唯一需要动态改 `barHeight` 的场景**，其他时候不要碰它。

**选中态**：与官方图库一致，**不加遮罩、不加描边**（早期版本用 `primary_soft` 蒙一层淡蓝 + 左上角勾选，都是错的）。勾选圆点 20vp，在单元格 **右下角**、内缩 4vp：选中实心蓝 + 白勾，未选半透明黑 + 1.5vp 白描边。已下载的照片不可选，只在 **右上角** 留一个绿点（`status_connected`，10vp），**不要再给整张缩略图描一圈绿框**。

**日期标题（含整组全选）**：官方图库在多选态的每个日期标题 **右侧** 放一个 20vp 圆形勾选（不是「全选当天」文字胶囊）。三态：未选 = 空心细圈（`text_tertiary` 1.5vp）、部分选中 = 实心蓝 + 白色横线、全选 = 实心蓝 + 白勾；热区用 `responseRegion` 扩到 44vp。点击调 `toggleSelectDate(dateKey)` 整组切换。

**数据流**：选中集在 `GalleryPage`，标题栏在 `MainScreen`，靠一组计数与 `@Monitor` 双向打通：

- 上行：`@Event onSelectionStats(selected, selectable)`，`GalleryPage` 每次增删选中项后调 `syncSelectionStats()`
- 下行：`@Local selectAllVersion` 递增 → `GalleryPage` 的 `@Monitor('selectAllVersion')` 执行 `toggleSelectAll()`
- 退出：`@Local exitSelectModeVersion` 递增 → `GalleryPage` 清空选中集

**新增选择入口时别忘调 `syncSelectionStats()`**，否则标题栏数量与全选态不会更新（`toggleSelectAll` / `toggleSelectDate` / 长按进多选 / 单击切换 / 退出 / 下载完成，六处都要）。

## 页面

### Index.ets
导航根与初始化。设置日志路径与下载目录、初始化 `GpsRecorder`、把 `AppLog` 交给 `PtpHost` 与 `ExifGeotagger`、监听深色模式设置并调用 `setColorMode`，最后把 `MainScreen` 作为首个目的地压入 `NavPathStack`。

### MainScreen.ets
NavDestination，标签页容器。持有标签状态、下载进度、已下载集合、GPS 开关状态、选择模式。订阅 `cachingDialogRequired` 弹出“发现新相机”对话框。点击缩略图时取该缩略图的屏幕矩形（`getRectangleById('thumb_<handle>')`，px）与附近 81 个单元格的位置缓存，连同 `positionLookup` 回调一起作为 NavPathStack 参数传给预览器，再 `pushPath('PhotoViewerScreen')` 触发一镜到底转场。缩略图位图不必传：预览器自己从 `svc.thumbnailPixelMapMap` 取。返回键在选择模式下先退出选择模式。标题栏是自己写的 `@Builder`（`NormalTitleRow` / `SelectTitleRow`）：大标题 + 右侧玻璃胶囊（格式筛选是 `Select` 下拉、加一颗「选择」胶囊），材质用通用属性 `systemMaterial`。

### GalleryPage.ets
- 网格对齐官方图库：**默认 3 列**（设置里可改 4/5/6）、**贴边无页边距**、间距 2vp、**直角无圆角**、缩略图上**不叠时刻角标**。两指缩放（0.4x–6.0x）时列数随之重算
- **捏合缩放只允许改「列数」，且只在跨档时改**：单元格是 `layoutWeight(1)` + `aspectRatio(1)`，视觉尺寸只由列数决定，倍数在同一档内连续变化不产生任何视觉差异。所以 `pinchScale` 是**普通字段**（逐帧更新不触发重建），只有列数跨档才写 `@Local appliedColumns`。**不要**把缩放倍数写成 `@Local`——那会让每个捏合事件都重建整页，实测 728 次事件只该换列十几次（日志 `PERF pinch: updates=…, columnChanges=…`）。列数/间距的换算在 `utils/GalleryZoom.ets`，有 Local Test（`GalleryZoom.test.ets`）
- 行模型**不依赖 `thumbnailVersion`**：缩略图到达时只有 `ThumbImage` 自己重建。以前把 `thumbnailVersion` 编进 `buildFlatItems()` 的缓存键，扫描时每 4 张缩略图就重排一次全量行模型，纯浪费
- 按拍摄日期分组，标题文案对齐官方：`今天` / `昨天` / `11月6日` / `2025年11月6日`，没有拍摄日期的归入「未知日期」。分组键是 `YYYYMMDD` 原始串，显示文案由 `dateHeaderLabel()` 换算
- 日期标题：左侧 16fp 粗体、上下各 24vp 留白、左右 16vp；多选态右侧多一个整组勾选圆圈（三态，见「多选模式」）
- 格式筛选是标题栏右侧的 `Select` 下拉（选项 = 全部 + 照片里出现过的扩展名，只在“文件优先”模式下出现）。**不要**再做成「点一下轮换到下一个格式」的循环按钮 —— 用户猜不到下一下会到哪，设计很差
- 长按进入多选（或点标题栏的「选择」胶囊）。多选态标题栏左叉 + 左对齐「已选择 N 项」+ 全选胶囊，底部悬浮胶囊操作栏只有「下载」一项。详见「多选模式」
- 缩略图按整行显示：一行（当前列数）全部解码完成才同时出现，否则该行显示占位
- `buildFlatItems()` 把日期标题与行拍平成一个数组交给 `Repeat` + `.virtualScroll()`，按 `photosVersion`、显示模式、筛选值、**当前列数**、宽度做缓存。日期分组另外缓存在 `ensureGrouping()` 里（只依赖照片与筛选）：捏合换列只需要重新分行，不要再扫一遍全量照片
- 缩略图单元格抽成独立 `@ComponentV2 ThumbImage`，内部调 `svc.thumbForRender(handle)` 建立 V2 依赖（原因见「状态管理」里的两个刷新坑）
- 末尾有 `FlatItem.tail()` 占位项（104vp），给悬浮页签留滚动空间；`ListItem` 的 `key` 必须保持稳定，把「行是否加载完成」编进 `key` 会让 `virtualScroll` 的复用项失效、整行渲染成空白
- `List` 用 `.contentStartOffset(this.listTopInset())` 让首行避开 HDS 标题栏，并设 `.clip(false)` + `.cachedCount(6, true)` 让滚动中的照片能穿到标题栏下方被模糊；扫描横幅显示时它自己就在内容顶部，此时 `listTopInset()` 归零（原因见「沉浸光感 > 顶部标题栏」）

### CameraPage.ets
- 主操作（未连接 → 「搜索相机」，已连接 → 「快速扫描」，扫描中 → 「扫描中」）在**标题栏**右侧的玻璃胶囊里（`MainScreen.NormalTitleRow` 的 `currentTab === 1` 分支）：内容区的 `Button` 拿不到材质，标题栏里的才能。胶囊不设 `backgroundColor` / `materialColor` 时材质取 Button 主题色，文字用 `text_on_primary`。
- 内容区只有三张 24vp 圆角白卡：状态卡（连接状态、相机名、扫描进度与统计）、设备信息卡（9 行 52vp）、操作卡（全量扫描 + 红色断开连接）。未连接时状态卡换成空态卡（图标 + 说明 + 指向右上角「搜索相机」）。
- 根节点 `Scroll` 用 `.contentStartOffset(titleBarTotalVp())` 避让标题栏。

### SettingsPage.ets
- 分组卡片统一 24vp 圆角、无描边、行高 56vp；分组标题 13fp 次级色。
- 选项类（深色模式 / 默认列数 / 显示模式 / 记录频率）全是**右侧 `Select` 玻璃胶囊**（`SettingSelectRow`），不要再用自制的「灰底 + 蓝胶囊」分段按钮——那东西在内容区拿不到材质。
- 开关（GPS 记录、模拟相机）用 `Toggle(Switch)`，**不要设 `selectedColor`**，否则会覆盖系统预设的沉浸光感样式。
- 导航类行带 `chevron_right`（定位记录管理、缩略图缓存）。删除定位记录统一放在「定位记录管理」页（多选批量删除，或全屏轨迹页「更多」里删当天），设置页不再提供「清除定位记录」入口，避免误触。
- 调试日志面板仍是等宽字体、高 240vp，只在调试包里渲染。
- 调试区新增「模拟 GPS 轨迹」开关：以当前定位为起点生成相机图案，覆盖今天的地图/列表显示；真实 `gps_records.jsonl` 不变，关掉开关立即恢复。仅 debug 包可见。

### PhotoViewer.ets
预览器，一个文件里有五个结构：`ZoomState`、`ZoomLayer`、`ZoomableImage`、`MainImageView`、`ThumbCellView`、`PhotoViewerScreen`。

- `ZoomableImage`：单张图片的缩放与拖动。捏合用 `pinchCenterX/Y`（屏幕绝对坐标）计算锚点；拖动位移要乘缩放倍数换算回屏幕空间；捏合期间 `PanGesture` 会持续累计位移，必须记录并在捏合结束后扣除，否则松手时会跳变。缩放范围 1x–5x，双击在 1x 与 2.5x 之间切换。捏合与拖动都要接 `onActionCancel`（来电、三指会取消手势），否则页面会永远停在「捏合中」。
- **逐帧变化的缩放值必须放在 `ZoomState`（`@ObservedV2` 的 `@Trace scale/x/y`）里，由叶子组件 `ZoomLayer` 订阅，`ZoomableImage` 自己不许再持有 `@Local scaleVal/offX/offY`**：一旦把这三个值写成 `ZoomableImage` 的 `@Local`，每个捏合事件都会重跑它的 `build()`，`GestureGroup` + 3 个手势连同 `PanGesture` 的触发距离每帧重建并重新绑定——这是预览器缩放卡顿的根因（2026-11-07）。`ZoomableImage` 里只保留一个 `@Local zoomed`，它只在 1x 边界翻转时才变，用来切换 `PanGesture` 的 `distance`（1x 时 80vp，让主 Swiper 先接管滑动；放大后 3vp）。
- `MainImageView`：主图容器，叠加加载指示与扫描进度横幅。**每张照片的状态是 `PhotoRenderState`（`@ObservedV2`，`@Trace fullPm/loading/photoW/photoH`），页面通过一张普通 `Map` 拿到它再传进来，页面自己绝不能在 `build()` 里读这些字段**：否则任何一张图解码完成都会重建整页（标题栏 + 两个 Swiper + Repeat 全量 diff）。后台每解完一张邻近照片就卡一下，就是这么来的。
- `fullResMap`、`loadingHandle` 必须是**普通字段/普通 Map**，`thumbnailPixelMapMap` 也是普通 Map；界面刷新靠 `PhotoRenderState` 和 `MainImageView` 内部读 `svc.thumbnailVersion`。
- 缩放/翻页期间主图每帧都在动，标题栏与缩略图条的 `backgroundBlurStyle` 会跟着每帧重算（渲染成本高）。`chromeMotion` 为真时换成半透明纯色（`chromeBg()` / `chromeBlur()`），静止时恢复模糊。捏合、`onGestureSwipe`、缩略图条滑动都要切换它，且只在状态翻转时写 `@Local`。
- `updateScales()` 只在值真的变化时写 `scaleArr/offsetArr`，并且**不要再引入逐帧变化的 `thumbFrac`**：`@Local` 数组每次赋值都会通知订阅者，逐帧全写会让窗口内 11 个缩略图单元格反复重算并重启自身的 150ms 动画。中间项的选中高亮由 `scaleArr[i] >= MAX_S` 判定。
- `ThumbCellView`：底部缩略图条的单元。
- `PhotoViewerScreen`：**打开时调用 `svc.suspendNeighborPreload()`，关闭时 `resumeNeighborPreload()`**（并把 `loadingPaused` 置真）：预览器自己有一套「当前优先、前后各 3 张」的串行加载队列，后台再跑一套邻近预加载只会在串行的 USB 管道上插队，把用户正在等的那张拖慢——2026-11-07 实测手机上预览期间每秒都有 `预加载[N]` 时，第一次开图要 1.0–1.4s，挂起后回到 0.5s（mock 的固定 520ms）。
- `PhotoViewerScreen`：NavDestination。主 `Swiper` 与缩略图 `Swiper` 双向联动（`startFakeDrag` / `fakeDragBy` 同步），主图滑动带惯性，缩略图中心项放大到 1.3x。原图按“当前照片优先，前后各 3 张”排队串行加载，手势期间暂停；预加载结果只写普通 Map，等翻到那张时再由 `presentCached()` 挂到渲染状态上。淘汰时 `PixelMap.release()` 要 `setTimeout(0)` 延后，不要正好压在手势中间。返回时用当前照片的缩略图更新共享元素，保证转场起点正确。
- 一次捏合结束会打两行性能日志：`ViewerPerf pinch updates=…, frames=…, fps=…, lateFrames=…, gapMax=…ms, workMax=…ms`（hilog，tag `ViewerPerf`）与 `PERF viewer pinch: swiperScrolls=…`（AppLog）。fps 掉 / gapMax 大 = UI 线程被拖住；fps 正常但不跟手 = 渲染侧。

#### 一镜到底转场（2026-11-07 重写，对齐官方图库）
官方图库的观感是三条独立的动作，**不是**「整页从缩略图放大」：
1. **只有照片在动**：起于被点缩略图单元格的矩形（方图、`Cover` 居中裁切），终于照片在预览器里的实际显示矩形（`Contain` 等比放入图片区域）。因为一直用 `Cover` 画，矩形从方图长到照片比例的过程天然就是「从中心裁切逐渐露出全图」，落位时矩形比例 == 照片比例，`Cover` 与 `Contain` 完全重合，可以无缝交还给页面内容。
2. **背景 180ms 压到纯黑**；3. **标题栏与缩略图条在照片快落位时才淡入**（220ms 起、200ms 淡完），返回时反过来先淡出 140ms，再收照片。

层级（都在 `PhotoViewerScreen` 的根 `Stack` 里，从下到上）：`MorphBackdrop`（黑底，`@Trace backdrop` 逐帧变）→ 内容 `Column`（主图 `Swiper` 挂 `.opacity(photoAlpha)`、标题栏与缩略图条各挂 `.opacity(chromeAlpha)`）→ `PhotoMorphLayer`（共享照片层，仅 `morph.visible` 时挂载）。

- **禁止再对整个 NavDestination 做 scale / translate / clip**（旧做法）：那会把标题栏、缩略图条一起从一个小方块里缩放着长出来，观感是「一个迷你版预览器在放大」，和官方差得很远。曾同时用 `showDetailContent` 布尔量做内容显隐，而它在 `animateTo` 里被翻转，`if` 立刻读到新值 → 共享层在动画第 0 帧就被拆掉，等于什么都没做。
- **`animateTo` 不会插值「本帧才创建」的节点的 `width/height/position`**（2026-11-07 实测：`onAppear` 里拿到的就是终点矩形）。共享层是转场开始那一刻才创建的，所以矩形必须用 `displaySync` 帧回调逐帧写 `PhotoMorphState`，缓动值取 `curve.interpolate(t)`（与引擎同一条曲线）。背景与标题栏的 `opacity` 作用在常驻节点上，可以继续用 `animateTo`。
- 矩形换算在 `CustomTransition/PhotoMorph.ets`：`containRect(aspect)` = 图片显示区域（窗口高 − 状态栏 − 56vp 标题栏 − 手势条）× 照片比例居中；起点由 `getRectangleById('thumb_<handle>')` 给的 px 直接 `px2vp`。**图片显示区域必须和 `TitleBar`/`padding` 的实际布局同源**，改标题栏高度要同步 `VIEWER_TITLE_BAR_HEIGHT`。
- 预览器页的 `NavDestination` 背景必须透明、内容区也**不许铺纯黑底**（否则下层画廊从第一帧就被挡住，只剩共享层在动）；黑底只由 `MorphBackdrop` 提供，它同时负责「透过它看到画廊」。
- 返回起点取「当前屏幕上的照片矩形」：未放大就是 `Contain` 矩形；放大过则用 `ZoomableImage.onTransform` 在**手势结束时**汇报的 `scale/offX/offY` 换算（`rect × s` 绕同一中心缩放再平移），这样放大状态下按返回也从当前画面收回，不会先跳回等比显示。`offX/offY` 是屏幕空间位移（`applyTransform` 的注释已经写明 finger 位移要乘 scale 换回屏幕空间，说明 `.translate` 在 `.scale` 之后应用）。
- **返回终点 = 当前照片的缩略图矩形；格子在可视区外就先把画廊滚过去再收**（对齐官方图库「回家时网格已经在当前张」）：
  - 目标格子可能①没被 `virtualScroll` 渲染（视口外）②渲染了但在屏幕外（`cachedCount` 缓存窗口），两种都拿不到可用的屏幕矩形，收回会收进看不见的地方。
  - `popRectFor()` 用 `positionLookup`（`getRectangleById('thumb_<handle>')` 实时查，push 时缓存的位置**只作兜底**，因为它可能已过期）判断「至少一半在窗口内」；否则通过 `requestGalleryScroll` → `MainScreen.galleryScrollVersion` 计数 → `GalleryPage` 的 `@Monitor` → `scroller.scrollToIndex(row, false, ScrollAlign.CENTER)` 滚过去。
  - 预览器按帧重试目标矩形（`POP_TARGET_RETRY_MS` × `POP_TARGET_RETRIES`），拿到才开始收回；**背景透出也挪到这一刻**，所以网格的跳变发生在完全不透明的背景下，用户看不到；请求过滚动还要多等 `POP_SCROLL_SETTLE_FRAMES` 一帧让新布局上屏。
  - 最终兜底顺序：实时矩形 → push 时缓存 → 最初点击的格子（`pop: 目标矩形兜底 …`）。日志里 `pop: 目标格子不在可视区，请求画廊滚动` / `viewer pop: scrollToIndex N` / `pop: 收回目标 …` 三行就能定位这类问题。
- 打开照片时**不立刻弹转圈**：`PhotoRenderState.spinnerOn` 在加载超过 `SPINNER_DELAY_MS`（420ms）才置真，否则照片落位瞬间会盖一个菊花，和「糊图先出现再变清晰」的官方观感冲突。
- 转场日志：`push morph <l,t> <w>x<h> pm=…` 与 `pop: handle=… pm=… rect=… -> …`（AppLog），排查时先看这两行矩形是否等于缩略图格子 / `Contain` 矩形。

### CacheManagementPage.ets
- 列出每个相机的缓存体积、条目数、开关、删除、清空全部。

### GpsManagementPage.ets
- 用原生 `NavDestination.title({ builder: this.ManagementTitleBar }, { barStyle: BarStyle.STACK })`：玻璃返回圆钮、标题/总数、玻璃「选择/取消」胶囊。**不要退回内容区的 `PageHeader`**——内容区 Button 设 `systemMaterial` 不生效，会变回没有材质的透明按钮。列表用 `.contentStartOffset(titleBarInsetVp())` 避让标题栏，滚动时卡片从玻璃控件下面透出。
- 按天分组列出记录条数、当天起止时间；卡片上不再放删除键，避免误触。
- **手风琴展开**：同一时刻只保留一个展开项，进入页面默认展开第一条（`@Provider` / `@Consumer` 下发 `expandedDays`）。不要改成多天同时展开——一天一张 `MapComponent`，多开会把列表拖垮。
- 页头右侧「选择」进入多选：多选态下卡片收起地图、右侧换成勾选圆圈，底部出现「已选 N 天 / 全选 / 删除」。批量删除要二次确认；单天删除只在全屏轨迹页的「更多」菜单里。多选删除要区分真实天和模拟天：模拟天只清内存覆盖层，弹窗不能把模拟条数算成真实删除，文案和按钮（删除/清除）都要对应。
- **多选底栏必须挂在 `ManagementTitleBar` 的浮岛层**：`SelectBottomBar` 自身不设背景，`Row.systemMaterial(REGULAR)`；外层 `Column` 用 `position({ x: 0, y: screenHeightVp - navIndicatorVp - 56 - 12 })` 画到屏幕底部。直接放回内容区，`systemMaterial` 不生效，又会变回整条不透明白栏。列表多选时底部 padding 用 `84 + navIndicatorVp()`，给悬浮栏留出高度。2026-11-07 模拟器验收通过。
- 展开区 `GpsTrackMap`：预览地图禁用手势，点击整张图或「全屏」胶囊进入 `GpsTrackViewerPage`。地图不可用时自动降级为 `GpsTrackSketch`（Canvas 轨迹示意图），全屏入口仍可用。
- 整图点击层用**最上层、带 1/255 背景的透明 Button**（实测 `0x01000000`），比空 `Column` + `Color.Transparent` 稳；点任意位置（包括「全屏」胶囊）都进全屏。
- `GpsTrackSketch` 只在地图不可用时渲染；地图可用时不要把它留在下层，MapComponent 会完全盖住它，但 Canvas 仍会随选中点/记录更新重绘，纯浪费。
- 卡片内部读 `gps.getGroupForDay()`，`Repeat` 的 key 只用 `day`：把 count/first/last 编进 key 会让每次心跳都重建整张卡片和地图。
- 模拟轨迹开启时日期旁只有一个小号「模拟」文字标识（不再做胶囊徽章），页头用 `displayRecordCount()` 而不是 `recordCount`，避免总数和当天卡片对不上。

### GpsTrackViewerPage.ets
- 全屏轨迹页：地图铺满，底部明细面板用系统 **`bindSheet`**（真正的半模态），三档高度 380 / 600 / 780vp；系统自带圆角、拖动条、系统材质和吸附，不再自绘面板。`bindSheet` 的沉浸光感**不受应用级开关影响**，必须在 `SheetOptions.systemMaterial` 显式设置；设置后不要再设 `backgroundColor` / `blurStyle`，避免盖住或重复处理材质。
- **`SheetOptions.onHeightDidChange` 回调高度单位是 px**（官方参考文档明确写“返回值为px”，模拟器 380vp 档实测返回 1330）。必须 `px2vp` 后再用于 `setPadding`、地图适配 padding 和示意图的 `bottomInset`；直接当 vp 用会把面板高度放大 3 倍多，地图/轨迹被压到顶部，示意图的说明文字也会沉到面板下面。
- 地图适配用 `map.newLatLngBounds(bounds, mapCommon.Padding)`，把标题栏和 `sheetHeightVp` 算进 padding；不要只传一个 32px 的均匀边距，否则轨迹下半段会压在明细面板下面。
- 标题栏只保留「返回 + 日期玻璃胶囊 + 更多」；日期胶囊是标题栏里的 Button + `systemMaterial`，单行只显示 `今天/昨天/11月7日`，高度与 40vp 返回/更多按钮一致；总数只放在面板统计行，不要在标题胶囊和统计行重复两次。更多菜单里放「删除当天记录」，二次确认后删除并返回。
- 明细列表按时间升序，点一条会高亮、把相机移到该点，并在选中点画红色 marker。
- 按**行程**分组，不再按 60 米逐点切：相邻采样间隔 >30 分钟才开新组；连续行程内累计位移 <120 米判为「停留」、否则判为「移动」。分组头标题统一用地点地址（移动组用起点地址），右侧状态字固定显示「移动/停留」，图标也区分（行走/定位）；副标题里移动给距离、停留给时长，再加时间范围和记录数。不要再用「地址 vs 移动距离」两种不同标题结构。小轨迹（≤30 条记录）默认展开，长轨迹默认收起只显示行程卡，用户点分组头展开。
- 当天第一组的 `first` 用 `max(runStart, 当天 0 点)`，与面板统计的「时长」同源；后续组用本组第一条采样时间，避免上一轮静止的 `runStart` 跨过行程间隔。面板副标题也要用 `track.first` / `track.last`，不能直接用 `points[0].timestamp`，否则跨午夜静止时「00:00–03:03」和「3 小时 4 分」会对不上。
- 分组内未选中行只显示时间、起点/终点；移动行程用 `HH:mm:ss`（采样间隔可能小于 1 分钟），停留行程用 `HH:mm`。选中行变成内嵌浅蓝卡，展开坐标、地址和海拔；面板头不再重复选中摘要。
- 面板头是「轨迹明细 + 日期/时间范围 + 距离/时长/定位记录」三段统计；统计标签用官方 `SymbolGlyph` 图标（距离/时长/定位点），下面用官方 `Slider` 做轨迹采样拖动条，拖到哪一点就选中哪一点。选中时副标题变「第 N / 总数 条定位记录」，右侧出现「回到全程」浅蓝胶囊。时长列给 `layoutWeight(1.4)`，否则「13 小时 12 分」在 16fp 的三等分栏里会折成两行。
- 明细列表用 `Repeat(...).virtualScroll()`；地址只为可视分组标题和选中点按需解析（`GpsGeocoder`）。不要在 `onScrollIndex` 里给每个可视点预取地址——未选中的行只显示时间，预取只会白耗逆地理编码请求。
- `bindSheet` 设 `enableOutsideInteractive: true` + `maskColor: Color.Transparent`，面板展开时地图仍可操作。**不要用空的 `shouldDismiss` 来阻止面板关闭**：官方语义里侧拉关闭包含侧滑（左/右滑）、三键 back、ESC，注册后不调用 `dismiss()` 会把这些交互一起吞掉，表现就是“系统侧滑返回失效”。改用 `onWillDismiss`：`reason` 为 `PRESS_BACK`/`SLIDE` 时 `showSheet = false` 并 `pageInfos.pop()`；`SLIDE_DOWN` 不处理，保持拖到最低档停住。`onHeightDidChange` 同步更新地图 padding / logo 和 Canvas 的 `bottomInset`。
- 地图不可用时（模拟器未签名、无网络）用 Canvas 示意图兜底，列表和地址仍然可用；`titleBarInsetVp()` / 底部面板高度会作为 `topInset` / `bottomInset` 传给示意图，避免轨迹被标题栏或面板裁掉。
- **地图重试只对“签名包 + 超时/加载失败”显示**：`canRetryMap()` 同时检查 `MapCapability.isSignedPackage()`、`SystemCapability.Map.Core` 和 `mapError` 前缀；未签名/无地图能力不弹重试。`retryMap()` 要清 `controller`、`mapReady`、`mapLoaded`、`gcjCache`、`mapError`，再 `startInitTimeout()`，让 `MapComponent` 重新挂载。按钮用 `glass_bg` + `COMPONENT_THIN` 兜底（内容区拿不到真材质），放在标题栏下方右侧。

### PtpHost.ets
PTP 会话层，封装 `@ohos.usbManager`，见“关键概念”。

## 组件

| 组件 | 位置 | 用途 |
|---|---|---|
| `PageHeader` | `components/PageHeader.ets` | 二级页头部：返回键 + 主/副标题 + 可选右侧文字操作（自己避让状态栏） |
| `SelectionActionBar` | `components/SelectionActionBar.ets` | 多选底部操作栏：悬浮胶囊 + 图标在上文字在下的「下载」项。**自身不设背景**，材质由 `MainScreen.TitleBar` 的浮岛层提供 |
| `DownloadProgressBar` | `components/DownloadProgressBar.ets` | 下载进度浮岛：**竖条**（60vp 宽）贴握持手一侧，**环心显示「第几张/共几张」**（百分比看弧长就够；**≥1000 张时自动拆成两行**；完成态是**同一个环满格 + 环心换成一个品牌蓝的勾**，不要换成绿色实心圆盘）+ 环下状态词 + 取消圆钮；不显文件名。**自身不设背景**，材质由 `MainScreen.TitleBar` 的浮岛层提供 |
| `GpsTrackMap` | `components/GpsTrackMap.ets` | 定位记录卡片的预览地图：禁用手势、折线抽稀 1200 点、按坐标缓存 GCJ02；失败/超时/未签名自动降级为 `GpsTrackSketch`，点击进全屏 |
| `GpsTrackSketch` | `components/GpsTrackSketch.ets` | Canvas 轨迹示意图：按可见区域（`topInset` / `bottomInset`）归一化，画起终点、选中红点；监听 `bottomInset` 重绘；不能用 `Shape`/`Path`，其 viewPort 会二次缩放 |

## 服务

### CameraService（`services/CameraService.ets`，约 1800 行）
单例，`@ObservedV2`，相机相关操作的入口：

- `scanForCamera(quickMode)`：搜索相机 → 连接 → 取设备信息 → 判断缓存设置 → Phase 0 缓存快照 → Phase 1 目录遍历 → Phase 2a 元数据 → Phase 2b 缩略图
- `collectPhotoHandles()`：递归遍历目录，用 `GetObjectHandles` 的格式筛选（`0x0000` 与 `0x3001`）区分文件与目录，不使用启发式判断
- `loadThumbnailsRowByRow()`：每 4 张为一组加载，整组完成才递增 `thumbnailVersion`
- `loadFullPhoto(handle)`：优先读 `compressedCache`，未命中走 USB，解码在 TaskPool 里执行，返回 `DecodedPhotoResult`（PixelMap + 旋转后的尺寸）。完成时打一行四段耗时 `下载完成: 1.0s (取图 …ms / 方向 …ms / 拷贝 …ms / 解码 …ms)`：**「第一次打开照片卡一下」先看这行**——取图占大头是 USB/排队，拷贝占大头是主线程 30MB `ArrayBuffer.slice`，解码占大头才是 TaskPool。
- **邻近预加载半径是 2，且预览器打开期间整体挂起**（`suspendNeighborPreload` / `resumeNeighborPreload`）。以前是 5 且每翻一张就重新排队 10 张，与预览器自己的队列抢 USB。**解码按最长边降采样到 `FULL_DECODE_MAX_EDGE`（3072px）**：手机屏幕长边约 2700px、预览器最多 5x 捏合，3072 已够用；24MP 原图全尺寸是 96MB/张，预览器同时驻留 6-7 张会把内存与纹理带宽打满。降采样用 `DecodingOptions.desiredSize`（2026-11-07 在模拟器把上限压到 600 验证过，日志 `full decode done 600x400 scale=0.500`）。
- `downloadPhotos(handles, onProgress, ctx)`：批量下载到沙箱，按拍摄时间匹配 GPS 并写入 EXIF，最后经 `showAssetsCreationDialog` 保存到系统相册，同时维护 `download_registry.json`
- `disconnect()`：关闭会话，清空全部内存缓存

### AppLog（`services/AppLog.ets`）
内存环形缓冲（最多 500 条）+ **追加写**文件 `app_log.txt`（1 秒节流，超过 512KB 轮转到 `app_log.txt.1`），同时写 hilog。进入后台/销毁时 `flushNow()` 强制补齐；`scanForCamera()` 不再清空日志，只写一条 `=== 开始扫描 ===` 分隔。从设备上读取：

```bash
hdc shell cat /data/app/el2/100/base/io.github.shaoyuanyu.strollandshoot/haps/entry/files/app_log.txt
```

`app_log.txt` 与 `.1` 已从系统备份中排除（见 `backup_config.json`）。

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

### HandednessService（`services/HandednessService.ets`）
握持手感知，决定下载进度浮岛贴左还是贴右。`@ObservedV2` 单例，只暴露一个 `leftHanded` 布尔（默认 `false`，即右侧）。

- 订阅 `motion.on('holdingHandChanged')`（`@kit.MultimodalAwarenessKit`），`LEFT_HAND_HELD` 切左、`RIGHT_HAND_HELD` 切右；`BOTH_HANDS_HELD` / `NOT_HELD` / `UNKNOWN_STATUS` **一律保持原位**，否则手机放桌上或换手途中浮岛会来回跳
- 由 `MainScreen.aboutToAppear` 启、`aboutToDisappear` 停
- 权限 `ohos.permission.DETECT_GESTURE`（normal / system_grant，声明即授予，不弹窗）
- 机型支持面窄：握持手识别自 API 20 起提供，只有系统设置里带「智感握姿」开关的机型可用，否则订阅抛 **801**。本项目全部走「失败即保持默认右侧」
- **模拟器一定返回 801**（`subscribe failed code=801`），只能验降级路径；握持切换必须真机验证
- 浮岛距屏幕边固定 12vp，不能更贴：官方写明「屏幕四周边缘 8mm 范围内不支持触控响应」，再贴边取消按钮会点不动

### Map Kit（`@kit.MapKit`）
- `MapComponent({ mapOptions, mapCallback })` 初始化后拿 `map.MapComponentController`；折线/标记/相机都从这里走。
- `mapOptions` 的 `position.target` 必须是 GCJ02；`geoLocationManager` 给的是 WGS84，必须 `map.convertCoordinateSync(WGS84, GCJ02, p)` 转换。用 `map.newLatLngBounds(bounds, paddingPx)` + `moveCamera` 适配全程。
- `setPadding` / `setLogoPadding` / `newLatLngBounds` 的 padding 单位都是**像素**，用 `getUIContext().vp2px()` 换算；`setPadding` 要把顶部标题栏和底部面板算进去，`setLogoPadding` 的 bottom 要抬到面板上方。
- **`mapLoad` 事件可能早于 `mapCallback`**：回调里先把 `mapLoaded` 置 true 并立即 `moveCamera`，不要只等 `mapLoad`，否则相机永远停在初始 zoom。
- 地图需要 `ohos.permission.INTERNET`；AGC 的「地图服务」开关会写进 Profile 的 `app-services-capabilities.com.huawei.service.mapkit`。签名 HAP 才有瓦片权限，unsigned 模拟器包只会拿到 403。
- 预览图 `setAllGesturesEnabled(false)`，全屏图打开手势；地图加载失败/超时/未签名时切 Canvas 示意图，不做空白兜底。

### ExifGeotagger（`services/ExifGeotagger.ets`）用 `modifyImagePropertiesEnhanced` 一次性写入 `GPSLatitudeRef`、`GPSLatitude`、`GPSLongitudeRef`、`GPSLongitude`（有海拔时还有 `GPSAltitudeRef`、`GPSAltitude`），写完读回验证。经纬度写成逗号分隔的度分秒，例如 `43,49,23.16`；官方把这两个字段定义为三个 RATIONAL 值，典型写法是 `dd/1,mm/1,ss/1`，改动格式之前先在真机确认读回结果。

## 缩略图缓存与快速扫描

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

### 调试

hilog 标签为 `ThumbnailCache`、`CameraCachePrefs`。应用内日志的关键字样：

```text
[ThumbnailCache] loaded manifest with 42 entries
[ThumbnailCache] stale: modDate changed for DSC_0001.JPG::1234567
[CameraService] [CACHE_HIT] handle=0x1234 160x120
[CameraService] 缓存已启用: NIKON D850
```

## 数据模型（`model/PhotoEntry.ets`）

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

同文件还有：`DisplayGroup`（内容优先模式下把同名文件合成一组）、`DownloadRecord`（下载注册表条目，键为 `filename::size`）、`DownloadProgress`、`DownloadResult`、`GpsRecord`、`GpsDailyGroup`。

`model/SettingsStore.ets` 存放持久化设置（深色模式、画廊列数、显示模式）。

## 关键概念

### PTP（Picture Transfer Protocol）
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

### 相机身份
`GetDeviceInfo` 提供的标识，用来区分相机、隔离各自的缓存目录。优先级：`serialNumber` → USB `serial` → `manufacturer + model + deviceVersion + vid + pid` → `vid + pid`。

### Native PTP 引擎（`cpp/`）
从 libgphoto2 移植：

- `ptp_engine.h/cpp`：PTP/MTP 容器构造与响应解析，参与构建
- `napi_init.cpp`：NAPI 导出层，参与构建
- `ptp.h`：协议常量与结构体，只作为头文件被 `ptp_engine.h` 引入
- `ptp.c`、`usb.c`、`ptp_client.cpp/h`、`gphoto2-port.h`、`device-flags.h`、`ptp-bugs.h`、`ptp-private.h`：不参与构建

## 当前进度

### 已完成
- PTP 协议引擎（命令构造、响应解析、设备信息 / 存储 / 对象查询）
- USB 相机通信（会话管理、递归目录遍历的照片枚举）
- 画廊：日期分组、格式筛选、两指缩放、多选下载、按行显示缩略图
- 预览器：主图与缩略图条联动、缩放拖动、串行预加载、一镜到底转场
- 缩略图磁盘缓存 + 元数据快照 + 快速扫描
- 批量下载到系统相册，下载注册表校验
- EXIF 方向纠正（1–8 全部支持），缩略图与原图都按方向解码
- GPS 连续定位、后台长时任务、按天管理、反地理编码
- 定位记录按天展开轨迹（Map Kit，预览 + 全屏），全屏底部明细列表、选中点定位、地址按需解析；地图不可用时 Canvas 示意图兜底
- 调试包「模拟 GPS 轨迹」开关：以当前定位为原点注入相机图案，覆盖当天显示，不改真实记录
- 导出时把 GPS 信息写入 JPEG 的 EXIF
- 深色模式、缓存管理页
- 状态管理全部迁移到 V2

### 未实现
- 边框、水印、LUT、滤镜、美颜。只有 `string.json` 里留着 `btn_process_border`、`btn_process_watermark` 两条字符串，其余没有代码。

## 已知问题

2026-10-14 审视代码时定位的问题，2026-11-05 已全部修复，当前无已知缺陷。

已修复（2026-11-05 第二批）：

- `disconnect()` 先把 `cachingEnabled` 置 false 再判断，缓存 flush 永不执行 → 改为 flush 后再清标志
- `saveRawThumbnail` 第 4 个形参是 `handle`，实际传入原始宽度 → 调用改为 `saveRawThumbnail(key, modDate, data, handle, exifRotate, flipH, flipV, w, h)`
- 缓存清单里的方向字段只写不读 → manifest 升级到 v2（`{version, entries}`），条目新增 `corrected`；`loadCachedThumbnail` 按标记决定是否应用 EXIF 变换；**旧版 manifest 会被整体丢弃**
- `setDetailIndex()` 无调用点 → 在 `PhotoViewer` 的主图索引变化时调用；`evictFurthest()` 改为按照片列表索引计算距离，不再拿 handle 当索引
- 遗留的 `// TEST: only load first 300 photos` → 删除
- `scanRefreshKey` 传入但无人读取 → 占位视图读取它显示解码状态，同时建立 V2 依赖
- 亮色下设置页卡片与页面同为白色 → 卡片统一加 `divider` 描边、圆角 12
- `MainScreen` 点击缩略图时对全部照片调用 `getRectInfoById()` → 只缓存点击位置前后各 40 个，超出范围回退到实时查询
- 无调用点代码全部删除（`getLogText` / `isPhotoDownloaded` / `loadThumbnail` / `cacheOrientedSize` / `getDisplayPixelMap` / `onEdgeChange` / `ThumbnailCache` 的 5 个查询方法 / `PtpSession.close` / `AppLog.getEntries` / `float.json`）

### 2026-11-05 已修复

- 共享元素转场结束后 NavDestination 背景是 `#00ffffff`，亮色下露出窗口白底：标题栏变灰、底部出现白条 → 改为不透明黑色
- 预览器标题栏与缩略图条重复叠加状态栏/手势区高度，顶部多出约 39vp 空白 → 去掉重复内边距
- 系统栏颜色只在预览器里设置过，退出后固定为亮色，后续切深色模式时状态栏仍然是白的 → 统一由 `WindowUtils.applyThemeSystemBars()` 跟随主题
- 主题切换后标签页回到“相机”（`Tabs({ index: 1 })` 写死）→ 绑定 `currentTab`
- 快速扫描 Phase 0 早于 `loadManifest()`，磁盘缓存永远不命中 → 先加载 manifest 再部署快照，`ThumbnailCache.init()` 同相机幂等
- 画廊列数设置不生效（`buildFlatItems()` 缓存键缺列数与宽度）→ 缓存键补齐
- 自动列数恒为 8 列、缩小无效果（`baseItemW()` 用 px 当 vp）→ 统一为 vp，宽度改为 `onAreaChange` 实测
- 点击标题栏返回绕过了 `onBackPressed` 的共享元素更新，回退动画飞向最初点击的缩略图 → 合并为 `handleBack()`
- 早期原型页 `SwiperSyncTestPage` 随应用打包 → 删除
- 已废弃 API（`animateTo`、`AlertDialog.show`、`router.*`、`getContext`、`Packer.packing`）全部迁移
- syscap 告警（`geoLocationManager`）用 `canIUse()` 防护，构建 0 告警

## 调试经验

### `deploy.sh run` 不会重新构建
`bash deploy.sh run` 只做签名、安装、启动。代码有改动时用 `bash deploy.sh full`，否则安装的还是旧 HAP。这个坑已经造成过多次“bug 没有修复”的误判。

### 只截应用窗口（不含系统浮层）

**真机验收一律用内部截屏；系统截屏只用于模拟器，或确实需要确认状态栏/手势条的场景。** 真机上的视频通话、录屏控件等悬浮窗会被系统截屏带进来，内部截屏只渲染本应用窗口。

`hdc shell snapshot_display` 和 `uitest screenCap` 都只能截**整屏**，会把其它应用的悬浮窗（视频通话、录屏控件等）一起截进来。应用侧 `window.Window.snapshot()` 只渲染本应用窗口，调试包已内置触发器（`utils/WindowShot.ets` + `EntryAbility.onNewWant`）：

```bash
HDC=.../hdc; T=<设备>
$HDC -t $T shell "aa start -a EntryAbility -b io.github.shaoyuanyu.strollandshoot --ps shot gallery"
$HDC -t $T shell "ls -t /data/app/el2/100/base/io.github.shaoyuanyu.strollandshoot/haps/entry/files/*.jpg" | head -1
$HDC -t $T file recv <上面那个路径> /tmp/app_shot.jpg
```

- `--ps shot <label>` 的 `label` 只用于文件名后缀，便于区分场景
- 走的是 singleton 的 `onNewWant`，**不会重启应用、不改变当前页面**，所以在任何页面任何时刻都能截；已验证画廊/设置两页分别触发
- 应用没在运行时 `aa start` 走 `onCreate`，不会回调 `onNewWant` → 不截图（冷启动截到的是启动画面，没意义）
- 仅 debug 包生效（`MockPtpDevice.isDebugBuild()` 判断），release 包里不执行
- 截图落在应用沙箱 `filesDir`，命名 `shot_<label>_<时间戳>.jpg`
- 只有 `want.parameters.shot` 存在时才触发，正常启动不受影响
- 图里不含状态栏与系统手势条，判断应用内布局用它、判断沉浸/状态栏效果仍要用整屏截图
- **阅后即焚（强制规则）**：这些 jpg 没有任何自动清理机制。`file recv` 取回后**必须立刻删除**设备上的文件，取图与删除写进同一条命令，不要分两步、更不要留到"以后清理"：

  ```bash
  $HDC -t $T file recv <path> /tmp/app_shot.jpg && $HDC -t $T shell rm -f <path>
  ```

  验收收尾时用 `ls .../files/shot_*.jpg` 确认没有残留；有残留就当场删掉。不打算删就不要截。

### 构建缓存会造成假象
改动回退之后直接重新构建，hvigor 可能复用旧的构建产物，看起来像是回退没有生效。回退代码之后先清理：Linux 用 `hvigorw clean --no-daemon`，macOS 用 `devecocli build clean`。

### 留意写定的上限
旧的 `loadPhotoList` 里有 `const limit = Math.min(handles.length, 50)`，照片数量被悄悄限制在 50 张。遇到“功能大体正常但数字对不上”时，检索 `limit`、`min(`、`max(`、`slice` 以及写定的小数字。

### 目录遍历不用启发式判断
旧逻辑用 `validCount <= 2` 作为是否继续进入子目录的条件，遇到同一层有多个子目录（如 DCIM/100NCD90 与 DCIM/101NCD90）、一个目录下超过 2 个直接子项、或者同一层文件与目录混排的相机就会漏照片。现在的写法是进入全部目录，把所有非目录 handle 当作照片。

### 手机 USB 连接不稳定
开发过程中手机经常与 `hdc` 断开。部署或查日志之前先确认设备，返回 `[Empty]` 就让用户重新插线。

```bash
# Linux
hdc list targets
# macOS（hdc 不在 PATH）
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc list targets
```

手机改走无线调试后不受插拔影响，部署与查日志都不再依赖 USB 线的接触，见「无线调试（Wi-Fi）」。

### 统计计数器要与条件分支同步
`statsPartialSkips` 曾经声明了、也用在统计公式里，但没有任何地方递增，导致 USB 调用次数统计翻倍。新增计数变量后，检查每个对应的条件分支是否都做了递增。

**同类型坑（2026-11-06，真机反馈“很多缩略图无法显示”）**：`loadThumbnailsRowByRow()` 里原来只有一个 `hasNewLoads` 标志、仅在走 USB 的分支置位，`if (hasNewLoads) thumbnailVersion++`。命中磁盘缓存的行（`loadCachedThumbnail`）不置位，于是**整轮扫描一次都不递增**——扫描结束前就已挂载的缩略图单元格（比如扫描中切到画廊）永远停在占位符，只有重新进出画廊才会刷新。现改为「本行只要有加载动作（`rowPromises.length > 0`）就递增」。另外 `thumbnailLoadedSet` 与 `thumbnailPixelMapMap` 必须同时命中才算“已有图”，否则会出现标记已加载但实际没图、被永久跳过。

### 涉及相机与 USB 的改动要在真机上确认
流程：构建 → 部署 → 告诉用户改了什么 → 用户把手机从电脑拔开、接上相机测试 → 用户反馈结果 → 用户把手机接回电脑 → 查看 hilog。手势与相机相关功能在没有真机确认之前，不要当成已经可用。

### 查 HarmonyOS 官方资料（强制前置步骤）

凡是涉及 HarmonyOS / ArkTS / ArkUI 的 **API 用法、参数含义、起始版本、设计规范、最佳实践、版本行为差异**，一律**先查知识库，再动手写代码**。不要凭记忆回答，也不要只翻本地 `.d.ts` 就下结论——`.d.ts` 只看得到签名，看不到"什么条件下才生效"。

HarmonyOS 开发者知识库 MCP（工具名前缀 `mcp__harmonyos_developer_knowledge__`）：

| 工具 | 用途 |
|---|---|
| `mcp__harmonyos_developer_knowledge__searchDocuments` | 自然语言检索官方知识库（API 参考、开发指南、设计规范、最佳实践、FAQ、版本说明）。入参 `query`，可选 `topK` |
| `mcp__harmonyos_developer_knowledge__getDocumentsById` | 用搜索结果里的 `parent` 字段（文档 ID）取正文，一次最多 10 篇 |

- `parent` 前缀说明来源：`alliance/document/cn/harmonyos-guides/…` 是开发指南，`alliance/document/cn/harmonyos-references/…` 是 API 参考，`alliance/document/cn/design-guides/…` 是设计规范
- 返回内容过长会被截断，改用更精确的关键词分多次检索；或先 `getDocumentsById` 落盘再读全文
- 检索词尽量用文档里会出现的中文原词，命中率明显更高：

| 想问什么 | 检索词 |
|---|---|
| 某视觉效果有没有官方实现 | `沉浸光感 设计规范 开发指南`、`HDS 组件 材质` |
| 某组件怎么用 | `HdsTabs 使用指南`、`HdsNavigation TitleBarStyleOptions` |
| 某接口从哪个版本开始有 | `<接口名> 起始版本` |
| 效果写了但看不到 | `<能力名> FAQ`、`生效范围` |
| 性能/功耗约束 | `<能力名> 功耗优化`、`约束与限制` |

**为什么这一步不能省（本项目真实踩坑）**：做沉浸光感 UI 时只查了本地 SDK 的 `@ohos.arkui.uiMaterial.d.ts`，看到 `@since 26.0.0` 就判定“项目 targetSdk 23 用不了”，转而用 `backgroundBlurStyle` 手搓毛玻璃。而知识库的《HDS 组件沉浸光感》明确写着 **UI Design Kit 的 `HdsNavigation` / `HdsTabs` 自 6.1.0(23) 起就支持 `systemMaterialEffect`**。根因是：SDK 的 OpenHarmony 目录只覆盖 ArkUI 那部分，HMS 侧的 `@kit.UIDesignKit` 在 `sdk/default/hms/ets/kits/`，翻一个目录就漏了。

备用渠道与补充材料：

- `devecocli docs`（`catalog` / `search` / `read`）——离线文档目录、全文检索、读完整 markdown（不截断）
- 本机 SDK 类型声明：OpenHarmony 侧 `…/sdk/default/openharmony/ets/api/`（Linux 为 `~/.hmos/command-line-tools/sdk/default/openharmony/ets/api/`），HMS 侧 `…/sdk/default/hms/ets/kits/`
- 两者的分工：`.d.ts` 确认签名、参数类型、`@since`；**"生效范围、前置条件、算力档位、和别的属性冲突"必须回知识库确认**，这类信息不在类型声明里

### 已经对照官方资料核对过的结论

- USB 单次 `bulkTransfer` 小于 200KB：官方 `usbManager` 参考里没有写这个数值，属于本项目实测，改动缓冲区必须在真机验证
- `@SyncMonitor`：官方文档写明从 API 23 开始支持，`@Monitor` 从 API 12 开始支持
- `Repeat`：`LazyForEach` 的官方迁移写法是 `Repeat(data).virtualScroll()`，没有 `RepeatForEach` 这个组件
- EXIF Orientation：官方 FAQ 给出 8 个取值与字符串表示的对应关系（1 = `Top-left`，……，8 = `Left-bottom`），读取时返回字符串，未写入该字段的图片按不旋转处理
- GPS 经纬度：官方把 `GPSLatitude` / `GPSLongitude` 定义为三个 RATIONAL 值（度、分、秒），典型写法是 `dd/1,mm/1,ss/1`；本项目写入的是逗号分隔的度分秒（如 `43,49,23.16`），写完读回验证
- 图片编码默认不保留 EXIF：`PackingOption.needsPackProperties` 默认 false。缩略图缓存里保存的编码结果因此没有 EXIF，方向信息另外记在 manifest 里
- 沉浸光感有两条技术路线，版本门槛不同：
  - **ArkUI 侧**：`uiMaterial.ImmersiveMaterial` + 通用属性 `systemMaterial()`，`@since 26.0.0`，且要求 **targetSdkVersion ≥ 26.0.0** 才生效。本项目 targetSdk 与 compatibleSdk 都是 26.0.0，可直接使用，无需版本保护
  - **UI Design Kit 侧**：`HdsNavigation` 的 `TitleBarStyleOptions.systemMaterialEffect`、`HdsTabs` 的 `HdsTabsFloatingStyle.systemMaterialEffect`，**自 6.1.0(23) 起支持**，无需版本保护
- 沉浸光感的生效范围有限制：除弹窗类组件与 `Slider`/`Toggle`/`Select` 外，其他组件的材质**只在 Navigation/NavDestination 标题栏，或横向 Tabs 且 `barPosition: End` 的底部 TabBar 里生效**；写在页面内容区不生效
- 标题栏材质走 **UI Design Kit** 的 `HdsNavDestination.titleBar({ style: { systemMaterialEffect } })`，`@since 6.1.0(23)`，不需要版本保护；ArkUI 原生 `Navigation` 的 `NavigationTitleOptions.systemMaterial` 只落在返回键/menu 背板上，拿不到整条标题栏，所以最终没有用它
- 材质与属性会打架：设了材质就要把 `backgroundColor` 设为 `Color.Transparent`（不透明背景会盖住材质），且**不要再叠加 `backgroundBlurStyle` / `backgroundEffect`**，否则重复模糊、功耗翻倍。同一子树只在外层设一次材质，避免嵌套
- 材质效果随设备算力档位自适应：`hdsMaterial.MaterialLevel.ADAPTIVE` 交给系统决定；若自己指定，要先 `hdsMaterial.getSystemMaterialTypes()` 判断设备是否支持 `IMMERSIVE`，不支持则退回 `SMOOTH`

## DevEco CLI（`devecocli`）

华为官方的 agent coding 工具包（npm 包 `@deveco/deveco-cli`），包装 hvigor、ohpm、hdc、模拟器工具链，内置离线文档与官方 skills。本机装的是 1.3.0，命令名是 `devecocli`。包内自带 `SKILL.md` 与 `docs.zip`。

### 环境变量（分平台）

macOS 上**什么都不用设**，`devecocli` 会自动发现 `/Applications/DevEco-Studio.app/Contents/tools/hvigor`。把 `DEVECO_CLI_CLT_PATH` 指向 `Contents/tools` 反而报 `Invalid DEVECO_CLI_CLT_PATH`。

Linux 上两个都必需：

```bash
export DEVECO_CLI_CLT_PATH=~/.hmos/command-line-tools   # CLT 不会被自动发现
export DEVECO_CLI_SKIP_VERSION_CHECK=1                  # 本机 CLT 6.1.0.830 低于 CLI 要求的最低版本
```

Linux 的 CLT 位于 `~/.hmos/command-line-tools/`，内含 hvigor 6.23.5、codelinter 6.0.240、ohpm 与 HarmonyOS SDK API 23。升级 CLT 之后可以去掉第二个变量。

### 本项目实测可用

| 命令 | 用途 | 实测平台 |
|---|---|---|
| `devecocli build` | 构建，等同 `hvigorw assembleHap`，输出更简洁；`devecocli build clean` 可清理 | macOS、Linux |
| `devecocli check lint [path]` | 运行 code-linter，支持 `--fix`、`--format json`、`--output-path` | macOS、Linux |
| `devecocli docs catalog` / `search` / `read` | 离线文档目录、全文检索、读取完整文档 | macOS、Linux |
| `devecocli device list` | 列出真机与模拟器 | macOS、Linux |
| `devecocli emulator list` / `start` / `stop` | 模拟器实例管理，见「模拟器」 | macOS |
| `devecocli skills list` / `find` / `add --skill <name> --path <dir>` | 官方 skills（53 个）的检索与安装，`--all` 全装 | macOS、Linux |

官方 skills 的实体仓库在 `/home/ysy/Projects/hmos/.skills/`，Linux 开发机上本项目通过 `.agents/skills` 符号链接接入。链接丢失时重建（路径只在 Linux 上存在）：

```bash
mkdir -p .agents && ln -s /home/ysy/Projects/hmos/.skills .agents/skills
```

### skills

`.agents/skills/` 是 VS Code 识别的三处技能目录之一（另两处是 `.github/skills/`、`.claude/skills/`）。只有落在这些目录里的技能，其 `name` + `description` 才会进入系统提示的技能索引，模型才可能语义触发；放在别处、或用 `devecocli skills list` 临时查看，都不会自动加载。

- macOS 上是**真实目录**，`devecocli skills add --all --path .agents/skills` 装全量 53 个，约 186 MB。目录必须先存在，否则报 `Directory "..." not found`。
- `/.agents` 在 `.gitignore` 里，不会入库。
- 索引开销实测约 **12k tokens**（53 个 `<skill>` 块，平均每个 230，最长的是 `hmos-push-kit` 629）；被触发的技能再按需读 `SKILL.md`，57 个正文合计约 272k tokens，单次通常只读 1~2 个（约 5k）。
- 只装相关子集可把常驻开销降到 4k 左右：`devecocli skills remove --skill <name> --path .agents/skills`。
- 技能清单在对话开始时固定，新装的要新开一轮对话才生效。

### 模拟器

macOS 上唯一能跑起来应用的通道。`devecocli emulator` 只是拼参数并 detached 启动 DevEco Studio 自带的模拟器二进制，不需要开 IDE：

```bash
devecocli emulator list                  # Mate 80 / stopped
devecocli emulator start "Mate 80"       # 起来后以 127.0.0.1:5555 出现在 device list
devecocli emulator stop "Mate 80"
```

实际进程是 `/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator -start "Mate 80" -bootmode snapshot`，实例数据在 `~/.Huawei/Emulator/deployed/Mate 80`。

**签名 HAP 装不进模拟器**：`.profile/` 里两套 Profile 的 `debug-info.device-ids` 只登记了真机 UDID（`0BA1CACC…`），模拟器 UDID 是另一串（`bm get --udid` 可查），安装报 `error: install sign info inconsistent`。模拟器**接受未签名 HAP**，所以装 `entry-default-unsigned.hap`：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc

$HDC -t 127.0.0.1:5555 install -r entry/build/default/outputs/default/entry-default-unsigned.hap
$HDC -t 127.0.0.1:5555 shell aa start -a EntryAbility -b io.github.shaoyuanyu.strollandshoot
```

界面自动化（坐标要用真实像素，先 dump 出 bounds；`snapshot_display` 的图可以直接看）：

```bash
$HDC -t 127.0.0.1:5555 shell uitest dumpLayout -p /data/local/tmp/layout.json
$HDC -t 127.0.0.1:5555 shell uitest uiInput click <x> <y>
$HDC -t 127.0.0.1:5555 shell snapshot_display -f /data/local/tmp/s.jpeg
$HDC -t 127.0.0.1:5555 file recv /data/local/tmp/s.jpeg /tmp/s.jpeg
```

能验证：布局、V2 状态管理、导航与转场、设置持久化、深色模式、空态与错误分支、崩溃排查、**沉浸光感材质**（悬浮页签的磨砂/折射在模拟器上与真机一致）。不能验证：USB PTP（模拟器无 USB 主机，`搜索相机` 必然搜不到）、相机通信、EXIF 方向与 GPS 写入、保存到系统相册、真实性能与手势手感。

**地图在模拟器上一定没有瓦片**：模拟器只接受 unsigned HAP，Profile 里的 `com.huawei.service.mapkit` 不生效，Map Kit 初始化成功但每个瓦片请求都返回 `403 no map permission`。代码会通过 `MapCapability.isSignedPackage()` 自动切到 Canvas 轨迹示意图（预览和全屏都可用）。地图瓦片、marker、相机 fit 必须用 signed HAP 在真机确认；不要因为模拟器上看到灰底就怀疑 Map Kit 代码。

### 需要设备、登录或尚未验证

- `run` / `--apply <file>`（快速增量部署，要求 DevEco Studio ≥ 6.1.1）/ `--hotreload`（需要后台进程保活）
- `log`（hilog 与崩溃日志）、`ui`（界面检视与操作），两者都需要设备
- `signature generate`（生成签名材料，需先 `devecocli auth login` 且连接设备）
- `check compat`（两个 SDK 版本之间的破坏性变更扫描）、`update`（更新 CLI 自身）

签名与安装仍走 `deploy.sh`（仅 Linux），`devecocli` 只用来构建、静态检查、模拟器与查文档。macOS 上构建产物是 AgentDebug 签名的 HAP，能装模拟器的只有 unsigned 那个；真机走无线调试装 signed 包，已验证。

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
