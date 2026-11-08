# 页面设计与组件

> 本文覆盖主界面/画廊/多选、相机/设置/缓存、预览器/一镜到底转场、定位记录/轨迹页与复用组件。ArkUI 通用规则见 [AGENTS.md](AGENTS.md)，业务服务见 [SERVICES.md](SERVICES.md)，调试与验收见 [AGENTS.md](AGENTS.md)。
>
> 所有字号、圆角、行高、图标尺寸一律取 `entry/src/main/ets/utils/UiTokens.ets`，不要在页面里手写数字；令牌清单与取值规则见 [AGENTS.md](AGENTS.md) 的「UI 令牌」。

## 主界面与画廊

### Index.ets

导航根与初始化。设置日志路径与下载目录、初始化 `GpsRecorder`、把 `AppLog` 交给 `PtpHost` 与 `ExifGeotagger`、监听深色模式设置并调用 `setColorMode`，最后把 `MainScreen` 作为首个目的地压入 `NavPathStack`。

### MainScreen.ets

NavDestination，标签页容器。持有标签状态、下载进度、已下载集合、GPS 开关状态、选择模式。订阅 `cachingDialogRequired` 弹出“发现新相机”对话框。点击缩略图时取该缩略图的屏幕矩形（`getRectangleById('thumb_<handle>')`，px）与附近 81 个单元格的位置缓存，连同 `positionLookup` 回调一起作为 NavPathStack 参数传给预览器，再 `pushPath('PhotoViewerScreen')` 触发一镜到底转场。缩略图位图不必传：预览器自己从 `svc.thumbnailPixelMapMap` 取。返回键在选择模式下先退出选择模式。标题栏是自己写的 `@Builder`（`NormalTitleRow` / `SelectTitleRow`）：大标题 + 右侧玻璃胶囊（格式筛选是 `Select` 下拉、加一颗「选择」胶囊），材质用通用属性 `systemMaterial`。

标签页索引拆成两个：`currentTab` 是 `Tabs({ index })` 的受控索引，只在 `onChange`（切换动画结束后）更新；`visualTab` 是标题栏、底部页签、浮岛等视觉状态用的索引，在 `Tabs.onSelected`（点击页签 / 滑动离手开始切换动画时）更新。**不要把 `currentTab` 用于标题栏条件**，否则旧页的按钮会在新页上停留整个 220ms 动画。官方 `Tabs` 的 `onChange` 说明与示例 17 就是这个用法。

导航骨架、标题栏与材质规则见 [AGENTS.md](AGENTS.md) 的「导航、标题栏与沉浸光感」。

### GalleryPage.ets

- 网格对齐官方图库：**默认 3 列**（设置里可改 4/5/6）、**贴边无页边距**、间距 2vp、**直角无圆角**、缩略图上**不叠时刻角标**。两指缩放（0.4x–6.0x）时列数随之重算。
- **捏合缩放只允许改「列数」，且只在跨档时改**：单元格是 `layoutWeight(1)` + `aspectRatio(1)`，视觉尺寸只由列数决定，倍数在同一档内连续变化不产生任何视觉差异。所以 `pinchScale` 是**普通字段**（逐帧更新不触发重建），只有列数跨档才写 `@Local appliedColumns`。**不要**把缩放倍数写成 `@Local`——那会让每个捏合事件都重建整页，实测 728 次事件只该换列十几次（日志 `PERF pinch: updates=…, columnChanges=…`）。列数/间距的换算在 `utils/GalleryZoom.ets`，有 Local Test（`GalleryZoom.test.ets`）。
- 行模型**不依赖 `thumbnailVersion`**：缩略图到达时只有 `ThumbImage` 自己重建。以前把 `thumbnailVersion` 编进 `buildFlatItems()` 的缓存键，扫描时每 4 张缩略图就重排一次全量行模型，纯浪费。
- 按拍摄日期分组，标题文案对齐官方并跟随系统语言：`今天` / `昨天` / 本地化月日（中文 `11月6日`、英文 `Nov 6`，跨年带年份），没有拍摄日期的归入「未知日期」。分组键是 `YYYYMMDD` 原始串，显示文案由 `dateHeaderLabel()` 换算，日期本身交给 `utils/DateTimeText.ets` 的 `Intl.DateTimeFormat`。
- 日期标题：左侧 16fp 粗体、上下各 24vp 留白、左右 16vp；多选态右侧多一个整组勾选圆圈（三态，见下文）。
- 格式筛选是标题栏右侧的 `Select` 下拉（选项 = 全部 + 照片里出现过的扩展名，只在“文件优先”模式下出现）。**不要**再做成「点一下轮换到下一个格式」的循环按钮 —— 用户猜不到下一下会到哪，设计很差。
- 长按进入多选（或点标题栏的「选择」胶囊）。多选态标题栏左叉 + 左对齐「已选择 N 项」+ 全选胶囊，底部悬浮胶囊操作栏只有「下载」一项。详见下文「多选模式」。
- 缩略图按整行显示：一行（当前列数）全部解码完成才同时出现，否则该行显示占位。
- `buildFlatItems()` 把日期标题与行拍平成一个数组交给 `Repeat` + `.virtualScroll()`，按 `photosVersion`、显示模式、筛选值、**当前列数**、宽度做缓存。日期分组另外缓存在 `ensureGrouping()` 里（只依赖照片与筛选）：捏合换列只需要重新分行，不要再扫一遍全量照片。
- 缩略图单元格抽成独立 `@ComponentV2 ThumbImage`，内部调 `svc.thumbForRender(handle)` 建立 V2 依赖（原因见 [AGENTS.md](AGENTS.md) 的三个刷新坑）。
- 末尾有 `FlatItem.tail()` 占位项（104vp），给悬浮页签留滚动空间；`ListItem` 的 `key` 必须保持稳定，把「行是否加载完成」编进 `key` 会让 `virtualScroll` 的复用项失效、整行渲染成空白。
- `List` 用 `.contentStartOffset(this.listTopInset())` 让首行避开标题栏，并设 `.clip(false)` + `.cachedCount(6, true)` 让滚动中的照片能穿到标题栏下方被模糊；扫描横幅显示时它自己就在内容顶部，此时 `listTopInset()` 归零（原因见 [AGENTS.md](AGENTS.md) 的「顶部标题栏」）。

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

#### 日期标题（含整组全选）

官方图库在多选态的每个日期标题 **右侧** 放一个 20vp 圆形勾选（不是「全选当天」文字胶囊）。三态：未选 = 空心细圈（`text_tertiary` 1.5vp）、部分选中 = 实心蓝 + 白色横线、全选 = 实心蓝 + 白勾；热区用 `responseRegion` 扩到 44vp。点击调 `toggleSelectDate(dateKey)` 整组切换。

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
- 根节点 `Scroll` 用 `.contentStartOffset(titleBarTotalVp())` 避让标题栏。

扫描阶段、缓存与快速扫描的细节见 [SERVICES.md](SERVICES.md)。

### SettingsPage.ets

- 分组卡片统一 24vp 圆角、无描边；单行 56vp、双行 64vp；分组标题 13fp 次级色。
- 选项类（深色模式 / 语言 / 默认列数 / 显示模式 / 记录频率）全是**右侧 `Select` 玻璃胶囊**（`SettingSelectRow`），不要再用自制的「灰底 + 蓝胶囊」分段按钮——那东西在内容区拿不到材质。
- 开关（GPS 记录、模拟相机）用 `Toggle(Switch)`，**不要设 `selectedColor`**，否则会覆盖系统预设的沉浸光感样式。
- 导航类行带 `chevron_right`（定位记录管理、缩略图缓存）。删除定位记录统一放在「定位记录管理」页（多选批量删除，或全屏轨迹页「更多」里删当天），设置页不再提供「清除定位记录」入口，避免误触。
- 调试日志面板仍是等宽字体、高 240vp，只在调试包里渲染。
- 调试区新增「模拟 GPS 轨迹」开关：以当前定位为起点生成相机图案，覆盖今天的地图/列表显示；真实 `gps_records.jsonl` 不变，关掉开关立即恢复。仅 debug 包可见。

调试包判定与模拟相机见 [AGENTS.md](AGENTS.md) 的「调试用的虚拟相机」；模拟 GPS 轨迹见上文「SettingsPage.ets」。

- 「外观 → 语言」提供跟随系统 / 简体中文 / 繁體中文 / English；默认跟随系统。选项切换后弹「应用将重启」确认框，确认后调用 `i18n.System.setAppPreferredLanguage()` 并用 `ApplicationContext.restartApp()` 重启进程（官方要求冷启动才重新加载资源）。语言偏好存在独立的 `model/LanguageStore.ets`，不要追加到 `SettingsStore`。

### CacheManagementPage.ets

- 列出每个相机的缓存体积、条目数、开关、删除、清空全部。卡片 24vp 圆角、无描边，与相机/设置页一致。

缓存实现见 [SERVICES.md](SERVICES.md) 的「ThumbnailCache」与「扫描的四个阶段」。

## 预览器与一镜到底转场

### PhotoViewer.ets

预览器，一个文件里有这些结构：`ZoomState`、`ZoomLayer`、`ZoomableImage`、`MainImageView`、`ThumbCellView`、`PhotoViewerScreen`。

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

### 一镜到底转场

2026-11-07 重写，对齐官方图库。官方图库的观感是三条独立的动作，**不是**「整页从缩略图放大」：

1. **只有照片在动**：起于被点缩略图单元格的矩形（方图、`Cover` 居中裁切），终于照片在预览器里的实际显示矩形（`Contain` 等比放入图片区域）。因为一直用 `Cover` 画，矩形从方图长到照片比例的过程天然就是「从中心裁切逐渐露出全图」，落位时矩形比例 == 照片比例，`Cover` 与 `Contain` 完全重合，可以无缝交还给页面内容。
2. **背景 180ms 压到纯黑**；
3. **标题栏与缩略图条在照片快落位时才淡入**（220ms 起、200ms 淡完），返回时反过来先淡出 140ms，再收照片。

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
