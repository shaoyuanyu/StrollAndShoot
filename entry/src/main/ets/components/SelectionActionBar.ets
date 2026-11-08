import { ControlHeight, FontSize, IconSize } from '../utils/UiTokens';

/**
 * 多选底部操作栏。
 *
 * 形态对齐官方图库的多选页：悬浮胶囊里放「图标在上、文字在下」的操作项。
 * 胶囊的尺寸与纵向位置必须和底部页签完全一致（高 56vp、底边贴着导航手势条
 * 避让区），否则切换多选态时下沿会跳一下，非常割裂 —— 宿主 MainScreen 负责定位。
 *
 * 背景与磨砂由宿主提供：它被放在 `MainScreen.TitleBar` 的浮岛层里，用 position
 * 画到屏幕底部 —— 真·沉浸光感只在 Navigation/NavDestination 标题栏内生效，而
 * 弹层（popup / dialog）虽然能拿到材质，却会铺一层遮罩把整页点击吞掉，所以只能
 * 借标题栏这个"壳"把浮岛画到别处。组件自身不设背景色，否则会盖住材质。
 */
@ComponentV2
export struct SelectionActionBar {
  @Param selectedCount: number = 0;
  @Event onDownload: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      // 图标与文字尺寸照抄底部页签的 TabItem（24fp / 10fp），两套控件才像一家人
      SymbolGlyph($r('sys.symbol.arrow_down_and_rectangle'))
        .fontSize(IconSize.Large)
        .fontColor([this.selectedCount > 0
          ? $r('app.color.text_primary') : $r('app.color.text_tertiary')])
      Text('下载')
        .fontSize(FontSize.Micro)
        .fontWeight(this.selectedCount > 0 ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selectedCount > 0
          ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
    }
    .width(96)
    .height(ControlHeight.Bar)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (this.selectedCount > 0) {
        this.onDownload();
      }
    })
    // 背景与磨砂完全不画：宿主（MainScreen.TitleBar 的浮岛层）会设置
    // systemMaterial，材质会接管 backgroundColor / border / shadow。
    // 自己再铺一层半透明底会把材质整个盖住。
  }
}
