import { ConfigurationConstant, bundleManager } from '@kit.AbilityKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { SettingsStore } from '../model/SettingsStore';
import { CameraService } from '../services/CameraService';
import { MockPtpDevice } from '../debug/MockPtpDevice';
import { BusinessError } from '@kit.BasicServicesKit';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';

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
  { value: '日常' },
  { value: '省电' }
];

@ComponentV2
export struct SettingsPage {
  @Param scroller: Scroller = new Scroller();
  @Param logText: string = '';
  @Param gpsRunning: boolean = false;
  @Param gpsRecordCount: number = 0;
  @Param gpsMode: number = 2;
  @Event onClear: () => void = () => {};
  @Event onCopy: () => void = () => {};
  @Event onGpsToggle: () => void = () => {};
  @Event onGpsModeChange: (mode: number) => void = (_m: number) => {};
  @Event onGpsClear: () => void = () => {};
  @Event onOpenGpsManagement: () => void = () => {};
  @Event onOpenCacheManagement: () => void = () => {};
  settings: SettingsStore = SettingsStore.getInstance();
  @Local versionName: string = '';
  @Local debugBuild: boolean = false;
  @Local svc: CameraService = CameraService.getInstance();

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionName = info.versionName;
    } catch (err) {
      this.versionName = `${(err as BusinessError).message}`;
    }
    this.debugBuild = MockPtpDevice.isDebugBuild();
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
      .fontSize(13)
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
        .borderRadius(24)

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
        .borderRadius(24)

        // ---- 定位 ----
        this.GroupTitle('定位记录')
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text('定位记录')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
                .alignSelf(ItemAlign.Start)
              Text(this.gpsRunning ? '正在记录位置' : '关闭时不会记录位置')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .alignSelf(ItemAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 不设 selectedColor：应用级沉浸光感开启后，Toggle 的开关样式
            // 由系统预设材质接管，自己添颜色会把手感改回去。
            Toggle({ type: ToggleType.Switch, isOn: this.gpsRunning })
              .onChange((_on: boolean) => { this.onGpsToggle(); })
          }
          .width('100%').height(64)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

          SettingSelectRow({
            label: '记录频率',
            options: GPS_MODE_OPTIONS,
            selectedIndex: this.gpsMode,
            onSelect: (index: number) => { this.onGpsModeChange(index); }
          })

          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text('位置点管理')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
                .alignSelf(ItemAlign.Start)
              Text(`已记录 ${this.gpsRecordCount} 个位置点`)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .alignSelf(ItemAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor([$r('app.color.text_tertiary')])
          }
          .width('100%').height(60)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
          .onClick(() => { this.gotoManage(); })

          Row() {
            Text('清除定位记录')
              .fontSize(16)
              .fontColor($r('app.color.button_danger'))
          }
          .width('100%').height(56)
          .onClick(() => { this.onGpsClear(); })
        }
        .width('100%').padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(24)

        // ---- 存储 ----
        this.GroupTitle('存储')
        Row({ space: 8 }) {
          Text('缩略图缓存')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width('100%').height(56).padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(24)
        .onClick(() => { this.onOpenCacheManagement(); })

        // ---- 关于 ----
        this.GroupTitle('关于')
        Row() {
          Text('版本')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.versionName)
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%').height(56).padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(24)

        // ---- 调试 ----
        if (this.debugBuild) {
          this.GroupTitle('调试')
          Column({ space: 12 }) {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text('模拟相机设备')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .alignSelf(ItemAlign.Start)
                Text(this.svc.photoCount > 0
                  ? `已连接虚拟相机，共 ${this.svc.photoCount} 张`
                  : '开启后到「相机」页点右上角的「搜索相机」，会连上一台虚拟 PTP 相机并扫描 38 张合成照片')
                  .fontSize(11)
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
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Button('清除')
                .height(30)
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.filter_chip_bg'))
                .onClick(() => { this.onClear(); })
              Button('复制')
                .height(30)
                .fontSize(12)
                .fontColor($r('app.color.primary'))
                .backgroundColor($r('app.color.primary_soft'))
                .onClick(() => { this.onCopy(); })
            }
            .width('100%')

            Scroll() {
              Text(this.logText)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor($r('app.color.log_text'))
                .width('100%')
                .padding(10)
            }
            .width('100%')
            .height(240)
            .backgroundColor($r('app.color.bg_debug_log'))
            .borderRadius(12)
            .align(Alignment.Top)
          }
          .width('100%').padding(16)
          .backgroundColor($r('app.color.bg_surface'))
          .borderRadius(24)
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
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Select(this.options)
        .selected(this.selectedIndex)
        .value(this.selectedLabel())
        .font({ size: 15, weight: FontWeight.Medium })
        .fontColor($r('app.color.text_secondary'))
        .selectedOptionFont({ size: 15, weight: FontWeight.Medium })
        .selectedOptionFontColor($r('app.color.primary'))
        .optionFont({ size: 15 })
        .optionFontColor($r('app.color.text_primary'))
        .height(40)
        .borderRadius(20)
        .backgroundColor(Color.Transparent)
        .arrowModifier(new SymbolGlyphModifier($r('sys.symbol.chevron_down'))
          .fontColor([$r('app.color.text_secondary')]))
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true
        }))
        .accessibilityText(`${this.label}，当前${this.selectedLabel()}`)
        .onSelect((index: number) => { this.onSelect(index); })
    }
    .width('100%')
    .height(56)
    .border({ width: { bottom: this.last ? 0 : 0.5 }, color: $r('app.color.divider') })
  }
}
