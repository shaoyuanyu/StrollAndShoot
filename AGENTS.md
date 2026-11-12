# StrollAndShoot（走走拍拍）

HarmonyOS 手机应用。通过 USB PTP 连接相机，浏览并导入照片，写入 GPS 地理标记。

**交流语言：中文。**

`AGENTS.md` 只保留项目的全局约定、开发流程、运行环境、构建发布、架构总览与项目状态。具体实现与页面设计放在根目录的 2 个主题文档中：PAGES.md、SERVICES.md。HarmonyOS 知识、调试、工具链、官方资料检索与历史问题已并入本文件。

## 文档地图

| 文档 | 内容 |
|---|---|
| [PAGES.md](PAGES.md) | 所有页面、多选模式、复用组件 |
| [SERVICES.md](SERVICES.md) | 相机/照片管线、缓存与扫描、数据模型、GPS/地图、PTP/USB/Native |

HarmonyOS/ArkUI 知识见下文「HarmonyOS 开发知识」；调试、工具链、官方资料检索与历史问题也在本文件。

**维护规则**：改某个模块前先读对应文档；改完实现后同步更新文档。文档与代码冲突时以代码为准，并顺手修正文档。新增长篇经验优先写进对应主题文档，`AGENTS.md` 只加索引。

## 开发纪律（强制）

### 官方组件优先

- 任何 UI 都先使用官方 ArkUI / HarmonyOS 组件或系统能力（如 `bindSheet`、`List`、`Navigation`、`Tabs`、`Select`、`Toggle`、`Swiper` 等），按官方推荐方式实现。
- **不得**以“自己画更可控/更快”为理由自绘组件。
- 只有官方组件确实无法实现所需特殊效果时，才允许自绘；落地前必须先向用户说明：官方组件为什么不够、自绘范围、交互/主题/性能风险、验证方式，并得到确认。
- 自绘也必须遵循系统设计语言，优先保留官方组件的壳、动画和材质；能用官方容器 + 自定义内容组合的，不要从零画。

### 无障碍不在范围内

本项目**不考虑无障碍功能**：不添加 `accessibilityText` / `accessibilityGroup` / `accessibilityLevel` 等无障碍标注，也不为读屏与无障碍焦点顺序做专项适配；实现、评审与验收都不把无障碍作为检查项。历史上为按钮补过的无障碍标注已全部移除，后续不要重新引入。如果平台规范或第三方集成强制要求，先与用户确认，不要自行补回。

### 先查官方资料，再写 HarmonyOS 代码

凡是涉及 HarmonyOS / ArkTS / ArkUI 的 **API 用法、参数含义、起始版本、设计规范、最佳实践、版本行为差异**，一律先查官方知识库，再动手写代码。不要凭记忆回答，也不要只翻本地 `.d.ts` 就下结论——`.d.ts` 只看得到签名，看不到“什么条件下才生效”。

工具、检索技巧与备用渠道见下文「查 HarmonyOS 官方资料」。

### 真机验证

涉及相机、USB、EXIF、GPS、系统相册与手势手感的改动，必须真机确认后才算完成。模拟器能验证布局、状态、导航、主题与材质，但 PTP、相机通信、EXIF 方向与 GPS 写入、系统相册保存、真实性能与手势手感不能替代。流程见下文「无线调试（Wi-Fi）」「调试经验」「涉及相机与 USB 的改动要在真机上确认」。

### 版本号

agent 在完成每次功能开发或 bug 修复后，**必须**自动更新版本号。规则见下文「[版本号与发布](#版本号与发布)」。

### 截图与验收

真机验收一律用应用内部截屏，系统截屏只用于模拟器或需要确认状态栏/手势条的场景。截图文件取回后必须立刻删除设备上的副本，规则见下文「应用窗口截图（真机验收）」。

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
| 版本号 | 定义在 `AppScope/app.json5`，写作时为 1.30.1 / 1030001 |
| 开发机 | macOS + DevEco Studio（日常开发）；Linux + command-line-tools（完整构建、签名、部署） |

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
| 模拟器镜像 | `~/Library/Huawei/Sdk/system-image/HarmonyOS-7.0.0`，实例 `Mate 80` 可用 |

`devecocli` 由 nvm 装的 node v26.13.0 提供。新开的 shell 若没加载 nvm，会出现 `command not found`，先 `source ~/.nvm/nvm.sh`。

### 与 Linux 开发机的差异

| 项 | macOS | Linux |
|---|---|---|
| `DEVECO_CLI_CLT_PATH` | 不设；设成 `Contents/tools` 会报 `Invalid DEVECO_CLI_CLT_PATH` | 必须设为 `~/.hmos/command-line-tools` |
| `DEVECO_CLI_SKIP_VERSION_CHECK` | 不需要 | 需要 |
| `hvigorw` 脚本 | 项目根目录**没有**，只能用 `devecocli` | 有（本地文件，未纳入版本控制） |
| `deploy.sh` | **不存在**（被 `.gitignore` 忽略，只在 Linux 上） | 有，内含签名材料路径与口令 |
| 签名材料 | **三套签名配置**：`default` 自动签名（`~/.ohos/config/`，备用）、`AgentDebug`、`AgentRelease`；手动材料在 `../KEYS/hmos_dev_key.p12`、`../CERTIFICATES/` 与 `.profile/` | `deploy.sh` 负责 |
| 安装到手机 | 真机走 Wi-Fi：`hdc -t IP:端口 install -r entry-default-signed.hap`；模拟器只认 unsigned 包 | `bash deploy.sh full` |

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
- 签名材料与 `AgentDebug` / `AgentRelease` 两套手动签名配置见下文「签名与分发」。
- **签好的 HAP 能装真机**（2026-11-06 实测）：Profile 的 `debug-info.device-ids` 里登记了真机 UDID，手机打开无线调试后 `hdc -t IP:端口 install -r entry-default-signed.hap` 1.4 秒装完并成功启动。真正装不进的是**模拟器**，它只接受 unsigned 包。
- `build-profile.json5` 里两个 product 都是 `targetSdkVersion: "26.0.0"`、`compatibleSdkVersion: "26.0.0"`：功能、行为变更与最低安装版本统一按 API 26，**只能安装到 7.0.0 及以上设备**，因此调用 API 26 接口不需要再包 `deviceInfo.apiAvailable('26.0.0')`。
- **API 26 起版本号写法变了**：26 及以上写成纯语义化字符串 `"26.0.0"`，不再是 `"6.1.0(23)"` 那种 `M.S.F(N)` 形式。
- 升级到 26 后已核过的行为变更：`shadow` 的 `radius: 0` 从“无阴影”变为“无模糊阴影”、Media Library `READ_IMAGEVIDEO` 只能读本地图库、`.kernel` 权限需 bin 显式声明——本项目均未触及（未用 `shadow`、未申请 `READ_IMAGEVIDEO`、手机应用无 bin 子进程）。
- 涉及相机与 USB 的验证仍然只能在真机上做。

## 目录结构

```text
StrollAndShoot/
├── AGENTS.md                       # 全局约定、开发流程、构建发布、架构总览
├── PAGES.md                        # 页面、多选、组件
├── SERVICES.md                     # 服务、缓存、数据模型、GPS/地图、PTP/Native
├── AppScope/app.json5              # bundleName、版本号、图标
├── build-profile.json5             # SDK 版本、products、signingConfigs（本地，未纳入版本控制）
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
│   │   │   ├── utils/              # 分组、缩放列数、窗口、标题栏、L10n、日期格式化
│   │   │   ├── workers/            # ImageDecoder：TaskPool 并发函数（不是 Worker 线程）
│   │   │   └── CustomTransition/   # 一镜到底转场：注册表 + PhotoMorph（共享照片层与几何换算）
│   │   ├── debug/                  # 仅调试包生效的虚拟 PTP 相机（MockPtpDevice / MockPtpSession）
│   │   ├── cpp/                    # NAPI 代码与 libentry.so 的类型声明
│   │   └── resources/              # base 为浅色且简体中文，dark 为深色，en / zh_Hant 为语言资源
│   ├── src/test/                   # Local Test：主机侧 ArkTS 单测，不需要设备
│   ├── src/ohosTest/               # Instrument Test：装到设备/模拟器上跑（仍是模板用例）
│   └── src/mock/                   # NAPI mock，让 Local Test 能跑依赖 libentry.so 的代码
└── hvigor/
```

## 构建、测试与部署

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
- `entry/src/test` 已有真实单测（分组、键计算、GPS 合并/心跳/轨迹聚合/格式化/模拟图案等，共 37 个用例）；`entry/src/ohosTest` 仍是模板用例。

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
- `bash deploy.sh run` 只做签名、安装、启动；代码有改动时必须用 `bash deploy.sh full`，否则安装的还是旧 HAP。
- 改动回退之后先清理再构建，否则 hvigor 可能复用旧产物，看起来像回退没有生效。
- 无线调试、hdc 日志与截图：见下文「无线调试（Wi-Fi）」「应用窗口截图（真机验收）」。

### 签名与分发

- 签名材料分散在项目外，均不纳入版本控制：
  - 密钥库：`../KEYS/hmos_dev_key.p12`
  - 调试证书：`../CERTIFICATES/Agent_Debug.cer`
  - 发布证书：`../CERTIFICATES/Agent_RELEASE.cer`
  - 调试 Profile：`.profile/StrollAndShoot_DebugDebug.p7b`
  - 指定设备发布 Profile：`.profile/StrollAndShoot_Specific_ReleaseRelease.p7b`
- `.profile/` 已加入 `.gitignore`。
- 根目录 `build-profile.json5` 已从版本控制移除并加入 `.gitignore`；它只存在于各开发机本地，Linux 上需要单独维护一份（`deploy.sh` 依赖它）。
- `build-profile.json5` 已配好 `AgentDebug` / `AgentRelease` 两套手动签名。工程里有两个 product，签名与用途分开：
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

### 版本号与发布

采用语义化版本（SemVer）：`MAJOR.MINOR.PATCH`。版本号定义在 `AppScope/app.json5`：

```json5
{
  "app": {
    "versionName": "1.25.1",  // 语义化版本字符串
    "versionCode": 1025001    // 整数编码，用于程序化比较
  }
}
```

| 分段 | 何时递增 | 示例 |
|---|---|---|
| **MAJOR** | 不兼容的 API / 行为变更（极少发生） | `1.1.0` → `2.0.0` |
| **MINOR** | 新增功能（向后兼容） | `1.1.0` → `1.2.0` |
| **PATCH** | Bug 修复（向后兼容） | `1.1.0` → `1.1.1` |

`versionCode = MAJOR * 1_000_000 + MINOR * 1_000 + PATCH`。例如 `1.2.3` → `1_002_003` → `1002003`。

每次代码变更按以下步骤执行：

1. **判断变更类型**：新增功能 → MINOR；修复 bug → PATCH；破坏性变更 → MAJOR（极少）
2. **读取** `AppScope/app.json5` 中的当前 `versionName` 和 `versionCode`
3. **解析**当前 `versionName` 得到 `MAJOR.MINOR.PATCH`
4. **递增**对应分段，低分段归零（如 MINOR+1 则 PATCH 归零）
5. **计算**新的 `versionCode`
6. **更新** `AppScope/app.json5` 中的 `versionName` 和 `versionCode`，并同步 `build-profile.json5` 里 `default` 的 `versionName`

- `versionCode` / `versionName` 定义在 `AppScope/app.json5`：前者是整数（0~2147483647，只用于比较新旧，每次发布递增），后者是展示串，设置页「关于 → 版本」直接显示 `versionName`。
- **调试版必须在版本名里标明**：调试包用 `<版本>{debug}`（如 `1.25.1{debug}`），发布包用纯数字（`1.17.0`）。
- `versionName` 只接受两种形态 —— ① 只有数字和点；② 同时包含 `{` 和 `}`、字符集为数字/字母/下划线/点/花括号。打包工具的校验正则是 `^[0-9.]+|(?=.*[{])(?=.*[}])[0-9a-zA-Z_.{}]+$`，所以 `1.17.0-beta`、`1.17.0 Debug`、`v1.17.0` 都不合法。`{debug}` 会**原样**显示在「关于」页，这是预期行为。
- 调试标记写在 **product 级** `build-profile.json5` 的 `products[]` 里，只配 `default`：

  ```json5
  { "name": "default", "signingConfig": "AgentDebug", "versionName": "1.25.1{debug}", ... }
  ```

  `AppScope/app.json5` 被两个 product 共用，写在那里会让发布包也带上 `{debug}`；`dist` 不要配 `versionName`，沿用 `app.json5` 的干净版本号。反过来（`app.json5` 写 `{debug}`、`dist` 覆盖）一旦忘了覆盖，发布包就会带调试标记，不要这么干。
- 升版本时改两处：`AppScope/app.json5` 的 `versionCode` / `versionName`，以及 `build-profile.json5` 里 `default` 的 `versionName`。Linux 上的 `build-profile.json5` 是另一份，别忘了同步。
- `versionCode` 不要拿来编码调试标记：它是整数，且每次升级必须严格递增。
- 每次代码变更只递增一个分段；同时包含新功能和 bug 修复时按 MINOR 处理；纯文档/注释/重构（无行为变化）不更新版本号。
- 版本更新与代码变更在同一轮编辑中完成，不需要额外的提交或沟通。

## 无线调试（Wi-Fi）

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

### 读日志 / 截图

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

### 断点调试

hdc 本身不带调试器。断点仍走 DevEco Studio 的 `Tools > IP Connection`（6.1.1 起）或设备下拉框里的 IP Connection，输入同一个 `IP:端口`，再用 Debug 启动。

### 坑：首次启动可能被应用市场管控拦截

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

## 应用窗口截图（真机验收）

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
- **阅后即焚（强制规则）**：这些 jpg 没有任何自动清理机制。`file recv` 取回后**必须立刻删除**设备上的文件，取图与删除写进同一条命令，不要分两步、更不要留到“以后清理”：

  ```bash
  $HDC -t $T file recv <path> /tmp/app_shot.jpg && $HDC -t $T shell rm -f <path>
  ```

  验收收尾时用 `ls .../files/shot_*.jpg` 确认没有残留；有残留就当场删掉。不打算删就不要截。

## 调试用的虚拟相机

模拟器没有 USB 主机，PTP 永远搜不到相机，画廊、预览器、共享元素转场这些纯 UI 功能因此无法验收。调试包内置了一台**虚拟 PTP 相机**，走的是与真机完全相同的流程：

| 文件 | 作用 |
|---|---|
| `debug/MockPtpDevice.ets` | 虚拟相机的“硬件”：USB 描述符、DeviceInfo、1 个 storage、`DCIM → 100MOCK / 101MOCK` 两层目录树、38 张照片的元数据，以及按 handle 现场编码出的 JPEG（缩略图 180×120，原图 1200×800；4×3 多色块 + 白框 + 中心十字，左上角固定深色块做方向参照） |
| `debug/MockPtpSession.ets` | `PtpTransport` 的第二个实现：`connect` / `getDeviceInfo` / `getStorageIDs` / `getObjectHandles` / `getObjectInfo` / `getThumb` / `getObject` / `getPartialObject`，每个调用带少量延迟让进度条可见。**`getObject` 固定 520ms/张**（靠近真实 USB 单张原图耗时）：之前 120ms 时 38 张几秒就传完，进度浮岛的下载中 / 保存中 / 完成三种状态根本来不及看 |

**`makeJpeg` 必须保持「按色带算一行 + 逐行 memcpy」的写法**（2026-11-07 实测，2026-11-09 改成多色块后复核）：原先是 1200×800 逐像素写 RGBA，96 万次 JS 循环、每次 4 次写入，`hilog` 实测 **fill 就要 127–167ms，整张 130–175ms**，而且跑在 UI 线程上；打开一张照片会连续生成「当前 + 邻近预加载」好几张，真机上表现就是「一开图 / 一传输就卡」。现在 4×3 色块图每个「色带行」只算一条行缓冲（横向 4 个色块 + 中心竖线 + 左右白框），再 `u8.set(row, offset)` 复制到该带所有行，fill 仍是 **1–2ms**、整张 10–17ms（余下是原生的 `createPixelMap` + `packToData`）。日志里每次生成会打一行 `MockPtp: jpeg 1200x800 10ms (fill 1ms)`，改这块时先看这个数。

多色块 + 白框 + 中心十字是刻意的：纯色渐变看不出 `Contain`/`Cover` 的裁切差异，也看不出缩放锚点是否在几何中心、缩略图是否把边框裁掉。左上角固定深色块是方向/翻转的不对称参照。改图案时保持「每个色带只算一行」的结构，不要退回逐像素写。

`PtpHost.ets` 里 `PtpSession` 与 `MockPtpSession` 共用 `PtpTransport` 接口，`CameraService.session` 声明为该接口，`scanForCamera()` 开头用 `syncSessionMode()` 按调试开关选实现。于是：

- 设置页最底部「调试（仅调试包可见）→ 模拟相机设备」打开开关；
- 开关下面会出现「模拟型号」下拉（1.48.0）：决定虚拟相机上报的 `manufacturer` / `model`，也就是**标题里的型号与页首立牌用哪张图**。选项由 `cameraStandeeKeys()` + `cameraStandeeLabel()` 生成，所以每一项都必然有立牌；第一项「未知型号」上报 `Virtual PTP Camera`，用来验收「认不出机型、不出立牌、标题退回全局『相机』」的分支。改型号会断开当前会话，回「相机」页再点一次「搜索相机」才生效；
- 到「相机」页点「搜索相机」，会走 **搜索 → 连接 → 取设备信息 → 首次连接询问是否启用缓存 → 遍历目录 → 取元数据 → 按行取缩略图** 的完整流程；
- 画廊里看到的是扫描结果，不是直接塞进去的数组；第二次点「快速扫描」会命中磁盘缩略图缓存（`[CACHE_HIT]`）；
- 预览器里的原图来自 `getObject()` 返回的真实 JPEG。

其它注意点：

- 是否调试包由 `bundleManager.getBundleInfoForSelfSync(...).appInfo.debug` 判定，release 包里设置项不渲染、`isEnabled()` 恒为 false。
- 未签名的 HAP 装到模拟器上同样返回 true，所以模拟器上可以正常用。
- 虚拟相机的身份是 `<厂商>_<型号>_MOCK-0001`（未知型号时是 `Mock_Virtual_PTP_Camera_MOCK-0001`），它的缩略图缓存会落到真实缓存目录里，可用于验证缓存与快速扫描。**切换模拟型号会换一份缓存标识**，各型号互不干扰。
- 型号存在 `SettingsStore.mockCameraModel`（默认空串 = 未知型号），真实机型名一律取 `cameraStandeeLabel()`，不要手写（手写拼错会落到「认不出」分支）。
- 开关状态持久化在 `SettingsStore.mockCameraEnabled`。改完开关或重装包后，需要重新到「相机」页点一次「搜索相机」。
- 验证完记得关掉开关，否则会与真实相机状态混淆。

## 调试经验

### `deploy.sh run` 不会重新构建

`bash deploy.sh run` 只做签名、安装、启动。代码有改动时用 `bash deploy.sh full`，否则安装的还是旧 HAP。这个坑已经造成过多次“bug 没有修复”的误判。

### 构建缓存会造成假象

改动回退之后直接重新构建，hvigor 可能复用旧的构建产物，看起来像是回退没有生效。回退代码之后先清理：Linux 用 `hvigorw clean --no-daemon`，macOS 用 `devecocli build clean`。

### 留意写定的上限

旧的 `loadPhotoList` 里有 `const limit = Math.min(handles.length, 50)`，照片数量被悄悄限制在 50 张。遇到“功能大体正常但数字对不上”时，检索 `limit`、`min(`、`max(`、`slice` 以及写定的小数字。

### 目录遍历不用启发式判断

旧逻辑用 `validCount <= 2` 作为是否继续进入子目录的条件，遇到同一层有多个子目录（如 `DCIM/100NCD90` 与 `DCIM/101NCD90`）、一个目录下超过 2 个直接子项、或者同一层文件与目录混排的相机就会漏照片。现在的写法是进入全部目录，把所有非目录 handle 当作照片。实现见 [SERVICES.md](SERVICES.md)。

### 手机 USB 连接不稳定

开发过程中手机经常与 `hdc` 断开。部署或查日志之前先确认设备，返回 `[Empty]` 就让用户重新插线。

```bash
# Linux
hdc list targets
# macOS（hdc 不在 PATH）
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc list targets
```

手机改走无线调试后不受插拔影响，部署与查日志都不再依赖 USB 线的接触，见上文「无线调试（Wi-Fi）」。

### 统计计数器要与条件分支同步

`statsPartialSkips` 曾经声明了、也用在统计公式里，但没有任何地方递增，导致 USB 调用次数统计翻倍。新增计数变量后，检查每个对应的条件分支是否都做了递增。

**同类型坑（2026-11-06，真机反馈“很多缩略图无法显示”）**：`loadThumbnailsRowByRow()` 里原来只有一个 `hasNewLoads` 标志、仅在走 USB 的分支置位，`if (hasNewLoads) thumbnailVersion++`。命中磁盘缓存的行（`loadCachedThumbnail`）不置位，于是**整轮扫描一次都不递增**——扫描结束前就已挂载的缩略图单元格（比如扫描中切到画廊）永远停在占位符，只有重新进出画廊才会刷新。现改为「本行只要有加载动作（`rowPromises.length > 0`）就递增」。另外 `thumbnailLoadedSet` 与 `thumbnailPixelMapMap` 必须同时命中才算“已有图”，否则会出现标记已加载但实际没图、被永久跳过。

### 涉及相机与 USB 的改动要在真机上确认

流程：构建 → 部署 → 告诉用户改了什么 → 用户把手机从电脑拔开、接上相机测试 → 用户反馈结果 → 用户把手机接回电脑 → 查看 hilog。手势与相机相关功能在没有真机确认之前，不要当成已经可用。

模拟器能验证布局、状态、导航、主题与材质，但 PTP、相机通信、EXIF 方向与 GPS 写入、系统相册保存、真实性能与手势手感必须真机确认。

## DevEco CLI、skills 与模拟器

### DevEco CLI（`devecocli`）

华为官方的 agent coding 工具包（npm 包 `@deveco/deveco-cli`），包装 hvigor、ohpm、hdc、模拟器工具链，内置离线文档与官方 skills。本机装的是 1.3.0，命令名是 `devecocli`。包内自带 `SKILL.md` 与 `docs.zip`。

#### 环境变量（分平台）

macOS 上**什么都不用设**，`devecocli` 会自动发现 `/Applications/DevEco-Studio.app/Contents/tools/hvigor`。把 `DEVECO_CLI_CLT_PATH` 指向 `Contents/tools` 反而报 `Invalid DEVECO_CLI_CLT_PATH`。

Linux 上两个都必需：

```bash
export DEVECO_CLI_CLT_PATH=~/.hmos/command-line-tools   # CLT 不会被自动发现
export DEVECO_CLI_SKIP_VERSION_CHECK=1                  # 本机 CLT 6.1.0.830 低于 CLI 要求的最低版本
```

Linux 的 CLT 位于 `~/.hmos/command-line-tools/`，内含 hvigor 6.23.5、codelinter 6.0.240、ohpm 与 HarmonyOS SDK API 23。升级 CLT 之后可以去掉第二个变量。

#### 本项目实测可用

| 命令 | 用途 | 实测平台 |
|---|---|---|
| `devecocli build` | 构建，等同 `hvigorw assembleHap`，输出更简洁；`devecocli build clean` 可清理 | macOS、Linux |
| `devecocli check lint [path]` | 运行 code-linter，支持 `--fix`、`--format json`、`--output-path` | macOS、Linux |
| `devecocli docs catalog` / `search` / `read` | 离线文档目录、全文检索、读取完整文档 | macOS、Linux |
| `devecocli device list` | 列出真机与模拟器 | macOS、Linux |
| `devecocli emulator list` / `start` / `stop` | 模拟器实例管理，见下文 | macOS |
| `devecocli skills list` / `find` / `add --skill <name> --path <dir>` | 官方 skills（53 个）的检索与安装，`--all` 全装 | macOS、Linux |

官方 skills 的实体仓库在 `/home/ysy/Projects/hmos/.skills/`，Linux 开发机上本项目通过 `.agents/skills` 符号链接接入。链接丢失时重建（路径只在 Linux 上存在）：

```bash
mkdir -p .agents && ln -s /home/ysy/Projects/hmos/.skills .agents/skills
```

#### skills

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

#### 需要设备、登录或尚未验证

- `run` / `--apply <file>`（快速增量部署，要求 DevEco Studio ≥ 6.1.1）/ `--hotreload`（需要后台进程保活）
- `log`（hilog 与崩溃日志）、`ui`（界面检视与操作），两者都需要设备
- `signature generate`（生成签名材料，需先 `devecocli auth login` 且连接设备）
- `check compat`（两个 SDK 版本之间的破坏性变更扫描）、`update`（更新 CLI 自身）

签名与安装仍走 `deploy.sh`（仅 Linux），`devecocli` 只用来构建、静态检查、模拟器与查文档。macOS 上构建产物是 AgentDebug 签名的 HAP，能装模拟器的只有 unsigned 那个；真机走无线调试装 signed 包，已验证。

## 查 HarmonyOS 官方资料

### 强制前置步骤

不要凭记忆回答，也不要只翻本地 `.d.ts` 就下结论——`.d.ts` 只看得到签名，看不到“什么条件下才生效”。

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

### 为什么这一步不能省（本项目真实踩坑）

做沉浸光感 UI 时只查了本地 SDK 的 `@ohos.arkui.uiMaterial.d.ts`，看到 `@since 26.0.0` 就判定“项目 targetSdk 23 用不了”，转而用 `backgroundBlurStyle` 手搓毛玻璃。而知识库的《HDS 组件沉浸光感》明确写着 **UI Design Kit 的 `HdsNavigation` / `HdsTabs` 自 6.1.0(23) 起就支持 `systemMaterialEffect`**。根因是：SDK 的 OpenHarmony 目录只覆盖 ArkUI 那部分，HMS 侧的 `@kit.UIDesignKit` 在 `sdk/default/hms/ets/kits/`，翻一个目录就漏了。

### 备用渠道与补充材料

- `devecocli docs`（`catalog` / `search` / `read`）——离线文档目录、全文检索、读完整 markdown（不截断）
- 本机 SDK 类型声明：OpenHarmony 侧 `…/sdk/default/openharmony/ets/api/`（Linux 为 `~/.hmos/command-line-tools/sdk/default/openharmony/ets/api/`），HMS 侧 `…/sdk/default/hms/ets/kits/`
- 两者的分工：`.d.ts` 确认签名、参数类型、`@since`；**“生效范围、前置条件、算力档位、和别的属性冲突”必须回知识库确认**，这类信息不在类型声明里

已经核过的具体结论见下文「已核对官方结论」。

## 架构

### 分层与入口

- `EntryAbility` 负责窗口尺寸、全屏、系统栏主题、避让区监听，加载 `pages/Index`；`Index` 用 `Navigation` + `NavPathStack`，`route_map.json` 注册 NavDestination，`MainScreen` 承载画廊 / 相机 / 设置三个标签页。
- 页面只调用 services；services 再调用 PTP 会话层与 `libentry.so`。入口、标题栏与转场的完整规则见下文「导航、标题栏与沉浸光感」。

### 服务与数据

| 模块 | 职责 |
|---|---|
| `services/CameraService.ets` | 扫描、连接、下载、缩略图/原图加载、缓存与 GPS 匹配 |
| `services/GpsRecorder.ets` | 连续定位、后台长时任务、按天聚合、模拟轨迹 |
| `services/ThumbnailCache.ets` | 缩略图磁盘缓存、manifest、过期清理 |
| `services/AppLog.ets` | 内存环形缓冲 + `app_log.txt` 追加写 + hilog |
| `services/UsbAttachWatcher.ets` | USB 相机插入监听：前台提示扫描、后台通知 |
| `pages/PtpHost.ets` | USB/PTP 会话层 |
| `model/SettingsStore.ets` | 持久化设置 |
| `model/LanguageStore.ets` | 应用语言偏好（单独 PersistenceV2 key，默认跟随系统） |
| `model/PhotoEntry.ets` | `PhotoEntry`、`DownloadRecord`、`GpsRecord` 等数据结构 |

缓存阶段、数据模型、GPS 与地图服务的细节见 [SERVICES.md](SERVICES.md)。

### Native bridge

`libentry.so` 暴露的函数，类型声明在 `entry/src/main/cpp/types/libentry/Index.d.ts`：

- 命令构造：`buildOpenSession`、`buildCloseSession`、`buildGetDeviceInfo`、`buildGetStorageIDs`、`buildGetObjectHandles`、`buildGetObjectInfo`、`buildGetThumb`、`buildGetObject`、`buildGetPartialObject`、`buildGetObjectPropList`
- 响应解析：`processResponse`、`parseDeviceInfo`、`parseStorageIDs`、`parseObjectHandles`、`parseObjectInfo`、`parseObjectPropList`

`processResponse(data, expectData)` 累积多包 USB 数据，返回 `0` 继续读、`1` 拿到数据包、`2` 拿到响应包（`responseCode` 为 `0x2001` 表示成功）。完整协议与 Native 引擎见 [SERVICES.md](SERVICES.md)。

## HarmonyOS 开发知识

> 以下为跨页面的 ArkUI/HarmonyOS 规则，页面级设计见 [PAGES.md](PAGES.md)。

### 状态管理（V2）

#### 只用 V2

V1 装饰器（`@State`、`@Prop`、`@Link`、`@StorageLink`、`@StorageProp`、`@Provide`、`@Consume`、`@Observed`、`@ObjectLink`、`@Track`、`@Watch`）禁止出现在新代码里。

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

#### 数据流

`CameraService` 是 `@ObservedV2` 单例，`photos`、`photosVersion`、`thumbnailVersion`、`scanning`、`connected`、`statusText`、`lastDecodedHandle` 等字段带 `@Trace`。页面用 `@Local svc: CameraService = CameraService.getInstance()` 直接持有，读到 `@Trace` 字段就会自动刷新。跨页面传递的状态（下载进度、已下载集合、GPS 状态）由 `MainScreen` 用 `@Param` 下发，子页面用 `@Event` 上报。持久化设置放在 `SettingsStore`（`@ObservedV2` + `PersistenceV2.globalConnect()`），任何组件直接取单例。

**注意**：`thumbnailPixelMapMap`、`orientedDisplaySizes`、`compressedCache` 是普通 `Map`，不参与自动追踪。界面能刷新依靠 `thumbnailVersion`、`lastDecodedHandle`、`photosVersion` 这类手工计数被 `build()` 读到。改动缩略图与原图加载逻辑时，必须同时维护这些计数。

#### 三个必须记住的刷新坑

2026-11-05 / 2026-11-08 实测：

1. `Repeat` 命中相同 key **不会重跑 `each`**。把 `Image(pm)` 直接写在 `@Builder` 里，缩略图解码完成后单元格会永远停在占位图。正确做法是把单元格内容抽成独立 `@ComponentV2`（见 `GalleryPage.ets` 末尾的 `ThumbImage`），并在 `build()` 里调 `svc.thumbForRender(handle)`——该方法内部先读一次 `thumbnailVersion`，从而让组件订阅材质变化（Map 本身不可观测）。
2. `@Builder` 的**值参数不会刷新**。例如 `WideChip(label, selected, onTap)` 这种写法，点击后 `selected` 变了但高亮不跟随。凡是会变化的状态，都要在构建期直接读（`this.settings.darkMode === ...`），不要经由 `@Builder` 形参传入。
3. `Tabs.onChange` 在**切换动画结束后**才触发（本项目动画 220ms）。用它驱动标题栏、自定义底部页签、浮岛等视觉状态，旧页的按钮会在新页上停留整个动画时长。视觉索引要用独立的 `visualTab`，在 `Tabs.onSelected`（点击页签 / 滑动离手开始切换动画时触发）里更新；`onChange` 只负责 `Tabs({ index })` 的受控索引与持久化。官方 `Tabs` 示例 17 与 `onChange` 说明就是这个用法；`onSelected` 里不能回写 `Tabs` 的受控 `index`，所以两个索引必须分开。

更多按页面的应用方式见 [PAGES.md](PAGES.md)。

### 手势与滚动坐标（2026-11-09 核对）

- **`GestureEvent.offsetX/offsetY` 是屏幕空间位移**（「相对手指按下位置」，单位 vp），不会被 `.scale()` 缩小。凡是把位移加到屏幕空间的 `translate` 上，**不能再乘缩放倍数**——预览器曾经乘了 `zoom.scale`，5 倍缩放时手指划 100vp、照片走 500vp。
- 同理，`GestureEvent.pinchCenterX/Y` 已是屏幕坐标，捏合锚点可以直接用。
- 多选框选这类「手指跨单元格」的交互不要给单元格加 PanGesture（跨格收不到 Move），也不要和 List 的滚动抢优先级。当前做法：多选态 `List.enableScrollInteraction(false)` + `List.onTouch` 原始触摸 + 官方 `Scroller.getItemIndex(x, y)`（API 14）把坐标换成 flat 列表下标，再用 `Scroller.getItemRect(index)`（API 11）拿行矩形、按列均分反推单元格。
- `TouchObject.x/y` 是**相对注册 onTouch 的组件**，与 `getItemIndex/getItemRect` 的坐标口径一致，可以直接混用。
- 拖到列表上下边缘时要自己开定时器 `scrollBy`（官方 List 不会替你做），否则长列表选不到屏幕外的照片。

### 后台长时任务与通知进度（2026-11-09 核对）

- 长时任务：`module.json5` 的 `abilities[].backgroundModes` 要声明类型（本项目 `location` + `dataTransfer`），权限 `ohos.permission.KEEP_BACKGROUND_RUNNING`。申请成功后**通知栏出现系统通知**，用户划掉通知系统会自动停任务。
- **一个 UIAbility 同时只允许一个长时任务**（API 20 及以前）；API 21 起才有 `startBackgroundRunning(context, ContinuousTaskRequest)` 多任务版本。两个业务都要保活时，要么合并类型，要么换新接口。
- **长时任务通知的内容应用改不了**：`ContinuousTaskRequest` 只有模式、子模式、`wantAgent`、`continuousTaskId`，没有进度或自定义文案。
- 想在通知栏显示**进度环**，用系统预置通知模板 `NotificationTemplate`：`name: 'downloadTemplate'`，`data` 只认 `title` / `fileName` / `progressValue(0~100)`，`>= 100` 时环消失。模板只覆盖上传/下载场景。这是普通通知，和长时任务通知是两条。
- DATA_TRANSFER 的附加约束：进度首次更新超过 10 分钟会被取消，且官方要求「更新进度的通知类型必须为实况窗」。实况窗的 `event` 只支持固定场景（打车/配送/取餐/航班/排队/比分/租赁/计时/运动/导航/打卡/快递/高铁），**照片导入不在其中**，不要硬套场景。
- 实现与日志见 [SERVICES.md](SERVICES.md)「传输期间的后台长时任务与通知进度环」。

### 导航、标题栏与沉浸光感

#### 导航骨架

- `pages/Index.ets` 是唯一入口（`@Entry`），内部用 ArkUI 原生 **`Navigation`** + `NavPathStack`，隐藏系统导航栏（`hideNavBar(true)`），并注册自定义转场 `customNavContentTransition`。
- `route_map.json` 注册 NavDestination：`MainScreen`、`PhotoViewerScreen`、`GpsManagementPage`、`GpsTrackViewerPage`、`CacheManagementPage`。
- 二级页（缓存管理、定位记录、轨迹全屏）都走 `route_map.json` 的 NavDestination，用 `NavPathStack.pushPath` / `pop`，不是 `@Entry`，也不再用 `router.*`。
- `MainScreen` 承载三个标签页（画廊 / 相机 / 设置）。

#### 标题栏的几种形态

- **一级页**用 `.title({ builder: this.TitleBar, height: titleBarInsetVp() }, { barStyle: BarStyle.STACK })` 自定义 builder，见下文「顶部标题栏」；标题栏里的玻璃胶囊用通用属性 `systemMaterial`。
- **轻量二级页**（如缓存管理）仍用 `.hideTitleBar(true)` + `components/PageHeader.ets`（自己避让状态栏）。
- **定位记录页与轨迹全屏页**用原生 `.title()` 标题栏，返回/选择/日期胶囊才能拿到真材质。
- **预览器** 用 `NavDestination.title({ builder, height }, { barStyle: BarStyle.STACK })` 挂自己的标题栏：标题栏是通用控件唯一能拿到真材质的两处区域之一；内容区顶部仍留 56vp（与 `PhotoMorph` 同源）让开。底部下载/收藏/分享放在一个 56vp 高的 `Tabs` 悬浮页签里当材质背板。转场见 [PAGES.md](PAGES.md)。
- 轨迹全屏页用 `BarStyle.STACK` 自定义标题栏，地图内容可以延伸到标题栏下方；`hideBackButton(true)`，否则系统返回键会和自定义返回键叠成两个。

#### 内容避让与底部留白

- 首屏内容避让用**滚动容器的 `contentStartOffset(titleBarInsetVp())`**（不是 `padding-top`），详见下文「顶部标题栏」。
- **底部要给悬浮页签留空间，但不能用 `List.padding({ bottom })`**：那会收缩 List 的可视区域，内容在胶囊上方就被裁断、中间露出一条空带。正确做法是给 List 末尾加一个 104vp 占位项（`FlatItem.tail()`）；`Scroll` 页面（相机 / 设置）用内容末尾的 `padding-bottom` 即可。

#### 沉浸光感总开关与生效范围

- **应用级开关**在 `entry/src/main/module.json5` 的 `metadata`：`{ "name": "ohos.arkui.UIMaterial.state", "value": "enable" }`。开启后 `Toggle` / `Slider` / `Select` / 弹窗类组件在全页面生效，其余组件只在 Navigation/NavDestination 标题栏与底部 TabBar 生效。
- **材质只在「Navigation/NavDestination 标题栏」或「横向 Tabs 且 barPosition: End 的底部 TabBar」里生效**（官方《组件适配沉浸光感》）。写在内容区不生效——所以胶囊必须画在 `title({ builder })` 里，不能挪到页面内容里。
  - 例外是官方「按钮与选择类」里明确列出全页面生效的 `Select` / `Toggle` / `Slider`：`Select`、`Toggle(Switch)`、`Slider` 在内容区也能拿到真材质（应用级开关已开时默认生效）。`Button`、`ChipGroup`、`SegmentButton` **不行**，内容区里只能写成普通胶囊。所以设置页的选项控件用 `Select` + `Toggle`，相机页的主操作用标题栏胶囊。
  - `Select` 的按钮文字只认 `value()`，`selected()` 只控制菜单里的选中态；只给 `selected()` 会渲染成一个**只有箭头、没有文字**的空胶囊。设置页的 `SettingSelectRow` 就是因此才单独取了 `selectedLabel()`。

#### 底部页签

- 底部是系统 `Tabs` 的**悬浮页签**：只设 `barOverlap(true)` + `Tabs.barFloatingStyle({ barBottomMargin: this.navIndicatorVp(), maskColor: Color.Transparent, systemMaterial: new uiMaterial.ImmersiveMaterial({ style: REGULAR, interactive: true }) })`。
- **不要**再设 `barBackgroundColor` / `barBackgroundBlurStyle`（会盖住材质），也不要设 `barMode`（会破坏悬浮样式的默认布局；`vertical(false)`、`barPosition: End` 为默认）。`barHeight` 只在多选态动态置 0。
- **`scrollable` 例外**：为了实现画廊「按住拖拽多选」并避免横向拖动被 Tabs 抢走，2026-11-09 起**故意**设了 `.scrollable(false)`（REQ-001，用户已确认接受取消 3 个 tab 之间的左右滑动）。模拟器实测：悬浮页签的材质、圆角、位置与点击切换都正常，只是左右滑动不再切页。此前「不要设 `scrollable`」的经验来自同时设了 `barMode` 的场景；**再改动这一行要重新确认材质与页签点击**。
- **底边距必须自己算**：窗口是 `setWindowLayoutFullScreen(true)`，Tabs 是全屏的，`barFloatingStyle` 不会自动避让手势条。`barBottomMargin: this.navIndicatorVp()` 才让胶囊底边正好贴在手势条避让区上沿；写成固定的 10 会让胶囊压在手势条上（官方图库也是这么摆的）。
- **实测（2026-11-06，模拟器 Mate 80 + 真机 VYG-AL00）**：只写 `systemMaterial` 时，两边都能正确呈现磨砂透明，内容从胶囊下面透出且带模糊与折射。
- **踩过的坑**：一度以为“模拟器渲染不出材质”，其实是同时设了 `barBackgroundColor` + `barBackgroundBlurStyle`，把材质整个盖住了。**只要这两个属性还在，材质就一定看不到**——不是设备能力问题。排查时先确认没有别的东西压在上面。
- 多选时隐藏页签栏：`.barHeight(this.gallerySelectMode ? 0 : 56)`。实测 `barHeight(0)` 对悬浮样式的页签栏有效，置 0 后 `barFloatingStyle` 的材质与圆角一并消失、操作栏可以占据同一位置；恢复 56 后悬浮样式正常。**这是唯一需要动态改 `barHeight` 的场景**，其他时候不要碰它。详见 [PAGES.md](PAGES.md)。

#### 顶部标题栏

**顶部标题栏 = 大标题浮层 + 浮动玻璃控件 + 渐隐遮罩**（2026-11-06 对照官方「备忘录」逐帧校准）。官方形态**不是**一条通栏材质背板：

1. 顶部只有**独立的浮动玻璃控件**（圆形钮 / 胶囊），它们之间是纯页面底色，看不到任何“条”；
2. 大标题是**纯文字浮在内容上**，内容滑到标题后面时被**平滑压淡**——`linearGradient` 用 4 档压色（`nav_bg` 77% → `nav_bg_mid` 55% → `nav_bg_weak` 20% → `bg_page_fade` 0%）做缓出，衰减一直延伸到标题下方 28vp（`TITLE_FADE_EXTRA`）。**不要**做成「上不透明 → 下全透明」（内容被抹掉），也**不要**做成均匀一块压色（看着像一条带子）；标题要停在渐隐区**顶部**（状态栏下方），不要压在渐隐区底边；
3. 玻璃控件用 `uiMaterial.ImmersiveMaterial`（`ULTRA_THIN` + `interactive: true`），与底部页签同一套材质，且与滚动无关、常驻；
4. 压色之外还要一点点**磨砂**，但**不能用 `backdropBlur`**：它的边界是硬的，标题栏下边缘会留下一条泾渭分明的横线（2026-11-06 实测，用户一眼看出来）。正解是给**内容容器**加 `linearGradientBlur(96, { fractionStops: [[1, 0], [0.9, 0.06], [0, 0.18], [0, 1]], direction: GradientDirection.Bottom })`——模糊强度连续衰减到 0，天然没有边界。
   - **`fractionStops` 必须覆盖到位置 1**（2026-11-09 实测）：每一档是 `[模糊程度, 模糊位置]`，位置要严格递增，且**最后一档的位置必须是 1**。只写到 `[0, 0.18]` 时，0.18→1 这段的模糊遮罩没有定义，模拟器（Mate 80 / 7.0.0）会在整个内容区画出大片三角碎片；补上 `[0, 1]` 后立刻恢复干净。

- 实现：`MainScreen.TitleBar` = `Stack` 里「一整块 `linearGradient` 渐隐层」+「底部 56vp 的一行：28fp 大标题 + 右侧两颗玻璃胶囊」，`.title({ builder, height: titleBarInsetVp() }, { barStyle: BarStyle.STACK })`。
- **标题栏要延伸到状态栏**：`EntryAbility` 里 `setWindowLayoutFullScreen(true)`，`applyThemeSystemBars` 把 `statusBarColor` 设成透明；标题 builder 的渐隐层自然铺到最顶，标题文字靠 `Stack` 的底部对齐停在状态栏下方。
- **`Navigation` 上不要再加 `ignoreLayoutSafeArea(TOP)`**：加完 `NavDestination` 的标题栏会被整个推出可视区，直接消失（2026-11-06 实测）。
- **`NavDestination` 上不要再加 `bindToScrollable`**：它的语义是「上滑隐藏、下滑显示」标题栏，一滚标题栏就没了。

#### 内容区浮动卡片拿真材质

**做法：挂进标题栏 builder，再用 `position` 画到目标位置**（2026-11-06 突破）。这是目前唯一同时满足「真材质 + 不挡交互」的做法，下载进度浮岛与多选底部操作栏都这么干：

- 在 `MainScreen.TitleBar` 的 `Stack` 里加一层「浮岛层」，把组件写成它的子节点；
- 外面包一层 `Column` 承载 `.position({ top, left/right })` 与 `.systemMaterial(this.floatMaterial)` —— **自定义组件不能直接链式挂通用属性**（会报 `does not meet UI component syntax`），必须包容器；
- `position` 的原点是标题栏顶部（= 屏幕顶部，因为 `windowLayoutFullScreen`），所以可以直接用屏幕绝对 vp 坐标（`WindowUtils.windowHeightPx` 换算）；
- **标题栏容器不裁剪超出边界的子节点**，所以能画到屏幕中部和底部；材质照样生效，且**不会拦截其他区域的点击**（实测点「全选」、点缩略图、滚列表都正常）。

**全屏预览器的底部操作栏（2026-11-10，用户已确认保留）**：内容区需要一条「下载 / 收藏 / 分享」玻璃操作栏时，用一个高度 56vp、`TabContent` 为空的 `Tabs` 当材质背板（`barOverlap(true)` + `barPosition: End` + `barFloatingStyle.systemMaterial`），照片区域仍由外层 `Column` 承担；直接给内容区的 `Row` 设 `systemMaterial` 不生效。这是为拿系统材质而接受的**设计语义例外**（不符合《底部页签》3–5 个一级导航的规范），2026-11-10 用户确认保留；若要严格合规，改成普通底部工具栏 + `backgroundBlurStyle`/渐变。

**不要试图用弹层（popup / tips / dialog）在内容区拿材质 —— 它会吞掉整页点击**（同日实测，试过又退回）。官方确实把 `Popup控制` / `Tips控制` / `菜单控制` / `半模态转场` / `PromptAction` 列为「沉浸光感可在全页面生效」的接口，`bindPopup` + `CustomPopupOptions.systemMaterial` 也真能渲染出材质（折射、高光都对）。但**弹层一显示就铺一层全屏遮罩**：点标题栏「全选」、点缩略图、滚动列表全部失效；`autoCancel: false` + `focusable: false` + `levelMode: LevelMode.EMBEDDED`（需 `import { LevelMode } from '@ohos.promptAction'`）都救不回来。

#### bindSheet 的材质

- **`bindSheet` 不跟随应用级开关**：半模态的沉浸光感必须通过 `SheetOptions.systemMaterial` 显式设置（本项目用 `THICK`），设置后不要再设 `backgroundColor` / `blurStyle`，否则会盖住或重复处理材质。轨迹明细面板就是靠这一条拿到系统材质。
- 用法与挡板交互见 [PAGES.md](PAGES.md)。

#### 禁区、兜底与可用性

- **不要用 HDS 的 `HdsNavigation` / `HdsNavDestination`**：2026-11-06 试过又全部退回。官方《沉浸光感》写明 HDS 的 `systemMaterialEffect` 只给**标题栏按钮**材质，背板永远拿不到沉浸光感，轻划时看着就是全透明。**HDS 的 `HdsNavDestination.titleBar` 拿不到背板材质**，官方原文是「可为**标题栏按钮**设置沉浸光感视效」，轻划时整条标题栏会变成全透明（踩过）。所以本项目用 ArkUI 原生 `Navigation` / `NavDestination`，不用 HDS 导航组件。
- **`enableComponentSafeArea` / `avoidLayoutSafeArea` / `titleBar(...)` / `systemMaterialEffect` 都是 HDS 专有**，ArkUI 的 `NavDestination` 没有这些，别混用。
- **兜底方案**（万一标题栏壳子走不通）：`backgroundColor(glass_bg)`（55% 白/黑）+ `backgroundBlurStyle(BlurStyle.COMPONENT_THICK)`，官方 FAQ 的降级做法。但观感明显不如真材质，只在真材质不可用时用。判断依据看日志：`Material inactive: out of scope. Use component in navigation title bar or Tabbar.`
- **材质可用性**：`uiMaterial.isImmersiveMaterialSupported()` 为 `true`、`getGlobalMaterialLevel()` 为 `EXQUISITE` 时材质可正常渲染（模拟器与真机均验证过）。判断依据是**胶囊背后有没有被模糊的内容**，不是胶囊的底色。
- **功耗约束**：不要在大面积容器上用材质，不要与 `backgroundBlurStyle` / `backgroundEffect` 叠加，同一子树只设一次；算力档位交给 `MaterialLevel.ADAPTIVE` 或系统自适应。

更多官方结论见下文「已核对官方结论」。

### 设计系统与资源

#### 资源解析

- `$r('app.type.name')` 从 `entry/src/main/resources/` 解析。浅色在 `base/element/`，深色在 `dark/element/`。
- 颜色模式跟随系统：`COLOR_MODE_NOT_SET`（值为 -1）表示不设置，`COLOR_MODE_LIGHT` / `COLOR_MODE_DARK` 为显式指定。

#### UI 令牌

字号、圆角、行高、图标尺寸统一定义在 `entry/src/main/ets/utils/UiTokens.ets`，页面和组件一律引用，不再手写数字：

| 类别 | 取值 |
|---|---|
| 字号 `FontSize` | Display 28 / Title 22 / PageTitle 20 / CardTitle 16 / Body 15 / Section 13 / Caption 12 / Micro 10 / Nano 9（角标） |
| 图标 `IconSize` | Small 12 / Body 16 / Nav 20 / Large 24 / Empty 44 |
| 圆角 `Radius` | Card 24 / Inner 18 / Chip 12 / Thumb 4 / Line 1 |
| 行高 `RowHeight` | Single 56 / Double 64 |
| 控件高度 `ControlHeight` | Pill 40 / Bar 56 |

- 胶囊/圆形按钮的圆角一律用 `pillRadius(height)`，不要写死半高。
- 卡片 24、卡内嵌块 18、小胶囊 12 是三档静态圆角；新增页面先选角色，再取值。
- 字号按角色取值，不按页面取值；同一语义在不同页面必须用同一个令牌。

#### 颜色资源

颜色资源共 49 条（`base/element/color.json` 与 `dark/element/color.json` 各一份，含 `start_window_background`），分四组：

- 品牌与语义：`primary`、`primary_light`、`primary_soft`、`status_connected`、`status_disconnected`、`status_error`、`button_danger`
- 背景、材质与文本：`bg_page`、`bg_surface`、`bg_page_fade`、`bg_surface_fade`、`bg_debug_log`、`thumbnail_placeholder`、`glass_bg`、`nav_bg`、`nav_bg_mid`、`nav_bg_weak`、`progress_track`、`scrim`、`filter_chip_bg`、`card_border`、`divider`、`text_primary`、`text_secondary`、`text_tertiary`、`text_on_primary`、`text_on_dark`、`log_text`
- 预览器专用（跟随深浅色；浅色为页面底、深色为纯黑）：`viewer_backdrop`、`viewer_scrim`、`viewer_scrim_top`、`viewer_scrim_clear`、`viewer_banner_bg`、`viewer_text_on_dark_80`、`viewer_text_on_dark_70`、`viewer_chrome_text`、`viewer_chrome_text_secondary`、`viewer_glass_button`、`viewer_chrome`、`viewer_chrome_motion`、`viewer_material_tint`、`viewer_placeholder_bg`、`viewer_placeholder_thumb`、`viewer_placeholder_image`、`viewer_text_secondary`、`viewer_text_tertiary`、`viewer_accent`

设计语言为 HarmonyOS 沉浸光感：

- 冷灰页面底
- 纯黑/白卡片
- 品牌蓝 `#0A59F7`（深色 `#4C91FF`）只用于主行动与选中态
- 底栏与预览器标题栏使用半透明模糊材质

**页面内监听深浅色变化**：用 `ApplicationContext.on('environment', callback)` 注册、`off('environment', callbackId)` 注销。回调里用 `WindowUtils.isDarkMode(ctx)` 取应用的有效模式，**不能用 `config.colorMode`**：官方文档明确，应用显式设置深浅色后，系统主题变化仍会触发该回调。`backgroundBlurStyle` 的 `colorMode`、`chromeBg()` 等在 build 里计算的值不会随资源系统自动刷新，必须用 `@Local` 状态驱动页面重建；预览器缩略图条已按此处理（2026-11-10，1.30.1）。

**新增界面一律引用颜色资源与 UiTokens，不要写定颜色、字号、圆角、行高或图标尺寸。**

- 已删除的死 token：`bg_elevated`、`tab_bar_bg`、`list_bg`、`action_bar_bg`、`detail_bg`、`sheet_bg`。
- 裸色只有两处例外，均因 API 不接受 `Resource`：`WindowUtils` 的系统栏颜色字符串、`GpsTrackSketch` 的 Canvas `fillStyle`。两处取值与 `color.json` 手工保持一致，改 token 时必须同步。

#### 字符串资源与多语言

界面文案一律走资源，不写死在组件里：

- `base/element/string.json` + `base/element/plural.json`：简体中文，也是未匹配语言时的兜底。
- `en/element/*.json`：英文。语言限定词只写 `en`，覆盖 en-US / en-GB 等所有英语区域。
- `zh_Hant/element/*.json`：繁体中文。只写文字限定词 `zh_Hant`，覆盖 zh-Hant-TW / zh-Hant-HK 等。
- `AppScope/resources` 下的同名语言目录负责应用名 `app_name`；模块的 `EntryAbility_label`、权限申请理由也各有翻译。

约定：

- 静态 UI 文案用 `$r('app.string.xxx')`；带占位符用 `$r('app.string.xxx', arg1, arg2)`；数量用 `$r('app.plural.xxx', count, count)`。
- service / utils 里运行时拼出来的状态、错误与单位文案走 `utils/L10n.ets`：`L10n.tr(name, ...args)` / `L10n.plural(name, count, ...args)`。资源管理器在 `EntryAbility.onCreate` 注入，`Index.aboutToAppear` 再补一次（预览器不走 Ability）。
- 日期与月份名用 `utils/DateTimeText.ets` 的 `Intl.DateTimeFormat`，不要在资源里维护 12 个月份；「今天 / 昨天」仍走资源。
- 调试日志（Settings 页的日志框）保持中文，属于开发诊断信息，不做翻译。
- 新增文案必须同时补 `base` / `en` / `zh_Hant` 三份；占位符用 `%1$s` / `%2$d` 形式，便于翻译调整语序。

应用内语言切换在「设置 → 外观 → 语言」：

- 选项：跟随系统（默认）/ 简体中文 / 繁體中文 / English。
- 偏好存在 `model/LanguageStore.ets`，**不要**把 `appLanguage` 追加到 `SettingsStore`：PersistenceV2 恢复旧对象时不会补新增的 `@Trace` 字段。
- 切换时调用 `i18n.System.setAppPreferredLanguage('zh-Hans' | 'zh-Hant' | 'en')`；选「跟随系统」传 `'default'` 清空偏好。
- 官方约束：应用偏好语言在冷启动时加载。设置成功后用 `ApplicationContext.restartApp(want)` 重启进程；`want` 用当前 `UIAbilityContext.abilityInfo` 的 bundle / module / ability 构造，不要写死包名。
- 切换前弹确认框；取消（按钮或点遮罩）必须把 `LanguageStore.appLanguage` 退回原值，避免 Select 显示与实际语言不一致。

### 已核对官方结论

- `linearGradientBlur(radius, options)` 的 `fractionStops` 是 `Array<[number, number]>`，每档含义是 **`[模糊程度, 模糊位置]`**，两个值范围都是 0–1；**模糊位置必须严格递增**，且数组至少 2 档，最后一档位置要写到 1，否则未覆盖区间的遮罩没有定义（模拟器上表现为三角碎片）。
- 模拟器（Mate 80，HarmonyOS 7.0.0）的渲染服务在日志里会打 `GEXFrostedGlassBlurShaderFilter::IsFilterSupported is false`：**GPU 不支持磨砂玻璃（沉浸光感）着色器**。单个悬浮页签的材质能看，但「标题栏材质按钮 + 底部操作栏材质 + 页签材质」叠加并持续重绘（多选态、画廊滚动/切页、预览器返回）时，会退化成大片多边形色块。**这是模拟器渲染管线的缺陷，不是应用代码问题**（2026-11-09 用 `git stash` 对照基线同样复现）。官方依据：UI Design Kit「模拟器支持情况」明确模拟器**不支持 HDS 沉浸视效（含沉浸光感材质）**；图形模块文档也列了「模拟器与真机的差异」；模拟器 FAQ 对图形异常的建议是清数据重启、更新驱动/模拟器。
- **2026-11-09 深入 A/B**（画廊顶部彩色三角形）：把应用级 `ohos.arkui.UIMaterial.state` 设为 `disable`（`hilog` 里着色器日志归零）、全部 `systemMaterial` 换 `uiMaterial.Material.empty`、`backgroundBlurStyle` 换 `NONE`、完全移除 `linearGradientBlur`、去掉 `List.clip(false)` / `cachedCount(6, true)` / `virtualScroll`、关掉扫描浮卡、缩略图换成纯色块 —— 顶部大块彩色三角形**仍然复现**，形状随重绘变化；应用内 `Window.snapshot()`（`--ps shot`）同样能截到。结论：**不是某一个应用属性可以稳定规避的渲染器缺陷**，不要把这类整页截图当成布局验收依据。
- **处理方式**：布局、状态、导航、交互用模拟器验证；**材质/模糊观感与整页视觉以真机为准**。模拟器上如果必须截图，可以用设置页「调试 → 关闭磨砂玻璃」（`utils/GlassEffect.ets` 统一换空材质、`BlurStyle.NONE`、0 模糊）减少材质叠加造成的乱花，但它**不能保证消除**上述渲染器缺陷；遇到持续花屏先重启/清数据重启模拟器、更新 DevEco Studio 与模拟器镜像，仍复现就用真机或向华为反馈（附 `GEXFrostedGlassBlurShaderFilter::IsFilterSupported is false` 日志与复现步骤）。

- USB 单次 `bulkTransfer` 的总数据（含 pipe、endpoint、buffer、timeout）必须小于 200KB，官方 `usbManager` 参考的 `bulkTransfer` 一节明确写了，超出返回 -1。`usbSubmitTransfer` 走 ashmem，官方只约束 `length` 为 [0, INT_MAX]；实测 1MB / 8MB 可用。改动缓冲区必须在真机验证。
- `@SyncMonitor`：官方文档写明从 API 23 开始支持，`@Monitor` 从 API 12 开始支持。
- `Repeat`：`LazyForEach` 的官方迁移写法是 `Repeat(data).virtualScroll()`，没有 `RepeatForEach` 这个组件。
- `Tabs.onChange` 在 Tab 页签切换后触发，滑动时是滑动动画结束后；自定义页签 / 标题栏联动应在 `onSelected`（API 18+，点击或滑动离手开始动画时触发）或 `onAnimationStart` 中更新视觉索引。`onSelected` 回调里不能通过 `index` / `changeIndex()` 改 Tabs 当前页，所以视觉索引必须独立。
- 应用偏好语言：`i18n.System.setAppPreferredLanguage()` 设置应用语言，传 `'default'` 恢复跟随系统；官方写明资源在**冷启动**时按偏好语言加载，所以本项目设置后用 `ApplicationContext.restartApp()` 重启进程。`getAppPreferredLanguage()` 用于读取偏好。
- EXIF Orientation：官方 FAQ 给出 8 个取值与字符串表示的对应关系（1 = `Top-left`，……，8 = `Left-bottom`），读取时返回字符串，未写入该字段的图片按不旋转处理。
- GPS 经纬度：官方把 `GPSLatitude` / `GPSLongitude` 定义为三个 RATIONAL 值（度、分、秒），典型写法是 `dd/1,mm/1,ss/1`；本项目写入的是逗号分隔的度分秒（如 `43,49,23.16`），写完读回验证。
- 图片编码默认不保留 EXIF：`PackingOption.needsPackProperties` 默认 false。缩略图缓存里保存的编码结果因此没有 EXIF，方向信息另外记在 manifest 里。
- 沉浸光感有两条技术路线，版本门槛不同：
  - **ArkUI 侧**：`uiMaterial.ImmersiveMaterial` + 通用属性 `systemMaterial()`，`@since 26.0.0`，且要求 **targetSdkVersion ≥ 26.0.0** 才生效。本项目 targetSdk 与 compatibleSdk 都是 26.0.0，可直接使用，无需版本保护。
  - **UI Design Kit 侧**：`HdsNavigation` 的 `TitleBarStyleOptions.systemMaterialEffect`、`HdsTabs` 的 `HdsTabsFloatingStyle.systemMaterialEffect`，**自 6.1.0(23) 起支持**，无需版本保护。
- 沉浸光感的生效范围有限制：除弹窗类组件与 `Slider`/`Toggle`/`Select` 外，其他组件的材质**只在 Navigation/NavDestination 标题栏，或横向 Tabs 且 `barPosition: End` 的底部 TabBar 里生效**；写在页面内容区不生效。
- 标题栏材质走 **UI Design Kit** 的 `HdsNavDestination.titleBar({ style: { systemMaterialEffect } })`，`@since 6.1.0(23)`，不需要版本保护；ArkUI 原生 `Navigation` 的 `NavigationTitleOptions.systemMaterial` 只落在返回键/menu 背板上，拿不到整条标题栏，所以最终没有用它。
- 材质与属性会打架：设了材质就要把 `backgroundColor` 设为 `Color.Transparent`（不透明背景会盖住材质），且**不要再叠加 `backgroundBlurStyle` / `backgroundEffect`**，否则重复模糊、功耗翻倍。同一子树只在外层设一次材质，避免嵌套。
- 材质效果随设备算力档位自适应：`hdsMaterial.MaterialLevel.ADAPTIVE` 交给系统决定；若自己指定，要先 `hdsMaterial.getSystemMaterialTypes()` 判断设备是否支持 `IMMERSIVE`，不支持则退回 `SMOOTH`。

## 当前进度

已完成：PTP/USB 通信、画廊与多选、预览器与一镜到底转场、缩略图缓存与快速扫描、批量下载与 EXIF/GPS、GPS 连续定位与轨迹地图、深色模式、缓存管理、V2 状态管理迁移、UI 令牌化与全局统一、简体中文 / 繁体中文 / 英文多语言、应用内语言切换。

未实现：边框、水印、LUT、滤镜、美颜。

## 开发流程

每次改动按这个顺序走：

1. 读 `AGENTS.md` 与对应主题文档，确认现有实现和约束。
2. 涉及 HarmonyOS API 时先查官方资料，确认用法、起始版本与生效范围。
3. 用官方组件和 V2 状态管理实现；需要自绘时先征得用户确认。
4. `devecocli build` + `devecocli check lint entry/src/main/ets`。
5. 改了纯逻辑就补/跑 Local Test；改了 UI 就在模拟器验收，涉及相机/USB/EXIF/GPS/手势再上真机。
6. 验收截图按规则取回并立即删除设备副本。
7. 递增版本号并同步 `AppScope/app.json5` 与 `build-profile.json5` 的调试版本名。
8. 行为、设计或调试结论有变化时，同步更新对应文档；回退过代码则先清理再构建。

## 已知问题与历史

2026-10-14 审视代码时定位的问题，2026-11-05 已全部修复，当前无已知缺陷。

### 2026-11-09（真机测试 ISSUES.md 整改）

- **PTP 数组解析多出伪元素**：`parseU32Array` 没跳过 `NumberOfElements`，`StorageIDs count` 多 1、`ObjectHandles` 多 1，每次扫描产生 10×`0x2008` + 6×`0x2009`。新增 `parseCountedU32Array` 并按 count 截断（ISSUE-010）
- **扫描失败无反馈**：`statusText` 只有在 `connected === false` 时才渲染 → 状态卡改为永远优先显示 `statusText`；传输层改用 `PtpError(code)` 抛出、服务层按 `0x200F/0x200E/0x2008` 映射文案；失败补 toast、`usable` 与 `connected` 分开、失败不再清空 `photos`、扫描加 800ms 节流（ISSUE-001~005）
- **热扫描 39s 全花在重读元数据**：快速扫描改为复用 `metadata_cache.json`（按 handle 命中，抽样 8 个 `GetObjectInfo` 校验，7 天有效期），只对新增照片读取；`metadata_cache` 升 v2 带 `savedAt`，并缓存 EXIF 方向，缩略图阶段不再为每张读 16KB 头（ISSUE-007~009）
- **缩略图两张写盘**：不再在解码后重新编码覆盖，磁盘只留原始 JPEG + manifest 变换参数，解码时再裁剪；manifest 升 v3（旧 NEF 缩略图带黑边无法补救）（ISSUE-012）
- **NEF 缩略图带黑边**：原始尺寸优先用 PTP `imagePixWidth/Height`（NEF 的 EXIF 尺寸在 SubIFD，16KB 窗口读不到），EXIF 只在 PTP 给 0 时兜底
- **日期显示英文**：`Intl.DateTimeFormat` 全部改为显式区域 —— 应用内语言优先，跟随系统时取 `i18n.System.getSystemLocaleInstance()`（ISSUE-011）
- **预览器放大后拖动飞快**：去掉 `offsetX * zoom.scale`；**捏合卡顿**：手势期间持续保持预加载暂停（以前 300ms 冷却后无条件恢复）；**切图卡顿**：USB 忙时被丢弃的全尺寸请求改为记下并在当前下载结束后补投；**缩略图条不跟手**：删掉自算惯性与 5s 动画，交还 Swiper 自身 fling，只在落位期间暂停加载（ISSUE-014/015）
- **返回转场掉帧**：共享照片层不再逐帧改 `Image.width/height`，改为固定布局尺寸 + 外层裁剪框 + 内层等比 `scale`（数学上与原 Cover 等价）；新增 `ViewerPerf transition push/pop frames/fps/lateFrames/gapMax` 帧采样（ISSUE-016）
- **新增拖拽多选**（REQ-001）：多选态按住滑动连续选中/取消，起手格决定整笔方向，已下载跳过，边缘自动滚动；Tabs 设 `.scrollable(false)` 取消左右滑动切页

### 2026-11-08

- 快速在相机 / 设置间切换时，标题栏「搜索相机」在设置页停留约 220ms → 标题栏、底部页签、浮岛改用独立 `visualTab`，在 `Tabs.onSelected` 提前更新；`currentTab` 只保留给 `Tabs.index` 与 `onChange`。根因与官方建议见「三个必须记住的刷新坑」第 3 条。

### 2026-11-05 第二批

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
