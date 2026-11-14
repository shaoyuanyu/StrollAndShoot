import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, type WantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import usbManager from '@ohos.usbManager';

import { PtpSession } from '../pages/PtpHost';
import { CameraService } from './CameraService';
import { L10n } from '../utils/L10n';
import { cameraAttachKey, shouldHandleAttach } from '../utils/UsbAttachUtil';

const DOMAIN = 0x0000;
const TAG = 'UsbAttachWatcher';

const EVENT_ATTACHED = 'usual.event.hardware.usb.action.USB_DEVICE_ATTACHED';
/**
 * 设备拔出（1.66.0）。
 *
 * 相机拔线 / 断电后，正在建立的 PTP 会话不会立刻报错——bulk 端点要等下一次
 * 传输才知道对端没了，空闲时页面就一直停在「已连接」。系统这个公共事件是
 * 零成本的拔出信号，交给 `CameraService.onUsbDeviceDetached()` 确认后收尾。
 */
const EVENT_DETACHED = 'usual.event.hardware.usb.action.USB_DEVICE_DETACHED';
/** 相机接入后常会重新枚举，等描述符稳定再查一次设备列表。 */
const ENUM_SETTLE_MS = 800;
/** 拔出事件比系统枚举还早：等一拍再看设备列表，避免把「正在重枚举」判成「没了」。 */
const DETACH_SETTLE_MS = 400;
/** 同一台相机（VID/PID/产品名）在这个窗口内只提示一次。 */
const ATTACH_DEDUPE_MS = 15000;
/** 与 TransferNotice 的 4210 错开。 */
const NOTICE_ID = 4211;
const BUNDLE_NAME = 'io.github.shaoyuanyu.strollandshoot';
const ABILITY_NAME = 'EntryAbility';

/**
 * USB 相机插入监听。
 *
 * 原生三方应用**不能**像 Android 那样在 USB 插入时被系统自动拉起：静态订阅
 * 公共事件仅系统应用可用，后台启动 UIAbility 也需要系统级权限。所以这里只做
 * 运行期能做到的两件事：
 * - App 在前台：递增 `attachVersion`，由 MainScreen 切到相机页并弹「发现相机」；
 * - App 在后台但进程还活着：发一条带 WantAgent 的通知，用户点通知再打开。
 *
 * 冷启动不监听历史设备；没运行时的插入事件收不到，仍走用户手动「搜索相机」。
 */
@ObservedV2
export class UsbAttachWatcher {
  private static instance: UsbAttachWatcher;

  /** 递增一次 = 要求 MainScreen 弹一次「发现相机」。 */
  @Trace attachVersion: number = 0;
  /** 触发提示的相机名，供对话框/通知文案使用。 */
  @Trace cameraName: string = '';

  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private started: boolean = false;
  private appForeground: boolean = true;
  private noticeOpenPending: boolean = false;
  private noticeVisible: boolean = false;
  private noticeAuthorized: boolean | null = null;
  private lastKey: string = '';
  private lastHandledAt: number = 0;

  static getInstance(): UsbAttachWatcher {
    if (!UsbAttachWatcher.instance) {
      UsbAttachWatcher.instance = new UsbAttachWatcher();
    }
    return UsbAttachWatcher.instance;
  }

  /** 应用启动时调用一次。没有插拔监听 API，只能订阅系统公共事件。 */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.appForeground = true;
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [EVENT_ATTACHED, EVENT_DETACHED]
    };
    commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      this.subscriber = subscriber;
      try {
        commonEventManager.subscribe(subscriber,
          (err: BusinessError, data: commonEventManager.CommonEventData) => {
            if (err) {
              this.log(`USB 插入事件订阅失败: ${err.message}`);
              return;
            }
            if (data.event === EVENT_ATTACHED) {
              this.onUsbAttached();
            } else if (data.event === EVENT_DETACHED) {
              this.onUsbDetached();
            }
          });
        this.log('USB 插入监听已启动');
      } catch (err) {
        this.started = false;
        this.subscriber = null;
        this.log(`USB 插入监听启动失败: ${(err as BusinessError).message}`);
      }
    }).catch((err: BusinessError) => {
      this.started = false;
      this.log(`创建 USB 插入订阅者失败: ${err.message}`);
    });
  }

  /** 应用销毁时调用；重装/重建 Ability 时会重新 start。 */
  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    const subscriber = this.subscriber;
    this.subscriber = null;
    if (subscriber !== null) {
      try {
        commonEventManager.unsubscribe(subscriber);
      } catch (_e) {
        // best effort
      }
    }
    this.cancelNotice();
    this.log('USB 插入监听已停止');
  }

  /** EntryAbility 前后台切换时更新；回前台顺手撤掉后台通知。 */
  setAppForeground(foreground: boolean): void {
    this.appForeground = foreground;
    if (!foreground) {
      return;
    }
    this.cancelNotice();
    if (this.noticeOpenPending) {
      this.noticeOpenPending = false;
      this.promptForeground();
    }
  }

  /** 用户点了「相机已连接」通知：等回到前台再提示。 */
  noteNoticeOpen(): void {
    this.noticeOpenPending = true;
  }

  /**
   * 前台显式提示一次（通知被点开时使用，绕过插入去重）。
   * 没有相机、正在扫描或已经连着可用相机时不打扰。
   */
  promptForeground(): void {
    const camera = this.findCamera();
    if (camera === null) {
      return;
    }
    const svc = CameraService.getInstance();
    if (svc.scanning || (svc.connected && svc.usable)) {
      return;
    }
    this.lastKey = cameraAttachKey(camera.vendorId, camera.productId, camera.productName);
    this.lastHandledAt = Date.now();
    this.cameraName = this.displayName(camera);
    this.attachVersion++;
    svc.getLog().add(`USB 相机接入（通知打开）: ${this.cameraName}`);
  }

  private onUsbAttached(): void {
    // 相机插入后台可能马上重枚举，先等描述符稳定，再统一判断。
    setTimeout(() => {
      const camera = this.findCamera();
      if (camera === null) {
        return;
      }
      const svc = CameraService.getInstance();
      const key = cameraAttachKey(camera.vendorId, camera.productId, camera.productName);
      const now = Date.now();
      if (!shouldHandleAttach(key, this.lastKey, this.lastHandledAt, now, ATTACH_DEDUPE_MS)) {
        return;
      }
      if (svc.scanning) {
        svc.getLog().add('USB 相机接入：扫描中，忽略提示');
        return;
      }
      if (svc.connected && svc.usable) {
        this.lastKey = key;
        this.lastHandledAt = now;
        svc.getLog().add('USB 相机接入：已有可用会话，忽略提示');
        return;
      }
      this.lastKey = key;
      this.lastHandledAt = now;
      this.cameraName = this.displayName(camera);
      if (this.appForeground) {
        this.attachVersion++;
        svc.getLog().add(`USB 相机接入（前台）: ${this.cameraName}`);
      } else {
        svc.getLog().add(`USB 相机接入（后台）: ${this.cameraName}`);
        this.publishNotice(this.cameraName).catch((_e: Error) => {
          // 通知失败不影响相机主流程
        });
      }
    }, ENUM_SETTLE_MS);
  }

  /**
   * 设备拔出：交给服务层确认「是不是我们这台相机」再收尾。
   *
   * 这个事件对任何 USB 设备都会发（鼠标、U 盘），所以不在这里判断，服务层会
   * 拿会话设备名和设备列表对一次。
   */
  private onUsbDetached(): void {
    setTimeout(() => {
      CameraService.getInstance().onUsbDeviceDetached().catch((err: Error) => {
        this.log(`USB 拔出处理失败: ${err.message}`);
      });
    }, DETACH_SETTLE_MS);
  }

  private findCamera(): usbManager.USBDevice | null {
    const cameras: usbManager.USBDevice[] = PtpSession.findCameras();
    return cameras.length > 0 ? cameras[0] : null;
  }

  private displayName(device: usbManager.USBDevice): string {
    if (device.productName !== '') {
      return device.productName;
    }
    if (device.manufacturerName !== '') {
      return device.manufacturerName;
    }
    return device.name;
  }

  private async publishNotice(cameraName: string): Promise<void> {
    if (this.noticeVisible || this.appForeground) {
      return;
    }
    if (!await this.notificationEnabled()) {
      this.log('通知未授权，跳过后台相机提示');
      return;
    }
    if (this.appForeground) {
      return;
    }
    try {
      const agent = await this.buildWantAgent();
      const request: notificationManager.NotificationRequest = {
        id: NOTICE_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: L10n.tr('usb_camera_notice_title'),
            text: L10n.tr('usb_camera_notice_text', cameraName),
            additionalText: ''
          }
        },
        wantAgent: agent
      };
      await notificationManager.publish(request);
      if (this.appForeground) {
        // 通知还在路上时用户已经回到前台，撤掉，避免留下一条过期的“相机已连接”。
        notificationManager.cancel(NOTICE_ID).catch((_e: BusinessError) => {
          // best effort
        });
        return;
      }
      this.noticeVisible = true;
      this.log('已发送相机接入通知');
    } catch (err) {
      this.log(`发送相机接入通知失败: ${(err as BusinessError).message}`);
    }
  }

  private async buildWantAgent(): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: BUNDLE_NAME,
        abilityName: ABILITY_NAME,
        parameters: {
          'usbCamera': '1'
        }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: NOTICE_ID,
      actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
  }

  private async notificationEnabled(): Promise<boolean> {
    if (this.noticeAuthorized !== null) {
      return this.noticeAuthorized;
    }
    try {
      this.noticeAuthorized = await notificationManager.isNotificationEnabled();
    } catch (_e) {
      this.noticeAuthorized = false;
    }
    return this.noticeAuthorized;
  }

  private cancelNotice(): void {
    if (!this.noticeVisible) {
      return;
    }
    this.noticeVisible = false;
    notificationManager.cancel(NOTICE_ID).catch((_e: BusinessError) => {
      // 通知可能已经被用户划掉
    });
  }

  private log(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
  }
}
