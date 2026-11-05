import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';

/**
 * Window-level facts and helpers shared across pages.
 *
 * System bar colours are driven explicitly from the app theme: the platform
 * default is only applied once at first launch, so leaving the bars untouched
 * after the viewer pinned them would keep stale colours (e.g. a white status
 * bar in dark mode).
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
   * Colours match `start_window_background`, i.e. the window backdrop the
   * pages are drawn on, so the bars blend into the page.
   */
  public static applyThemeSystemBars(dark: boolean): void {
    const w = WindowUtils.window;
    if (!w) return;
    const bg = dark ? '#FF000000' : '#FFFFFFFF';
    const fg = dark ? '#FFFFFF' : '#000000';
    w.setWindowSystemBarProperties({
      statusBarColor: bg,
      statusBarContentColor: fg,
      navigationBarColor: bg,
      navigationBarContentColor: fg
    }).catch((_e: Error) => { /* best effort */ });
  }

  /**
   * Paint the system bars for the photo viewer, which is always dark.
   */
  public static applyViewerSystemBars(): void {
    const w = WindowUtils.window;
    if (!w) return;
    w.setWindowSystemBarProperties({
      statusBarColor: '#FF000000',
      statusBarContentColor: '#FFFFFF',
      navigationBarColor: '#FF000000',
      navigationBarContentColor: '#FFFFFF'
    }).catch((_e: Error) => { /* best effort */ });
  }
}
