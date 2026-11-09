import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { WindowUtils } from '../utils/WindowUtils';
import { L10n } from '../utils/L10n';
import { saveWindowSnapshot } from '../utils/WindowShot';
import { MockPtpDevice } from '../debug/MockPtpDevice';
import { CameraService } from '../services/CameraService';
import { GpsRecorder } from '../services/GpsRecorder';
import { GpsGeocoder } from '../services/GpsGeocoder';
import { UsbAttachWatcher } from '../services/UsbAttachWatcher';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private currentBreakPoint: string = '';

  /**
   * 调试用截图。触发方式：
   *   hdc shell aa start -a EntryAbility -b <bundle> --ps shot <label>
   * `label` 只作为文件名后缀，便于区分截图场景（如 gallery / settings）。
   * 仅调试包生效；release 包里不会执行。
   */
  onNewWant(want: Want): void {
    const usbCamera = want.parameters ? want.parameters['usbCamera'] : undefined;
    if (usbCamera !== undefined && String(usbCamera) === '1') {
      // 点「相机已连接」通知回到前台时，等 onForeground 再提示，避免在后台弹窗。
      UsbAttachWatcher.getInstance().noteNoticeOpen();
    }
    const shot = want.parameters ? want.parameters['shot'] : undefined;
    if (shot === undefined) return;
    if (!MockPtpDevice.isDebugBuild()) return;
    const label = String(shot).replace(/[^a-zA-Z0-9_-]/g, '');
    // 稍等一帧，避免把前后台切换的中间态截进去
    setTimeout(() => {
      saveWindowSnapshot(this.context, label === '' ? 'window' : label)
        .then((path: string) => {
          hilog.info(DOMAIN, TAG, 'window snapshot: %{public}s', path);
        })
        .catch((err: Error) => {
          hilog.error(DOMAIN, TAG, 'window snapshot failed: %{public}s', JSON.stringify(err));
        });
    }, 300);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // service / utils 里的运行时文案通过资源管理器取，必须在加载页面前注入。
    L10n.init(this.context.resourceManager);
    UsbAttachWatcher.getInstance().start();
    const usbCamera = want.parameters ? want.parameters['usbCamera'] : undefined;
    if (usbCamera !== undefined && String(usbCamera) === '1') {
      UsbAttachWatcher.getInstance().noteNoticeOpen();
    }
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
    UsbAttachWatcher.getInstance().stop();
    this.flushPersistence();
  }

  /** 应用退到后台 / 销毁前，把延迟落盘的数据强制补齐。 */
  private flushPersistence(): void {
    try {
      GpsRecorder.getInstance().flush();
    } catch (_e) {
      // best effort
    }
    try {
      GpsGeocoder.getInstance().flush();
    } catch (_e) {
      // best effort
    }
    try {
      CameraService.getInstance().getLog().flushNow();
    } catch (_e) {
      // best effort
    }
    CameraService.getInstance().flushPersistence().catch((_e: Error) => {
      // best effort
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    // ---- Initialize WindowUtils ----
    try {
      WindowUtils.window = windowStage.getMainWindowSync();
      const mainRect = WindowUtils.window.getWindowProperties().windowRect;
      WindowUtils.windowWidthPx = mainRect.width;
      WindowUtils.windowHeightPx = mainRect.height;

      // Get top avoid area (status bar etc.)
      const avoidArea = WindowUtils.window.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      WindowUtils.topAvoidAreaHeightPx = avoidArea.topRect.height;

      // Get navigation indicator height
      const navigationArea = WindowUtils.window.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      WindowUtils.navigationIndicatorHeightPx = navigationArea.bottomRect.height;

      hilog.info(DOMAIN, TAG, 'window size: ' + WindowUtils.windowWidthPx + 'x' + WindowUtils.windowHeightPx +
        ' topAvoidArea: ' + WindowUtils.topAvoidAreaHeightPx +
        ' navIndicator: ' + WindowUtils.navigationIndicatorHeightPx);
    } catch (exception) {
      hilog.error(DOMAIN, TAG, 'init WindowUtils failed: ' + JSON.stringify(exception));
    }

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
      // 全屏布局：界面元素才能延伸到状态栏/导航条区域（官方《开发应用沉浸式效果》）
      WindowUtils.window.setWindowLayoutFullScreen(true).then(() => {
        WindowUtils.applyThemeSystemBars(WindowUtils.isDarkMode(this.context));
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(e));
      });
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    this.flushPersistence();
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    UsbAttachWatcher.getInstance().setAppForeground(true);
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    UsbAttachWatcher.getInstance().setAppForeground(false);
    this.flushPersistence();
  }
}