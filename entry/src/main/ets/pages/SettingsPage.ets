import { ConfigurationConstant, bundleManager } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { SettingsStore } from '../model/SettingsStore';
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
  settings: SettingsStore = SettingsStore.getInstance();
  @Local versionName: string = '';

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionName = info.versionName;
    } catch (err) {
      this.versionName = `${(err as BusinessError).message}`;
    }
  }

  gotoManage(): void {
    router.pushUrl({ url: 'pages/GpsManagementPage' });
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
        .backgroundColor($r('app.color.bg_surface')).borderRadius(8)
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
        .backgroundColor($r('app.color.bg_surface')).borderRadius(8)
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
        .backgroundColor($r('app.color.bg_surface')).borderRadius(8)
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
        .backgroundColor($r('app.color.bg_surface')).borderRadius(8)
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
        .backgroundColor($r('app.color.bg_surface')).borderRadius(8)
        .margin({ bottom: 16 })

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
