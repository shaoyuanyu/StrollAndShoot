import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { CameraService } from '../services/CameraService';
import { GpsRecorder } from '../services/GpsRecorder';
import { ExifGeotagger } from '../services/ExifGeotagger';
import { SettingsStore } from '../model/SettingsStore';
import { CustomTransition } from '../CustomTransition/CustomNavigationUtils';

@Entry
@ComponentV2
struct Index {
  private pageInfos: NavPathStack = new NavPathStack();
  private gpsRecorder: GpsRecorder = GpsRecorder.getInstance();
  private svc: CameraService = CameraService.getInstance();
  @Local settings: SettingsStore = SettingsStore.getInstance();

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;

    // Initialize dark mode
    if (this.settings.darkMode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
      this.applyDarkMode(this.settings.darkMode);
    }

    // Initialize services
    this.svc.initLogPath(ctx.filesDir);
    this.svc.initDownloadDir(ctx.filesDir);
    this.gpsRecorder.init(ctx.filesDir, this.svc.getLog(), ctx);
    ExifGeotagger.setLog(this.svc.getLog());
    this.gpsRecorder.autoStart();

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
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      ctx.getApplicationContext().setColorMode(mode);
    } catch (_e) { /* ignore */ }
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
  }
}
