# 页面设计与组件

> 本文覆盖主界面/画廊/多选、相机/设置/缓存、预览器/一镜到底转场、定位记录/轨迹页与复用组件。ArkUI 通用规则见 [AGENTS.md](AGENTS.md)，业务服务见 [SERVICES.md](SERVICES.md)，调试与验收见 [AGENTS.md](AGENTS.md)。
>
> 所有字号、圆角、行高、图标尺寸一律取 `entry/src/main/ets/utils/UiTokens.ets`，不要在页面里手写数字；令牌清单与取值规则见 [AGENTS.md](AGENTS.md) 的「UI 令牌」。

## 主界面与画廊

### Index.ets

导航根与初始化。设置日志路径与下载目录、初始化 `GpsRecorder`、把 `AppLog` 交给 `PtpHost` 与 `ExifGeotagger`、监听深色模式设置并调用 `setColorMode`，最后把 `MainScreen` 作为首个目的地压入 `NavPathStack`。

### MainScreen.ets

NavDestination，标签页容器。持有标签状态、下载进度、已下载集合、GPS 开关状态、选择模式。订阅 `cachingDialogRequired` 弹出“发现新相机”对话框。点击缩略图时取该缩略图的屏幕矩形（`getRectangleById('thumb_<handle>')`，px）与附近 81 个单元格的位置缓存，连同 `positionLookup` 回调一起作为 NavPathStack 参数传给预览器，再 `pushPath('PhotoViewerScreen')` 触发一镜到底转场。缩略图位图不必传：预览器自己从 `svc.thumbnailPixelMapMap` 取。返回键在选择模式下先退出选择模式。标题栏是自己写的 `@Builder`（`NormalTitleRow` / `SelectTitleRow`）：大标题 + 右侧玻璃胶囊（格式筛选是 `Select` 下拉、加一颗「选择」胶囊），材质用通用属性 `systemMaterial`。USB 插入相机时，`@Monitor('usbWatcher.attachVersion')` 会切到相机页并弹「发现相机」确认框；预览器/二级页在栈顶时不抢前台。确认框的「稍后」在左、「开始扫描」在右（`secondaryButton` + `fontColor: primary`），点击走 `scanForCamera(true, true)`（有缓存走快速扫描，否则自动全量）。

标签页索引拆成两个：`currentTab` 是 `Tabs({ index })` 的受控索引，只在 `onChange`（切换动画结束后）更新；`visualTab` 是标题栏、底部页签、浮岛等视觉状态用的索引，在 `Tabs.onSelected`（点击页签 / 滑动离手开始切换动画时）更新。**不要把 `currentTab` 用于标题栏条件**，否则旧页的按钮会在新页上停留整个 220ms 动画。官方 `Tabs` 的 `onChange` 说明与示例 17 就是这个用法。

导航骨架、标题栏与材质规则见 [AGENTS.md](AGENTS.md) 的「导航、标题栏与沉浸光感」。

### GalleryPage.ets

- 网格对齐官方图库：**默认 3 列**（设置里可改 4/5/6）、**贴边无页边距**、间距 2vp、**直角无圆角**、缩略图上**不叠时刻角标**。两指缩放（0.4x–6.0x）时列数随之重算。
- **捏合缩放只允许改「列数」，且只在跨档时改**：单元格是 `layoutWeight(1)` + `aspectRatio(1)`，视觉尺寸只由列数决定，倍数在同一档内连续变化不产生任何视觉差异。所以 `pinchScale` 是**普通字段**（逐帧更新不触发重建），只有列数跨档才写 `@Local appliedColumns`。**不要**把缩放倍数写成 `@Local`——那会让每个捏合事件都重建整页，实测 728 次事件只该换列十几次（日志 `PERF pinch: updates=…, columnChanges=…`）。列数/间距的换算在 `utils/GalleryZoom.ets`，有 Local Test（`GalleryZoom.test.ets`）。
- 行模型**不依赖 `thumbnailVersion`**：缩略图到达时只有 `ThumbImage` 自己重建。以前把 `thumbnailVersion` 编进 `buildFlatItems()` 的缓存键，扫描时每 4 张缩略图就重排一次全量行模型，纯浪费。
- 按拍摄日期分组，标题文案对齐官方并跟随系统语言：`今天` / `昨天` / 本地化月日（中文 `11月6日`、英文 `Nov 6`，跨年带年份），没有拍摄日期的归入「未知日期」。分组键是 `YYYYMMDD` 原始串，显示文案由 `dateHeaderLabel()` 换算，日期本身交给 `utils/DateTimeText.ets` 的 `Intl.DateTimeFormat`。
- 日期标题：左侧 16fp 粗体、上下各 24vp 留白、左右 16vp；多选态右侧多一个整组勾选圆圈（三态，见下文）。
- 格式筛选是标题栏右侧的 `Select` 下拉（选项 = 全部 + 照片里出现过的扩展名，只在“文件优先”模式下出现）。**不要**再做成「点一下轮换到下一个格式」的循环按钮 —— 用户猜不到下一下会到哪，设计很差。
- **「文件优先」下一个文件一格，但同一张照片的多个文件必须相邻**（JPG 在前、RAW 在后），2026-11-09 真机修复（R3-001）。排序与配对全部由 `utils/PhotoGroupUtil.ets` 的 `buildDisplayGroups()` 负责：内容优先按 basename 合组，文件优先按「拍摄时间倒序 → 同名词条收成相邻块」排。**内容优先的兜底键必须是 basename 降序**（2026-11-09 真机反馈“顺序乱”）：相机时间戳只到秒，连拍会有多张落在同一秒（Z50_2 的 1288 个文件只有 360 个不同时间），原来用升序兜底，与整体“时间降序”方向相反，表现为 `4482 → 4480 → 4481 → 4477` 来回跳；改降序后整条列表单调。`GalleryPage.allDisplayGroups()` **不要再按 `captureDate` 重排一次**：那会把 EXIF 时间差 1 秒的同名文件重新拆开。为什么不能只靠时间 + handle 兜底，见 [ISSUES.md](ISSUES.md) R3-001（连拍同秒 + 相机按格式分段分配 handle，1288 个文件里 438 组被拆）。
- 长按进入多选（或点标题栏的「选择」胶囊）。多选态标题栏左叉 + 左对齐「已选择 N 项」+ 全选胶囊，底部悬浮胶囊操作栏只有「下载」一项。详见下文「多选模式」。
- 缩略图按整行显示：一行（当前列数）全部解码完成才同时出现，否则该行显示占位。
- `buildFlatItems()` 把日期标题与行拍平成一个数组交给 `Repeat` + `.virtualScroll()`，按 `photosVersion`、显示模式、筛选值、**当前列数**、宽度做缓存。日期分组另外缓存在 `ensureGrouping()` 里（只依赖照片与筛选）：捏合换列只需要重新分行，不要再扫一遍全量照片。
- 缩略图单元格抽成独立 `@ComponentV2 ThumbImage`，内部调 `svc.thumbForRender(handle)` 建立 V2 依赖（原因见 [AGENTS.md](AGENTS.md) 的三个刷新坑）。
- 末尾有 `FlatItem.tail()` 占位项（104vp），给悬浮页签留滚动空间；`ListItem` 的 `key` 必须保持稳定，把「行是否加载完成」编进 `key` 会让 `virtualScroll` 的复用项失效、整行渲染成空白。
- `List` 用 `.contentStartOffset(this.listTopInset())` 让首行避开标题栏，并设 `.clip(false)` + `.cachedCount(6, true)` 让滚动中的照片能穿到标题栏下方被模糊。
- **扫描状态显示为「浮卡」，不要再放回列表上方的流内横幅**（2026-11-09 真机）：列表设了 `clip(false)`，滚动内容会越过自身边界盖上来，流内横幅会被日期标题和缩略图压住、文字被切。现在 `ScanCard()` 是根 `Stack` 里排在列表**之后**的浮层（定位在 `titleBarTotalVp() + 4`、左右 12vp），`listTopInset()` 返回 `titleBarTotalVp() + (扫描中 ? SCAN_CARD_INSET(64) : 0)`，两者互不遮挡。卡片内容：加载环 + 「正在载入照片」+ 实时阶段文案 + `已处理/总数` + 2vp 进度线，`hitTestBehavior(None)` 不挡点击。

### 多选模式的模拟器限制

2026-11-09 复现：模拟器（Mate 80 / 7.0.0）进入多选态后，整页会出现大片白/灰/彩色多边形。排查结论是**模拟器 GPU 不支持磨砂玻璃着色器**（`hilog` 里 `GEXFrostedGlassBlurShaderFilter::IsFilterSupported is false`），而多选态同时挂了「标题栏材质按钮 + 底部操作栏材质 + 页签材质」并持续重绘。用 `git stash` 回到改动前基线同样复现；关掉内容区模糊、去掉操作栏材质、`barHeight` 设 0 或 56 都不消失。**功能本身正常**（选择计数、拖拽框选、全选、下载栏都工作），真机需要另行确认材质渲染。

**调试缓解与排查结论（2026-11-09）**：设置页「调试 → 关闭磨砂玻璃」打开后，`utils/GlassEffect.ets` 用 `uiMaterial.Material.empty` / `BlurStyle.NONE` / 0 模糊替换所有材质与模糊，材质叠加造成的乱花会减少。但本轮进一步 A/B 发现：**即使把应用级材质开关设为 disable、全部材质换空、完全移除 `linearGradientBlur`、去掉 `List.clip(false)`/`cachedCount(6,true)`/`virtualScroll`、关掉扫描浮卡、把缩略图换成纯色块，顶部的大块彩色三角形仍然复现**，且形状随重绘变化；应用内 `Window.snapshot()` 同样能截到。这说明是模拟器的渲染管线（virtio-gpu / GLES 驱动）在模糊与图层合成上的缺陷，不是某个应用属性可以稳定规避的。处理方式：**布局、状态、交互用模拟器验证；材质/模糊观感与整页截图以真机为准**。官方依据：UI Design Kit「模拟器支持情况」明确模拟器不支持 HDS 沉浸视效（含沉浸光感材质），图形模块也有「模拟器与真机的差异」；模拟器 FAQ 建议清数据重启、更新驱动/模拟器。

### 多选模式

2026-11-06 对照顶行官方图库（`com.huawei.hmos.photos`）逐像素校准过一轮，形态与实现要点如下。

#### 标题栏

`MainScreen.SelectTitleRow`：左叉 40vp 圆形玻璃钮（`sys.symbol.xmark` + `systemMaterial`）→ **左对齐** 22fp 粗体标题「已选择 N 项」（**不要居中**，那是上一版的错误做法）→ 右侧 40vp 高玻璃胶囊「全选 / 取消全选」。外层 `Row` 左右内边距 16vp，与浏览态大标题对齐。

#### 底部操作栏

`components/SelectionActionBar.ets`：悬浮胶囊，图标在上（24fp）、文字在下（10fp），与底部页签的 `TabItem` 尺寸一致；宿主 `MainScreen.TitleBar` 的浮岛层负责 `position` 与 `systemMaterial`。

#### 位置

操作栏胶囊 **高 56vp**，`top = screenHeightVp() - navIndicatorVp() - 56`，宽 96vp 水平居中。页签栏是 `barBottomMargin: navIndicatorVp()`、高 56vp —— 两者在屏幕上完全同一矩形（实测都是 `[*,2538][*,2734]`），切换多选态时下沿不会跳。

#### 页签栏在多选时隐藏

`.barHeight(this.gallerySelectMode ? 0 : 56)`。实测 `barHeight(0)` 对悬浮样式的页签栏有效，置 0 后 `barFloatingStyle` 的材质与圆角一并消失、操作栏可以占据同一位置；恢复 56 后悬浮样式正常。**这是唯一需要动态改 `barHeight` 的场景**，其他时候不要碰它。

#### 选中态

与官方图库一致，**不加遮罩、不加描边**（早期版本用 `primary_soft` 蒙一层淡蓝 + 左上角勾选，都是错的）。勾选圆点 20vp，在单元格 **右下角**、内缩 4vp：选中实心蓝 + 白勾，未选半透明黑 + 1.5vp 白描边。已下载的照片不可选，只在 **右上角** 留一个绿点（`status_connected`，10vp），**不要再给整张缩略图描一圈绿框**。

**绿点即时刷新（2026-11-09）**：`GalleryPage` 用 `@Monitor('downloadedKeys')` 清空行缓存并递增 `downloadedDotRevision`，把它编进行 key。`Repeat` 命中相同 key 不会重跑 `each`，不这样做时从预览器「保存到相册」后回到画廊，绿点要等滚动/切页才出现。

#### 日期标题（含整组全选）

官方图库在多选态的每个日期标题 **右侧** 放一个 20vp 圆形勾选（不是「全选当天」文字胶囊）。三态：未选 = 空心细圈（`text_tertiary` 1.5vp）、部分选中 = 实心蓝 + 白色横线、全选 = 实心蓝 + 白勾；热区用 `responseRegion` 扩到 44vp。点击调 `toggleSelectDate(dateKey)` 整组切换。

#### 拖拽多选（REQ-001，2026-11-09）

多选态下按住并滑动，划过的缩略图连续选中/取消：

- 起手格决定整笔方向：起手格已选 → 整笔取消；未选 → 整笔选中；同一笔内不反复翻转
- 支持斜向、跨行；已下载的照片跳过
- 手指贴住列表上下边缘 72vp 内自动滚动（50ms 一次 `scrollBy`），长列表也能选到屏幕外的照片
- 手势实现**不用 PanGesture**：多点跨格收不到 Move，且会和 List 滚动抢优先级。现在用 `List.onTouch` 原始触摸 + `List.enableScrollInteraction(!selectMode)`（多选态禁止拖动滚动）+ 官方 `Scroller.getItemIndex(x, y)` / `getItemRect(index)` 把坐标换成单元格。`TouchObject.x/y` 与这两个接口都是「相对 List」的坐标。
- `suppressNextTap`：拖选改过选择集后，抬手时单元格自己的 `TapGesture` 要跳过反选，否则整笔方向会被最后一格抵消。
- 长按进入多选后手指不抬起、直接继续拖，会按「选中」方向接着选（MOVE 时补建这一笔）。
- 多选态**不能拖动列表滚动**，这是有意取舍：拖动已经被框选占用，长距离用边缘自动滚动。退出多选恢复滚动。

#### 数据流

选中集在 `GalleryPage`，标题栏在 `MainScreen`，靠一组计数与 `@Monitor` 双向打通：

- 上行：`@Event onSelectionStats(selected, selectable)`，`GalleryPage` 每次增删选中项后调 `syncSelectionStats()`
- 下行：`@Local selectAllVersion` 递增 → `GalleryPage` 的 `@Monitor('selectAllVersion')` 执行 `toggleSelectAll()`
- 退出：`@Local exitSelectModeVersion` 递增 → `GalleryPage` 清空选中集

**新增选择入口时别忘调 `syncSelectionStats()`**，否则标题栏数量与全选态不会更新（`toggleSelectAll` / `toggleSelectDate` / 长按进多选 / 单击切换 / 退出 / 下载完成，六处都要）。

## 相机页、设置页与缓存管理

### CameraPage.ets

- 主操作（未连接 → 「搜索相机」，已连接 → 「快速扫描」，扫描中 → 「扫描中」）在**标题栏**右侧的玻璃胶囊里（`MainScreen.NormalTitleRow` 的 `visualTab === 1` 分支，不是 `currentTab`）：内容区的 `Button` 拿不到材质，标题栏里的才能。胶囊不设 `backgroundColor` / `materialColor` 时材质取 Button 主题色，文字用 `text_on_primary`。
- 内容区只有三张 24vp 圆角白卡、内边距 16vp：状态卡（连接状态、相机名、扫描进度与统计）、设备信息卡（9 行 56vp）、操作卡（全量扫描 + 红色断开连接）。未连接时状态卡换成空态卡（图标 + 说明 + 指向右上角「搜索相机」）。
- **状态卡标题永远优先显示 `svc.statusText`**，`connected` 只决定圆点颜色与是否展示设备卡。历史上写成 `connected ? 已连接 : statusText`，导致连上相机之后所有失败原因（无存储 / 拒绝访问 / 扫描出错）都不可见（ISSUE-001）。圆点颜色：扫描中蓝、`connected && usable` 绿、`connected && !usable` 红、未连接灰。未连接态的空态卡下方也会显示 `lastScanError`。
- 扫描失败还会由 `MainScreen` 的 `@Monitor('svc.scanErrorVersion')` 弹一次 toast（`getUIContext().getPromptAction().showToast`），文案来自 `svc.lastScanError`。
- 根节点 `Scroll` 用 `.contentStartOffset(titleBarTotalVp())` 避让标题栏。
- **未连接时多一张「无线连接」卡（1.31.0）**：标题 + 一行说明 + `TextInput`（相机 IP，回车即连）+ 主色胶囊「连接」。已连接且走 Wi-Fi 时，同一张卡改成「地址 + 断开无线」，不显示输入框；设备信息卡的「连接」一行也显示 `Wi-Fi · <host>`。连接成功后 `MainScreen` 自动触发一次快速扫描，首次会自动退化为全量。
- 无线卡是**手动填 IP** 的第一版入口：mDNS 发现、网段扫描、BLE 配对都还没接，说明文案里只承诺「同一网络」这个前提，不要写成「自动发现」。

扫描阶段、缓存与快速扫描的细节见 [SERVICES.md](SERVICES.md)。

### SettingsPage.ets

- 分组卡片统一 24vp 圆角、无描边；单行 56vp、双行 64vp；分组标题 13fp 次级色。
- 选项类（深色模式 / 语言 / 默认列数 / 显示模式 / 记录频率）全是**右侧 `Select` 玻璃胶囊**（`SettingSelectRow`），不要再用自制的「灰底 + 蓝胶囊」分段按钮——那东西在内容区拿不到材质。
- 开关（GPS 记录、模拟相机）用 `Toggle(Switch)`，**不要设 `selectedColor`**，否则会覆盖系统预设的沉浸光感样式。
- 导航类行带 `chevron_right`（定位记录管理、缩略图缓存）。删除定位记录统一放在「定位记录管理」页（多选批量删除，或全屏轨迹页「更多」里删当天），设置页不再提供「清除定位记录」入口，避免误触。
- 调试日志面板仍是等宽字体、高 240vp，只在调试包里渲染。
- 调试区新增「模拟 GPS 轨迹」开关：以当前定位为起点生成相机图案，覆盖今天的地图/列表显示；真实 `gps_records.jsonl` 不变，关掉开关立即恢复。仅 debug 包可见。
- 调试区新增「关闭磨砂玻璃」开关（2026-11-09，仅 debug 包）：打开后 `utils/GlassEffect.ets` 把所有 `.systemMaterial(...)` 换成官方 `uiMaterial.Material.empty`、`backgroundBlurStyle` 换成 `BlurStyle.NONE`、`linearGradientBlur` 半径归零。模拟器 GPU 不支持磨砂着色器，材质叠加时会画出乱花的多边形，打开它才能拿截图验收布局与交互；真机不需要。

调试包判定与模拟相机见 [AGENTS.md](AGENTS.md) 的「调试用的虚拟相机」；模拟 GPS 轨迹见上文「SettingsPage.ets」。

- 「外观 → 语言」提供跟随系统 / 简体中文 / 繁體中文 / English；默认跟随系统。选项切换后弹「应用将重启」确认框，确认后调用 `i18n.System.setAppPreferredLanguage()` 并用 `ApplicationContext.restartApp()` 重启进程（官方要求冷启动才重新加载资源）。语言偏好存在独立的 `model/LanguageStore.ets`，不要追加到 `SettingsStore`。

### CacheManagementPage.ets

- 列出每个相机的缓存体积、条目数、开关、删除、清空全部。卡片 24vp 圆角、无描边，与相机/设置页一致。

缓存实现见 [SERVICES.md](SERVICES.md) 的「ThumbnailCache」与「扫描的四个阶段」。

## 预览器与一镜到底转场

### PhotoViewer.ets

预览器，一个文件里有这些结构：`ZoomState`、`ZoomLayer`、`ZoomableImage`、`MainImageView`、`ThumbCellView`、`PhotoViewerScreen`。

- `ZoomableImage`：单张图片的缩放与拖动。捏合用 `pinchCenterX/Y`（屏幕绝对坐标）计算锚点；**拖动位移直接用 `GestureEvent.offsetX/Y`（屏幕空间 vp），不要再乘缩放倍数**——乘上去会让 5x 缩放时手指划 100vp、照片走 500vp（ISSUE-015-B，2026-11-09 修正）。捏合期间 `PanGesture` 会持续累计位移，必须记录并在捏合结束后扣除，否则松手时会跳变。缩放范围 1x–5x，双击在 1x 与 2.5x 之间切换。捏合与拖动都要接 `onActionCancel`（来电、三指会取消手势），否则页面会永远停在「捏合中」。
- **逐帧变化的缩放值必须放在 `ZoomState`（`@ObservedV2` 的 `@Trace scale/x/y`）里，由叶子组件 `ZoomLayer` 订阅，`ZoomableImage` 自己不许再持有 `@Local scaleVal/offX/offY`**：一旦把这三个值写成 `ZoomableImage` 的 `@Local`，每个捏合事件都会重跑它的 `build()`，`GestureGroup` + 3 个手势连同 `PanGesture` 的触发距离每帧重建并重新绑定——这是预览器缩放卡顿的根因（2026-11-07）。`ZoomableImage` 里只保留一个 `@Local zoomed`，它只在 1x 边界翻转时才变，用来切换 `PanGesture` 的 `distance`（1x 时 80vp，让主 Swiper 先接管滑动；放大后 3vp）。
- `MainImageView`：主图容器，叠加加载指示与扫描进度横幅。**每张照片的状态是 `PhotoRenderState`（`@ObservedV2`，`@Trace fullPm/loading/photoW/photoH`），页面通过一张普通 `Map` 拿到它再传进来，页面自己绝不能在 `build()` 里读这些字段**：否则任何一张图解码完成都会重建整页（标题栏 + 两个 Swiper + Repeat 全量 diff）。后台每解完一张邻近照片就卡一下，就是这么来的。
- `fullResMap`、`loadingHandle` 必须是**普通字段/普通 Map**，`thumbnailPixelMapMap` 也是普通 Map；界面刷新靠 `PhotoRenderState` 和 `MainImageView` 内部读 `svc.thumbnailVersion`。
- 缩放/翻页期间主图每帧都在动，标题栏与缩略图条的 `backgroundBlurStyle` 会跟着每帧重算（渲染成本高）。`chromeMotion` 为真时换成半透明纯色（`chromeBg()` / `chromeBlur()`），静止时恢复模糊。捏合、`onGestureSwipe`、缩略图条滑动都要切换它，且只在状态翻转时写 `@Local`。
- `updateScales()` 只在值真的变化时写 `scaleArr/offsetArr`，并且**不要再引入逐帧变化的 `thumbFrac`**：`@Local` 数组每次赋值都会通知订阅者，逐帧全写会让窗口内 11 个缩略图单元格反复重算并重启自身的 150ms 动画。中间项的选中高亮由 `scaleArr[i] >= MAX_S` 判定。
- `ThumbCellView`：底部缩略图条的单元。
- `PhotoViewerScreen`：**打开时调用 `svc.suspendNeighborPreload()`，关闭时 `resumeNeighborPreload()`**（并把 `loadingPaused` 置真）：预览器自己有一套「当前优先、前后各 3 张」的串行加载队列，后台再跑一套邻近预加载只会在串行的 USB 管道上插队，把用户正在等的那张拖慢——2026-11-07 实测手机上预览期间每秒都有 `预加载[N]` 时，第一次开图要 1.0–1.4s，挂起后回到 0.5s（mock 的固定 520ms）。
- `PhotoViewerScreen`：NavDestination。主 `Swiper` 与缩略图 `Swiper` 双向联动（`startFakeDrag` / `fakeDragBy` 同步），缩略图中心项放大到 1.3x。
- **缩略图条不再自定义惯性**（2026-11-09）：以前手指还没抬起就置 `_inertiaAnim` 让主图停跟，抬手后又自己算跳数 + Friction/5000ms 动画，观感是“飘”。现在把 fling 交还 Swiper 自身（固定 `Curve.Linear` + 150ms），`_inertiaAnim` 只表示“缩略图条正在落位”，用于在这段时间暂停全量图加载；落位结束再补一次 `scheduleFullResLoad()`，并带 `THUMB_SETTLE_GUARD_MS` 安全超时（ISSUE-014-C）。
- **手势期间预加载必须一直暂停**：`gestureDepth` 在 `onGestureStart/End` 增减，300ms 冷却到点时若计数仍 > 0 就继续排下一次冷却。以前冷却结束无条件恢复，捏合超过 300ms 后后台又开始每 1–2 秒读 7MB + 解码，与捏合渲染抢带宽（ISSUE-015-A）。
- **全尺寸加载不能被静默丢弃**：USB 忙（另一张正在下载且不可取消）时把请求记进 `pendingFullResHandle`，当前下载结束的 `finally` 里优先补投「当前页」，其次补投排队的那张（ISSUE-014-A/B）。
- 原图按“当前照片优先，前后各 3 张”排队串行加载，手势期间暂停；预加载结果只写普通 Map，等翻到那张时再由 `presentCached()` 挂到渲染状态上。淘汰时 `PixelMap.release()` 要 `setTimeout(0)` 延后，不要正好压在手势中间。返回时用当前照片的缩略图更新共享元素，保证转场起点正确。
- 一次捏合结束会打两行性能日志：`ViewerPerf pinch updates=…, frames=…, fps=…, lateFrames=…, gapMax=…ms, workMax=…ms`（hilog，tag `ViewerPerf`）与 `PERF viewer pinch: swiperScrolls=…`（AppLog）。fps 掉 / gapMax 大 = UI 线程被拖住；fps 正常但不跟手 = 渲染侧。
- **控件显隐只由单击照片触发，不做自动隐藏**（2026-11-09 按用户反馈去掉 2 秒自动隐藏）：单击照片切换标题栏与底部操作栏；缩略图条常驻，不参与显隐。隐藏分两步，先淡出 180ms 再 `Visibility.Hidden`。**不能**用 `if` 拆掉标题栏（照片区域会瞬间变高、图片位置跳动，一镜到底落点也会偏），也**不能**只把父容器设成 `hitTestBehavior(None)`——它只作用于父节点本身，子按钮仍会响应，隐藏后点击原来的返回/保存位置仍会误触（实测），必须用 `Visibility.Hidden` 让整棵子树退出命中测试。缩略图条不跟 `overlayAlpha`，只跟转场的 `chromeAlpha`。
- **标题栏挂在 NavDestination.title（2026-11-10）**：高度仍是 56vp（`VIEWER_TITLE_BAR_HEIGHT`），返回与「详情」两颗 40vp 圆形钮用 `systemMaterial(ULTRA_THIN + 跟随主题的 materialColor)`，背板用压色渐变而不是材质。**通用组件只有 Navigation/NavDestination 标题栏与横向 Tabs 的底部 TabBar 两处能拿到系统沉浸光感**，在内容区写 `systemMaterial` 不生效——这就是之前「预览器没有沉浸光感」的根因。标题只显示拍摄时间 + 「序号 / 总数」；文件名 / 大小 / 分辨率移进上滑详情面板，避免一行副标题被省略号吃掉。标题栏高度必须与 `PhotoMorph` 的常量同源，否则一镜到底的落点会和真实照片错开几 vp。
- **底部操作栏（2026-11-10）**：下载 / 收藏 / 分享放在一个只有 56vp 高的 `Tabs` 悬浮底部页签里（`barOverlap(true)` + `barPosition: End` + `barFloatingStyle.systemMaterial`），`TabContent` 为空，照片区域仍由内容 `Column` 承担。材质底色跟随主题（浅色给白底、深色给黑底），避免胶囊与页面背板撞色。操作栏放在缩略图条**上方**（底部让出导航条 + `thumbStripHeight()` + 8vp），随单击照片与标题栏一起淡出；缩略图条常驻。
  - **产品决策（2026-11-10，用户确认）**：保留「Tabs 当材质背板」的 workaround，接受它与《底部页签》规范（页签放 3–5 个一级导航、不放次要动作）的语义偏差；不改成普通工具栏。以后若要求严格合规，按「普通底部工具栏 + backgroundBlurStyle/渐变」替换即可。
- **照片显示区域上移（2026-11-11）**：底部控件（缩略图条 + 间距 + 操作栏）占掉图片区域一截，照片原来在整块区域里居中，视觉上偏下。现在主 `Swiper` 底部让出 `bottomChromeHeight() = thumbItemW + 16 + 8 + 56`，照片在剩余可见区域居中；`MorphGeometry.containRect(aspect, bottomChrome)` 使用同一个值，保证一镜到底落点不偏。以 365vp 屏宽、9 个缩略图为例：`itemW ≈ 35.3vp`，底部控件 `≈ 115.3vp`，照片中心上移 `≈ 57.6vp`。
- **保存到系统相册**：底部操作栏的下载项未保存时是下载图标、已保存是绿色对勾、保存中显示转圈。复用画廊的 `svc.downloadPhotos`（USB 读取 → 写沙箱 → GPS → 系统相册确认框 → 下载记录）；先清空并暂停预览器自己的邻近预加载，避免抢同一条 USB 管道。保存成功后通过 NavPathStack 传入的 `onDownloadSaved` 回调让 `MainScreen.syncDownloadedKeys()` 刷新画廊绿点。扫描中拒绝保存；系统确认框取消时以「下载记录里没有这条」为准提示「已取消保存」。
- **收藏（2026-11-10）**：`model/FavoritesStore.ets` 用 `PersistenceV2`（key `photo_favorites`）持久化键列表，键与下载记录同源（`cameraKey::filename::size`）。预览器底部切换收藏，画廊单元格左下角显示书签角标，跨重启保留。
- **分享（2026-11-11）**：**单击分享 = 原图**、**长按分享 = 压缩图**，两者都不弹选择框，直接走 `systemShare.SharedData` + `fileUri.getUriFromPath` 拉起系统面板。原图走 `CameraService.getOriginalBytes()`（相机原始压缩字节，优先命中 `compressedCache`，未命中时串行取一次 USB），不重新编码、保留 EXIF；压缩图把已解码 `PixelMap` 重编码为高质量 JPEG。取原图期间会暂停预览器的邻近预加载；扫描中拒绝取原图并提示。
- **浅色模式适配（2026-11-10）**：预览器不再固定深色，页面背板、顶部压色、标题/操作栏文字、占位图、缩略图条与系统栏都跟随应用深浅色。`MorphBackdrop` 用 `viewer_backdrop`（浅色 `#F1F3F5` / 深色 `#000000`），与画廊页面同色，所以一镜到底的背景在浅色下不会先压黑再亮回来。`viewer_scrim_top/clear`、`viewer_glass_button`、`viewer_material_tint`、`viewer_chrome`、`viewer_chrome_motion`、`viewer_placeholder_*` 在 `base` / `dark` 各一套；标题与操作栏文字用 `viewer_chrome_text` / `viewer_chrome_text_secondary`。压在照片上的加载转圈（`text_on_dark` + `viewer_scrim`）与扫描横幅（`viewer_text_on_dark_*` + `viewer_banner_bg`）保持深色，避免照片底色变化时对比度丢失。`backgroundBlurStyle` 的 `colorMode`、系统栏图标由 `WindowUtils.isDarkMode()` 决定；进入/退出预览器时用 `applyThemeSystemBars()` 与全局主题对齐。浅色下标题栏、底部操作栏与详情面板的材质需在真机复核，模拟器只能验证布局、配色与材质形状。
- **停留期间切换系统主题（2026-11-10，1.30.1）**：预览器在 `aboutToAppear` 注册 `ApplicationContext.on('environment')`，在 `aboutToDisappear` 用 `off('environment', callbackId)` 注销。回调里用 `WindowUtils.isDarkMode(ctx)` 取应用的有效模式，**不能用 `config.colorMode`**：应用显式设置深浅色时，系统主题变化仍会触发该回调。把 `isDark` 改成 `@Local` 并参与 `build()`（缩略图条 `backgroundBlurStyle` 的 `colorMode` 依赖它），主题切换时页面重建，`chromeBg()` 返回的颜色资源才会按新主题重新解析，同时重刷系统栏。此前缩略图条不跟随，就是因为它只在 `aboutToAppear` 读了一次普通字段，之后既不重建也没有新的 colorMode。
- **上滑详情（2026-11-11）**：`bindSheet`（`detents: [MEDIUM, LARGE]`，`systemMaterial: THICK`；调试关闭磨砂时退回不透明底色 + 顶部圆角），显示文件名、拍摄时间、尺寸、文件大小、格式、相机与位置。位置按 `captureDate` 从 `GpsRecorder.findClosest` 匹配（30 分钟窗口），用单点 `GpsTrack.buildDayTrack(day, [gps])` 复用 `GpsTrackMap`：签名包上直接显示地图 + 点位标记，未签名包走 Canvas 示意图；点击地图/「查看当天轨迹」收起面板并 push 到 `GpsTrackViewerPage`。`GpsTrackMap` 新增 `showStats=false` 隐藏「1 条记录」统计，并修复单点轨迹不画折线但仍要加 marker。标题栏右侧 info 钮也能打开。
- **上滑手势**：挂在主 `Swiper` 的被动 `onTouch` 上采样（上移 ≥ 40vp 且横向位移小），不额外加 PanGesture，避免和捏合 / 翻页抢识别；单击照片的显隐也在这里统一处理（位移 < 8vp），**不要再给 `MainImageView` 单独挂 `onClick`**——上滑结束时会先触发一次 click，把标题栏和缩略图条误藏。
- **转场期间就开始取原图（2026-11-11）**：`initFromParams` 先把首张照片的 `spinnerOn` 置真，并立即 `loadFullRes(handle, true)`，不再等一镜到底落地。共享层始终用缩略图，全尺寸结果只更新被 `photoAlpha` 盖住的内容层；照片落位时通常已经就绪。翻页仍走 `SPINNER_DELAY_MS`，避免快速滑动时转圈闪。
- **缩略图条**：非中心项透明度 0.68，中心项保持 1.3x + 2vp 高亮边框，减少缩略图对照片的视觉干扰。

### 扫描期间只看缩略图（2026-11-09）

缩略图还在传的时候点开照片，**不下载原图**：`loadFullRes` / `scheduleFullResLoad` / `preloadNeighbors` / `processPreloadQueue` 四处都以 `svc.scanning` 为闸门，扫描结束后由 `@Monitor('svc.scanning')` 自动补投（约 100ms 后）。

界面必须明说，否则会被当成卡死：照片区底部一条提示「扫描中，暂时只显示缩略图 X/1288 / 扫描完成后会自动加载原图」（`viewer_scanning_thumb_only` / `viewer_scanning_thumb_note`），扫描结束自动消失。

### 一镜到底转场

2026-11-07 重写，对齐官方图库。官方图库的观感是三条独立的动作，**不是**「整页从缩略图放大」：

1. **只有照片在动**：起于被点缩略图单元格的矩形（方图、`Cover` 居中裁切），终于照片在预览器里的实际显示矩形（`Contain` 等比放入图片区域）。因为一直用 `Cover` 画，矩形从方图长到照片比例的过程天然就是「从中心裁切逐渐露出全图」，落位时矩形比例 == 照片比例，`Cover` 与 `Contain` 完全重合，可以无缝交还给页面内容。
2. **背景 180ms 压到纯黑**；
3. **标题栏、缩略图条与底部操作栏在照片快落位时才淡入**（220ms 起、200ms 淡完），返回时反过来先淡出 140ms，再收照片；缩略图条只跟 `chromeAlpha`，不跟单击显隐。

层级（都在 `PhotoViewerScreen` 的根 `Stack` 里，从下到上）：`MorphBackdrop`（页面背板，浅色为页面底、深色为纯黑，`@Trace backdrop` 逐帧变）→ 内容 `Column`（主图 `Swiper` 挂 `.opacity(photoAlpha)`，缩略图条挂 `.opacity(chromeAlpha)`）→ 底部操作栏（`.opacity(chromeAlpha * overlayAlpha)`，在缩略图条上方）→ `PhotoMorphLayer`（共享照片层，仅 `morph.visible` 时挂载）。标题栏在 NavDestination 的 `.title()` 层，自己挂 `chromeAlpha * overlayAlpha`。

- **禁止再对整个 NavDestination 做 scale / translate / clip**（旧做法）：那会把标题栏、缩略图条一起从一个小方块里缩放着长出来，观感是「一个迷你版预览器在放大」，和官方差得很远。曾同时用 `showDetailContent` 布尔量做内容显隐，而它在 `animateTo` 里被翻转，`if` 立刻读到新值 → 共享层在动画第 0 帧就被拆掉，等于什么都没做。
- **`animateTo` 不会插值「本帧才创建」的节点的 `width/height/position`**（2026-11-07 实测：`onAppear` 里拿到的就是终点矩形）。共享层是转场开始那一刻才创建的，所以矩形必须用 `displaySync` 帧回调逐帧写 `PhotoMorphState`，缓动值取 `curve.interpolate(t)`（与引擎同一条曲线）。背景与标题栏的 `opacity` 作用在常驻节点上，可以继续用 `animateTo`。
- 矩形换算在 `CustomTransition/PhotoMorph.ets`：`containRect(aspect)` = 图片显示区域（窗口高 − 状态栏 − 56vp 标题栏 − 手势条）× 照片比例居中；起点由 `getRectangleById('thumb_<handle>')` 给的 px 直接 `px2vp`。**图片显示区域必须和 `TitleBar`/`padding` 的实际布局同源**，改标题栏高度要同步 `VIEWER_TITLE_BAR_HEIGHT`。
- **共享照片层的矩形动画交给 `animateTo`，不要再逐帧回调 JS**（2026-11-09 真机实测后定稿）。曾经试过两种写法，都踩过坑：
  - ①（已废弃）「固定布局位图 + 逐帧改裁剪框 + 内层等比 `scale`」：数学上等价于 `ImageFit.Cover`，但外层每帧改尺寸又 `clip(true)`，等于**每帧离屏渲染一次**，真机 push 只有 47fps、pop 掉到 21fps（`gapMax=134ms`）。
  - ②（已废弃）`displaySync` 帧回调里改 4 个 `@Trace` 字段：每帧跑一次 JS build + 属性 diff，同样只有 47fps。
  - ③（当前）`startRectAnimation()` 先 `morph.apply(from)`，再用 `ui.animateTo({ duration, curve, onFinish }, () => morph.apply(to))` 让框架插值，JS 只在首尾各跑一次。真机观感恢复正常，`onFinish` 里与共享层同帧换手并 `finishTransition()`，另有 `duration + 200ms` 的兜底定时器防止共享层卡住。
  - **前提**：共享层必须在动画开始前已经渲染过一帧（`onReady` 里就 `apply(起点)` + `visible = true`）。`animateTo` 不会插值「本帧才创建」的节点的 `width/height/position`；若以后改成「动画开始才创建共享层」，必须退回逐帧方案。
- 转场埋点：`ViewerPerf transition push|pop native <ms>ms`（原生动画耗时）。改转场后先看这行，别只凭观感；需要逐帧数据时再把 `PinchPerf` + `displaySync` 的采样接回来。
- 预览器页的 `NavDestination` 背景必须透明、内容区也**不许铺不透明的页面底色**（否则下层画廊从第一帧就被挡住，只剩共享层在动）；页面背板只由 `MorphBackdrop` 提供，它同时负责「透过它看到画廊」。
- 返回起点取「当前屏幕上的照片矩形」：未放大就是 `Contain` 矩形；放大过则用 `ZoomableImage.onTransform` 在**手势结束时**汇报的 `scale/offX/offY` 换算（`rect × s` 绕同一中心缩放再平移），这样放大状态下按返回也从当前画面收回，不会先跳回等比显示。`offX/offY` 是屏幕空间位移（`applyTransform` 的注释已经写明 finger 位移要乘 scale 换回屏幕空间，说明 `.translate` 在 `.scale` 之后应用）。
- **返回终点 = 当前照片的缩略图矩形；格子在可视区外就先把画廊滚过去再收**（对齐官方图库「回家时网格已经在当前张」）：
  - 目标格子可能①没被 `virtualScroll` 渲染（视口外）②渲染了但在屏幕外（`cachedCount` 缓存窗口），两种都拿不到可用的屏幕矩形，收回会收进看不见的地方。
  - `popRectFor()` 用 `positionLookup`（`getRectangleById('thumb_<handle>')` 实时查，push 时缓存的位置**只作兜底**，因为它可能已过期）判断「至少一半在窗口内」；否则通过 `requestGalleryScroll` → `MainScreen.galleryScrollVersion` 计数 → `GalleryPage` 的 `@Monitor` → `scroller.scrollToIndex(row, false, ScrollAlign.CENTER)` 滚过去。
  - 预览器按帧重试目标矩形（`POP_TARGET_RETRY_MS` × `POP_TARGET_RETRIES`），拿到才开始收回；**背景透出也挪到这一刻**，所以网格的跳变发生在完全不透明的背景下，用户看不到；请求过滚动还要多等 `POP_SCROLL_SETTLE_FRAMES` 一帧让新布局上屏。
  - 最终兜底顺序：实时矩形 → push 时缓存 → 最初点击的格子（`pop: 目标矩形兜底 …`）。日志里 `pop: 目标格子不在可视区，请求画廊滚动` / `viewer pop: scrollToIndex N` / `pop: 收回目标 …` 三行就能定位这类问题。
- 首次打开照片时**照片一落位就显示转圈**：`initFromParams` 先把 `spinnerOn` 置真，`finishTransitionGate()` 直接发起原图下载；翻页仍等 `SPINNER_DELAY_MS`（300ms）再显示，避免快速滑动时转圈闪。
- 转场日志：`push morph <l,t> <w>x<h> pm=…` 与 `pop: handle=… pm=… rect=… -> …`（AppLog），排查时先看这两行矩形是否等于缩略图格子 / `Contain` 矩形。

相关：缩略图与原图的加载、预加载队列见 [SERVICES.md](SERVICES.md)；预览器返回后画廊滚动依赖的 `@Monitor` 数据流见本文「主界面与画廊」。

## 定位记录与轨迹页

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
- 标题栏只保留「返回 + 日期玻璃胶囊 + 更多」；日期胶囊是标题栏里的 Button + `systemMaterial`，单行只显示 `今天/昨天/本地化日期`（中文 `11月7日`、英文 `Nov 7`），高度与 40vp 返回/更多按钮一致；总数只放在面板统计行，不要在标题胶囊和统计行重复两次。更多菜单里放「删除当天记录」，二次确认后删除并返回。
- 明细列表按时间升序，点一条会高亮、把相机移到该点，并在选中点画红色 marker。
- 按**行程**分组，不再按 60 米逐点切：相邻采样间隔 >30 分钟才开新组；连续行程内累计位移 <120 米判为「停留」、否则判为「移动」。分组头标题统一用地点地址（移动组用起点地址），右侧状态字固定显示「移动/停留」，图标也区分（行走/定位）；副标题里移动给距离、停留给时长，再加时间范围和记录数。不要再用「地址 vs 移动距离」两种不同标题结构。小轨迹（≤30 条记录）默认展开，长轨迹默认收起只显示行程卡，用户点分组头展开。
- 当天第一组的 `first` 用 `max(runStart, 当天 0 点)`，与面板统计的「时长」同源；后续组用本组第一条采样时间，避免上一轮静止的 `runStart` 跨过行程间隔。面板副标题也要用 `track.first` / `track.last`，不能直接用 `points[0].timestamp`，否则跨午夜静止时「00:00–03:03」和「3 小时 4 分」会对不上。
- 分组内未选中行只显示时间、起点/终点；移动行程用 `HH:mm:ss`（采样间隔可能小于 1 分钟），停留行程用 `HH:mm`。选中行变成内嵌浅蓝卡，展开坐标、地址和海拔；面板头不再重复选中摘要。
- 面板头是「轨迹明细 + 日期/时间范围 + 距离/时长/定位记录」三段统计；统计标签用官方 `SymbolGlyph` 图标（距离/时长/定位点），下面用官方 `Slider` 做轨迹采样拖动条，拖到哪一点就选中哪一点。选中时副标题变「第 N / 总数 条定位记录」，右侧出现「回到全程」浅蓝胶囊。时长列给 `layoutWeight(1.4)`，否则「13 小时 12 分」在 16fp 的三等分栏里会折成两行。
- 明细列表用 `Repeat(...).virtualScroll()`；地址只为可视分组标题和选中点按需解析（`GpsGeocoder`）。不要在 `onScrollIndex` 里给每个可视点预取地址——未选中的行只显示时间，预取只会白耗逆地理编码请求。
- `bindSheet` 设 `enableOutsideInteractive: true` + `maskColor: Color.Transparent`，面板展开时地图仍可操作。**不要用空的 `shouldDismiss` 来阻止面板关闭**：官方语义里侧拉关闭包含侧滑（左/右滑）、三键 back、ESC，注册后不调用 `dismiss()` 会把这些交互一起吞掉，表现就是“系统侧滑返回失效”。改用 `onWillDismiss`：`reason` 为 `PRESS_BACK`/`SLIDE` 时 `showSheet = false` 并 `pageInfos.pop()`；`SLIDE_DOWN` 不处理，保持拖到最低档停住。`onHeightDidChange` 同步更新地图 padding / logo 和 Canvas 的 `bottomInset`。
- 地图不可用时（模拟器未签名、无网络）用 Canvas 示意图兜底，列表和地址仍然可用；`titleBarInsetVp()` / 底部面板高度会作为 `topInset` / `bottomInset` 传给示意图，避免轨迹被标题栏或面板裁掉。
- **地图重试只对“签名包 + 超时/加载失败”显示**：`canRetryMap()` 同时检查 `MapCapability.isSignedPackage()`、`SystemCapability.Map.Core` 和 `mapError` 前缀；未签名/无地图能力不弹重试。`retryMap()` 要清 `controller`、`mapReady`、`mapLoaded`、`gcjCache`、`mapError`，再 `startInitTimeout()`，让 `MapComponent` 重新挂载。按钮用 `glass_bg` + `COMPONENT_THIN` 兜底（内容区拿不到真材质），放在标题栏下方右侧。

### 相关

- 定位采集、按天聚合、模拟轨迹、逆地理编码、地图能力与 GCJ02 转换：[SERVICES.md](SERVICES.md)。
- 全屏页标题栏与 `bindSheet` 材质规则：[AGENTS.md](AGENTS.md) 的「bindSheet 的材质」。

## 复用组件

| 组件 | 位置 | 用途 |
|---|---|---|
| `PageHeader` | `components/PageHeader.ets` | 二级页头部：返回键 + 主/副标题 + 可选右侧文字操作（自己避让状态栏） |
| `SelectionActionBar` | `components/SelectionActionBar.ets` | 多选底部操作栏：悬浮胶囊 + 图标在上文字在下的「下载」项。**自身不设背景**，材质由 `MainScreen.TitleBar` 的浮岛层提供 |
| `DownloadProgressBar` | `components/DownloadProgressBar.ets` | 下载进度浮岛：**竖条**（60vp 宽）贴握持手一侧，**环心显示「第几张/共几张」**（百分比看弧长就够；**≥1000 张时自动拆成两行**；完成态是**同一个环满格 + 环心换成一个品牌蓝的勾**，不要换成绿色实心圆盘）+ 环下状态词 + 取消圆钮；不显文件名。**自身不设背景**，材质由 `MainScreen.TitleBar` 的浮岛层提供 |
| `GpsTrackMap` | `components/GpsTrackMap.ets` | 定位记录卡片的预览地图：禁用手势、折线抽稀 1200 点、按坐标缓存 GCJ02；失败/超时/未签名自动降级为 `GpsTrackSketch`，点击进全屏 |
| `GpsTrackSketch` | `components/GpsTrackSketch.ets` | Canvas 轨迹示意图：按可见区域（`topInset` / `bottomInset`）归一化，画起终点、选中红点；监听 `bottomInset` 重绘；不能用 `Shape`/`Path`，其 viewPort 会二次缩放 |

### 约定

- 自身不设背景的浮层组件（`SelectionActionBar`、`DownloadProgressBar`）必须由 `MainScreen.TitleBar` 的浮岛层负责 `position` 与 `systemMaterial`，原因与做法见 [AGENTS.md](AGENTS.md) 的「内容区浮动卡片拿真材质」。
- 地图相关组件的降级路径与地图服务见 [SERVICES.md](SERVICES.md)。
- `GpsTrackMap` / `GpsTrackSketch` 的使用场景见本文「定位记录与轨迹页」。
