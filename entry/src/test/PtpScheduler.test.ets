import { describe, it, expect } from '@ohos/hypium';
import usbManager from '@ohos.usbManager';
import { PtpPriority, type PtpTransport, type DeviceInfo, type ObjectInfo,
  type ObjectPropEntry, type ObjectPropList } from '../main/ets/pages/PtpHost';
import { PtpScheduler } from '../main/ets/services/PtpScheduler';

/**
 * 只验证队列行为，不碰 USB。
 * 每个取图请求都卡在一个可控的 promise 上，测试手动放行，观察执行顺序。
 */
class FakeTransport implements PtpTransport {
  order: string[] = [];
  private pending: Array<() => void> = [];

  get connectedDeviceName(): string {
    return 'fake';
  }

  get sessionConflict(): boolean {
    return false;
  }

  async connect(_device: usbManager.USBDevice, _priority?: PtpPriority): Promise<boolean> {
    return true;
  }

  async getDeviceInfo(_priority?: PtpPriority): Promise<DeviceInfo | null> {
    return null;
  }

  async getStorageIDs(_priority?: PtpPriority): Promise<number[]> {
    return [];
  }

  async getObjectHandles(_storageId: number, _parent?: number, _formatCode?: number,
    _priority?: PtpPriority): Promise<number[]> {
    return [];
  }

  async getObjectInfo(_handle: number, _priority?: PtpPriority): Promise<ObjectInfo | null> {
    return null;
  }

  getThumb(handle: number, _priority?: PtpPriority): Promise<Uint8Array | null> {
    return this.block(`thumb-${handle}`);
  }

  getObject(handle: number, _priority?: PtpPriority): Promise<Uint8Array | null> {
    return this.block(`object-${handle}`);
  }

  async getPartialObject(_handle: number, _offset: number, _maxBytes: number,
    _priority?: PtpPriority): Promise<Uint8Array | null> {
    return new Uint8Array(0);
  }

  async getObjectPropList(_objectHandle: number, _formatCode: number, _propertyCode: number,
    _groupCode: number, _depth: number, _priority?: PtpPriority): Promise<ObjectPropList> {
    const objects: ObjectPropEntry[] = [];
    const list: ObjectPropList = {
      objects: objects, codes: [], declared: 0, complete: false, bytes: 0, head: ''
    };
    return list;
  }

  async closeSessionAndPipe(_priority?: PtpPriority): Promise<void> {
  }

  releaseOne(): void {
    const next = this.pending.shift();
    if (next) next();
  }

  private block(label: string): Promise<Uint8Array | null> {
    this.order.push(label);
    return new Promise<Uint8Array | null>((resolve: (value: Uint8Array | null) => void) => {
      this.pending.push(() => resolve(new Uint8Array(1)));
    });
  }
}

function tick(): Promise<void> {
  return new Promise<void>((resolve: () => void) => { setTimeout(resolve, 0); });
}

export default function ptpSchedulerTest() {
  describe('PtpScheduler', () => {
    it('串行执行，且 FOREGROUND 插到 SCAN 前面', 0, async () => {
      const fake = new FakeTransport();
      const scheduler = new PtpScheduler(fake);

      const first = scheduler.getThumb(1, PtpPriority.SCAN);
      const second = scheduler.getThumb(2, PtpPriority.SCAN);
      const urgent = scheduler.getObject(3, PtpPriority.FOREGROUND);

      // 队列是串行的：只有第一笔真正开始。
      expect(fake.order.join(',')).assertEqual('thumb-1');

      fake.releaseOne();
      await tick();
      // 第一笔结束后，优先级更高的 foreground 先于第二笔 scan。
      expect(fake.order.join(',')).assertEqual('thumb-1,object-3');

      fake.releaseOne();
      await tick();
      expect(fake.order.join(',')).assertEqual('thumb-1,object-3,thumb-2');

      fake.releaseOne();
      await Promise.all([first, second, urgent]);
    });
  });
}
