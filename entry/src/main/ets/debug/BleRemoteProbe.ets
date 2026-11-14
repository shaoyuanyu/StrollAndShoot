import { BleCameraLink } from '../services/BleScanner';
import { CameraService } from '../services/CameraService';

/**
 * 蓝牙遥控探针（仅调试包，1.69.1）。
 *
 * 目的：验证 Z50II 的 `0x2020`（LSS_STATUS_FOR_CONTROL）/ `0x2021`
 * （LSS_CONTROL_POINT_FOR_CONTROL）是不是官方 SnapBridge 的「蓝牙遥控」通道。
 * 2.14.3 APK 给出的协议（`bleclient/H$a` 的编码器、`G$a` 的解析器）：
 *
 *   u16 LE 总长 | u8 opcode | u8 0 | body…
 *
 * - `0x01` 能力查询（4B，无 body）
 * - `0x10` 配置（4B）
 * - `0x11` 进/出遥控（5B：body = mode，1 = 进入，0 = 退出）
 * - `0x12` 按键（6B：body = keyCode, keyOperation；ON=1 / OFF=0）
 * - `0x13` 拍摄信息 / `0x14` 特殊拍摄 / `0x15` 回放（本探针暂不覆盖）
 *
 * 响应从 `0x2021` 的 **indication** 回来（`u16 | u8 op | u8 code`），
 * 状态（拍摄状态/禁止原因）从 `0x2020` 的 indication 推。所以第一步必须先
 * `enableIndication` 两条特征 —— 上一轮 1.68.5 的失败正是「写成功、没开指示」。
 *
 * 触发：`aa start ... --ps blectl <mode>`（仅调试包）。前提：相机醒着、App 的
 * BLE 已配对连着。不写持久化；只在用户显式调用的调试命令里碰 0x2020/0x2021。
 *
 * mode：
 * - `feature` 开指示 + 发 0x01 能力查询（先看相机认不认这条通道）
 * - `on` / `off` 进出遥控模式
 * - `shot` 半按 ON→半按 OFF→全按 ON→全按 OFF
 * - `movie` 录像键 ON→OFF
 * - `config` 发 0x10 配置查询
 * - `status` 只读 0x2020 / 0x2081 的当前值
 *
 * 注意：相机侧一旦把控制点判成 busy（1.68.5 那次），要断电重启才恢复；
 * 探针每轮只发一笔请求，失败就停，不循环重试。
 */
export class BleRemoteProbe {
  private static readonly CH_STATUS = '00002020-3dd4-4255-8d62-6dc7b9bd5561';
  private static readonly CH_CONTROL = '00002021-3dd4-4255-8d62-6dc7b9bd5561';
  private static readonly CH_CAPTURE = '00002081-3dd4-4255-8d62-6dc7b9bd5561';

  private static readonly OP_FEATURE = 0x01;
  private static readonly OP_CONFIG = 0x10;
  private static readonly OP_REMOTE = 0x11;
  private static readonly OP_KEY = 0x12;

  /** 官方 `KeyCode`：2 半按、3 全按、4 录像。 */
  private static readonly KEY_HALF = 2;
  private static readonly KEY_FULL = 3;
  private static readonly KEY_MOVIE = 4;
  /** 官方 `KeyOperation`：0 OFF、1 ON。 */
  private static readonly OP_OFF = 0;
  private static readonly OP_ON = 1;

  private static log(msg: string): void {
    try {
      CameraService.getInstance().getLog().add(`[BLECTL] ${msg}`);
    } catch (_e) {
      // 日志不可用不影响探针
    }
  }

  static run(arg: string): void {
    const mode = arg.trim();
    let task: Promise<void>;
    if (mode === 'on' || mode === 'off') {
      task = BleRemoteProbe.remote(mode === 'on');
    } else if (mode === 'shot') {
      task = BleRemoteProbe.shot();
    } else if (mode === 'movie') {
      task = BleRemoteProbe.movie();
    } else if (mode === 'config') {
      task = BleRemoteProbe.config();
    } else if (mode === 'status') {
      task = BleRemoteProbe.status();
    } else {
      task = BleRemoteProbe.feature();
    }
    task.catch((err: Error) => {
      BleRemoteProbe.log(`异常终止: ${err.message}`);
    });
  }

  /** 组一帧：`u16 总长 | u8 op | u8 0 | body`。 */
  private static frame(op: number, body: number[]): Uint8Array {
    const size = 4 + body.length;
    const out = new Uint8Array(size);
    out[0] = size & 0xff;
    out[1] = (size >> 8) & 0xff;
    out[2] = op;
    out[3] = 0;
    for (let i = 0; i < body.length; i++) {
      out[4 + i] = body[i];
    }
    return out;
  }

  /** 取链路、开两条指示、挂原始通知日志。 */
  private static async prepare(): Promise<BleCameraLink | null> {
    const link = CameraService.getInstance().getBleLinkForProbe();
    if (link === null || !link.connected) {
      BleRemoteProbe.log('BLE 未连接：先把相机连上（蓝牙待机）再跑');
      return null;
    }
    link.onAnyNotification = (uuid: string, value: Uint8Array): void => {
      BleRemoteProbe.log(`← ${BleRemoteProbe.short(uuid)} ${BleRemoteProbe.hex(value)}`);
    };
    for (const ch of [BleRemoteProbe.CH_STATUS, BleRemoteProbe.CH_CONTROL]) {
      try {
        await link.enableIndication(ch);
        BleRemoteProbe.log(`指示已开 ${BleRemoteProbe.short(ch)}`);
      } catch (err) {
        BleRemoteProbe.log(`开指示失败 ${BleRemoteProbe.short(ch)}: ${(err as Error).message}`);
      }
      await BleRemoteProbe.sleep(300);
    }
    return link;
  }

  private static async write(link: BleCameraLink, label: string, frame: Uint8Array): Promise<boolean> {
    try {
      await link.writeCharacteristic(BleRemoteProbe.CH_CONTROL, frame);
      BleRemoteProbe.log(`→ ${label} ${BleRemoteProbe.hex(frame)}`);
      return true;
    } catch (err) {
      BleRemoteProbe.log(`→ ${label} 写入失败: ${(err as Error).message}`);
      return false;
    }
  }

  private static async feature(): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    if (!await BleRemoteProbe.write(link, '能力查询 0x01', BleRemoteProbe.frame(BleRemoteProbe.OP_FEATURE, []))) return;
    await BleRemoteProbe.sleep(2500);
    BleRemoteProbe.log('能力查询结束（2.5 秒内没有 ← 就说明相机不认这一笔）');
  }

  private static async config(): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    if (!await BleRemoteProbe.write(link, '配置查询 0x10', BleRemoteProbe.frame(BleRemoteProbe.OP_CONFIG, []))) return;
    await BleRemoteProbe.sleep(2500);
    BleRemoteProbe.log('配置查询结束');
  }

  private static async remote(on: boolean): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    const label = on ? '进入遥控 0x11=1' : '退出遥控 0x11=0';
    if (!await BleRemoteProbe.write(link, label,
      BleRemoteProbe.frame(BleRemoteProbe.OP_REMOTE, [on ? 1 : 0]))) return;
    await BleRemoteProbe.sleep(2000);
    BleRemoteProbe.log(`${label} 结束`);
  }

  private static async shot(): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    const steps: number[][] = [
      [BleRemoteProbe.KEY_HALF, BleRemoteProbe.OP_ON],
      [BleRemoteProbe.KEY_HALF, BleRemoteProbe.OP_OFF],
      [BleRemoteProbe.KEY_FULL, BleRemoteProbe.OP_ON],
      [BleRemoteProbe.KEY_FULL, BleRemoteProbe.OP_OFF]
    ];
    for (const step of steps) {
      const label = `按键 ${BleRemoteProbe.keyName(step[0])} ${step[1] === 1 ? 'ON' : 'OFF'}`;
      if (!await BleRemoteProbe.write(link, label, BleRemoteProbe.frame(BleRemoteProbe.OP_KEY, step))) return;
      await BleRemoteProbe.sleep(700);
    }
    BleRemoteProbe.log('快门序列结束（相机没反应说明 0x11 还没进遥控，先跑 on）');
  }

  private static async movie(): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    if (!await BleRemoteProbe.write(link, '录像 ON',
      BleRemoteProbe.frame(BleRemoteProbe.OP_KEY, [BleRemoteProbe.KEY_MOVIE, BleRemoteProbe.OP_ON]))) return;
    await BleRemoteProbe.sleep(800);
    if (!await BleRemoteProbe.write(link, '录像 OFF',
      BleRemoteProbe.frame(BleRemoteProbe.OP_KEY, [BleRemoteProbe.KEY_MOVIE, BleRemoteProbe.OP_OFF]))) return;
    await BleRemoteProbe.sleep(1500);
  }

  private static async status(): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    const status = await link.readWithReason(BleRemoteProbe.CH_STATUS);
    BleRemoteProbe.log(status.value === null
      ? `读 0x2020 失败: ${status.error}`
      : `0x2020 = ${BleRemoteProbe.hex(status.value)}`);
    const capture = await link.readWithReason(BleRemoteProbe.CH_CAPTURE);
    BleRemoteProbe.log(capture.value === null
      ? `读 0x2081 失败: ${capture.error}`
      : `0x2081 = ${BleRemoteProbe.hex(capture.value)}`);
  }

  private static keyName(code: number): string {
    if (code === BleRemoteProbe.KEY_HALF) return '半按';
    if (code === BleRemoteProbe.KEY_FULL) return '全按';
    if (code === BleRemoteProbe.KEY_MOVIE) return '录像';
    return `key${code}`;
  }

  private static short(uuid: string): string {
    return uuid.length >= 8 ? uuid.slice(4, 8) : uuid;
  }

  private static hex(value: Uint8Array): string {
    let out = '';
    for (let i = 0; i < value.length; i++) {
      out += (value[i] < 16 ? '0' : '') + value[i].toString(16) + ' ';
    }
    return `[${out.trim()}]`;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }
}
