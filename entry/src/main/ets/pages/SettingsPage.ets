import { ConfigurationConstant, bundleManager } from '@kit.AbilityKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { SettingsStore } from '../model/SettingsStore';
import { CameraService } from '../services/CameraService';
import { GpsRecorder } from '../services/GpsRecorder';
import { MockPtpDevice } from '../debug/MockPtpDevice';
import { BusinessError } from '@kit.BasicServicesKit';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';
import { ControlHeight, FontSize, IconSize, Radius, RowHeight, pillRadius } from '../utils/UiTokens';

/** 深色模式下拉的取值顺序，与 DARK_OPTIONS 一一对应。 */
const DARK_VALUES: number[] = [
  ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET,
  ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT,
  ConfigurationConstant.ColorMode.COLOR_MODE_DARK
];
const DARK_OPTIONS: SelectOption[] = [
  { value: '跟随系统' },
  { value: '浅色' },
  { value: '深色' }
];

const COLUMN_VALUES: number[] = [-1, 3, 4, 5, 6];
const COLUMN_OPTIONS: SelectOption[] = [
  { value: '自动' },
  { value: '3 列' },
  { value: '4 列' },
  { value: '5 列' },
  { value: '6 列' }
];

const DISPLAY_VALUES: string[] = ['content_first', 'file_first'];
const DISPLAY_OPTIONS: SelectOption[] = [
  { value: '内容优先' },
  { value: '文件优先' }
];

const GPS_MODE_OPTIONS: SelectOption[] = [
  { value: '精确' },
  { value: '出行' },
  { value: '日常' },
  { value: '省电' }
];

/**
 * 下拉框顺序映射到 GpsRecorder 的内部模式码。
 * 内部码保持 0=精确 / 1=日常 / 2=省电，新增 3=出行，避免旧配置文件迁移。
 */
const GPS_MODE_UI_TO_CODE: number[] = [0, 3, 1, 2];

@ComponentV2
export struct SettingsPage {
  @Param scroller: Scroller = new Scroller();
  @Param logText: string = '';
  @Event onClear: () => void = () => {};
  @Event onCopy: () => void = () => {};
  @Event onOpenGpsManagement: () => void = () => {};
  @Event onOpenCacheManagement: () => void = () => {};
  settings: SettingsStore = SettingsStore.getInstance();
  /** GPS 服务的真实状态。直接读单例的 @Trace 字段，不再要页面之间传副本。 */
  @Local gps: GpsRecorder = GpsRecorder.getInstance();
  /** 开关的显示值。用 !! 双向绑定，启动失败时才能把滑块弹回去。 */
  @Local gpsOn: boolean = false;
  @Local versionName: string = '';
  @Local debugBuild: boolean = false;
  /** 调试包的模拟 GPS 轨迹开关；真实轨迹记录不受影响。 */
  @Local mockGpsOn: boolean = false;
  @Local mockGpsBusy: boolean = false;
  @Local svc: CameraService = CameraService.getInstance();

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionName = info.versionName;
    } catch (err) {
      this.versionName = `${(err as BusinessError).message}`;
    }
    this.debugBuild = MockPtpDevice.isDebugBuild();
    this.gpsOn = this.gps.running;
    this.mockGpsOn = this.gps.hasMockTrack();
  }

  /** 服务侧状态变化（自动恢复、启动失败回滚）时跟上开关显示。 */
  @Monitor('gps.running')
  onGpsRunningChanged(monitor: IMonitor): void {
    const now = monitor.value('gps.running')?.now as boolean;
    this.gpsOn = now === true;
  }

  /** 模拟轨迹在 GPS 页被删除/清除后，回到设置页时同步开关状态。 */
  @Monitor('gps.recordsVersion')
  onGpsRecordsChanged(): void {
    if (!this.mockGpsBusy) {
      this.mockGpsOn = this.gps.hasMockTrack();
    }
  }

  /** 开关的意图交给服务执行；服务拒绝（如位置服务未开）时弹提示并回弹滑块。 */
  private async onToggleGps(on: boolean): Promise<void> {
    // 不要在这里提前 return：启动过程中 running 还是 false，用户拨回开关时
    // 必须让 GpsRecorder.toggle(false) 等启动落定后再停，否则开关会弹回去。
    const ok = await this.gps.toggle(on);
    this.gpsOn = this.gps.running;
    if (!ok) {
      this.toast(this.gps.lastError === '' ? '定位启动失败' : this.gps.lastError);
    }
  }

  /** UI 顺序（精确/出行/日常/省电）→ 内部模式码；找不到时落回省电。 */
  private gpsModeUiIndex(): number {
    const index = GPS_MODE_UI_TO_CODE.indexOf(this.gps.gpsMode);
    return index >= 0 ? index : 3;
  }

  private async onChangeGpsMode(mode: number): Promise<void> {
    const ok = await this.gps.setGpsMode(mode);
    if (!ok && this.gps.lastError !== '') {
      this.toast(this.gps.lastError);
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 3000 });
    } catch (_e) {
      // ignore
    }
  }

  /** 开关下面那行说明：还要区分「已启动但还没拿到定位」。 */
  private gpsStatusText(): string {
    if (!this.gps.running) return '关闭时不会记录位置';
    if (this.gps.lastFix === null) return '正在等待定位…';
    return '正在记录位置';
  }

  private async onToggleMockGps(on: boolean): Promise<void> {
    if (this.mockGpsBusy) return;
    if (!on) {
      this.gps.clearMockTrack();
      this.mockGpsOn = false;
      this.toast('模拟轨迹已清除');
      return;
    }

    this.mockGpsBusy = true;
    const ok = await this.gps.createMockTrack();
    this.mockGpsBusy = false;
    this.mockGpsOn = this.gps.hasMockTrack();
    if (!ok) {
      this.mockGpsOn = false;
      this.toast(this.gps.lastError === '' ? '模拟轨迹生成失败' : this.gps.lastError);
    } else {
      this.toast(`已注入相机图案轨迹（${this.gps.mockCount()} 条模拟定位记录）`);
    }
  }

  private mockGpsStatusText(): string {
    if (this.mockGpsBusy) return '正在获取当前位置…';
    if (this.gps.hasMockTrack()) {
      return `模拟中 · ${this.gps.mockCount()} 条模拟定位记录（仅今日显示，不改真实记录）`;
    }
    return '以当前位置为起点注入一个相机图案，仅影响今日显示，不改真实记录';
  }

  onToggleMockCamera(enabled: boolean): void {
    // 只切换"虚拟相机是否存在"，不直接灌数据：用户仍需在相机页点「搜索相机」，
    // 之后走的是与真机完全相同的连接与扫描流程。
    this.settings.mockCameraEnabled = enabled;
    this.svc.onMockCameraToggled();
  }

  gotoManage(): void {
    this.onOpenGpsManagement();
  }

  /** 当前深色模式在 DARK_VALUES 里的下标。 */
  private darkIndex(): number {
    const i = DARK_VALUES.indexOf(this.settings.darkMode);
    return i < 0 ? 0 : i;
  }

  private columnIndex(): number {
    const i = COLUMN_VALUES.indexOf(this.settings.galleryColumnCount);
    return i < 0 ? 0 : i;
  }

  private displayIndex(): number {
    return this.settings.displayMode === 'content_first' ? 0 : 1;
  }

  @Builder
  GroupTitle(title: string) {
    Text(title)
      .fontSize(FontSize.Section)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 4, top: 6 })
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 10 }) {

        // ---- 外观 ----
        this.GroupTitle('外观')
        Column() {
          // 选项类控件用 Select：它属于官方「选择类」沉浸光感组件，
          // 内容区也能拿到真材质（自制的分段按钮拿不到）。
          SettingSelectRow({
            label: '深色模式',
            options: DARK_OPTIONS,
            selectedIndex: this.darkIndex(),
            last: true,
            onSelect: (index: number) => {
              const v = DARK_VALUES[index];
              if (v !== undefined) {
                this.settings.darkMode = v;
              }
            }
          })
        }
        .width('100%').padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(Radius.Card)

        // ---- 画廊 ----
        this.GroupTitle('画廊')
        Column() {
          SettingSelectRow({
            label: '默认列数',
            options: COLUMN_OPTIONS,
            selectedIndex: this.columnIndex(),
            onSelect: (index: number) => {
              const v = COLUMN_VALUES[index];
              if (v !== undefined) {
                this.settings.galleryColumnCount = v;
              }
            }
          })
          SettingSelectRow({
            label: '显示模式',
            options: DISPLAY_OPTIONS,
            selectedIndex: this.displayIndex(),
            last: true,
            onSelect: (index: number) => {
              const v = DISPLAY_VALUES[index];
              if (v !== undefined) {
                this.settings.displayMode = v;
              }
            }
          })
        }
        .width('100%').padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(Radius.Card)

        // ---- 定位 ----
        this.GroupTitle('定位记录')
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text('定位记录')
                .fontSize(FontSize.CardTitle)
                .fontColor($r('app.color.text_primary'))
                .alignSelf(ItemAlign.Start)
              Text(this.gpsStatusText())
                .fontSize(FontSize.Caption)
                .fontColor($r('app.color.text_tertiary'))
                .alignSelf(ItemAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 不设 selectedColor：应用级沉浸光感开启后，Toggle 的开关样式
            // 由系统预设材质接管，自己添颜色会把手感改回去。
            // isOn 用 !! 双向绑定：用户拨动后状态变真，服务拒绝启动时才能把
            // 滑块弹回去（单向绑定下组件会停在拨动后的位置，和真实状态对不上）。
            Toggle({ type: ToggleType.Switch, isOn: this.gpsOn!! })
              .onChange((on: boolean) => { this.onToggleGps(on); })
          }
          .width('100%').height(RowHeight.Double)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          SettingSelectRow({
            label: '记录频率',
            options: GPS_MODE_OPTIONS,
            selectedIndex: this.gpsModeUiIndex(),
            onSelect: (index: number) => {
              const code = GPS_MODE_UI_TO_CODE[index];
              if (code !== undefined) this.onChangeGpsMode(code);
            }
          })

          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text('定位记录管理')
                .fontSize(FontSize.CardTitle)
                .fontColor($r('app.color.text_primary'))
                .alignSelf(ItemAlign.Start)
              Text(`已记录 ${this.gps.displayRecordCount()} 条定位记录` +
                (this.gps.trimmedRecords > 0
                  ? ` · 已按保留策略清理 ${this.gps.trimmedRecords} 条旧记录`
                  : ''))
                .fontSize(FontSize.Caption)
                .fontColor($r('app.color.text_tertiary'))
                .alignSelf(ItemAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(IconSize.Body)
              .fontColor([$r('app.color.text_tertiary')])
          }
          .width('100%').height(RowHeight.Double)
          .onClick(() => { this.gotoManage(); })
        }
        .width('100%').padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(Radius.Card)

        // ---- 存储 ----
        this.GroupTitle('存储')
        Row({ space: 8 }) {
          Text('缩略图缓存')
            .fontSize(FontSize.CardTitle)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(IconSize.Body)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width('100%').height(RowHeight.Single).padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(Radius.Card)
        .onClick(() => { this.onOpenCacheManagement(); })

        // ---- 关于 ----
        this.GroupTitle('关于')
        Row() {
          Text('版本')
            .fontSize(FontSize.CardTitle)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.versionName)
            .fontSize(FontSize.Body)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%').height(RowHeight.Single).padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(Radius.Card)

        // ---- 调试 ----
        if (this.debugBuild) {
          this.GroupTitle('调试')
          Column({ space: 12 }) {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text('模拟 GPS 轨迹')
                  .fontSize(FontSize.CardTitle)
                  .fontColor($r('app.color.text_primary'))
                  .alignSelf(ItemAlign.Start)
                Text(this.mockGpsStatusText())
                  .fontSize(FontSize.Caption)
                  .fontColor($r('app.color.text_tertiary'))
                  .alignSelf(ItemAlign.Start)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.mockGpsOn })
                .enabled(!this.mockGpsBusy)
                .onChange((isOn: boolean) => { this.onToggleMockGps(isOn); })
            }
            .width('100%')

            Divider().color($r('app.color.divider'))

            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text('模拟相机设备')
                  .fontSize(FontSize.CardTitle)
                  .fontColor($r('app.color.text_primary'))
                  .alignSelf(ItemAlign.Start)
                Text(this.svc.photoCount > 0
                  ? `已连接虚拟相机，共 ${this.svc.photoCount} 张`
                  : '开启后到「相机」页点右上角的「搜索相机」，会连上一台虚拟 PTP 相机并扫描 38 张合成照片')
                  .fontSize(FontSize.Caption)
                  .fontColor($r('app.color.text_tertiary'))
                  .alignSelf(ItemAlign.Start)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.settings.mockCameraEnabled })
                .onChange((isOn: boolean) => { this.onToggleMockCamera(isOn); })
            }
            .width('100%')

            Divider().color($r('app.color.divider'))

            Row({ space: 8 }) {
              Text(`${this.logText ? this.logText.split('\n').length : 0} 条日志`)
                .fontSize(FontSize.Caption)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Button('清除')
                .height(30)
                .fontSize(FontSize.Caption)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.filter_chip_bg'))
                .onClick(() => { this.onClear(); })
              Button('复制')
                .height(30)
                .fontSize(FontSize.Caption)
                .fontColor($r('app.color.primary'))
                .backgroundColor($r('app.color.primary_soft'))
                .onClick(() => { this.onCopy(); })
            }
            .width('100%')

            Scroll() {
              Text(this.logText)
                .fontSize(FontSize.Caption)
                .fontFamily('monospace')
                .fontColor($r('app.color.log_text'))
                .width('100%')
                .padding(10)
            }
            .width('100%')
            .height(240)
            .backgroundColor($r('app.color.bg_debug_log'))
            .borderRadius(Radius.Chip)
            .align(Alignment.Top)
          }
          .width('100%').padding(16)
          .backgroundColor($r('app.color.bg_surface'))
          .borderRadius(Radius.Card)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 96 })
    }
    .width('100%').height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    // 标题栏浮在内容之上，首屏内容按其高度内缩；滚动时从标题栏下方穿过
    .contentStartOffset(titleBarTotalVp())
  }
}

/**
 * 设置行：左侧标题 + 右侧 Select 玻璃胶囊。
 *
 * 必须是独立组件：@Builder 的形参不会刷新，把 selectedIndex 传给 @Builder 后
 * 选项变了界面不会跟着变。Select 属于官方「选择类」沉浸光感组件，内容区也能
 * 拿到真材质。
 */
@ComponentV2
struct SettingSelectRow {
  @Param label: string = '';
  @Param options: SelectOption[] = [];
  @Param selectedIndex: number = 0;
  @Param last: boolean = false;
  @Event onSelect: (index: number) => void = (_i: number) => {};

  /** Select 的按钮文字由 value() 决定，selected() 只负责菜单里的选中态。 */
  private selectedLabel(): string {
    const i = this.selectedIndex;
    if (i < 0 || i >= this.options.length) return '';
    const v = this.options[i].value;
    return typeof v === 'string' ? v : '';
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(FontSize.CardTitle)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Select(this.options)
        .selected(this.selectedIndex)
        .value(this.selectedLabel())
        .font({ size: FontSize.Body, weight: FontWeight.Medium })
        .fontColor($r('app.color.text_secondary'))
        .selectedOptionFont({ size: FontSize.Body, weight: FontWeight.Medium })
        .selectedOptionFontColor($r('app.color.primary'))
        .optionFont({ size: FontSize.Body })
        .optionFontColor($r('app.color.text_primary'))
        .height(ControlHeight.Pill)
        .borderRadius(pillRadius(ControlHeight.Pill))
        .backgroundColor(Color.Transparent)
        .arrowModifier(new SymbolGlyphModifier($r('sys.symbol.chevron_down'))
          .fontColor([$r('app.color.text_secondary')]))
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true
        }))
        .onSelect((index: number) => { this.onSelect(index); })
    }
    .width('100%')
    .height(RowHeight.Single)
    .border({ width: { bottom: this.last ? 0 : 0.5 }, color: $r('app.color.divider') })
  }
}
