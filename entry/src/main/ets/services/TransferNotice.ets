import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 传输进度通知（系统预置的下载进度模板）。
 *
 * 长时任务那条通知由系统生成，应用改不了内容；想让通知栏出现**进度环**，官方唯一
 * 的正规办法是 `NotificationTemplate` 里用预置的 `downloadTemplate`：
 * 只要给 `title` / `fileName` / `progressValue(0~100)`，系统自己渲染进度环，
 * 到 100 环消失表示完成（见《NotificationTemplate》API 参考）。
 *
 * 约束：模板目前只支持上传/下载场景；通知需要用户授权，未授权时静默跳过。
 */
const NOTICE_ID = 4210;
const TEMPLATE_NAME = 'downloadTemplate';
/** 进度通知的最小更新间隔，避免每张缩略图都发一次通知。 */
const MIN_INTERVAL_MS = 800;

export class TransferNotice {
  /** null = 还没问过用户。 */
  private static authorized: boolean | null = null;
  private static lastPercent: number = -1;
  private static lastAt: number = 0;
  private static visible: boolean = false;

  private static async ensureAuthorized(context: common.UIAbilityContext): Promise<boolean> {
    if (TransferNotice.authorized !== null) {
      return TransferNotice.authorized;
    }
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        // 首次传输时向用户申请一次；被拒绝也不影响传输，只是看不到通知
        await notificationManager.requestEnableNotification(context);
      }
      TransferNotice.authorized = await notificationManager.isNotificationEnabled();
    } catch (err) {
      TransferNotice.authorized = false;
      const e = err as BusinessError;
      hilogUnavailable(e.message);
    }
    return TransferNotice.authorized === true;
  }

  /**
   * 更新进度通知。`percent` 取 0~100，多次重复进度会被节流。
   * `fileName` 建议写「512/1288 · 正在加载缩略图」这种一眼能读懂的串。
   */
  static async update(context: common.UIAbilityContext | null, title: string,
    fileName: string, percent: number): Promise<void> {
    if (context === null) {
      return;
    }
    const p = Math.max(0, Math.min(100, Math.round(percent)));
    const now = Date.now();
    if (p === TransferNotice.lastPercent && now - TransferNotice.lastAt < 3000) {
      return;
    }
    if (now - TransferNotice.lastAt < MIN_INTERVAL_MS) {
      return;
    }
    if (!await TransferNotice.ensureAuthorized(context)) {
      return;
    }
    TransferNotice.lastPercent = p;
    TransferNotice.lastAt = now;
    try {
      const data: Record<string, Object> = {
        'title': title,
        'fileName': fileName,
        'progressValue': p
      };
      const request: notificationManager.NotificationRequest = {
        id: NOTICE_ID,
        template: {
          name: TEMPLATE_NAME,
          data: data
        },
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: fileName,
            additionalText: ''
          }
        }
      };
      await notificationManager.publish(request);
      TransferNotice.visible = true;
    } catch (err) {
      const e = err as BusinessError;
      hilogUnavailable(e.message);
    }
  }

  /** 传输结束：撤掉进度通知。 */
  static async cancel(): Promise<void> {
    if (!TransferNotice.visible) {
      return;
    }
    try {
      await notificationManager.cancel(NOTICE_ID);
    } catch (_e) {
      // 通知已经被用户划掉时 cancel 会报错，忽略即可
    }
    TransferNotice.visible = false;
    TransferNotice.lastPercent = -1;
    TransferNotice.lastAt = 0;
  }
}

function hilogUnavailable(message: string): void {
  // 通知不是关键路径，失败只记一条轻量日志，不打断传输
  hilog.warn(0x0000, 'TransferNotice', '%{public}s', message);
}
