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
 * - `shot2` / `shot3` 官方触摸序列 / 半按保持 1.5 秒
 * - `movie` 录像键 ON→OFF
 * - `config` 发 0x10 配置查询
 * - `status` 只读 0x2020 / 0x2081 的当前值
 * - `interval` / `lapse` / `focus` 特殊拍摄开始（0x14：1/2/3 + START）
 * - `stop1` / `stop2` / `stop3` 特殊拍摄停止（0x14：对应 functionCode + STOP）
 * - `play` / `menu` / `up` / `down` / `left` / `right` / `ok` 单键轻点（1.71.0）
 * - `cable` 读 0x200a 并订上通知（1.71.0）
 *
 * 注意：相机侧一旦把控制点判成 busy（1.68.5 那次），要断电重启才恢复；
 * 探针每轮只发一笔请求，失败就停，不循环重试。
 */
export class BleRemoteProbe {
  private static readonly CH_STATUS = '00002020-3dd4-4255-8d62-6dc7b9bd5561';
  private static readonly CH_CONTROL = '00002021-3dd4-4255-8d62-6dc7b9bd5561';
  private static readonly CH_CAPTURE = '00002081-3dd4-4255-8d62-6dc7b9bd5561';
  private static readonly CH_CABLE = '0000200a-3dd4-4255-8d62-6dc7b9bd5561';

  private static readonly OP_FEATURE = 0x01;
  private static readonly OP_CONFIG = 0x10;
  private static readonly OP_REMOTE = 0x11;
  private static readonly OP_KEY = 0x12;
  private static readonly OP_SHOOTING_EVENT = 0x14;

  /** 官方 `KeyCode`：2 半按、3 全按、4 录像、5 菜单、6 回放、7 确定、8~11 方向。 */
  private static readonly KEY_HALF = 2;
  private static readonly KEY_FULL = 3;
  private static readonly KEY_MOVIE = 4;
  private static readonly KEY_MENU = 5;
  private static readonly KEY_PLAYBACK = 6;
  private static readonly KEY_OK = 7;
  private static readonly KEY_UP = 8;
  private static readonly KEY_DOWN = 9;
  private static readonly KEY_RIGHT = 10;
  private static readonly KEY_LEFT = 11;
  /** 官方 `KeyOperation`：0 OFF、1 ON。 */
  private static readonly OP_OFF = 0;
  private static readonly OP_ON = 1;
  /** `0x14` 的 controlInfo：1 START、2 STOP。 */
  private static readonly SHOOT_START = 1;
  private static readonly SHOOT_STOP = 2;

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
    } else if (mode === 'shot2') {
      task = BleRemoteProbe.shotOfficial();
    } else if (mode === 'shot3') {
      task = BleRemoteProbe.shotHold();
    } else if (mode === 'movie') {
      task = BleRemoteProbe.movie();
    } else if (mode === 'config') {
      task = BleRemoteProbe.config();
    } else if (mode === 'status') {
      task = BleRemoteProbe.status();
    } else if (mode === 'interval' || mode === 'lapse' || mode === 'focus') {
      const fc = mode === 'interval' ? 1 : (mode === 'lapse' ? 2 : 3);
      task = BleRemoteProbe.shootingEvent(fc, BleRemoteProbe.SHOOT_START);
    } else if (mode.startsWith('stop')) {
      const fc = mode.length > 4 ? Number(mode.slice(4)) : 1;
      task = BleRemoteProbe.shootingEvent(Number.isNaN(fc) ? 1 : fc, BleRemoteProbe.SHOOT_STOP);
    } else if (mode === 'play') {
      task = BleRemoteProbe.keyTap(BleRemoteProbe.KEY_PLAYBACK, '回放');
    } else if (mode === 'menu') {
      task = BleRemoteProbe.keyTap(BleRemoteProbe.KEY_MENU, '菜单');
    } else if (mode === 'up') {
      task = BleRemoteProbe.keyTap(BleRemoteProbe.KEY_UP, '上');
    } else if (mode === 'down') {
      task = BleRemoteProbe.keyTap(BleRemoteProbe.KEY_DOWN, '下');
    } else if (mode === 'left') {
      task = BleRemoteProbe.keyTap(BleRemoteProbe.KEY_LEFT, '左');
    } else if (mode === 'right') {
      task = BleRemoteProbe.keyTap(BleRemoteProbe.KEY_RIGHT, '右');
    } else if (mode === 'ok') {
      task = BleRemoteProbe.keyTap(BleRemoteProbe.KEY_OK, '确定');
    } else if (mode === 'cable') {
      task = BleRemoteProbe.cable();
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
    await BleRemoteProbe.logStatus(link, '开始前');

    await BleRemoteProbe.press(link, BleRemoteProbe.KEY_HALF, BleRemoteProbe.OP_ON, '半按 ON', 450);
    await BleRemoteProbe.logStatus(link, '半按后');
    await BleRemoteProbe.press(link, BleRemoteProbe.KEY_HALF, BleRemoteProbe.OP_OFF, '半按 OFF', 250);
    await BleRemoteProbe.press(link, BleRemoteProbe.KEY_FULL, BleRemoteProbe.OP_ON, '全按 ON', 150);
    await BleRemoteProbe.logStatus(link, '全按后 150ms');
    await BleRemoteProbe.sleep(450);
    await BleRemoteProbe.logStatus(link, '全按后 600ms');
    await BleRemoteProbe.press(link, BleRemoteProbe.KEY_FULL, BleRemoteProbe.OP_OFF, '全按 OFF', 900);
    await BleRemoteProbe.logStatus(link, '释放后');
    BleRemoteProbe.log('快门序列结束（相机没反应说明 0x11 还没进遥控，先跑 on）');
  }

  /**
   * 官方触摸序列：按下 = 半按 ON + 全按 ON，松开 = 全按 OFF + 半按 OFF。
   *
   * `i7/x.smali` 的 ACTION_DOWN 分支就是「半按 ON → 全按 ON」连着发；
   * 之前我们在松手时才发全按、且先发了半按 OFF，相机可能因此不释放快门。
   */
  private static async shotOfficial(): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    await BleRemoteProbe.logStatus(link, '开始前');
    if (!await BleRemoteProbe.press(link, BleRemoteProbe.KEY_HALF, BleRemoteProbe.OP_ON, '半按 ON', 120)) return;
    if (!await BleRemoteProbe.press(link, BleRemoteProbe.KEY_FULL, BleRemoteProbe.OP_ON, '全按 ON', 500)) return;
    await BleRemoteProbe.logStatus(link, '全按后');
    if (!await BleRemoteProbe.press(link, BleRemoteProbe.KEY_FULL, BleRemoteProbe.OP_OFF, '全按 OFF', 200)) return;
    await BleRemoteProbe.press(link, BleRemoteProbe.KEY_HALF, BleRemoteProbe.OP_OFF, '半按 OFF', 400);
    await BleRemoteProbe.logStatus(link, '释放后');
    BleRemoteProbe.log('shot2 结束（官方序列）');
  }

  /**
   * 半按保持 1.5 秒再全按：官方帮助里「半按对焦」和「快门释放」是两个动作，
   * 中间要给相机完成 AF 的时间；Z50II 默认是焦点优先，AF 没合焦就不释放快门。
   */
  private static async shotHold(): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    await BleRemoteProbe.logStatus(link, '开始前');
    if (!await BleRemoteProbe.press(link, BleRemoteProbe.KEY_HALF, BleRemoteProbe.OP_ON, '半按 ON', 1500)) return;
    await BleRemoteProbe.logStatus(link, '半按 1.5s 后');
    if (!await BleRemoteProbe.press(link, BleRemoteProbe.KEY_FULL, BleRemoteProbe.OP_ON, '全按 ON', 600)) return;
    await BleRemoteProbe.logStatus(link, '全按后');
    if (!await BleRemoteProbe.press(link, BleRemoteProbe.KEY_FULL, BleRemoteProbe.OP_OFF, '全按 OFF', 250)) return;
    await BleRemoteProbe.press(link, BleRemoteProbe.KEY_HALF, BleRemoteProbe.OP_OFF, '半按 OFF', 400);
    await BleRemoteProbe.logStatus(link, '释放后');
    BleRemoteProbe.log('shot3 结束（半按保持 1.5s）');
  }

  /** 发一个按键并等 [gapMs]，失败返回 false。 */
  private static async press(link: BleCameraLink, key: number, op: number,
                             label: string, gapMs: number): Promise<boolean> {
    if (!await BleRemoteProbe.write(link, label,
      BleRemoteProbe.frame(BleRemoteProbe.OP_KEY, [key, op]))) return false;
    await BleRemoteProbe.sleep(gapMs);
    return true;
  }

  /** 读 0x2020 并把拍摄状态/限制位解出来写日志（不依赖通知）。 */
  private static async logStatus(link: BleCameraLink, when: string): Promise<void> {
    const r = await link.readWithReason(BleRemoteProbe.CH_STATUS);
    if (r.value === null) {
      BleRemoteProbe.log(`${when} 读 0x2020 失败: ${r.error}`);
      return;
    }
    const v = r.value;
    const main = v.length > 0 ? v[0] : -1;
    const sub = v.length > 1 ? v[1] : -1;
    const capture = v.length > 2 ? v[2] : -1;
    const restriction = v.length > 3 ? v[3] : -1;
    BleRemoteProbe.log(`${when} 状态 main=${main} sub=${sub} capture=${capture}`
      + ` restriction=0x${restriction.toString(16)}`);
    await BleRemoteProbe.sleep(150);
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

  /**
   * 特殊拍摄启停（1.71.0）：`06 00 14 00 <functionCode> <controlInfo>`。
   *
   * functionCode：1 间隔定时、2 延时摄影、3 焦点移位；controlInfo 1 开始、2 停止。
   * 相机按自己菜单里的间隔/张数拍，所以开始前要在相机上把「间隔定时拍摄」设好。
   */
  private static async shootingEvent(fc: number, control: number): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    await BleRemoteProbe.logStatus(link, '开始前');
    const label = `特殊拍摄 fc=${fc} control=${control}`;
    if (!await BleRemoteProbe.write(link, label,
      BleRemoteProbe.frame(BleRemoteProbe.OP_SHOOTING_EVENT, [fc, control]))) return;
    await BleRemoteProbe.sleep(2500);
    await BleRemoteProbe.logStatus(link, '2.5 秒后');
    BleRemoteProbe.log('特殊拍摄结束（响应码 1 = 成功、4 = 相机拒绝：多半没设间隔）');
  }

  /** 单键轻点（1.71.0）：ON → 90ms → OFF，和页面里 `bleRemoteKeyTap` 同一条序列。 */
  private static async keyTap(key: number, label: string): Promise<void> {
    const link = await BleRemoteProbe.prepare();
    if (link === null) return;
    await BleRemoteProbe.logStatus(link, `${label}前`);
    if (!await BleRemoteProbe.press(link, key, BleRemoteProbe.OP_ON, `${label} ON`, 90)) return;
    await BleRemoteProbe.press(link, key, BleRemoteProbe.OP_OFF, `${label} OFF`, 1200);
    await BleRemoteProbe.logStatus(link, `${label}后`);
  }

  /** 线缆接入（1.71.0）：读 0x200a 并订通知，插拔数据线看有没有 ←。 */
  private static async cable(): Promise<void> {
    const link = CameraService.getInstance().getBleLinkForProbe();
    if (link === null || !link.connected) {
      BleRemoteProbe.log('BLE 未连接：先把相机连上（蓝牙待机）再跑');
      return;
    }
    link.onAnyNotification = (uuid: string, value: Uint8Array): void => {
      BleRemoteProbe.log(`← ${BleRemoteProbe.short(uuid)} ${BleRemoteProbe.hex(value)}`);
    };
    const r = await link.readWithReason(BleRemoteProbe.CH_CABLE);
    BleRemoteProbe.log(r.value === null
      ? `读 0x200a 失败: ${r.error}`
      : `0x200a = ${BleRemoteProbe.hex(r.value)}（bit0 = 数据线已插入）`);
    try {
      await link.enableNotification(BleRemoteProbe.CH_CABLE);
      BleRemoteProbe.log('0x200a 通知已开：插/拔数据线看 ← 有没有变化');
    } catch (err) {
      BleRemoteProbe.log(`0x200a 通知开启失败: ${(err as Error).message}`);
    }
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
