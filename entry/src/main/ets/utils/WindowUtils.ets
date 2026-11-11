import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';

/**
 * Window-level facts and helpers shared across pages.
 *
 * System bar colours are driven explicitly from the app theme: the platform
 * default is applied only once at first launch, so screens that change them
 * restore the theme colours when they disappear.
 */
export class WindowUtils {
  public static window: window.Window;
  public static windowWidthPx: number = 0;
  public static windowHeightPx: number = 0;
  public static topAvoidAreaHeightPx: number = 0;
  public static navigationIndicatorHeightPx: number = 0;

  /**
   * Resolve the effective colour mode from the given context.
   * Falls back to light when the configuration cannot be read.
   */
  public static isDarkMode(ctx: common.Context | undefined): boolean {
    try {
      if (ctx) {
        return ctx.resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
      }
    } catch (_e) { /* best effort */ }
    return false;
  }

  /**
   * Paint the status/navigation bars for the given theme.
   * Colours match the window backdrop the pages are drawn on, so the bars blend
   * into the page.
   */
  public static applyThemeSystemBars(dark: boolean): void {
    const w = WindowUtils.window;
    if (!w) return;
    // 窗口是全屏布局（内容延伸到状态栏下方），系统栏透明，
    // 状态栏/导航条区域直接透出页面背板。
    const bg = '#00000000';
    const fg = dark ? '#FFFFFF' : '#000000';
    w.setWindowSystemBarProperties({
      statusBarColor: bg,
      statusBarContentColor: fg,
      navigationBarColor: bg,
      navigationBarContentColor: fg
    }).catch((_e: Error) => { /* best effort */ });
  }
}
