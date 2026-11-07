import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { CameraService } from '../services/CameraService';
import { GpsRecorder } from '../services/GpsRecorder';
import { GpsGeocoder } from '../services/GpsGeocoder';
import { ExifGeotagger } from '../services/ExifGeotagger';
import { SettingsStore } from '../model/SettingsStore';
import { CustomTransition } from '../CustomTransition/CustomNavigationUtils';
import { WindowUtils } from '../utils/WindowUtils';

@Entry
@ComponentV2
struct Index {
  private pageInfos: NavPathStack = new NavPathStack();
  private gpsRecorder: GpsRecorder = GpsRecorder.getInstance();
  private svc: CameraService = CameraService.getInstance();
  @Local settings: SettingsStore = SettingsStore.getInstance();

  aboutToAppear(): void {
    const hostCtx = this.getUIContext().getHostContext();

    // Initialize dark mode
    if (this.settings.darkMode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
      this.applyDarkMode(this.settings.darkMode);
    } else {
      // Following the system theme: still make the bars match on cold start,
      // because leaving them untouched keeps whatever was last painted.
      WindowUtils.applyThemeSystemBars(WindowUtils.isDarkMode(hostCtx));
    }

    // Initialize services
    if (hostCtx) {
      const ctx = hostCtx as common.UIAbilityContext;
      this.svc.initLogPath(ctx.filesDir);
      this.svc.initDownloadDir(ctx.filesDir);
      this.gpsRecorder.init(ctx.filesDir, this.svc.getLog(), ctx);
      GpsGeocoder.getInstance().init(ctx.filesDir);
      ExifGeotagger.setLog(this.svc.getLog());
      this.gpsRecorder.autoStart();
    }

    // Push the main tab screen as the initial Navigation destination
    this.pageInfos.pushPath({ name: 'MainScreen' });
  }

  @Monitor('settings.darkMode')
  onDarkModeChange(mon: IMonitor) {
    const mode = mon.value()?.now as number;
    if (mode !== undefined) {
      this.applyDarkMode(mode);
    }
  }

  applyDarkMode(mode: number): void {
    const ctx = this.getUIContext().getHostContext();
    try {
      if (ctx) {
        (ctx as common.UIAbilityContext).getApplicationContext().setColorMode(mode);
      }
    } catch (_e) { /* ignore */ }
    // Keep the system bars in step with the theme. Read from the requested
    // mode where it is explicit, because the configuration change triggered
    // by setColorMode() may not have been applied yet at this point.
    let dark: boolean;
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      dark = true;
    } else if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      dark = false;
    } else {
      dark = WindowUtils.isDarkMode(ctx);
    }
    WindowUtils.applyThemeSystemBars(dark);
  }

  build() {
    Navigation(this.pageInfos)
      .hideNavBar(true)
      .customNavContentTransition((from: NavContentInfo, to: NavContentInfo, operation: NavigationOperation) => {
        // Require both pages to exist and have names
        if ((!from || !to) || (!from.name || !to.name)) {
          return undefined;
        }

        // Validate that both pages have registered animation callbacks
        const fromParam = CustomTransition.getInstance().getAnimateParam(from.index);
        const toParam = CustomTransition.getInstance().getAnimateParam(to.index);
        if (!fromParam.animation || !toParam.animation) {
          return undefined;
        }

        // Build the custom animation descriptor
        const customAnimation: NavigationAnimatedTransition = {
          onTransitionEnd: (_isSuccess: boolean) => {
            this.svc.getLog().add('transition ended, isSuccess=' + _isSuccess);
          },
          timeout: 2000,
          transition: (transitionProxy: NavigationTransitionProxy) => {
            if (fromParam.animation) {
              fromParam.animation(operation === NavigationOperation.PUSH, true, transitionProxy);
            }
            if (toParam.animation) {
              toParam.animation(operation === NavigationOperation.PUSH, false, transitionProxy);
            }
          }
        };
        return customAnimation;
      })
      // 注意：ArkUI Navigation 不要再加 ignoreLayoutSafeArea(TOP)
      // 会把 NavDestination 的标题栏整个推出可视区（实测标题栏直接消失）
  }
}
