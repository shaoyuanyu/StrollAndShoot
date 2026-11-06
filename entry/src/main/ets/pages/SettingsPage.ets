import { ConfigurationConstant, bundleManager } from '@kit.AbilityKit';
import { SettingsStore } from '../model/SettingsStore';
import { CameraService } from '../services/CameraService';
import { MockPtpDevice } from '../debug/MockPtpDevice';
import { BusinessError } from '@kit.BasicServicesKit';
import { titleBarTotalVp } from '../utils/TitleBarMetrics';

const COLUMN_OPTIONS: number[] = [-1, 3, 4, 5, 6];

function formatColumn(n: number): string {
  if (n <= 0) return '自动';
  return `${n} 列`;
}

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

  @Builder
  GroupTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 4, top: 4 })
  }

  build() {
    Scroll(this.scroller) {
      Column({ space: 10 }) {

        // ---- 外观 ----
        this.GroupTitle('外观')
        Column({ space: 12 }) {
          Text('深色模式')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Row() {
            Text('跟随系统')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.darkMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.darkMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.darkMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.darkMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET; })
            Text('浅色')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.darkMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.darkMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.darkMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.darkMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT; })
            Text('深色')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.darkMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.darkMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.darkMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.darkMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK; })
          }
          .width('100%').padding(3)
          .backgroundColor($r('app.color.filter_chip_bg'))
          .borderRadius(19)
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(16)
        .border({ width: 1, color: $r('app.color.card_border') })

        // ---- 画廊 ----
        this.GroupTitle('画廊')
        Column({ space: 12 }) {
          Text('默认列数')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Row() {
            Text('自动')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.galleryColumnCount === -1 ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.galleryColumnCount === -1
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.galleryColumnCount === -1
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.galleryColumnCount = -1; })
            Text('3 列')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.galleryColumnCount === 3 ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.galleryColumnCount === 3
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.galleryColumnCount === 3
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.galleryColumnCount = 3; })
            Text('4 列')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.galleryColumnCount === 4 ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.galleryColumnCount === 4
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.galleryColumnCount === 4
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.galleryColumnCount = 4; })
            Text('5 列')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.galleryColumnCount === 5 ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.galleryColumnCount === 5
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.galleryColumnCount === 5
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.galleryColumnCount = 5; })
            Text('6 列')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.galleryColumnCount === 6 ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.galleryColumnCount === 6
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.galleryColumnCount === 6
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.galleryColumnCount = 6; })
          }
          .width('100%').padding(3)
          .backgroundColor($r('app.color.filter_chip_bg'))
          .borderRadius(19)

          Divider().color($r('app.color.divider'))

          Text('显示模式')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Row() {
            Text('内容优先')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.displayMode === 'content_first' ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.displayMode === 'content_first'
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.displayMode === 'content_first'
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.displayMode = 'content_first'; })
            Text('文件优先')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.settings.displayMode === 'file_first' ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.settings.displayMode === 'file_first'
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.settings.displayMode === 'file_first'
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.settings.displayMode = 'file_first'; })
          }
          .width('100%').padding(3)
          .backgroundColor($r('app.color.filter_chip_bg'))
          .borderRadius(19)
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(16)
        .border({ width: 1, color: $r('app.color.card_border') })

        // ---- 定位 ----
        this.GroupTitle('定位记录')
        Column({ space: 14 }) {
          Row() {
            Column({ space: 2 }) {
              Text('定位记录')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .alignSelf(ItemAlign.Start)
              Text(this.gpsRunning ? '正在记录位置' : '关闭时不会记录位置')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .alignSelf(ItemAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.gpsRunning })
              .selectedColor($r('app.color.primary'))
              .onChange((_on: boolean) => { this.onGpsToggle(); })
          }
          .width('100%')

          Row() {
            Text('精确')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.gpsMode === 0 ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.gpsMode === 0
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.gpsMode === 0
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.onGpsModeChange(0); })
            Text('日常')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.gpsMode === 1 ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.gpsMode === 1
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.gpsMode === 1
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.onGpsModeChange(1); })
            Text('省电')
              .fontSize(13).textAlign(TextAlign.Center)
              .fontWeight(this.gpsMode === 2 ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.gpsMode === 2
                ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
              .height(36).borderRadius(16).layoutWeight(1)
              .backgroundColor(this.gpsMode === 2
                ? $r('app.color.primary') : Color.Transparent)
              .onClick(() => { this.onGpsModeChange(2); })
          }
          .width('100%').padding(3)
          .backgroundColor($r('app.color.filter_chip_bg'))
          .borderRadius(19)

          Row({ space: 8 }) {
            Text(`已记录 ${this.gpsRecordCount} 个位置点`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Button('管理')
              .height(32)
              .fontSize(13)
              .fontColor($r('app.color.primary'))
              .backgroundColor($r('app.color.primary_soft'))
              .onClick(() => { this.gotoManage(); })
            Button('清除')
              .height(32)
              .fontSize(13)
              .fontColor($r('app.color.button_danger'))
              .backgroundColor($r('app.color.primary_soft'))
              .onClick(() => { this.onGpsClear(); })
          }
          .width('100%')
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(16)
        .border({ width: 1, color: $r('app.color.card_border') })

        // ---- 存储 ----
        this.GroupTitle('存储')
        Row({ space: 8 }) {
          Text('缩略图缓存')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width('100%').height(56).padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(16)
        .border({ width: 1, color: $r('app.color.card_border') })
        .onClick(() => { this.onOpenCacheManagement(); })

        // ---- 关于 ----
        this.GroupTitle('关于')
        Row() {
          Text('版本')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.versionName)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%').height(56).padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.bg_surface'))
        .borderRadius(16)
        .border({ width: 1, color: $r('app.color.card_border') })

        // ---- 调试 ----
        if (this.debugBuild) {
          this.GroupTitle('调试')
          Column({ space: 12 }) {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text('模拟相机设备')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .alignSelf(ItemAlign.Start)
                Text(this.svc.photoCount > 0
                  ? `已连接虚拟相机，共 ${this.svc.photoCount} 张`
                  : '开启后到「相机」页点「搜索相机」，会连上一台虚拟 PTP 相机并扫描 38 张合成照片')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .alignSelf(ItemAlign.Start)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.settings.mockCameraEnabled })
                .selectedColor($r('app.color.primary'))
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
          .borderRadius(16)
          .border({ width: 1, color: $r('app.color.card_border') })
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
