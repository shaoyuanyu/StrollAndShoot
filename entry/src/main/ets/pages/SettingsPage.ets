import { ConfigurationConstant, bundleManager } from '@kit.AbilityKit';
import { SettingsStore } from '../model/SettingsStore';
import { CameraService } from '../services/CameraService';
import { MockPtpDevice } from '../debug/MockPtpDevice';
import { BusinessError } from '@kit.BasicServicesKit';

const COLUMN_OPTIONS: number[] = [-1, 3, 4, 5, 6];

function formatColumn(n: number): string {
  if (n <= 0) return '自动';
  return `${n}列`;
}

@ComponentV2
export struct SettingsPage {
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

  build() {
    Scroll() {
      Column() {
        Text('通用设置')
          .fontSize(13).fontColor($r('app.color.text_secondary'))
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start).margin({ top: 12, bottom: 8 })

        Column() {
          Text('深色模式').fontSize(14).fontColor($r('app.color.text_primary'))
            .alignSelf(ItemAlign.Start).margin({ bottom: 10 })

          Row({ space: 8 }) {
            this.ModeButton('跟随系统', ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET)
            this.ModeButton('浅色', ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT)
            this.ModeButton('深色', ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
          }
          .width('100%')
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.bg_surface')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ bottom: 16 })

        Text('画廊')
          .fontSize(13).fontColor($r('app.color.text_secondary'))
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start).margin({ bottom: 8 })

        Column() {
          Text('默认列数').fontSize(14).fontColor($r('app.color.text_primary'))
            .alignSelf(ItemAlign.Start).margin({ bottom: 10 })

          Row({ space: 8 }) {
            Repeat<number>(COLUMN_OPTIONS)
              .each((ri: RepeatItem<number>) => {
                Text(formatColumn(ri.item))
                  .fontSize(13)
                  .fontColor(this.settings.galleryColumnCount === ri.item ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor(this.settings.galleryColumnCount === ri.item ? $r('app.color.primary') : $r('app.color.bg_page'))
                  .borderRadius(14)
                  .onClick(() => { this.settings.galleryColumnCount = ri.item; })
              })
              .key((n: number) => n.toString())
          }
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.bg_surface')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ bottom: 16 })

        Column() {
          Text('显示模式').fontSize(14).fontColor($r('app.color.text_primary'))
            .alignSelf(ItemAlign.Start).margin({ bottom: 10 })

          Row({ space: 8 }) {
            this.DisplayModeChip('内容优先', 'content_first')
            this.DisplayModeChip('文件优先', 'file_first')
          }
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.bg_surface')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ bottom: 16 })

        Text('GPS定位记录')
          .fontSize(13).fontColor($r('app.color.text_secondary'))
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start).margin({ bottom: 8 })

        Column() {
          Row() {
            Text('定位记录').fontSize(14).fontColor($r('app.color.text_primary'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.gpsRunning })
              .onChange((on: boolean) => { this.onGpsToggle(); })
          }
          .width('100%')

          Divider().margin({ top: 10, bottom: 10 })

          Text('定位模式')
            .fontSize(13).fontColor($r('app.color.text_secondary'))
            .alignSelf(ItemAlign.Start).margin({ bottom: 8 })

          Row() {
            this.GpsModeChip('精确', 0)
            this.GpsModeChip('日常', 1)
            this.GpsModeChip('省电', 2)
          }
          .width('100%').padding(3)
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(18)
          Row() {
            Text(`已记录 ${this.gpsRecordCount} 个位置点`)
              .fontSize(12).fontColor($r('app.color.text_secondary'))
            Blank()
            Button('管理')
              .fontSize(11).height(28)
              .onClick(() => { this.gotoManage(); })
              .margin({ right: 6 })
            Button('清除')
              .fontSize(11).height(28)
              .onClick(() => { this.onGpsClear(); })
          }
          .width('100%').margin({ top: 10 })
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.bg_surface')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ bottom: 16 })

        Text('关于')
          .fontSize(13).fontColor($r('app.color.text_secondary'))
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start).margin({ bottom: 8 })

        Row() {
          Text('版本').fontSize(14).fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.versionName).fontSize(14).fontColor($r('app.color.text_secondary'))
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.bg_surface')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ bottom: 16 })

        Text('缓存')
          .fontSize(13).fontColor($r('app.color.text_secondary'))
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start).margin({ bottom: 8 })

        Row() {
          Text('缩略图缓存').fontSize(14).fontColor($r('app.color.text_primary'))
          Blank()
          Text('管理 >').fontSize(13).fontColor($r('app.color.text_secondary'))
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.bg_surface')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ bottom: 16 })
        .onClick(() => {
          this.onOpenCacheManagement();
        })

        if (this.debugBuild) {
          Text('调试（仅调试包可见）')
            .fontSize(13).fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Medium)
            .alignSelf(ItemAlign.Start).margin({ bottom: 8 })

          Row() {
            Column() {
              Text('模拟相机设备')
                .fontSize(14).fontColor($r('app.color.text_primary'))
                .alignSelf(ItemAlign.Start)
              Text(this.svc.photoCount > 0
                ? `已连接虚拟相机，共 ${this.svc.photoCount} 张`
                : '开启后到「相机」页点「搜索相机」，即可连上一台虚拟相机并扫描 38 张合成照片')
                .fontSize(11).fontColor($r('app.color.text_secondary'))
                .alignSelf(ItemAlign.Start).margin({ top: 3 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.settings.mockCameraEnabled })
              .onChange((isOn: boolean) => { this.onToggleMockCamera(isOn); })
          }
          .width('100%').padding(14)
          .backgroundColor($r('app.color.bg_surface')).borderRadius(12)
          .border({ width: 1, color: $r('app.color.divider') })
          .margin({ bottom: 16 })
        }

        Text('调试日志')
          .fontSize(13).fontColor($r('app.color.text_secondary'))
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start).margin({ bottom: 8 })

        Column() {
          Row() {
            Text(`${this.logText ? this.logText.split('\n').length : 0} 条`)
              .fontSize(11).fontColor($r('app.color.text_secondary'))
            Blank()
            Button('清除')
              .onClick(() => { this.onClear(); })
              .fontSize(11).height(28).margin({ right: 6 })
            Button('复制')
              .onClick(() => { this.onCopy(); })
              .fontSize(11).height(28)
          }
          .width('100%').margin({ bottom: 6 })

          Scroll() {
            Text(this.logText)
              .fontSize(11).fontFamily('monospace')
              .fontColor($r('app.color.log_text'))
              .width('100%').padding(8)
          }
          .width('100%').height(300)
          .backgroundColor($r('app.color.bg_debug_log')).borderRadius(8)
        }
      }
      .width('100%').padding({ left: 12, right: 12, bottom: 20 })
    }
    .width('100%').height('100%')
  }

  @Builder
  GpsModeChip(label: string, mode: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.gpsMode === mode ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
      .textAlign(TextAlign.Center)
      .padding({ top: 7, bottom: 7 })
      .backgroundColor(this.gpsMode === mode ? $r('app.color.primary') : 'transparent')
      .borderRadius(16)
      .layoutWeight(1)
      .onClick(() => { this.onGpsModeChange(mode); })
  }

  @Builder
  DisplayModeChip(label: string, mode: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.settings.displayMode === mode ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.settings.displayMode === mode ? $r('app.color.primary') : $r('app.color.bg_page'))
      .borderRadius(16)
      .onClick(() => { this.settings.displayMode = mode; })
  }

  @Builder
  ModeButton(label: string, mode: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.settings.darkMode === mode ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.settings.darkMode === mode ? $r('app.color.primary') : $r('app.color.bg_page'))
      .borderRadius(16)
      .onClick(() => {
        this.settings.darkMode = mode;
      })
  }
}
