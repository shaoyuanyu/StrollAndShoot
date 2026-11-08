import type { DownloadProgress } from '../model/PhotoEntry';
import { FontSize, IconSize, pillRadius } from '../utils/UiTokens';

/**
 * 批量下载的进度浮岛。
 *
 * 竖条形态，贴屏幕左侧或右侧竖着放 —— 下载是临时浮动面板，不该和底部页签栏挤在
 * 一起（官方《智感握姿》把「悬浮操作按钮、浮动面板根据握持手左右切换」列为首要
 * 适用场景）。左右由 HandednessService 的握持手识别决定，识别不可用时固定右侧。
 *
 * 宽度只有 60vp，所以信息压成三层：环形进度（环心第几张/共几张）→ 状态词 → 取消。
 * 文件名不再展示：批量导入时「第几张」才是用户关心的，逐张文件名没有价值。
 *
 * 背景与磨砂由宿主提供：它被放在 `MainScreen.TitleBar` 的浮岛层里（真·沉浸光感
 * 只在 Navigation/NavDestination 标题栏内生效），用 position 画到屏幕中部。
 * 组件自身绝不能设 backgroundColor / backgroundBlurStyle，否则会盖住材质。
 */
@ComponentV2
export struct DownloadProgressBar {
  @Param progress: DownloadProgress = {
    phase: 'idle', currentIndex: 0, totalCount: 0,
    currentFilename: '', currentSizeBytes: 0,
    downloadedCount: 0, totalBytes: 0, downloadedBytes: 0,
    errors: []
  };
  @Event onCancel: () => void = () => {};

  private ringStyle: RingStyleOptions = {
    strokeWidth: 3.5,
    enableSmoothEffect: true
  };

  private percent(): number {
    if (this.progress.totalCount <= 0) return 0;
    const p = Math.round((this.progress.downloadedCount / this.progress.totalCount) * 100);
    return Math.max(0, Math.min(100, p));
  }

  private failed(): boolean {
    return this.progress.phase === 'error';
  }

  /**
   * 环心那一行：直接给「第几张/共几张」。
   * 百分比和它同时出现是冗余的 —— 弧长本身已经表达了比例，用户真正关心的是传到了第几张。
   */
  private countText(): string {
    if (this.progress.totalCount <= 0) return '--';
    return `${this.progress.downloadedCount}/${this.progress.totalCount}`;
  }

  /** 四位数以上时「1234/5678」在 44vp 的环里一行放不下，要改成两行。 */
  private countIsLong(): boolean {
    return this.progress.totalCount >= 1000;
  }

  /** 环下那一行：只说当前在干什么，四态等长，浮岛高度不会跳。 */
  private phaseText(): string {
    if (this.progress.phase === 'complete') return `${this.progress.totalCount} 张`;
    if (this.progress.phase === 'saving') return '保存中';
    if (this.progress.phase === 'error') return '失败';
    return '下载中';
  }

  private running(): boolean {
    return this.progress.phase === 'downloading' || this.progress.phase === 'saving';
  }

  build() {
    Column({ space: 8 }) {
      // 环在所有阶段都保留，只换环心内容：下载中是「第几张/共几张」，完成时换成勾。
      // 之前完成态是一整块 44vp 的绿色实心圆盘，形态突变、颜色也跳出了
      // 「品牌蓝 + 中性灰」的体系，显得很突兀。
      Stack() {
        Progress({ value: this.percent(), total: 100, type: ProgressType.Ring })
          .width(44)
          .height(44)
          .color(this.failed() ? $r('app.color.status_error') : $r('app.color.primary'))
          // 轨道用专门的 progress_track：分栏线（divider）在半透明胶囊上太淡，
          // 环会看成一段“断弧”
          .backgroundColor($r('app.color.progress_track'))
          .style(this.ringStyle)
        if (this.progress.phase === 'complete') {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(IconSize.Body)
            .fontColor([$r('app.color.primary')])
        } else if (this.countIsLong()) {
          // 上千张时「1234/5678」一行塞不进 44vp 的环，拆成两行：
          // 上行是已传张数（用户真正关心的），下行是总数，弱化处理
          Column({ space: 0 }) {
            Text(`${this.progress.downloadedCount}`)
              .fontSize(FontSize.Micro)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.failed()
                ? $r('app.color.status_error') : $r('app.color.text_primary'))
              .maxLines(1)
            Text(`/${this.progress.totalCount}`)
              .fontSize(FontSize.Micro)
              .fontColor(this.failed()
                ? $r('app.color.status_error') : $r('app.color.text_secondary'))
              .maxLines(1)
          }
        } else {
          Text(this.countText())
            .fontSize(FontSize.Micro)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.failed()
              ? $r('app.color.status_error') : $r('app.color.text_primary'))
            .maxLines(1)
        }
      }
      .width(44)
      .height(44)

      Text(this.phaseText())
        .fontSize(FontSize.Micro)
        .fontColor(this.failed()
          ? $r('app.color.status_error') : $r('app.color.text_secondary'))
        .maxLines(1)

      if (this.running()) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(IconSize.Body)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(32)
        .height(32)
        // 不铺底色：宿主是沉浸材质，额外画一层灰圆会把它压成一块脏斑
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.onCancel(); })
      }
    }
    .width(60)
    .padding({ top: 10, bottom: 10 })
    .borderRadius(pillRadius(60))
    // 背景与磨砂完全不画：宿主（MainScreen.TitleBar 的浮岛层）会设置
    // systemMaterial，材质会接管 backgroundColor / border / shadow。
    // 自己再铺一层半透明底会把材质整个盖住。
  }
}
