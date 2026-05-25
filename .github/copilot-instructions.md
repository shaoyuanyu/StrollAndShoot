# StrollAndShoot（走走拍拍）项目开发指令

## 项目概述
HarmonyOS 手机应用，用于通过 USB PTP 连接相机、浏览导入照片、以及后期处理（GPS 地理标记、边框、水印、LUT、滤镜、美颜）。

## 技术栈
- **平台**: HarmonyOS 6.1.0 (API 23, Stage Model)
- **语言**: ArkTS（TypeScript 超集）
- **UI 框架**: ArkUI
- **构建系统**: Hvigor
- **原生桥接**: NAPI（C++ → ArkTS），BiSheng 编译器编译
- **原生 ABI**: `arm64-v8a`、`x86_64`
- **包管理**: ohpm
- **测试框架**: @ohos/hypium（单元+集成）、@ohos/hamock（mock）
- **Linter**: code-linter（ESLint 为基础，含安全规则）

## 项目结构
```
entry/src/main/ets/
├── entryability/     # EntryAbility（UIAbility）
├── entrybackupability/  # BackupExtensionAbility
├── pages/            # 页面组件
│   ├── Index.ets        # 根容器，Tabs + TabsController
│   ├── GalleryPage.ets  # 照片网格浏览器
│   ├── CameraPage.ets   # 扫描/连接相机
│   ├── SettingsPage.ets # 设置与调试日志
│   ├── PhotoDetailPage.ets  # 全分辨率查看器
│   └── PtpHost.ets      # PTP 会话层，USB 通信核心
├── components/       # 可复用组件
├── services/         # 服务层（CameraService 单例、AppLog）
├── model/            # 数据模型（PhotoEntry）
entry/src/main/cpp/   # NAPI 原生代码（PTP 协议引擎，移植自 libgphoto2）
```

## 状态管理 — 严格仅使用 V2
**所有新代码必须使用 ArkUI V2 状态管理。V1 装饰器（`@State`、`@Prop`、`@Link`、`@StorageLink`、`@StorageProp`、`@Provide`、`@Consume`、`@Observed`、`@ObjectLink`、`@Track`、`@Watch`）已禁止使用。**

| V2 装饰器 | 用途 | 替代的 V1 |
|-----------|------|----------|
| `@ComponentV2` | 所有组件定义 | `@Component` |
| `@Local` | 组件内部响应式状态 | `@State` |
| `@Param` | 父组件只读输入 | `@Prop` |
| `@Param @Once` | 父组件初始化，本地可写 | `@State`+外部初始化 |
| `@Event` | 子传父回调 | `@Link` |
| `@Provider()`/`@Consumer()` | 跨层级数据共享 | `@Provide`/`@Consume` |
| `@ObservedV2` | 标记可观察类 | `@Observed` |
| `@Trace` | 属性级精确追踪 | `@Track` |
| `@Monitor` | 异步变更监听（含 before/after 值） | `@Watch` |
| `@Computed` | 计算属性 | 无 V1 等价 |
| `Repeat` | 列表渲染 | `ForEach`/`LazyForEach` |
| `AppStorageV2.connect()` | 应用级响应式状态共享 | `AppStorage`/`@StorageLink` |
| `PersistenceV2.globalConnect()` | 持久化应用级状态 | `PersistentStorage.persistProp` |
| `!!` | 双向绑定语法 | `$$` |

## 导航
- `Index.ets` 为 `@Entry` 根容器，持有 `TabsController`、`CameraService` 单例引用、所有 `@Local` 状态变量
- `Index.ets` 通过 `onChange` 回调 → `syncState()` 同步服务层状态
- 子页面通过 `@Param` 接收数据
- 持久化设置（深色模式、画廊列数、显示模式）存储在 `SettingsStore`（`@ObservedV2` + `PersistenceV2.globalConnect()`），各组件通过单例直接访问
- 页面在 `src/main/resources/base/profile/main_pages.json` 中声明

## 关键约定
- **使用中文与我交流**
- `CameraService` 是单例，协调所有相机操作
- 所有 PTP USB 通信在 `PtpHost.ets` 中进行
- USB bulk 传输单次调用总数据量必须 ≤ 200KB，buffer 使用 192KB（196608 字节）以留出安全余量
- NAPI 函数类型声明在 `types/libentry/Index.d.ts`
- 资源引用使用 `$r('app.type.name')`

## PTP 协议关键概念
- **Session**: 任何操作前必须 `OpenSession(sessionId)`
- **Storage ID**: 逻辑存储单元（内部存储、SD 卡）
- **Object Handle**: 每个文件/目录的唯一 32 位标识符
- **Object Format Code**: `0x3801`=JPEG, `0x3001`=目录(DCIM), `0x3803`=TIFF
- **Parent handle**: `0xFFFFFFFF`=存储根目录；目录 handle=该目录的子项
- **Response code**: `0x2001`=OK
- **processResponse**: 累积多包 USB 数据，返回动作码 — `0`=数据累积中，`1`=数据包就绪，`2`=响应包就绪

## 构建与部署
```bash
bash deploy.sh full    # 完整流程：构建 → 签名 → 安装 → 启动
bash deploy.sh run     # 仅签名 → 安装 → 启动（不构建！代码变更后不要用）
hvigorw assembleHap --no-daemon  # 仅构建
hvigorw clean --no-daemon        # 清理构建缓存（回退代码后必须执行）
hvigorw test                      # 运行测试
```

## 调试注意事项

### `deploy.sh run` 不重新构建
`bash deploy.sh run` 只做签名、安装、启动，不构建。代码变更后必须用 `bash deploy.sh full`，否则会部署旧的 HAP。多次因此误判 bug 未修复。

### 旧构建缓存导致幽灵回归
回退代码后直接重建，hvigorw 可能复用旧的构建产物，表现为回退无效。回退后必须先执行 `hvigorw clean --no-daemon`。

### 检查任意限制
旧的 `loadPhotoList` 有 `const limit = Math.min(handles.length, 50)` 静默将照片限制在 50 张。当功能"基本正常但数字对不上"时，搜索 `limit`、`min(`、`max(`、slice 操作、硬编码的小数字。

### 目录遍历启发式很脆弱
旧逻辑用 `validCount <= 2` 作为递归进入目录的条件，这在多个同级子目录或多于 2 个直接子项的相机上会出错。正确做法：递归进入**所有**目录（format `0x3001`），收集所有非目录 handle 作为照片。不做启发式判断。

### HarmonyOS USB bulk 传输 ≤ 200KB
单次 `bulkTransfer` 调用总数据量必须低于 200KB，超过返回 -1。buffer 使用 192KB (196608 字节) 以留出 USB 容器开销的安全余量。

### 手机 USB 连接在开发期间不稳定
开发期间手机经常断开 `hdc`。每次部署或查日志前，用 `hdc list targets` 确认连接。如果 `[Empty]`，请用户重新连接手机。

### 查询 HarmonyOS 开发者文档
需要 API 参考、指南或系统接口时，用浏览器访问 https://developer.huawei.com/consumer/cn/doc/。使用 `#developer_search_input_pc` 输入框搜索。文档站点是客户端渲染的（用 `browser_evaluate` 提取内容，不要直接解析 HTML）。优先使用此方式，不要猜测 API 签名。

### 相机功能测试流程
任何涉及相机/USB 交互的代码更改后：构建 → 部署 → 告知用户改了什么 → 用户断开手机与 PC 的连接，连接相机进行测试 → 用户反馈结果 → 用户将手机重新连接到 PC → 检查 hilog 获取调试信息。在真机相机硬件上确认之前，不要假设手势或相机功能正常。

## 当前状态
- ✅ PTP 协议引擎（命令构建、响应解析、设备信息/存储/对象查询）
- ✅ USB 相机通信（会话管理、递归目录遍历的照片枚举）
- ✅ 五页面 UI（Index、Gallery、Camera、Settings、PhotoDetail）
- ✅ 服务层（CameraService 单例、含文件持久化的 AppLog）
- ✅ 缩略图管道加载（USB 读取与异步解码重叠）
- ✅ 全分辨率照片缓存（LRU 淘汰、方向性预加载）
- ✅ 格式过滤栏（根据文件扩展名动态生成）
- ✅ 画廊网格捏合缩放
- ✅ 深色模式切换（跟随系统/浅色/深色）
- ✅ 部署管道 `deploy.sh`
- ✅ 状态管理 V2 迁移完成
- 🚧 GPS 地理标记（进行中）
- 🚧 照片后期处理（边框、水印）
