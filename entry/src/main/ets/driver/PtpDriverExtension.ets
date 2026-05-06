import { DriverExtensionAbility } from '@kit.DriverDevelopmentKit';
import { rpc } from '@kit.IPCKit';
import { Want } from '@kit.AbilityKit';
import rawPtpDriver from 'libentry.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'PtpDriver';

interface PtpDriverApi {
  init(): number;
  initDevice(deviceId: number): boolean;
  releaseDevice(): void;
  execute(cmd: string, arg: number): Uint8Array | null;
  getLargeData(handle: number): Uint8Array | null;
}

const driver = rawPtpDriver as PtpDriverApi;

class PtpStub extends rpc.RemoteObject {
  constructor() {
    super('ptp_stub');
  }

  onRemoteMessageRequest(code: number, data: rpc.MessageSequence,
                         reply: rpc.MessageSequence, _option: rpc.MessageOption): boolean {
    try {
      switch (code) {
        case 1: { // initDevice
          const deviceId = data.readInt();
          const ok = driver.initDevice(deviceId);
          reply.writeInt(ok ? 1 : 0);
          break;
        }
        case 2: { // releaseDevice
          driver.releaseDevice();
          reply.writeInt(1);
          break;
        }
        case 3: { // execute (meta & thumb)
          const cmd = data.readString();
          const arg = data.readInt();
          const result = driver.execute(cmd, arg);
          if (result) {
            reply.writeInt(result.length);
            const arr = new Array<number>(result.length);
            for (let i = 0; i < result.length; i++) { arr[i] = result[i]; }
            reply.writeByteArray(arr);
          } else {
            reply.writeInt(-1);
          }
          break;
        }
        case 10: { // getLargeData (full photo)
          const handle = data.readInt();
          const result = driver.getLargeData(handle);
          if (result) {
            reply.writeInt(result.length);
            const arr = new Array<number>(result.length);
            for (let i = 0; i < result.length; i++) { arr[i] = result[i]; }
            reply.writeByteArray(arr);
          } else {
            reply.writeInt(-1);
          }
          break;
        }
        default:
          hilog.warn(0x0000, TAG, 'Unknown IPC code: %{public}d', code);
          reply.writeInt(-1);
          break;
      }
    } catch (err) {
      hilog.error(0x0000, TAG, 'IPC error: %{public}s', JSON.stringify(err));
      return false;
    }
    return true;
  }

  getDescriptor(): string {
    return 'ptp_stub';
  }
}

export default class PtpDriverExtension extends DriverExtensionAbility {
  onInit(want: Want): void {
    hilog.info(0x0000, TAG, 'onInit, want: %{public}s', want.abilityName ?? '');
    const ret = driver.init();
    hilog.info(0x0000, TAG, 'DDK init result: %{public}d', ret);
  }

  onConnect(want: Want): rpc.RemoteObject {
    hilog.info(0x0000, TAG, 'onConnect, want: %{public}s', want.abilityName ?? '');
    return new PtpStub();
  }

  onDisconnect(want: Want): void {
    hilog.info(0x0000, TAG, 'onDisconnect, want: %{public}s', want.abilityName ?? '');
    driver.releaseDevice();
  }

  onRelease(): void {
    hilog.info(0x0000, TAG, 'onRelease');
  }
}
