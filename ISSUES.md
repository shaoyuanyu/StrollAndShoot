# 真机测试问题记录

> 本轮（2026-11-08 夜）只做**问题发现、复现与归因**，没有修改任何业务代码。
> 每条问题都附实测证据；"根因"一栏指向具体文件与行号，"建议方向"一栏尚未实施。

## 测试环境

| 项 | 值 |
|---|---|
| 时间 | 2026-11-08 23:53 – 23:58（Asia/Shanghai） |
| 手机 | HUAWEI VYG-AL00，HarmonyOS 7.0.0.111(SP12C00E111R3P4) |
| 应用 | `io.github.shaoyuanyu.strollandshoot`，`1.20.1{debug}` / versionCode 1020001 |
| 相机 | Nikon Z50_2，VID `0x04b0` / PID `0x0455`，固件 V1.04，PTP 模式 |
| 调试通道 | hdc over Wi-Fi `10.15.98.124:37341`（USB 口留给相机） |
| 取证方式 | `hilog` 文本流、应用内 `app_log.txt`、`uitest dumpLayout` 文本树、PTP 报文十六进制 |

**隐私约束**：本轮未截屏（未用 `snapshot_display`、未用 `--ps shot`），未取回任何图片；
`files/` 下的 `DSC_1008.JPG`、`DSC_1013.JPG` 与 `thumb_cache/` 均未读取。

## 结论摘要

| ID | 标题 | 严重度 | 用户可见 | 状态 |
|---|---|---|---|---|
| ISSUE-001 | 扫描失败后界面无任何反馈 | 高 | 是 | 已复现、已归因 |
| ISSUE-002 | PTP 错误码在传输层被丢弃，失败原因不可区分 | 中 | 间接 | 已归因 |
| ISSUE-003 | `connected` 与"可用"不一致，失败后仍显示"已连接" | 中 | 是 | 已归因 |
| ISSUE-004 | 快速扫描无节流，连点会重复发起 | 低 | 是 | 已复现 |
| ISSUE-005 | 扫描失败会清空画廊已挂上的照片 | 中（潜在） | 是 | 代码推断，本轮未复现 |
| ISSUE-006 | `CloseSession` 发送失败仍记为已关闭 | 低 | 否 | 已观测 |
| ISSUE-007 | 冷扫描 1289 张耗时 4 分 47 秒（缩略图平均 186ms/张） | 高 | 是 | 已实测 |
| ISSUE-008 | 首次扫描前 47 秒画廊完全空白 | 中 | 是 | 已实测 |
| ISSUE-009 | 热扫描 39 秒（冷启动 47 秒），97% 花在重读未变化照片的元数据 | 高 | 是 | 已实测 |
| ISSUE-010 | PTP 数组解析未跳过 count 字段，凭空多出伪 storage / 伪句柄 | 高 | 是 | 已定位 |
| ISSUE-011 | 应用语言"跟随系统"（中文）下，画廊日期显示英文 | 中 | 是 | 已定位 |
| ISSUE-012 | NEF 缩略图带黑色侧边，同张 JPG 正常 | 中 | 是 | 已定位 |
| ISSUE-013 | 预览原图：NEF 单张 2.9 秒，瓶颈是 USB 吞吐 ≈5.7 MB/s | 高 | 是 | 已实测 |
| ISSUE-014 | 预览器：切图偶发卡顿、快速切图卡顿、缩略图条惯性不跟手 | 高 | 是 | 已定位（代码层） |
| ISSUE-015 | 预览器：捏合偶发卡顿、放大后拖动速度随倍率放大 | 高 | 是 | 已实测 + 已定位 |
| ISSUE-016 | 预览器返回画廊的一镜到底转场偶发轻微掉帧 | 中 | 是 | 已定位（代码层） |

---

## 第二轮真机测试（2026-11-09 下午）

第一轮整改装到真机后，又暴露了一批问题，本小节记录**新发现 + 已修复**的项；上面「修复状态」表里的「真机待验」已全部通过（见下）。

| ID | 现象 | 根因 | 处理 |
|---|---|---|---|
| R2-001 | 首次全量扫描时 app 闪退 | 扫描期分批上屏（ISSUE-008）让画廊在扫描中反复重排行模型；`Repeat` 复用元素时 `RepeatItem.item` 这个 getter 在某些时刻返回 `null`，`PhotoCell` 判空之后再次读取就炸了（`TypeError: Cannot read property displayPhoto of null`，`GalleryPage.ets:668`） | ①行数据里**去掉 `null` 占位**（`rowPhotos` 只放真照片，末行空白格用独立 `padIndexes` 渲染）；②格子 builder 恢复读 `RepeatItem`（传值参数在列表复用时不刷新，会显示成别的照片）。真机重测 1288 张不再闪退 |
| R2-002 | 崩溃后「相机连着却搜不到」 | 进程被系统杀掉时来不及 `CloseSession`，相机保留旧 PTP 会话，`OpenSession` 恒返回 `0x201E` | `PtpHost.connect()` 收到 `0x201E` 先补发 `CloseSession` 再重试，失败才提示拔插线。真机验证：`补发 CloseSession 后 OpenSession 成功` |
| R2-003 | 扫描期滚动画廊，照片成群出现在别人的位置上 | 与 R2-001 同源：为躲空指针把格子换成「传值参数」，`@Builder` 值参数随列表复用不刷新，格子停在旧照片上 | 同 R2-001（去 null 占位 + 恢复响应式参数） |
| R2-004 | 扫描横幅被日期标题压住、进度文字被格子切掉，首个日期标题怎么下拉都在标题栏后面 | 列表为了「照片钻到标题栏底下」设了 `clip(false)`，流内横幅被滚动内容覆盖；同时 `listTopInset()` 因为「有横幅」返回 0 | 横幅改成**浮在列表之上的状态卡**（`ScanCard`，圆角 + 加载环 + 阶段文案 + 进度线），列表 `contentStartOffset` 让开 `SCAN_CARD_INSET` |
| R2-005 | 预览器转场卡顿、pop 掉到 21fps | 逐帧驱动：先是「固定布局 + 逐帧裁剪框 + clip」每帧离屏渲染，后是 `displaySync` 每帧回调解 JS + 改 4 个 `@Trace` | 改为 `animateTo` 原生插值（`startRectAnimation`），JS 只在首尾各跑一次；真机观感恢复 |
| R2-006 | 扫描中打开照片会一直等原图 | 扫描期不允许下载原图，但界面没有任何说明 | 预览器底部提示「扫描中，暂时只显示缩略图 X/1288 / 扫描完成后会自动加载原图」，扫描结束自动消失并补投原图 |
| R2-007 | 传输退到后台就断 | 没有申请长时任务 | `backgroundModes` 加 `dataTransfer`，扫描/下载期间按引用计数申请 `DATA_TRANSFER` 长时任务 |
| R2-008 | 通知栏看不到传输进度 | 系统长时任务通知的内容由系统生成，应用无法注入进度 | 用系统预置通知模板 `downloadTemplate` 另发一条进度环通知（`TransferNotice`），1 秒刷新、结束撤销 |

真机已验证（A1–A11）：扫描浮卡布局、扫描期缩略图提示、退后台传输、快速扫描 2 秒级、失败文案与不清空画廊、NEF 无黑边、日期本地化、5x 拖动 1:1、缩略图条落位、下载 + GPS 写入、多选态材质与拖拽框选。

---

## 第三轮真机测试（2026-11-09 晚）

| ID | 现象 | 根因 | 处理 |
|---|---|---|---|
| R3-001 | 「文件优先」模式下同一张照片的 JPG 与 NEF 不成对，散在好几行之外 | 见下（两条独立原因） | `buildFileFirstGroups()` 改成「按时间排 → 同名词条收成相邻块」；删掉 `GalleryPage.allDisplayGroups()` 里多余的 captureDate 重排 |

**取证**：从真机拉回 `metadata_cache.json`（Nikon Z50，1288 个文件、644 组 JPG+NEF），按 `publishPhotoList()` 的比较器离线复算，**438 组被拆开**。

1. **连拍落在同一秒**（主因）：`DSC_4477/4478/4479` 的 EXIF 时间戳都是 `20260920T213747`，`captureDate` 与 `modificationDate` 两把键完全相同，只剩 `handle` 降序兜底。相机按**格式分段**分配 handle（JPEG 在 `6895087xx` 段、NEF 在 `1526378xx` 段），数值顺序跟拍摄顺序无关，于是同一秒内所有 JPG 排到所有 NEF 前面：`…4481.JPG, 4480.JPG, 4481.NEF, 4480.NEF…`。
2. **两文件时间差 1 秒**（次因，66 组）：`DSC_3840.NEF=20260709T140428` 而 `.JPG=140427`，主键本身就不同，排序时被其它照片隔开。

修复后离线复算：644 组**全部相邻**（0 组被拆），整体仍是倒序，只在 1 秒级精度上让位给配对。新增 3 个 Local Test 覆盖。

---

## 修复状态（2026-11-09）

本轮整改后版本 **1.21.0 / 1021000**。验证环境：Mate 80 模拟器（HarmonyOS 7.0.0 / API 26）+ 调试包的虚拟 PTP 相机；**没有动真机**（用户要求）。模拟器能覆盖扫描管线、缓存、日期、拖选、加载队列与转场，但覆盖不到真实 PTP 错误码、USB 吞吐、EXIF 方向与手势手感。

| ID | 处理 | 模拟器验证 | 真机待验 |
|---|---|---|---|
| 001 | 状态卡永远优先显示 `statusText`；失败弹 toast；未连接态也显示 `lastScanError` | 成功路径：状态卡显示「已连接 - 38 张」；无相机路径：toast + 空态红字「未检测到USB相机」（日志 `扫描失败: 未检测到USB相机`） | `0x200F` → 拒绝访问 的文案分支（mock 相机不返回错误码） |
| 002 | 传输层抛 `PtpError(code)`，服务层按码映射文案 | 编译 + 正常路径通过；mock 相机不返回错误码 | `0x200F` / `0x2008` 的文案分支 |
| 003 | 新增 `usable`（`GetStorageIDs` 成功），与 `connected` 分开；状态点红/绿 | 已连接 + 正常扫描为绿 | 连接成功但存储读不到时变红 |
| 004 | `scanForCamera()` 800ms 最小间隔 + 进行中请求合并 | 连点只触发一次 | — |
| 005 | 失败分支不再清空 `photos` / `photoCount` | 无缓存相机扫描失败看不到画廊闪空 | 同上 |
| 006 | `CloseSession` 发送失败不再打 acknowledged | — | 日志措辞 |
| 007 | 删掉每张的二次编码落盘；EXIF 方向随 `metadata_cache.json` 缓存；PTP 双写日志去掉；`[EXIF_PARSE]` 明细删除 | 冷扫 38 张：`磁盘命中 0 / USB 读取 38`；热扫：`USB 读取 0` | 1288 张冷扫耗时（预期 286.9s → 明显下降） |
| 008 | 元数据每 100 张排序上屏 | 冷扫时画廊逐批出现 | 1288 张的 47s 空窗是否消失 |
| 009 | 快速扫描复用 `metadata_cache.json`（抽样 8 个校验 + 7 天有效期），只读新增 | **复用 38 / 读取 0**，`元数据复用校验通过: 8 个样本一致` | 1288 张热扫（预期 39s → ~2s） |
| 010 | native 新增 `parseCountedU32Array` 跳过 count 并按 count 截断 | mock 不走 native | `StorageIDs count: 1`、`ObjectHandles total: 1288`、`0x2008/0x2009` 归零 |
| 011 | `DateTimeText` 全部改为显式区域（应用语言优先，否则系统区域） | 画廊标题为「10月20日」「10月19日」 | 切 English 后为 `Oct 20` |
| 012 | 原始尺寸优先用 PTP `imagePixWidth/Height`（NEF 的 EXIF 尺寸在 SubIFD）+ `MANIFEST_VERSION` 2→3 | manifest 升级后旧缓存整体重建（日志可见冷扫） | NEF 格子左右黑边消失；预览器全屏 NEF 是否也有黑边 |
| 013 | 首帧已有「缩略图先显示」；预加载优先级维持 | 打开照片先出缩略图再出原图 | USB 分块大小（192KB → 512KB）实验仍未做 |
| 014 | A/B：`pendingFullResHandle` 补投；C：删自定义惯性，交还 Swiper fling，落位期暂停加载 | 连续快切 3 张 → 7/38 正常；缩略图条 fling 7 格后稳定落位 | 真机手感 |
| 015 | A：`gestureDepth` 让预加载在整个手势期间持续暂停；B：去掉 `offsetX * zoom.scale` | 无法在模拟器模拟双指 | 5x 拖动是否 1:1、捏合 fps 是否回到 60 |
| 016 | 共享层改为固定布局尺寸 + 裁剪框 + 等比 `scale`；新增 `ViewerPerf transition` 帧采样 | push `fps=64 lateFrames=0 gapMax=16ms`；pop `fps=63 lateFrames=0 gapMax=16ms` | 6MP 原图的 push/pop 是否仍满帧、起止矩形是否对齐 |
| REQ-001 | 多选态按住滑动框选（原始触摸 + `getItemIndex/getItemRect` + 边缘自动滚动），Tabs `.scrollable(false)` | 横向拖一行选中 3；反向拖取消到 0；竖向跨行 3；Tab 不再左右滑动、点击正常 | 手势手感与材质 |

### 模拟器上未解决/新发现

- **内容区白色/灰色多边形伪影（首页、画廊、设置都有）**：根因是内容容器 `.linearGradientBlur(96, { fractionStops: [[1, 0], [0.9, 0.06], [0, 0.18]] })` **没有覆盖到位置 1**——官方定义每档是 `[模糊程度, 模糊位置]`，位置要严格递增，最后一档应写到 1；0.18→1 这段的模糊遮罩没有定义，模拟器会把它画成大片三角碎片（并且随滚动重新计算）。补上 `[0, 1]` 后复测：相机页滚动、画廊、设置页均干净，磨砂效果保留。**已修**（`MainScreen.ets:717`）。
- **多选态整屏彩色/白色多边形伪影**：经 A/B 对照确认与本次改动无关，并且**不是应用代码问题**：
  - 用 `git stash` 回到改动前基线（1.20.1）重新构建 → 同样复现；
  - 关掉内容区 `linearGradientBlur` → 仍复现；去掉底部操作栏材质 → 仍复现；`barHeight` 设 0 或 56 → 都复现；
  - `hilog` 里持续出现 `E C01406/render_service/OHOS::GE: GEXFrostedGlassBlurShaderFilter::IsFilterSupported is false` —— **模拟器 GPU 不支持磨砂玻璃（沉浸光感）着色器**，多选态同时叠了标题栏材质按钮 + 底部操作栏材质 + 页签材质并持续重绘，渲染器退化成乱画的几何。
  - 功能不受影响（标题计数、拖拽框选、全选、下载栏都正常）。**真机需确认材质渲染**；模拟器上不要再拿多选态截图做视觉验收。
  - **调试缓解（2026-11-09）**：设置页「调试 → 关闭磨砂玻璃」会通过 `utils/GlassEffect.ets` 把所有 `systemMaterial` 换成 `uiMaterial.Material.empty`、`backgroundBlurStyle` 换成 `BlurStyle.NONE`、`linearGradientBlur` 半径归零。打开后材质叠加造成的乱花会减少，布局与交互截图基本可用。
  - **进一步 A/B（2026-11-09，画廊顶部大块彩色三角形）**：以下改动**每一项都单独验证过，伪影仍复现**，形状随重绘变化：
    1. 应用级 `ohos.arkui.UIMaterial.state` 设为 `disable`（`hilog` 里 `GEXFrostedGlassBlurShaderFilter::IsFilterSupported is false` 归零）；
    2. 全部 `systemMaterial` 换 `Material.empty` + `backgroundBlurStyle(NONE)`；
    3. 完全移除 `linearGradientBlur`；
    4. 去掉 `List.clip(false)`、`cachedCount(6, true)`、`virtualScroll()`；
    5. 关闭扫描浮卡（`ScanCard`）；
    6. 缩略图 `Image` 换成纯色 `Column`。
    - 应用内 `Window.snapshot()`（`--ps shot`）同样能截到，排除「系统截屏/悬浮窗」假象。
    - 冷启动、未扫描时画廊空态**完全干净**；一旦列表里有照片行就出现。触发点是「有内容的列表层」的栅格化/合成，不是页面壳子、标题栏或某个单个组件。
    - 结论：这是模拟器渲染管线（virtio-gpu / GLES + 图层合成）的缺陷，应用侧没有可稳定规避的属性组合；**模拟器截图只能用于布局/状态/交互，材质与整页视觉以真机为准**。
    - 官方依据：UI Design Kit《模拟器支持情况》明确模拟器不支持 HDS 沉浸视效（含沉浸光感材质）；图形模块文档列出「模拟器与真机的差异」；模拟器 FAQ 对图形异常建议清数据重启、更新驱动/模拟器。
    - 处理建议：真机验收；模拟器持续花屏时重启或清数据重启模拟器、更新 DevEco Studio/模拟器镜像；仍复现就附日志 `GEXFrostedGlassBlurShaderFilter::IsFilterSupported is false` 与复现步骤向华为反馈。
- `devecocli check lint` 在本机报告 `Files checked: 0`（工具链问题），本轮以编译 0 error 为准。


---

## ISSUE-001 扫描失败后界面无任何反馈

### 现象

相机（Nikon Z50_2）已插上并开机，应用显示"已连接"，点标题栏「快速扫描」后：
按钮不转圈、页面不变化、无 toast、画廊仍为空。连续点 4 次，表现完全一致。

### 复现步骤

1. 设置 → 调试 → 关闭「模拟相机设备」（否则走的是虚拟相机）
2. USB 接 Nikon Z50_2，相机开机
3. 相机页完成首次连接与缓存选择
4. 点标题栏右上角「快速扫描」
5. 观察：状态卡仍是"已连接"，照片数量 0，没有任何错误提示

### 实测证据

**每次扫描全程 12–16 ms**（hilog 毫秒时间戳）：

```
23:54:20.841  USB设备总数: 1
23:54:20.845  [快速扫描] 缓存快照就绪: 0 张
23:54:20.853  Response error: 0x200f
23:54:20.853  StorageIDs count: 0
```

**`statusText` 其实被设成了"已连接 (无存储设备)"，但没有渲染出来**。`uitest dumpLayout`
拿到的文本节点只有这些（节选）：

```
"已连接"    "快速扫描"    "Z50_2"    "Nikon Corporation"
"照片数量"  "0"           "全量扫描"  ...
```

没有出现 `已连接 (无存储设备)`，也没有 `未检测到USB相机`。

**扫描路径没有任何 toast**：全工程 `promptAction` 只在 `SettingsPage.ets:212` 使用一次。

### 根因

1. `entry/src/main/ets/services/CameraService.ets:1289-1295` —— `getStorageIDs()` 返回空数组时，
   把 `statusText` 设为 `camera_status_no_storage`（"已连接 (无存储设备)"），然后 `return`。
2. `entry/src/main/ets/pages/CameraPage.ets:32-34` —— 状态卡标题写死成三元：

   ```ts
   Text(this.svc.connected
     ? $r('app.string.camera_status_connected')      // ← 已连接时永远显示"已连接"
     : (this.svc.statusText || $r('app.string.camera_empty_title')))
   ```

3. `statusText` **全工程只有一个读取点**（就是上面这一行），且只在 `connected === false` 分支生效。
   也就是说：**一旦连上相机，之后所有失败原因都注定不可见**。
4. 页面结构上也没有别的出口：`connected` 为真时渲染 StatusCard + DeviceCard + ActionsCard
   （`CameraPage.ets:171-179`）；扫描结束后 `scanning=false`、`scanTotal=0`，进度条也不显示，
   所以视觉上零变化。
5. 标题栏按钮的「扫描中…」态（`MainScreen.ets:437-449`）只存在 12–16 ms，肉眼不可见。

**同一根因的第二个表现**：23:54:06 那次扫描 `USB设备总数: 0`，`statusText` 被设为
"未检测到USB相机"，但扫描一结束 `connected=false` → 页面切回 `EmptyCard`（静态文案），
`statusText` 同样不会显示。用户看到的就是"点了没反应"。

### 复发：杀进程重启 + 相机休眠后，第一次点击必然静默失败

00:38 用户杀掉进程重进应用，相机已休眠约 27 分钟。第一次点「快速扫描」：

```
00:38:46.804  === 开始扫描 ===
00:38:47.013  [快速扫描] 部署缓存快照...
00:38:48.372  缓存快照: 1288 张照片, 1288 个缩略图     ← 缓存已经显示出来了
00:38:48.382  Response error: 0x200f                   ← GetStorageIDs 被拒，9 ms
             （此后无任何日志，scanning 归位，界面无变化）
00:38:54.439  === 开始扫描 ===                         ← 用户 6 秒后又点了一次，这次成功
```

也就是说：**缓存里的 1288 张照片都已经渲染出来了，但界面停在"已连接"，
用户完全不知道刚才那一下失败了**，只能凭直觉再点一次。这正是 ISSUE-001 在真实场景里的样子。

相机侧的原因推测是休眠唤醒需要时间（第一次 `OpenSession` + `GetDeviceInfo` 成功、只有
`GetStorageIDs` 被拒）。应用侧的缺陷是：把"一次可以重试的临时失败"呈现成了"什么也没发生"。

### 影响

用户无法区分以下四种情况：没连上 / 连上了但读不到存储 / 正在扫描 / 扫描完成但确实没照片。
只能反复点击（见 ISSUE-004）。

### 建议方向（未实施）

- 状态卡文案优先用 `statusText`，`connected` 只决定圆点颜色与是否展示设备卡；
- 失败分支补一次 `showToast`，把原因说到"相机是否开机 / 是否插卡 / 是否在回放态"这一层；
- 给 `camera_status_no_storage` 换成可执行提示，而不是陈述一个没被证实的结论（见 ISSUE-002）。

---

## ISSUE-002 PTP 错误码在传输层被丢弃，失败原因不可区分

### 现象

日志里唯一线索是 `Response error: 0x200f`，业务层拿不到它，UI 也就无法给出准确提示。

### 实测证据

同一次扫描的 PTP 报文时序：

```
OpenSession        → 0x2001 (OK)
GetDeviceInfo      → 0x2001 (OK)，解析出 manu="Nikon Corporation" model="Z50_2" ver="V1.04"
GetStorageIDs      → 0x200f (AccessDenied)
```

相机能完成 `OpenSession` 和 `GetDeviceInfo`，说明**相机是开机状态、PTP 通道正常**，
只有读存储这一步被拒。

### 根因

1. `entry/src/main/ets/pages/PtpHost.ets:414-420` —— 响应码不是 `0x2001` 时直接 `return null`：

   ```ts
   if (result.action === 2) {
     if (result.responseCode === 0x2001) return dataPayload;
     log(`Response error: 0x${...}`);   // 只写日志
     return null;                        // 错误码到此为止
   }
   ```

2. `entry/src/main/ets/pages/PtpHost.ets:192-198` —— `getStorageIDs()` 把 `null` 变成 `[]`；
3. `entry/src/main/ets/services/CameraService.ets:1289` —— 把 `[]` 当成"相机没有存储设备"。

**"拒绝访问"与"没有存储"在业务层完全等价**，文案因此断言"无存储设备"，属于误报。

### 影响

即便以后把文案显示出来（修 ISSUE-001），用户看到的也是错误归因；排障时也无法从界面判断是
没插卡、卡被锁、还是相机停在回放/菜单态。

### 建议方向（未实施）

- 传输层返回 `{ data, responseCode }`，或用带 `code` 的 Error 抛出；
- 服务层按码映射文案：`0x200F` → "相机拒绝了存储访问（请确认已插入存储卡、且不在回放/菜单状态）"，
  空存储 ID 列表 → "相机没有可用存储"。

---

## ISSUE-003 `connected` 与"可用"不一致

### 现象

`GetStorageIDs` 失败后，应用仍然认为相机是"已连接"：状态卡显示已连接、设备信息卡完整、
标题栏按钮仍是「快速扫描」。

### 根因

1. `CameraService.ets:1138` 在 `session.connect()` 成功后就把 `connected = true`，
   之后 `loadPhotosAndThumbnails()` 失败**不会回退**这个标志；
2. 下一次点「快速扫描」走 `sameDevice` 分支（`CameraService.ets:1092-1115`），复用同一会话重试，
   所以 `connected` 永远是 true；
3. 标题栏按钮文案由 `connected` 决定（`MainScreen.ets:451`），
   所以按钮永远停在「快速扫描」，不会退回「搜索相机」；
4. `cameraName` / `deviceManufacturer` / `deviceSerialNumber` / `usbVidPid` 等字段在连接阶段已填好，
   设备卡看起来完全正常。

### 影响

"已连接 + 快速扫描按钮 + 0 张照片"这个组合本身就在误导用户，让他以为相机是好的、只是没照片。

### 建议方向（未实施）

区分 `connected`（USB 会话建立）与 `usable`（存储可读）。存储读不到时：
按钮退回「重新搜索」、设备卡加一行状态、`photos` 保持不变。

---

## ISSUE-004 快速扫描无节流，连点会重复发起

### 实测证据

连接建立后约 50 秒内 5 次快速扫描，其中 3 次集中在 1 秒内：

```
23:54:20.841   → 23:54:20.853   (12 ms)
23:54:23.119   → 23:54:23.133   (14 ms)
23:54:23.790   → 23:54:23.802   (12 ms)
23:55:07.599   → 23:55:07.806   (207 ms，含重连)
23:55:09.066   → 23:55:09.082   (16 ms)
```

本轮会话共记录 7 次 `=== 开始扫描 ===`。

### 根因

按钮只在 `svc.scanning === true` 时换成「扫描中…」（`MainScreen.ets:437`），
而一次失败扫描只有 12–16 ms，节流窗口几乎不存在；`scanForCamera()` 本身没有最小间隔、
没有请求合并、没有串行队列。

### 影响

在"看起来没反应"的场景下，用户会连续点击，把连点放大成多次 USB 会话与多次错误响应。
本身不致命，但会加重 ISSUE-001 的感知。

### 建议方向（未实施）

给 `scanForCamera()` 加最小触发间隔（例如 800 ms），或对进行中的扫描做请求合并。

---

## ISSUE-005 扫描失败会清空画廊已挂上的照片（潜在）

### 现状

`CameraService.ets:1289-1294`：

```ts
if (storageIDs.length === 0) {
  this.photoCount = 0;
  this.photos = [];                       // ← 直接清空
  this.statusText = L10n.tr('camera_status_no_storage');
  return;
}
```

而快速扫描在进入这一步之前，已经通过 `deployCacheSnapshot()`（`CameraService.ets:1178`）
把磁盘缓存的照片挂到了画廊。

### 本次为什么没暴露

这台相机第一次连接，缓存快照是 0 张（日志：`[快速扫描] 缓存快照就绪: 0 张`），
所以"清空"看不出效果。

### 风险

对已有缓存的相机，一次失败的快速扫描会让画廊**先出现照片、随后全部消失**——
比"一直空着"更容易被误判成"照片被删了"。

### 建议方向（未实施）

失败分支不要动 `photos` / `photoCount`，只更新状态文案。

---

## ISSUE-006 `CloseSession` 发送失败仍记为已关闭（次要）

### 实测证据

```
23:55:07.599  Sending CloseSession
23:55:07.601  OUT failed: -1
23:55:07.601  CloseSession acknowledged
23:55:07.601  Session closed
```

`bulkTransfer` 返回 -1（发送失败）后，代码仍然打印 `acknowledged` 并把会话标记为已关闭。
重连随即成功（`Connected to 2-3`），本轮未观察到实际故障，但这是一个状态误报：
设备侧可能还留着旧会话。

### 建议方向（未实施）

`OUT failed` 时不要置 `sessionOpen = false` / 不要打印 acknowledged，或至少把失败
如实反映到返回值（现在 `closeSession()` 的调用方无从得知）。

---

## ISSUE-007 冷扫描 1289 张耗时 4 分 47 秒

### 实测环境

Nikon Z50_2，1288 张（NEF 与 JPEG 混合），**缓存为空**（该相机首次连接），
`cachingEnabled = true`，相机开机停在拍摄界面。

### 分阶段实测

| 阶段 | 起止（hilog 毫秒时间戳） | 耗时 | 单张 |
|---|---|---|---|
| 扫描开始 | 23:59:13.180 | — | — |
| GetStorageIDs | 23:59:13.402 | 0.22 s | — |
| 遍历目录（format 过滤） | 23:59:13.624，1289 个 handle | 0.22 s | — |
| 拉元数据 getObjectInfo | 23:59:13.625 → 00:00:00.487 | **46.9 s** | **36.4 ms** |
| 拉缩略图 | 00:00:00.487 → 00:04:00.117 | **239.6 s** | **186 ms** |
| **合计** | 23:59:13.180 → 00:04:00.117 | **286.9 s（4 分 47 秒）** | — |

**读取全部成功**：1288/1288 张缩略图入列，`NO_THUMB` 0 条、`[TASKPOOL_THUMB] FAIL` 0 条、
`[THUMB_SUBMIT] FAIL` 0 条。说明相机与 USB 链路本身没问题——上一轮的 `0x200f` 是相机未就绪，
不是读不动。

### 单张缩略图拆分（中位，样本约 500 张）

| 环节 | 耗时 | 代码位置 |
|---|---|---|
| `GetThumb` USB 往返 | 29 ms | `CameraService.ets:1521` |
| `GetPartialObject` 读 16KB EXIF 头 | 32 ms | `CameraService.ets:1528` |
| EXIF 解析 + raw 落盘 + TaskPool 解码 | ≈30 ms | `CameraService.ets:1531-1541` |
| `getImageInfo` + 二次编码落盘 + 画廊刷新 | ≈87 ms | `CameraService.ets:1677-1696` |
| 合计 | ≈178 ms（实测相邻两张中位间隔 202 ms） | |

### 根因

1. **每张两次串行 USB 往返**。`loadThumbnailsRowByRow` 每行并发 4 个 `loadSingleThumbnail`
   （`CameraService.ets:1439-1473`），但所有请求共用一条 PTP 管道：日志里严格是
   `GetThumb → Got data → GetPartialObject → Got data → 解码 → 下一张`，
   **并发没有产生任何并行收益**。
2. **每张重复读 16KB EXIF 头**（`CameraService.ets:1528`）。元数据阶段 `getObjectInfo` 已经拿到
   `imagePixWidth/Height`，方向确实要读 EXIF，但尺寸可以复用；现在为了一个 orientation
   每张多花 32 ms（1288 张约 41 秒）。
3. **每张写两次盘**：先 `saveRawThumbnail` 存原始 JPEG（`CameraService.ets:1657`），
   解码后再 `saveEncodedThumbnail` 重新编码并覆盖同一文件（`CameraService.ets:1692`）。
   日志可见 `raw ... -> xxx.jpg (11892 bytes)` 紧接着 `encoded ... -> xxx.jpg (5580 bytes)`。
   两次写的是同一个文件。
4. **日志放大**：`PtpHost.log()`（`PtpHost.ets:53-55`）先写 hilog，再把同一条消息交给
   `AppLog.add()`，而 `AppLog.add()` **又写一次 hilog**（`AppLog.ets:43-49`）——
   每条 PTP 报文在 hilog 里都出现两遍。叠加 `[EXIF_PARSE]` 每张照片约 25 行 IFD0 明细
   （`CameraService.ets:314`），1288 张会产生数万行日志，另外还完整写一遍 `app_log.txt`。
5. **扫描与画廊刷新抢 JS 线程**：每行结束 `thumbnailVersion++`（`CameraService.ets:1479`）
   触发画廊重建；实测最长空档 179 ms 正好落在一次 `PERF buildFlatItems` 上。

### 影响

1288 张要等 5 分钟，且这 5 分钟里 UI 间歇卡顿。相册规模越大越明显。

### 建议方向（未实施）

- EXIF 方向与尺寸合并进元数据阶段，缩略图阶段不再读 16KB 头；
- raw 落盘与二次编码二选一：不需要旋转/裁剪的缩略图（实测 120×160 原样）直接存，不重编码；
- 把"请求下一张"与"解码上一张"做成流水线（现在是解完才发下一张）；
- `[EXIF_PARSE]` 明细降到 debug 级，并去掉 hilog 双写。

---

## ISSUE-008 首次扫描前 47 秒画廊完全空白

### 现象

从点「快速扫描」到第一张照片出现，要等 **46.9 秒**——元数据循环结束后才一次性赋值。

### 根因

`CameraService.ets:1379`：

```ts
this.photos = photoList;      // ← 1289 张全部 getObjectInfo 完成后才赋值
this.photoCount = photoList.length;
this.photosVersion++;
```

缓存为空时 `deployCacheSnapshot()` 也提供不了内容，所以这段时间切到画廊就是空白。
用户只能在相机页看到"获取元数据 1083/1289"，容易以为卡死。

### 建议方向（未实施）

元数据每批（例如每 100 张）增量 push + `photosVersion++`，让画廊逐步出现缩略图占位。

---

## ISSUE-009 热扫描 39 秒（冷启动 47 秒），97% 花在重读未变化照片的元数据

### 实测对比

同一台相机、同一批照片，间隔 1 分 45 秒点了两次「快速扫描」：

| | 冷扫描（缓存空） | 热扫描（缓存满） | 冷启动 + 缓存（杀进程重进） |
|---|---|---|---|
| 起点 → 结束 | 23:59:13.180 → 00:04:00.117 | 00:05:45.707 → 00:06:25.028 | 00:38:54.439 → 00:39:41.167 |
| 总耗时 | **286.9 s（4 分 47 秒）** | **39.3 s** | **46.7 s** |
| 缓存快照部署 | 0 张 | 1288 张，0.83 s | 1288 张，**0.97 s** |
| 元数据 `getObjectInfo` | 46.9 s | 38.3 s | **≈45.5 s** |
| 缩略图 | 239.6 s | 0.009 s | 0.015 s |

热扫描快了 7.3 倍，缩略图几乎不再花时间——但 **38.3 s / 39.3 s = 97.4% 仍然耗在元数据上**。

**杀进程重启后**：磁盘缓存能完整还原（1288/1288，0.97 s），缩略图依旧不用走 USB，
但总耗时反而升到 46.7 s——`getObjectInfo` 中位间隔从 31.0 ms 涨到 **33.0 ms**（p90 46 ms），
冷进程的 JIT / 页缓存未热身。**结论不变：瓶颈就是元数据全量重读，与缓存无关。**

### 证据

逐张 `GetObjectInfo` 的事务间隔实测：

```
GetObjectInfo 次数 1289，相邻间隔中位 31.0ms  p90 43.0ms  最大 64.0ms
1289 次 × 31.0ms = 40.0s
```

单次响应只有 146 字节，耗时与载荷无关——**这是固定的事务延迟，不是带宽问题**：
一条 PTP 命令 = 1 次 bulk OUT + 1 次 bulk IN，在手机上约 30 ms 一个来回。

`CameraService.ets:1333-1356` 对 `handles` 全量循环 `getObjectInfo`，
**没有和缓存里的条目做任何比对**，所以 1288 张完全没变的照片也要重新逐张问一遍。

### 影响

"快速扫描"名义上很快，实际每次仍要等 39 秒，且这 39 秒里相机一直在被读。
相册越大越慢（线性）。

### 建议方向（未实施）

- 快速扫描改成增量：`getObjectHandles` 拿到的 handle 集合与本地缓存做差集，
  只对新增 handle 调 `getObjectInfo`，其余复用 `metadata_cache.json`；
- 保留「全量扫描」作为强制刷新入口（`quickMode=false` 已经是独立入口）；
- 删除/改动的照片靠时间兜底：例如每 N 次快速扫描或手动全量时强制重读。

---

## ISSUE-010 PTP 数组解析未跳过 count 字段，凭空多出伪 storage / 伪句柄

### 现象

- 相机页照片数徽标先显示 **1289 张**，扫描完成后变成 **1288 张**（第一张截图里就是 `1289 张`）；
- 日志 `ObjectHandles total: 1289`，但实际照片 1288 张；
- 日志 `StorageIDs count: 2`，但相机只有 1 个存储；
- **每次扫描**都会产生 10 次 `0x2008 InvalidStorageId` 与 6 次 `0x2009 InvalidObjectHandle`
  （冷扫、热扫完全一致，与是否复用会话无关）。

### 证据

`GetStorageIDs` 的响应数据包：

```
RAW IN (20B): 14 00 00 00 02 00 04 10 02 00 00 00 | 01 00 00 00 | 01 00 01 00
                                                  ^^^^^^^^^^^   ^^^^^^^^^^^
                                                  count = 1     唯一 storage = 0x00010001
```

按 PTP 规范，数据阶段是 `NumberOfStorageIDs (UINT32)` + `StorageIDs[]`。这里 count = 1、
只有 1 个 storage，但应用打印的是 **`StorageIDs count: 2`**。

随后遍历发出的命令（参数依次是 storageID、objectFormat、parent）：

```
txid 0x07: storage=0x00000001  parent=1  → 0x2008 InvalidStorageId
txid 0x08: storage=0x00010001  parent=1  → 0x2009 InvalidObjectHandle
```

`storage = 1` 与 `parent = 1` 都不存在，正是那个被当成数据的 count（=1）。
`GetObjectHandles` 同理：文件夹列表的 count = 1 被当成一个"目录句柄"递归进去；
照片列表的 count = 1288 被当成一个"照片句柄"去 `getObjectInfo`。

### 根因

`entry/src/main/cpp/ptp_engine.cpp:402-410`：

```cpp
std::vector<uint32_t> PTPEngine::parseU32Array(const uint8_t* data, size_t len) {
    std::vector<uint32_t> out;
    if (len < 4) return out;
    size_t count = len / 4;              // ← 把整段按 4 字节切开
    for (size_t i = 0; i < count; i++) {
        out.push_back(reinterpret_cast<const uint32_t*>(data)[i]);  // ← 首元素是 count，也被收进来
    }
    return out;
}
```

`entry/src/main/cpp/napi_init.cpp:259-266`（`ParseStorageIDs`）与 `:268-275`
（`ParseObjectHandles`）都直接调用它，返回值因此都**多带一个长度值**——缺了"跳过 count
并按 count 截断"这一步。

### 影响

1. 每次扫描多出 **16 次无效 USB 往返**（10×`0x2008` + 6×`0x2009`），约 0.5 秒；
2. 每次扫描多递归遍历一个不存在的 storage，日志被错误码污染；
3. UI 计数短暂错误（1289 → 1288），用户会怀疑"少了一张"；
4. **潜在正确性风险**：若某台相机的 `0x00000001` 恰好是合法 storage，
   或 count 值与某个真实 handle 相同，会出现重复照片或错拿对象。
   这次 Nikon 恰好是"不存在的 ID"，所以只报错，没有错数据。

### 建议方向（未实施）

给 `parseU32Array` 加 `skipCount` 语义（或新增 `parseCountedU32Array`）：
跳过首 4 字节、读其中的 count，再按 `min(count, (len-4)/4)` 截断；
`GetStorageIDs` 与 `GetObjectHandles` 都走这个版本。其它解析路径不受影响。
改完需真机复核：`StorageIDs count: 1`、`ObjectHandles total: 1288`、`0x2008/0x2009` 归零。

---

## ISSUE-011 应用语言"跟随系统"（中文）下，画廊日期显示英文

### 现象

设置 → 外观 → 语言为「跟随系统」，界面文案是中文；但画廊的日期分组标题显示
**`Sep 20`**（英文月份缩写），不是「9月20日」。

### 证据

`uitest dumpLayout` 拿到的文本节点（同一屏）：

```
"画廊" "相机" "设置"    ← 资源文案是中文
"Sep 20"                ← 日期是英文
```

设置持久化文件里 `"appLanguage":"system"`，确认是跟随系统。

**为什么能确定系统区域是中文**：工程里有 `entry/src/main/resources/en/element/string.json`，
如果系统区域是英文，资源会匹配到 `en/`，整个界面都会变英文。界面是中文 → 系统区域是中文。
所以这不是"系统语言没设对"，是**日期格式化没有跟随应用语言**。

### 根因

`entry/src/main/ets/utils/DateTimeText.ets` 里 4 个函数都把 locale 传成 `undefined`：

```ts
const formatter = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' });
//                                  ^^^^^^^^^ 依赖运行时默认区域
```

官方《多语言适配》对这类接口有明确要求：

> 为了确保接口返回值与用户设置保持一致，通常需要在 @ohos.i18n 和 @ohos.intl
> 接口中传入系统区域 ID 或系统区域对象。

也就是说**默认区域不保证跟随用户设置**，必须显式传入。本项目 4 处调用全都依赖默认值，
在这台设备上默认区域没有解析成中文。

### 影响面

所有走 `DateTimeText.ets` 的日期，不只是画廊：

| 位置 | 函数 | 表现 |
|---|---|---|
| 画廊 / 定位记录的分组标题 | `formatDayKey` → `formatDateParts` | `Sep 20` |
| 缓存管理页的时间列 | `formatIsoDate` | `09/20/2026` |
| 预览器的拍摄时间 | `formatCaptureTime` | `Sep 20, 2026, 14:03:22` |

### 建议方向（未实施）

加一个统一的"当前生效区域"取值，四个函数都用它：

```ts
import { i18n } from '@kit.LocalizationKit';
import { LanguageStore } from '../model/LanguageStore';

export function effectiveLocale(): string {
  const lang = LanguageStore.getInstance().appLanguage;
  if (lang !== 'system') return lang;                        // zh-Hans / zh-Hant / en
  return i18n.System.getSystemLocaleInstance().toString();   // 例如 zh-Hans-CN
}
```

```ts
new Intl.DateTimeFormat(effectiveLocale(), { month: 'short', day: 'numeric' })
```

注意两点：

1. **不能只传系统区域**。应用支持应用内切换语言，用户在设置页选「English」时，
   资源会变英文，日期也必须跟着变英文——所以要先看 `LanguageStore.appLanguage`，
   只有「跟随系统」时才回落到 `i18n.System.getSystemLocaleInstance()`。
2. **formatter 不要跨语言长期缓存**（或按 locale 做 key），否则切换语言后日期不刷新。
   切换语言本来就会重启进程，所以简单起见每次现建也可以接受。

验收标准：语言=跟随系统时显示「9月20日」；切成 English 后显示「Sep 20」；切回后恢复中文。
`i18n.System.getSystemLocaleInstance()` 在 API 26 可用（返回 `Intl.Locale`，
`@ohos.i18n.d.ts:264`）。

---

## ISSUE-012 NEF 缩略图带黑色侧边，同张 JPG 正常

### 现象

「文件优先」+ 筛选「全部」时，同一张照片的 NEF 与 JPG 并排：**NEF 单元格左右各有一条黑边，
JPG 没有**。行内格子视觉宽度不一致，排版看起来是歪的。

### 证据（应用内截屏 + 像素测量）

截屏为 5 列网格，屏幕宽 1280px，单元格约 252px。对内容带做按列均值扫描，找出黑色竖条：

```
(252, 270, 19)   ← NEF | JPG 之间
(495, 513, 19)   ← NEF | JPG 之间
(766, 770, 5)    ← JPG | JPG 之间（只有 2vp 间距）
(1023, 1041, 19) ← NEF | JPG 之间
```

19px = 2vp 间距（5px）+ 单侧黑边（≈14.7px）。**NEF 每格左右各有约 15px 黑边，JPG 没有。**

### 根因（完整链路）

1. Nikon 的内嵌缩略图是 **120×160 的 4:3 画布**，实际画面是 3:2 的 **106×160**，居中，
   左右各 7px 黑边——这是相机写进去的，不是解码产生的。
2. **JPG**：`parseExifDims` 从 APP1 拿到 5568×3712，`ImageDecoder` 按原始比例算出
   `crop=106x160`，把两侧黑边裁掉。
3. **NEF**：TIFF 容器。`parseExifDims` 在 IFD0 里找不到 `0x0100/0x0101`（尺寸在 SubIFD/ExifIFD）；
   ExifIFD 指针 `0x8769` 指向**偏移 35368**，而只读了 16384 字节：
   `CameraService.ets:360` 的 `exifIfdOff + 2 <= bytes.length` 不成立 → 直接返回 null。
4. `exifOrigDims` 没有该 handle → `origW/origH = 0` → `ImageDecoder.ets:85-89` 走
   `no orig dims, skip crop` → 120×160 原样返回 → 两侧黑边保留到屏幕上。

日志对照（同一批照片）：

```
NEF: [CROP] start orient=(270,false,false) orig=0x0
     [CROP] no orig dims, skip crop thumb=120x160
JPG: [CROP] start orient=(270,false,false) orig=5568x3712
     [CROP] thumb=120x160 scale=0.0287 crop=106x160
```

### 关键发现：尺寸数据其实早就有

`metadata_cache.json` 里 644 条 NEF，`imagePixWidth/Height` **全部是 5568×3712**，
没有一条为 0 —— PTP 的 `ObjectInfo` 已经把原始尺寸给了，只是解码时没用上。

### 修复方案

**方案 A（推荐）**：`exifOrigDims` 缺失时用 PTP 尺寸兜底。

```ts
const dim = this.exifOrigDims.get(h);
const origW = dim?.w ?? photo.imagePixWidth;
const origH = dim?.h ?? photo.imagePixHeight;
```

`loadSingleThumbnail` 里本来就有 `photo`，改动极小；把兜底值同时写进 `exifOrigDims`，
这样 `saveRawThumbnail` 也能记下 `origWidth/origHeight`。

**方案 B**：解析 TIFF 的 SubIFD（`0x014A`）或把 EXIF 头读到 64KB。
每张照片多一次 USB 往返（~30ms），收益不如 A，暂不考虑。

### 修复时必须注意：旧缓存会掩盖效果

现在缓存里的 NEF 缩略图已经是「未裁剪」版本，且 manifest 标了 `corrected: true`。
只改解码逻辑不清缓存，`findCached` 会继续命中旧图，**看起来像没修好**。

两种处理：

- bump `ThumbnailCache.MANIFEST_VERSION`（2 → 3）：manifest 版本不匹配时整库重建，
  代价是 1288 张缩略图重下一次（冷扫描约 4 分钟）；
- 或者先手动去「缓存管理」清一次缓存再验证，代码里不动版本号。

### 待验证

- 预览器全屏看 NEF 是否也有黑边：`decodeFullPhotoTask` 明确「不裁剪」
  （`ImageDecoder.ets:123`），如果相机给的全尺寸预览也带 padding，那里同样会露黑边。

### 顺带记录

`CameraService.ets:375` 的告警文案是 `no ExifIFD pointer (tag 0x8769) in IFD0`，
但它在「指针存在、只是越界」时也会打出来（这次就是），排障时会被误导。

---

## ISSUE-013 预览原图：NEF 单张 2.9 秒，瓶颈在 USB 吞吐（≈5.7 MB/s）

### 测试条件

真机 VYG-AL00 + Nikon Z50_2，无线调试；在预览器里逐张打开原图。
「文件优先」阶段 41 次，切换后「内容优先」阶段 44 次，共 85 次，零错误。

### 实测

| 模式 | 文件 | 次数 | 平均体积 | 平均传输 | 吞吐 | 解码中位 |
|---|---|---|---|---|---|---|
| 文件优先 | NEF | 20 | 14.6 MB | **2.55 s** | 5.6 MB/s | **315 ms** |
| 文件优先 | JPG | 21 | 6.0 MB | 1.18 s | 5.7 MB/s | 267 ms |
| 内容优先 | JPG | 44 | 7.3 MB | 1.22 s | 6.2 MB/s | 252 ms |

内容优先阶段 44 次全是 5.4–8.4 MB 的 JPG，**没有一次 14 MB 的 NEF**，
和 `displayPhoto` 的格式优先级（JPG 99 > NEF 30）一致。

### 拆解

- **传输吞吐两种格式一样**（5.6–6.2 MB/s），所以 NEF 慢完全是体积大 2.4 倍。
- 单张体感 ≈ 传输 + 解码：**NEF ≈ 2.87 s，JPG ≈ 1.45 s**。
- 解码全部是 `2048x3072 scale=0.552`；NEF 中位 315 ms，JPG 中位 267 ms。
- 44 次打开对应 50 次解码 —— 每开一张会顺带预加载下一张，两个解码任务在同一个
  taskpool 队列里排队，可能把首帧往后推。

### 瓶颈判断

1. **USB 吞吐 ≈5.7 MB/s 是主矛盾**。USB 2.0 的 PTP 远不止这个数；
   项目里记录过「单次 `bulkTransfer` 小于 200 KB」，小分块 + 每包往返开销是首要嫌疑。
2. **解码 250–330 ms 偏高**。`decodeFullPhotoTask` 已经用了 `desiredSize` 降采样，
   但因为要 270° 旋转设了 `editable: true`（`ImageDecoder.ets:154`），
   可能让它走软件可编辑路径而不是硬解。**这是假设，未验证。**
3. 内容优先模式天然规避了 NEF，是有效的产品级规避手段。

### 建议方向（未实施）

- 真机上试更大的 USB 读分块（这是唯一能直接抬吞吐的做法，必须真机验证）；
- 首帧可以先放「放大缩略图」，原图到位再替换——改善体感，不改吞吐；
- 若确认 `editable` 是解码变慢的原因，可改成「解码不旋转，交给 `Image` 做旋转」，
  但会影响现有的裁剪与方向记录逻辑，改动面较大；
- 预加载与首帧的优先级可以再排：当前首帧和预加载抢同一个 taskpool 队列。

### 待验证

- 本轮**没有产生任何 `ViewerPerf: pinch` 日志**，捏合缩放的手感与掉帧还没有数据。

---

## ISSUE-014 预览器手势与加载的三个体验问题

用户真机实测反馈（2026-11-09）。三条都定位到了具体代码位置，**尚未修改**。

### 14-A 左右滑动切换图片，偶发卡顿

**可能原因（加载被丢弃，不是渲染慢）**

`PhotoViewer.ets:1233`：

```ts
if (this.fullResMap.has(handle) || this.loadingHandle >= 0) return;   // ← 有加载在跑就直接丢
```

`loadFullRes` 在 `loadingHandle >= 0` 时**直接返回，不排队、不重试**；
而 `finally`（`1266-1277`）只恢复预加载队列，**不会回头检查"当前这张还需要不要加载"**。

叠加 `PtpHost.ets:260-269` 的 USB 互斥：`getObject` 等 `usbBusy` 释放，
**每 200ms 轮询一次，最多等 30 秒**，且**旧请求不可取消**——
一张 14 MB 的 NEF 要跑 2.5 秒，这期间切到的新图只能等。

结果是：滑动过程中触发的加载请求被丢掉，当前图停在大号缩略图上，
看起来就是"卡了一下才出来"。

**待验证**：加一条日志区分「本次请求被丢弃」和「真正加载耗时」，确认丢弃率。

### 14-B 连续快速切换图片，偶发卡顿

与 14-A 同源，且更严重：

- `scheduleFullResLoad()` 有 100ms 防抖（`1207-1210`），连续快切时定时器被反复取消；
- 一旦上一张已经开始下载，新的请求到点时正好撞上 `loadingHandle >= 0` 被丢弃（`1233`）；
- 旧下载**不会因为用户已经滑走而中止**，新图必须等在它后面；
- 快速切图期间 `onMainChange` 还会跳过 `scheduleFullResLoad`（`1125`，惯性态），
  动画结束后再补（`1104`），补的那次同样可能被 `loadingHandle` 挡掉。

**改进方向（未实施）**：给加载引入"目标句柄"概念——`loadingHandle` 与当前句柄不一致时，
要么取消旧下载，要么在旧下载结束时补一次当前图的加载。

### 14-C 快速滑动底部缩略图条进入自然滑行时，不跟手

用户的判断是对的，确实是**识别判定写得不对**，有三处：

**1）惯性标志在手指还没抬起时就被置位**

```ts
// 2036-2043：并行 PanGesture，手指移动过程中就改状态
.onActionUpdate((e: GestureEvent) => {
  const vx = e.velocityX || 0;
  if (Math.abs(vx) >= INERTIA_THRESHOLD && !this._inertiaAnim) {
    this._inertiaAnim = true;          // ← 拖动中途
  }
})
```

而 `onThumbGestureSwipe` 的第一行是（`1134`）：

```ts
if (this._fromMain || this._inertiaAnim) return;   // ← 一旦置位，主图立刻停止跟随
```

**所以拖动速度一超过阈值，主图就不再跟手了**，而手指还在屏幕上——这就是"不跟手"的直接来源。

**2）抬手后不是让 Swiper 自然减速，而是自己算一个跳数再 `changeIndex`**

```ts
// 2050-2061
const jump = Math.max(1, Math.round(Math.abs(vx) / INERTIA_FACTOR));
const target = clamp(this.mainIdx + step);
this.thumbCtrl.changeIndex(target, true);
this.mainCtrl.changeIndex(target, true);   // ← 中断并替换用户原本的手势
```

等于把用户的惯性手势**丢弃**，换成一次新的动画。

**3）判定阈值与时长都是硬编码，且量级可疑**

```ts
const SNAP_DURATION = 150;
const INERTIA_THRESHOLD = 3000;      // 速度阈值，单位未在代码里说明
const INERTIA_FACTOR = 150;          // 每 150 速度跳 1 格
const INERTIA_DURATION = 5000;       // 惯性动画 5 秒
```

`_inertiaAnim` 同时还会切换 Swiper 的 `curve`/`duration`（`2024-2025`）：
正常是 `Linear / 150ms`，惯性态是 `Friction / **5000ms**`。
一次快速甩动可能算出几十格的 `jump`，再配 5 秒动画，观感就是"飘"。

**改进方向（未实施）**：

- `_inertiaAnim` 只在 `onActionEnd` 判定，拖动过程中不要改；
- 或者干脆不要自定义惯性，交给 Swiper 自己的 fling，只做「滚动时暂停加载」；
- 若保留自定义惯性，`jump` 应基于位移而不是瞬时速度，时长应收到 600–800ms 量级。

### 补充：卡片式缩略图条本身的逐帧开销

每次手势回调都会跑：

- `updateScales()`（`1003-1030`）：遍历可见窗口写 `scaleArr` / `offsetArr`；
- `thumbCtrl.fakeDragBy()`（`1072`/`1087`）：每帧驱动另一条 Swiper。

两条 Swiper 通过 fakeDrag 联动，JS 主线程每帧要做两次几何计算 + 一次跨组件驱动。
真机上是否掉帧需要 Profiler 采样才能定性，这里只记为嫌疑。

---

## ISSUE-015 预览器：捏合偶发卡顿、放大后拖动飞快

用户真机实测（2026-11-09）。这两条表现完全不同，归因也不同。

### 15-A 双指捏合偶发卡顿

**实测（16 次捏合，`ViewerPerf: pinch` 摘要）**

| 指标 | 观测值 |
|---|---|
| `updates` | 16–49 |
| `fps` | 22–46，典型 **43–46** |
| `lateFrames` | 占帧数的 **80–90%**（几乎每帧都迟） |
| `gapMax` | 典型 22–23 ms，一次 **100 ms**，一次 33 ms |
| `workMax` | **1 ms** |

**结论：不是 JS 算不过来。** 每帧变换计算最长 1 ms，但帧间隔普遍 22 ms（约 45fps），
说明瓶颈在渲染/合成层，而不是手势逻辑。

**与后台任务重合**：捏合期间日志里仍在持续下载 + 解码——

```
01:05:02.841  USB下载: 7.1MB 0.9s
01:05:03.080  full decode done 2048x3072 in 227ms
01:05:04.045  ViewerPerf: pinch ... gapMax=100ms      ← 这次 100ms 卡顿
01:05:04.177  USB下载: 7.9MB 0.8s
01:05:04.327  full decode done 3072x2048 in 133ms
```

用户只是在捏合，但预加载队列每隔 1–2 秒就在读 7 MB、解一张 6MP。
**高度怀疑是后台下载/解码与捏合渲染抢内存带宽和 GPU**。

**建议方向（未实施）**：捏合/拖动期间暂停预加载队列（现有代码只在惯性滑行时暂停，
见 `PhotoViewer.ets:1189-1193`），手势结束后再恢复。

### 15-B 放大后拖动，速度随倍率成倍放大

**现象**：放大越大越离谱，"手指动一点点，照片从最下飞到最上"。

**根因**：`PhotoViewer.ets:425`：

```ts
this.applyTransform(1, effectiveOffX * this.zoom.scale, effectiveOffY * this.zoom.scale);
```

注释的解释是"`.scale()` 缩小了组件本地坐标系，offsetX 报的是小值，所以要乘回来"。但这个假设不成立。

**反证（同一份 zoom 状态内部的矛盾）**：捏合路径里 `zoom.x` 是**屏幕空间**的值——

```ts
// 337-345
const newW = this.imgW * ns;
const pointX = (this.compW - newW) / 2 + newW * this.zoomCenterX;
this.zoom.x = e.pinchCenterX - pointX;      // pinchCenterX 是屏幕坐标
```

`clampAndCheckEdge()` 的边界也是屏幕空间（`mx = (imgW * scale - compW) / 2`），
而捏合本身是正确的、用户没反馈缩放位置漂移。**既然同一个 `zoom.x` 由屏幕空间公式驱动是正常的，
拖动时就不该再乘一次 `scale`**。

乘上去的结果就是：**放 5 倍，手指划 100vp，照片走 500vp**；倍数越大越离谱，与用户描述完全一致。

**建议方向（未实施）**：去掉 `* this.zoom.scale`，直接用屏幕空间位移；
改完必须真机验证「1 倍率下拖动 1:1 跟手，5 倍率下也仍是 1:1」。

**顺带**：`onPanUpdate` 里还有一段「捏合期间累积 offset、结束后扣掉」的补偿逻辑
（`409-421`），在当前坐标口径被修正后需要重新审视，否则可能出现"捏合结束松手时图跳一下"。

### 待验证

- 捏合 45fps 是否为 `Image` + `.scale()` 的合成开销；需要一次「暂停预加载后捏合」的对照实验，
  若 fps 回到接近 60，则 15-A 的结论成立。
- 拖动速度修正后，边缘回弹与 `clampAndCheckEdge` 的手感是否仍然正确。

---

## ISSUE-016 预览器返回画廊的一镜到底转场偶发轻微掉帧

### 现象

从预览器返回画廊时，共享元素转场**效果正确**（起止位置、缩放都对），但有时能感觉到轻微卡顿/掉帧。

### 实测

```
01:06:36.957  pop: handle=689508559 pm=true rect=0.0,163.7 365.7x548.6 -> 293.7,379.4
01:06:36.974  pop: 收回目标 293.7,379.4 71.9x71.9
01:06:37.320  transition ended, isSuccess=true
```

- pop 全程 **363 ms**，push 全程 **405 ms**（`PUSH_MS = 380`），时长正常、`isSuccess=true`；
- **这次 pop 的窗口内没有任何并行的下载、解码或行重建**（相邻日志为空），
  所以这一例**不能**用 ISSUE-015 的资源竞争解释。

### 根因假设（代码层）

共享照片层在动画期间**逐帧修改 `Image` 的布局尺寸**：

`CustomTransition/PhotoMorph.ets:143-152`：

```ts
Image(this.pixelMap)
  .objectFit(ImageFit.Cover)
  .width(this.state.width)      // ← 每帧变化
  .height(this.state.height)    // ← 每帧变化
  .position({ x: this.state.left, y: this.state.top })
```

`width` / `height` 是**布局属性**，逐帧改变会触发重新布局 + 按新尺寸重新栅格化；
转场里挂的是一张 **2048×3072（约 6MP）** 的原图，每帧重绘的代价很高。

如果改成「布局尺寸固定，动画只改 `.scale()` / `.translate()`」，整个转场就能落在合成层上，
理论上应当稳定满帧。`position` 本身也是布局属性，但比尺寸变化的代价低，可以一并评估。

### 待验证

- 转场期间**没有任何帧级埋点**。要量化"掉帧"到底掉多少，需要像捏合那样加一个
  `displaySync` 采样（`PinchPerf` 已有现成实现，`PhotoViewer.ets:37-95`），
  在转场起止各打一条 `fps / lateFrames / gapMax`。
- 改 `.scale()` 方案后需要真机确认：起止矩形是否仍与缩略图/全屏图完全对齐
  （`Contain` 与 `Cover` 的换算不同，容易在矩形边缘出错）。

---

## 待验证假设

1. ~~`0x200F` 的真实成因~~ —— **已闭环**：相机开机、插卡、停在拍摄界面后，同一操作返回
   `StorageIDs count: 2`、`ObjectHandles total: 1289`、1288 张全部导入；
   说明 `0x200F` 是「相机未就绪」而非应用读不动，应用侧缺的只是把这句话说给用户。
2. 相机型号换成别的品牌时，`0x200F` 的语义是否一致（不同厂商对"无卡"的返回码不统一）。
3. `camera_scan_stats` 与空态文案是否也需要区分"失败"与"确实为 0 张"。
4. 修掉 ISSUE-010 的 count 解析后，需要复核：`StorageIDs count` 变 1、`ObjectHandles total`
   变 1288、`0x2008/0x2009` 消失、UI 不再闪 1289。
5. ~~缩略图缓存是否在冷启动后仍能全量命中~~ —— **已闭环**：杀进程重启后，
   `缓存快照: 1288 张照片, 1288 个缩略图`，耗时 0.97 s（热进程是 0.83 s），
   磁盘缓存完整还原，缩略图阶段 0 次 USB 请求。**缓存本身没有丢失问题。**

---

## 待开发需求

### REQ-001 多选模式支持滑动多选（按住拖拽框选）

**来源**：用户真机试用反馈（2026-11-09）。
**状态**：未开始，等本轮排查结束后与其它改动一起动手。
**交换条件**：用户明确接受**取消三个 tab 之间的左右滑动切换**。

#### 需求

多选态下按住并滑动，划过的缩略图连续进入/退出选中，行为对齐系统图库：

- 起手那一格决定整笔的方向：起手格已选 → 这一笔全是取消；未选 → 这一笔全是选中
- 划过的格子与起手格保持同态，同一笔内不反复翻转
- 支持斜向滑动、跨行
- 已下载的照片不可选，划过时跳过

#### 现状（代码位置）

| 项 | 位置 | 说明 |
|---|---|---|
| 网格容器 | `GalleryPage.ets:617` | `List` + `Repeat<FlatItem>().virtualScroll()` |
| flat item 三类 | 同上 | `header` 日期标题 / `row` 一行缩略图 / `tail` 底部占位 |
| 单元格 | `GalleryPage.ets:455` `PhotoCell` | 只有 `LongPressGesture(500ms)` + `TapGesture`，**没有 PanGesture** |
| 选中集 | `GalleryPage.selectedHandles: Set<number>` | 改完 `new Set(...)` 触发刷新，再 `syncSelectionStats()` |
| Tabs | `MainScreen.ets:501` | **当前没有设置 `.scrollable`**，默认允许左右滑动 |
| 列表手势 | `GalleryPage.ets:704` | 已有 `PinchGesture({ fingers: 2 })` 挂在 List 外层 Column |

#### 技术难点（动手前要解决）

1. **跨格手势拿不到事件**。手指从 A 格滑到 B 格时，touch 目标仍是 A，B 收不到 Move。
   所以拖拽必须挂在**容器层**（List 或其父 Column）的 PanGesture 上，
   再用坐标反查"手指当前压在哪个 handle 上"。
2. **坐标 → handle 的映射**，三条路线待评估：
   - `ListScroller.getItemRect(index)`：最干净，按 `onScrollIndex` 的可见区间取矩形。
     **本机 SDK 的 `.d.ts` 里刚才没 grep 到，需要再确认**（可能在别的声明文件，
     或该版本只在 `Scroller` 上提供）。
   - 几何推算：header 实测高度 + 行高 `(listWidth - gap*(n-1))/n` 累加。
     依赖字号缩放，脆弱，只能当兜底。
   - 每格 `onAreaChange` 记矩形：滚动时会不会触发存疑，需要实测。
3. **自动滚动**：手指贴住上下边缘时继续滚。可用 `scroller.scrollBy` + 定时器，
   注意与捏合手势、虚拟滚动回收的配合。
4. **与捏合共存**：List 外层原有双指 `PinchGesture`，新增单指 PanGesture 后要确认
   捏合仍生效（可能需要 `GestureGroup(Parallel)` 或 `fingers: 1`）。
5. **关掉 Tab 滑动的影响**：`.scrollable(false)` 后要实测悬浮页签
   （`barFloatingStyle` 的材质与圆角）是否仍正常。AGENTS.md 里记着
   "不要设 `scrollable`，会破坏悬浮样式默认布局"——这条经验要重新验证：
   是设 `scrollable(true)` 才破坏，还是任何设置都破坏。
   点击页签仍走 `onSelected`，视觉索引逻辑不受影响。

#### 验收标准

- 多选态按住滑动，划过的格子连续选中/取消，不闪烁、不跳
- 起手格已选 → 整笔取消；未选 → 整笔选中
- 已下载照片划过不选中
- 普通态左右滑动不再切 tab；点底部页签正常切换
- 悬浮页签材质、圆角、位置无变化
- 双指捏合缩放仍可用

---

## 附录 A：关键原始证据

### A.1 应用日志 `app_log.txt`（连接与首次失败）

```
[11:54:06 PM] === 开始扫描 ===
[11:54:06 PM] USB设备总数: 0
[11:54:06 PM] Found 0 camera(s)
[11:54:11 PM] === 开始扫描 ===
[11:54:11 PM] USB设备总数: 1
[11:54:11 PM] Device: name=2-2 vid=0x4b0 pid=0x455 manu=NIKON product=NIKON DSC Z50_2
[11:54:11 PM] Found 1 camera(s)
[11:54:11 PM] Requesting permission for 2-2
[11:54:14 PM] Connected to 2-2
[11:54:14 PM] PTP session opened
[11:54:14 PM] PTP DeviceInfo: manu="Nikon Corporation" model="Z50_2" serial="...08079350" ver="V1.04"
[11:54:14 PM] 相机身份: Nikon_Corporation_Z50_2_00000000000000000000000008079350
[11:54:14 PM] 新相机 Z50_2，先缓存后询问
[11:54:14 PM] Response error: 0x200f
[11:54:16 PM] 用户已启用缓存: Z50_2
[11:54:20 PM] === 开始扫描 ===
[11:54:20 PM] 缓存已启用: Z50_2
[11:54:20 PM] [快速扫描] 部署缓存快照...
[11:54:20 PM] [快速扫描] 缓存快照就绪: 0 张
[11:54:20 PM] Response error: 0x200f
```

注意：**没有** `照片 0 张 | 扫描完成`、**没有** `loadPhotos error`、**没有** `scan error`。
失败走的是"正常返回空列表"，不是异常路径，所以连 `camera_status_scan_error` 都不会触发。

### A.2 UI 树文本（`uitest dumpLayout`，非截图）

```
已连接 / 快速扫描 / 全量扫描 / 画廊 / 相机 / 设置
Z50_2 / Nikon Corporation / Nikon_Corporation_Z50_2_... / V1.04 / VID_04b0_PID_0455
照片数量 0 / 连接方式 USB PTP
```

### A.3 取证命令

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
T=10.15.98.124:37341

# 实时日志（只看应用 tag，避免被系统相机日志淹没）
$HDC -t $T shell "hilog -T AppLog,CameraService,PtpHost,ImageDecoder,ThumbnailCache,PhotoViewer,EntryAbility"

# 应用内落盘日志（文本）
$HDC -t $T file recv \
  /data/app/el2/100/base/io.github.shaoyuanyu.strollandshoot/haps/entry/files/app_log.txt \
  /tmp/app_log.txt

# UI 文本树（不含图像）
$HDC -t $T shell "uitest dumpLayout -p /data/local/tmp/layout.json"
$HDC -t $T shell "cat /data/local/tmp/layout.json"
```

## 附录 B：本轮顺带发现的取证障碍

应用日志缓冲默认只有 **512 KB**，被系统相机守护进程（CameraDaemon 的人脸/美颜日志）
刷满——导出的 6021 行里属于本应用的 **0 行**，等于没有取证能力。

已把 app 类型缓冲调到 16 MB（持久化配置，重启仍生效）：

```bash
$HDC -t $T shell "hilog -G 16M -t app"    # Set log type app buffer size to 16.0M successfully
$HDC -t $T shell "hilog -g"               # 校验：Log type app buffer size is 16.0M
```

需要还原成 512 KB：

```bash
$HDC -t $T shell "hilog -G 512K -t app"
```

这属于设备侧诊断配置，不是应用代码改动。

### B.1 突发日志会丢，别拿逐条日志当计数依据

第二次扫描部署缓存快照时，`AppLog` 在 0.83 秒内写了约 1288 条 `[CACHE_HIT]`。实际观测到：

| 来源 | 条数 | 原因 |
|---|---|---|
| 应用日志文件 `app_log.txt` | 417 | `AppLog` 的 `pendingLines` 上限 `MAX_ENTRIES = 500`，突发时只留最后 500 行 |
| hilog 无线抓取 | 196 | 突发速度超过 hdc over Wi-Fi 的流式吞吐，中间被丢 |

所以**判断"做了多少件事"要以阶段标记为准**（`缓存快照: 1288 张照片, 1288 个缩略图` 这种汇总行），
不要用逐条 `[CACHE_HIT]` 的条数去推断——本轮就一度误以为缓存只命中了 196 张。

要精确计数，可以先把 `MAX_ENTRIES` 调大或改成按需关闭逐条日志，但这属于代码改动，本轮未做。
