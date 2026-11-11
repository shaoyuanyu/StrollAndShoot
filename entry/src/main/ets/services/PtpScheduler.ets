import hilog from '@ohos.hilog';
import { PtpPriority, type PtpTransport, type PtpEndpoint, type DeviceInfo, type ObjectInfo,
  type ObjectPropList } from '../pages/PtpHost';

/**
 * 一个排队中的 PTP 事务。
 *
 * `run()` 内部已经把结果/异常交给调用方的 promise，所以队列本身只负责
 * 依次执行，不关心返回值类型。
 */
interface PtpJob {
  priority: number;
  run: () => Promise<void>;
}

/**
 * 把任意 `PtpTransport` 包成「单管道 + 优先级」的串行队列。
 *
 * 为什么需要它：
 * - PTP 会话只能串行：一条命令 → 数据 → 响应，中间不能插入第二条命令；
 * - 旧实现用 `usbBusy` 布尔标志 + 200ms 轮询做互斥，一个事务结束到下一个
 *   事务开始最多要等 200ms。1288 张缩略图时这条空档就是分钟级的浪费；
 * - 这里用 promise 队列，前一个事务一结束立刻交给下一个；同时按优先级
 *   （前台原图 > 邻近预加载 > 扫描）插队，让用户打开照片时不用排在
 *   一长串缩略图后面。
 *
 * 注意：队列只保证「事务」串行，不保证一个业务操作（例如缩略图 + EXIF）
 * 原子完成。各事务之间让出队列是好事：解码、写盘可以和下一笔 USB 传输重叠。
 */
export class PtpScheduler implements PtpTransport {
  private inner: PtpTransport;
  private queue: PtpJob[] = [];
  private running: boolean = false;

  constructor(inner: PtpTransport) {
    this.inner = inner;
  }

  get connectedDeviceName(): string {
    return this.inner.connectedDeviceName;
  }

  get sessionConflict(): boolean | undefined {
    return this.inner.sessionConflict;
  }

  connect(endpoint: PtpEndpoint, priority: PtpPriority = PtpPriority.FOREGROUND): Promise<boolean> {
    return this.enqueue(priority, () => this.inner.connect(endpoint));
  }

  getDeviceInfo(priority: PtpPriority = PtpPriority.FOREGROUND): Promise<DeviceInfo | null> {
    return this.enqueue(priority, () => this.inner.getDeviceInfo());
  }

  getStorageIDs(priority: PtpPriority = PtpPriority.SCAN): Promise<number[]> {
    return this.enqueue(priority, () => this.inner.getStorageIDs());
  }

  getObjectHandles(storageId: number, parent?: number, formatCode?: number,
    priority: PtpPriority = PtpPriority.SCAN): Promise<number[]> {
    return this.enqueue(priority, () => this.inner.getObjectHandles(storageId, parent, formatCode));
  }

  getObjectInfo(handle: number, priority: PtpPriority = PtpPriority.SCAN): Promise<ObjectInfo | null> {
    return this.enqueue(priority, () => this.inner.getObjectInfo(handle));
  }

  getThumb(handle: number, priority: PtpPriority = PtpPriority.SCAN): Promise<Uint8Array | null> {
    return this.enqueue(priority, () => this.inner.getThumb(handle));
  }

  getObject(handle: number, priority: PtpPriority = PtpPriority.FOREGROUND): Promise<Uint8Array | null> {
    return this.enqueue(priority, () => this.inner.getObject(handle, priority));
  }

  getPartialObject(handle: number, offset: number, maxBytes: number,
    priority: PtpPriority = PtpPriority.SCAN): Promise<Uint8Array | null> {
    return this.enqueue(priority, () => this.inner.getPartialObject(handle, offset, maxBytes));
  }

  getObjectPropList(objectHandle: number, formatCode: number, propertyCode: number,
    groupCode: number, depth: number,
    priority: PtpPriority = PtpPriority.SCAN): Promise<ObjectPropList> {
    return this.enqueue(priority,
      () => this.inner.getObjectPropList(objectHandle, formatCode, propertyCode, groupCode, depth));
  }

  closeSessionAndPipe(priority: PtpPriority = PtpPriority.FOREGROUND): Promise<void> {
    return this.enqueue(priority, () => this.inner.closeSessionAndPipe());
  }

  private enqueue<T>(priority: number, fn: () => Promise<T>): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (reason?: Object) => void) => {
      const job: PtpJob = {
        priority: priority,
        run: async (): Promise<void> => {
          try {
            resolve(await fn());
          } catch (err) {
            reject(err as Object);
          }
        }
      };
      this.insert(job);
      this.pump().catch((err: Error) => {
        hilog.error(0x0000, 'PtpScheduler', 'pump failed: %{public}s', JSON.stringify(err));
      });
    });
  }

  /** 数值小的先执行；同优先级插到队尾，保持 FIFO。 */
  private insert(job: PtpJob): void {
    let i = this.queue.length;
    while (i > 0 && this.queue[i - 1].priority > job.priority) {
      i--;
    }
    this.queue.splice(i, 0, job);
  }

  private async pump(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      while (this.queue.length > 0) {
        const job = this.queue.shift();
        if (!job) break;
        try {
          await job.run();
        } catch (_e) {
          // run() 已把异常交给调用方的 promise，这里只保证队列继续往下走。
        }
      }
    } finally {
      this.running = false;
    }
  }
}
