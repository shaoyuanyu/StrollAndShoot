import { ConfigurationConstant } from '@kit.AbilityKit';

const DARK_MODE_KEY = 'dark_mode_pref';

@Component
export struct SettingsPage {
  @Prop logText: string = '';
  @StorageLink(DARK_MODE_KEY) darkMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  onClear: () => void = () => {};
  onCopy: () => void = () => {};
  onDarkModeChange: (mode: number) => void = (_m: number) => {};

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

        Text('关于')
          .fontSize(13).fontColor($r('app.color.text_secondary'))
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start).margin({ bottom: 8 })

        Row() {
          Text('版本').fontSize(14).fontColor($r('app.color.text_primary'))
          Blank()
          Text('1.0.0').fontSize(14).fontColor($r('app.color.text_secondary'))
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
  ModeButton(label: string, mode: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.darkMode === mode ? $r('app.color.text_on_primary') : $r('app.color.text_primary'))
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.darkMode === mode ? $r('app.color.primary') : $r('app.color.bg_page'))
      .borderRadius(16)
      .onClick(() => {
        this.darkMode = mode;
        this.onDarkModeChange(mode);
      })
  }
}
