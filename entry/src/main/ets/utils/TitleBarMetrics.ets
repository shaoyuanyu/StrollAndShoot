import { WindowUtils } from './WindowUtils';

/**
 * 标准 NavDestination 标题栏（主标题 + 副标题）的高度，单位 vp。
 *
 * 标题栏设为 `barStyle: BarStyle.STACK` 后，NavDestination 内容区会从页面顶部开始
 * 布局、延伸到标题栏下方，滚动内容从标题栏底下透出，标题栏的沉浸光感材质才有可折射
 * 的底层。代价是首屏内容会被标题栏盖住，必须由滚动容器用 `contentStartOffset()`
 * 顶部留白避让（见官方《沉浸光感典型场景》“搜索框标题栏效果”）。
 *
 * 官方示例把标题栏高度写在自己的自定义标题 Builder 上；本项目使用系统标准标题，
 * 高度由截图实测校准。改标题结构（增减副标题、换字号）后需要重新校准。
 */
export const TITLE_BAR_HEIGHT: number = 56;

/**
 * 内容区需要避让的顶部总高度：状态栏 + 标题栏，单位 vp。
 *
 * 窗口用 `setWindowLayoutFullScreen(true)` 做全屏布局，标题栏配了
 * `avoidLayoutSafeArea: true`：背景铺满状态栏区域、内容避让状态栏，
 * 所以页面内容起点要把状态栏高度一起算进来。
 */
export function titleBarInsetVp(): number {
  const px = WindowUtils.topAvoidAreaHeightPx;
  return TITLE_BAR_HEIGHT + (px > 0 ? px2vp(px) : 0);
}

/** 渐隐在标题下方继续衰减的高度（vp）。 */
export const TITLE_FADE_EXTRA: number = 28;

/**
 * 标题栏的实际高度：状态栏 + 标题行 + 标题下方的渐隐余量。
 * 内容起点要用这个值，首屏才不会落在渐隐区里。
 */
export function titleBarTotalVp(): number {
  return titleBarInsetVp() + TITLE_FADE_EXTRA;
}
