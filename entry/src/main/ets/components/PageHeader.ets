import { WindowUtils } from '../utils/WindowUtils';
import { ControlHeight, FontSize, IconSize, pillRadius } from '../utils/UiTokens';

/**
 * 二级页头部：返回键 + 主标题 + 副标题。
 *
 * 窗口是全屏布局（内容延伸到状态栏下方），所以这里自己避让状态栏。
 * 一级页的标题栏走 `NavDestination.title({ builder })`，二级页只需要一个轻量头部。
 */
@ComponentV2
export struct PageHeader {
  @Param title: string = '';
  @Param subtitle: string = '';
  /** 右侧文字操作（如「选择」/「取消」）；空串表示不显示。 */
  @Param actionText: string = '';
  @Event onBack: () => void = () => {};
  @Event onAction: () => void = () => {};

  /** 状态栏高度（vp）。 */
  private statusBarVp(): number {
    const px = WindowUtils.topAvoidAreaHeightPx;
    return px > 0 ? px2vp(px) : 0;
  }

  build() {
    Row({ space: 8 }) {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(IconSize.Nav)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(ControlHeight.Pill)
      .height(ControlHeight.Pill)
      .backgroundColor(Color.Transparent)
      .borderRadius(pillRadius(ControlHeight.Pill))
      .onClick(() => { this.onBack(); })

      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(FontSize.PageTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(FontSize.Caption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.actionText.length > 0) {
        Button(this.actionText)
          .fontSize(FontSize.Body)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary'))
          .height(ControlHeight.Pill)
          .padding({ left: 12, right: 12 })
          .backgroundColor(Color.Transparent)
          .onClick(() => { this.onAction(); })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: 8,
      right: 16,
      top: this.statusBarVp() + 4,
      bottom: 8
    })
  }
}
