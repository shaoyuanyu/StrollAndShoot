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

/**
 * 连续截取本应用窗口（**临时调试工具**，2026-11-12 用于抓一帧级重影/闪烁）。
 *
 * 为什么不用 `snapshot_display`：它一次约 0.3s（约 3fps），而这里要抓的是
 * 持续几帧的合成残影。窗口快照 + JPEG 编码能到 5~10fps，命中率高一档，
 * 而且不带系统浮层。
 *
 * ```bash
 * hdc shell aa start -a EntryAbility -b <bundle> --ps burst
 * ```
 * 产物 `burst_<序号>_<起始毫秒>.jpg` 落在应用沙箱 filesDir 下。
 * 文件名里的毫秒数就是每一帧的起始时间，用来算帧间隔。
 */
export async function saveWindowSnapshotBurst(ctx: common.UIAbilityContext,
  count: number = 60): Promise<number> {
  const win = WindowUtils.window;
  if (!win) {
    throw new Error('main window is not ready');
  }
  const packer = image.createImagePacker();
  let saved = 0;
  try {
    for (let i = 0; i < count; i++) {
      const t0 = Date.now();
      const pixelMap = await win.snapshot();
      try {
        const buf = await packer.packing(pixelMap, { format: 'image/jpeg', quality: 70 });
        const path = `${ctx.filesDir}/burst_${i}_${t0}.jpg`;
        const file = fileIo.openSync(path,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, buf);
        fileIo.closeSync(file);
        saved++;
      } finally {
        await pixelMap.release();
      }
    }
  } finally {
    packer.release();
  }
  hilog.info(DOMAIN, TAG, 'burst saved %{public}d frames', saved);
  return saved;
}
