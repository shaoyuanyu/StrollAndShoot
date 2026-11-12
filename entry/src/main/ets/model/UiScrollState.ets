import { WindowUtils } from '../utils/WindowUtils';

/**
 * 页面滚动状态（跨组件共享）。
 *
 * 相机页的标题栏是完全透明的，标题一开始压在浅色页面上（黑字），
 * 滚到相机图上之后必须反色成白字才读得清。标题栏在 `MainScreen`、
 * 滚动发生在 `CameraPage`，所以用这个单例把进度传过去。
 *
 * 只保留一个 0~1 的进度值，不保存具体偏移量。
 */
@ObservedV2
export class UiScrollState {
  private static instance: UiScrollState = new UiScrollState();

  static getInstance(): UiScrollState {
    return UiScrollState.instance;
  }

  /** 相机页：0 = 顶部，1 = 相机立牌已经顶到屏幕顶（标题完全压在图上了）。 */
  @Trace cameraProgress: number = 0;
}
