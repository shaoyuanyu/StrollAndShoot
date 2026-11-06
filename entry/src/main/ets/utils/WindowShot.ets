import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowUtils } from './WindowUtils';

const DOMAIN = 0x0000;
const TAG = 'WindowShot';

/**
 * 截取「应用自己的窗口」并存成 JPEG。
 *
 * 为什么要它：hdc 的 `snapshot_display` / `uitest screenCap` 只能截整屏，
 * 会把其它应用的悬浮窗（比如视频通话小窗）一起截进来。
 * `window.Window.snapshot()` 只渲染本应用的窗口内容，不受系统浮层干扰。
 *
 * 触发方式（仅调试用）：
 *   hdc shell aa start -a EntryAbility -b io.github.shaoyuanyu.strollandshoot --ps shot 1
 * 产物落在应用沙箱 filesDir 下，用 hdc file recv 取走。
 */
export async function saveWindowSnapshot(ctx: common.UIAbilityContext, label: string = 'window'): Promise<string> {
  const win = WindowUtils.window;
  if (!win) {
    throw new Error('main window is not ready');
  }
  const pixelMap = await win.snapshot();
  const packer = image.createImagePacker();
  try {
    const buf = await packer.packing(pixelMap, { format: 'image/jpeg', quality: 95 });
    const path = `${ctx.filesDir}/shot_${label}_${Date.now()}.jpg`;
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, buf);
    fileIo.closeSync(file);
    hilog.info(DOMAIN, TAG, 'saved %{public}s', path);
    return path;
  } finally {
    await pixelMap.release();
    packer.release();
  }
}
