import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { WindowUtils } from '../utils/WindowUtils';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private currentBreakPoint: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    // ---- Initialize WindowUtils ----
    WindowUtils.window = windowStage.getMainWindowSync();
    WindowUtils.windowWidthPx = WindowUtils.window.getWindowProperties().windowRect.width;
    WindowUtils.windowHeightPx = WindowUtils.window.getWindowProperties().windowRect.height;

    // Get top avoid area (status bar etc.)
    const avoidArea = WindowUtils.window.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    WindowUtils.topAvoidAreaHeightPx = avoidArea.topRect.height;

    // Get navigation indicator height
    const navigationArea = WindowUtils.window.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    WindowUtils.navigationIndicatorHeightPx = navigationArea.bottomRect.height;

    hilog.info(DOMAIN, TAG, 'window size: ' + WindowUtils.windowWidthPx + 'x' + WindowUtils.windowHeightPx +
      ' topAvoidArea: ' + WindowUtils.topAvoidAreaHeightPx +
      ' navIndicator: ' + WindowUtils.navigationIndicatorHeightPx);

    // Listen for window size changes
    try {
      WindowUtils.window.on('windowSizeChange', (data: window.Size) => {
        hilog.info(DOMAIN, TAG, 'on windowSizeChange: ' + data.width + 'x' + data.height);
        WindowUtils.windowWidthPx = data.width;
        WindowUtils.windowHeightPx = data.height;
      });

      WindowUtils.window.on('avoidAreaChange', (data) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          WindowUtils.topAvoidAreaHeightPx = data.area.topRect.height;
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          WindowUtils.navigationIndicatorHeightPx = data.area.bottomRect.height;
        }
      });
    } catch (exception) {
      hilog.error(DOMAIN, TAG, 'register window listener failed: ' + JSON.stringify(exception));
    }
    // ---- End WindowUtils init ----

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}