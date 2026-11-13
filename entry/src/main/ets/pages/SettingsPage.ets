import { ConfigurationConstant, bundleManager, common, Want } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { SettingsStore } from '../model/SettingsStore';
import { LanguageStore } from '../model/LanguageStore';
import { StandeePreferenceStore } from '../model/StandeePreferenceStore';
import { CameraService } from '../services/CameraService';
import { GpsRecorder } from '../services/GpsRecorder';
import { MockPtpDevice } from '../debug/MockPtpDevice';
import { cameraStandeeKeys, cameraStandeeLabel } from '../utils/CameraStandee';
import { BusinessError } from '@kit.BasicServicesKit';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';
import { L10n } from '../utils/L10n';
import { CardShadow, ControlHeight, FontSize, IconSize, Radius, RowHeight, pillRadius } from '../utils/UiTokens';
import { GlassEffect } from '../utils/GlassEffect';

/** 深色模式下拉的取值顺序，与 DARK_OPTIONS 一一对应。 */
const DARK_VALUES: number[] = [
  ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET,
  ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT,
  ConfigurationConstant.ColorMode.COLOR_MODE_DARK
];
const DARK_OPTIONS: SelectOption[] = [
  { value: $r('app.string.settings_dark_follow') },
  { value: $r('app.string.settings_dark_light') },
  { value: $r('app.string.settings_dark_dark') }
];

const COLUMN_VALUES: number[] = [-1, 3, 4, 5, 6];
const COLUMN_OPTIONS: SelectOption[] = [
  { value: $r('app.string.settings_columns_auto') },
  { value: $r('app.string.settings_columns_n', 3) },
  { value: $r('app.string.settings_columns_n', 4) },
  { value: $r('app.string.settings_columns_n', 5) },
  { value: $r('app.string.settings_columns_n', 6) }
];

const DISPLAY_VALUES: string[] = ['content_first', 'file_first'];
const DISPLAY_OPTIONS: SelectOption[] = [
  { value: $r('app.string.settings_display_content_first') },
  { value: $r('app.string.settings_display_file_first') }
];

/** 语言下拉的取值顺序，与 LANGUAGE_OPTIONS 一一对应。 */
const LANGUAGE_VALUES: string[] = ['system', 'zh-Hans', 'zh-Hant', 'en'];
const LANGUAGE_OPTIONS: SelectOption[] = [
  { value: $r('app.string.settings_language_follow_system') },
  { value: $r('app.string.settings_language_zh_hans') },
  { value: $r('app.string.settings_language_zh_hant') },
  { value: $r('app.string.settings_language_en') }
];

/** 默认相机立牌：第一项「不显示」，其余按立牌表。 */
const STANDEE_VALUES: string[] = (() => {
  const values: string[] = [''];
  for (const key of cameraStandeeKeys()) {
    values.push(key);
  }
  return values;
})();

const STANDEE_OPTIONS: SelectOption[] = (() => {
  const options: SelectOption[] = [{ value: $r('app.string.settings_standee_none') }];
  for (const key of cameraStandeeKeys()) {
    options.push({ value: cameraStandeeLabel(key) });
  }
  return options;
})();

const GPS_MODE_OPTIONS: SelectOption[] = [
  { value: $r('app.string.settings_gps_precise') },
  { value: $r('app.string.settings_gps_travel') },
  { value: $r('app.string.settings_gps_daily') },
  { value: $r('app.string.settings_gps_power') }
];

/**
 * 下拉框顺序映射到 GpsRecorder 的内部模式码。
 * 内部码保持 0=精确 / 1=日常 / 2=省电，新增 3=出行，避免旧配置文件迁移。
 */
const GPS_MODE_UI_TO_CODE: number[] = [0, 3, 1, 2];

/**
 * 调试包「模拟型号」下拉的取值，与 `MOCK_MODEL_OPTIONS` 一一对应。
 *
 * 第一项是空串 = 认不出的机器（上报 `Virtual PTP Camera`）；其余直接取立牌表里的
 * 官方型号名（`cameraStandeeLabel`），所以每个选项都一定有立牌，选中后接上模拟
 * 相机就能看到那台机器的效果，也不会因为手写型号拼写不一致而落到「认不出」。
 */
const MOCK_MODEL_VALUES: string[] = (() => {
  const values: string[] = [''];
  for (const key of cameraStandeeKeys()) {
    values.push(cameraStandeeLabel(key));
  }
  return values;
})();

const MOCK_MODEL_OPTIONS: SelectOption[] = (() => {
  const options: SelectOption[] = [{ value: $r('app.string.settings_mock_model_unknown') }];
  for (const key of cameraStandeeKeys()) {
    options.push({ value: cameraStandeeLabel(key) });
  }
  return options;
})();

/** 日志条数：按行数选复数，与「清除 / 复制」按钮同一行。 */
function logCountText(logText: string): string {
  const count = logText ? logText.split('\n').length : 0;
  return L10n.tr('settings_log_count', L10n.plural('log_line_count', count, count));
}

@ComponentV2
export struct SettingsPage {
  @Param scroller: Scroller = new Scroller();
  @Param logText: string = '';
  @Event onClear: () => void = () => {};
  @Event onCopy: () => void = () => {};
  @Event onOpenGpsManagement: () => void = () => {};
  @Event onOpenCacheManagement: () => void = () => {};
  settings: SettingsStore = SettingsStore.getInstance();
  /** 应用语言偏好；单独 PersistenceV2 key，默认跟随系统。 */
  @Local languageStore: LanguageStore = LanguageStore.getInstance();
  /** 默认相机立牌；标题为「相机」时使用。 */
  @Local standeePref: StandeePreferenceStore = StandeePreferenceStore.getInstance();
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
      this.toast(this.gps.lastError === ''
        ? $r('app.string.settings_toast_gps_start_failed') : this.gps.lastError);
    }
  }

  private languageIndex(): number {
    const index = LANGUAGE_VALUES.indexOf(this.languageStore.appLanguage);
    return index < 0 ? 0 : index;
  }

  /**
   * 选择语言后先写偏好，再弹重启确认。取消（按钮或点遮罩）都要把偏好退回，
   * 否则 Select 的显示会和实际生效语言不一致。
   */
  private onLanguageSelect(index: number): void {
    const value = LANGUAGE_VALUES[index];
    if (value === undefined || value === this.languageStore.appLanguage) return;
    const previous = this.languageStore.appLanguage;
    this.languageStore.appLanguage = value;
    this.getUIContext().showAlertDialog({
      title: $r('app.string.settings_language_confirm_title'),
      message: $r('app.string.settings_language_confirm_message'),
      autoCancel: true,
      cancel: () => { this.languageStore.appLanguage = previous; },
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: () => { this.languageStore.appLanguage = previous; }
      },
      secondaryButton: {
        value: $r('app.string.settings_language_restart'),
        fontColor: $r('app.color.primary'),
        action: () => { this.applyLanguage(value, previous); }
      }
    });
  }

  private standeeIndex(): number {
    const index = STANDEE_VALUES.indexOf(this.standeePref.defaultKey);
    return index < 0 ? 0 : index;
  }

  private onStandeeSelect(index: number): void {
    const value = STANDEE_VALUES[index];
    if (value !== undefined) {
      this.standeePref.setDefaultKey(value);
    }
  }

  /** 设置应用偏好语言；'default' 清空偏好，恢复到跟随系统。 */
  private applyLanguage(value: string, previous: string): void {
    try {
      i18n.System.setAppPreferredLanguage(value === 'system' ? 'default' : value);
    } catch (_e) {
      this.languageStore.appLanguage = previous;
      this.toast($r('app.string.settings_language_failed'));
      return;
    }
    this.restartApp();
  }

  /**
   * 冷启动后资源才按新偏好重新加载（官方「应用偏好语言」约束），
   * 因此设置成功后重启进程。用当前 Ability 的 bundle/ability 信息构造 Want，
   * 不写死包名。
   */
  private restartApp(): void {
    const host = this.getUIContext().getHostContext();
    if (!host) {
      this.toast($r('app.string.settings_language_restart_failed'));
      return;
    }
    try {
      const ctx = host as common.UIAbilityContext;
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name,
        moduleName: ctx.abilityInfo.moduleName
      };
      ctx.getApplicationContext().restartApp(want);
    } catch (_e) {
      this.toast($r('app.string.settings_language_restart_failed'));
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

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 3000 });
    } catch (_e) {
      // ignore
    }
  }

  /** 开关下面那行说明：还要区分「已启动但还没拿到定位」。 */
  private gpsStatusText(): ResourceStr {
    if (!this.gps.running) return $r('app.string.settings_gps_off_desc');
    if (this.gps.lastFix === null) return $r('app.string.settings_gps_waiting');
    return $r('app.string.settings_gps_recording');
  }

  private async onToggleMockGps(on: boolean): Promise<void> {
    if (this.mockGpsBusy) return;
    if (!on) {
      this.gps.clearMockTrack();
      this.mockGpsOn = false;
      this.toast($r('app.string.settings_toast_mock_cleared'));
      return;
    }

    this.mockGpsBusy = true;
    const ok = await this.gps.createMockTrack();
    this.mockGpsBusy = false;
    this.mockGpsOn = this.gps.hasMockTrack();
    if (!ok) {
      this.mockGpsOn = false;
      this.toast(this.gps.lastError === ''
        ? $r('app.string.settings_toast_mock_failed') : this.gps.lastError);
    } else {
      const mockCount = this.gps.mockCount();
      this.toast($r('app.string.settings_toast_mock_injected',
        L10n.plural('mock_record_count', mockCount, mockCount)));
    }
  }

  private mockGpsStatusText(): ResourceStr {
    if (this.mockGpsBusy) return $r('app.string.settings_mock_gps_waiting');
    if (this.gps.hasMockTrack()) {
      const count = this.gps.mockCount();
      return $r('app.string.settings_mock_gps_active',
        L10n.plural('mock_record_count', count, count));
    }
    return $r('app.string.settings_mock_gps_desc');
  }

  onToggleMockCamera(enabled: boolean): void {
    // 只切换"虚拟相机是否存在"，不直接灌数据：用户仍需在相机页点「搜索相机」，
    // 之后走的是与真机完全相同的连接与扫描流程。
    this.settings.mockCameraEnabled = enabled;
    this.svc.onMockCameraToggled();
  }

  /** 模拟型号在 MOCK_MODEL_VALUES 里的下标；存的值不认识时回落到「未知型号」。 */
  private mockModelIndex(): number {
    const i = MOCK_MODEL_VALUES.indexOf(this.settings.mockCameraModel);
    return i < 0 ? 0 : i;
  }

  onMockModelSelect(index: number): void {
    const model = MOCK_MODEL_VALUES[index];
    if (model === undefined || model === this.settings.mockCameraModel) return;
    this.settings.mockCameraModel = model;
    // 型号是设备身份的一部分（缓存标识也是 厂商_型号_序列号）：断开当前虚拟相机，
    // 下次「搜索相机」才会按新型号重新握手、重新识别立牌。
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

  /** 已记录条数 + 保留策略清理条数；条数用复数资源，英文下不会出现 "1 records"。 */
  private gpsRecordText(): string {
    const count = this.gps.displayRecordCount();
    let text = L10n.tr('settings_gps_record_count',
      L10n.plural('record_count', count, count));
    if (this.gps.trimmedRecords > 0) {
      text += L10n.tr('settings_gps_trimmed',
        L10n.plural('record_count', this.gps.trimmedRecords, this.gps.trimmedRecords));
    }
    return text;
  }

  @Builder
  GroupTitle(title: ResourceStr) {
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
        this.GroupTitle($r('app.string.settings_section_appearance'))
        Column() {
          // 选项类控件用 Select：它属于官方「选择类」沉浸光感组件，
          // 内容区也能拿到真材质（自制的分段按钮拿不到）。
          SettingSelectRow({
            label: $r('app.string.settings_dark_mode'),
            options: DARK_OPTIONS,
            selectedIndex: this.darkIndex(),
            onSelect: (index: number) => {
              const v = DARK_VALUES[index];
              if (v !== undefined) {
                this.settings.darkMode = v;
              }
            }
          })
          SettingSelectRow({
            label: $r('app.string.settings_language'),
            options: LANGUAGE_OPTIONS,
            selectedIndex: this.languageIndex(),
            onSelect: (index: number) => { this.onLanguageSelect(index); }
          })
          SettingSelectRow({
            label: $r('app.string.settings_default_standee'),
            hint: $r('app.string.settings_default_standee_hint'),
            options: STANDEE_OPTIONS,
            selectedIndex: this.standeeIndex(),
            last: true,
            onSelect: (index: number) => { this.onStandeeSelect(index); }
          })
        }
        .width('100%').padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(Radius.Card)
        .shadow(CardShadow)

        // ---- 画廊 ----
        this.GroupTitle($r('app.string.settings_section_gallery'))
        Column() {
          SettingSelectRow({
            label: $r('app.string.settings_columns'),
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
            label: $r('app.string.settings_display_mode'),
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
        .shadow(CardShadow)

        // ---- 定位 ----
        this.GroupTitle($r('app.string.settings_section_location'))
        Column() {
          Row() {
            Column({ space: 2 }) {
              Text($r('app.string.settings_gps_records'))
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
            label: $r('app.string.settings_gps_frequency'),
            options: GPS_MODE_OPTIONS,
            selectedIndex: this.gpsModeUiIndex(),
            onSelect: (index: number) => {
              const code = GPS_MODE_UI_TO_CODE[index];
              if (code !== undefined) this.onChangeGpsMode(code);
            }
          })

          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text($r('app.string.settings_gps_manage'))
                .fontSize(FontSize.CardTitle)
                .fontColor($r('app.color.text_primary'))
                .alignSelf(ItemAlign.Start)
              Text(this.gpsRecordText())
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
        .shadow(CardShadow)

        // ---- 存储 ----
        this.GroupTitle($r('app.string.settings_section_storage'))
        Row({ space: 8 }) {
          Text($r('app.string.settings_cache'))
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
        .shadow(CardShadow)
        .onClick(() => { this.onOpenCacheManagement(); })

        // ---- 关于 ----
        this.GroupTitle($r('app.string.settings_section_about'))
        Row() {
          Text($r('app.string.settings_version'))
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
        .shadow(CardShadow)

        // ---- 调试 ----
        if (this.debugBuild) {
          this.GroupTitle($r('app.string.settings_section_debug'))
          Column({ space: 12 }) {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text($r('app.string.settings_mock_gps'))
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
                Text($r('app.string.settings_mock_camera'))
                  .fontSize(FontSize.CardTitle)
                  .fontColor($r('app.color.text_primary'))
                  .alignSelf(ItemAlign.Start)
                Text(this.svc.photoCount > 0
                  ? $r('app.string.settings_mock_camera_connected',
                    L10n.plural('photo_count', this.svc.photoCount, this.svc.photoCount))
                  : $r('app.string.settings_mock_camera_desc'))
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

            // 型号只在模拟相机打开时才有意义：它决定虚拟相机上报的机型，也就是
            // 标题里的型号、页首立牌用哪张图。关掉开关就整行收起。
            if (this.settings.mockCameraEnabled) {
              Divider().color($r('app.color.divider'))
              SettingSelectRow({
                label: $r('app.string.settings_mock_model'),
                hint: $r('app.string.settings_mock_model_hint'),
                options: MOCK_MODEL_OPTIONS,
                selectedIndex: this.mockModelIndex(),
                last: true,
                onSelect: (index: number) => { this.onMockModelSelect(index); }
              })
            }

            Divider().color($r('app.color.divider'))

            // 模拟器的 GPU 不支持磨砂玻璃着色器，材质叠加时会画出乱花的多边形；
            // 打开后所有 systemMaterial / blur 换成纯色，截图可用于布局与交互验收。
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text($r('app.string.settings_disable_glass'))
                  .fontSize(FontSize.CardTitle)
                  .fontColor($r('app.color.text_primary'))
                  .alignSelf(ItemAlign.Start)
                Text($r('app.string.settings_disable_glass_desc'))
                  .fontSize(FontSize.Caption)
                  .fontColor($r('app.color.text_tertiary'))
                  .alignSelf(ItemAlign.Start)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.settings.debugDisableGlass })
                .onChange((isOn: boolean) => { this.settings.debugDisableGlass = isOn; })
            }
            .width('100%')

            Divider().color($r('app.color.divider'))

            Row({ space: 8 }) {
              Text(logCountText(this.logText))
                .fontSize(FontSize.Caption)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Button($r('app.string.settings_clear'))
                .height(30)
                .fontSize(FontSize.Caption)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.filter_chip_bg'))
                .onClick(() => { this.onClear(); })
              Button($r('app.string.settings_copy'))
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
          .shadow(CardShadow)
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
  @Param label: ResourceStr = '';
  /** 标题下的一行说明；空串时不占位，行高仍是 56vp。 */
  @Param hint: ResourceStr = '';
  @Param options: SelectOption[] = [];
  @Param selectedIndex: number = 0;
  @Param last: boolean = false;
  @Event onSelect: (index: number) => void = (_i: number) => {};

  /** Select 的按钮文字由 value() 决定，selected() 只负责菜单里的选中态。 */
  private selectedLabel(): ResourceStr {
    const i = this.selectedIndex;
    if (i < 0 || i >= this.options.length) return '';
    return this.options[i].value;
  }

  build() {
    Row() {
      Column({ space: 2 }) {
        Text(this.label)
          .fontSize(FontSize.CardTitle)
          .fontColor($r('app.color.text_primary'))
          .alignSelf(ItemAlign.Start)
        if (this.hint !== '') {
          Text(this.hint)
            .fontSize(FontSize.Caption)
            .lineHeight(16)
            .fontColor($r('app.color.text_tertiary'))
            .alignSelf(ItemAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ right: 12 })
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
        .systemMaterial(GlassEffect.material(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true
        })))
        .onSelect((index: number) => { this.onSelect(index); })
    }
    .width('100%')
    // 用最小高度而不是固定高度：带 hint 的行会自己长高（双行 64vp 左右），
    // 不带的仍钉在 56vp，和单行设置项的节奏一致。
    .constraintSize({ minHeight: RowHeight.Single })
    .border({ width: { bottom: this.last ? 0 : 0.5 }, color: $r('app.color.divider') })
  }
}
