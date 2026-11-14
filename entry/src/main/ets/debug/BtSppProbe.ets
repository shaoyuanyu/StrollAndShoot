import { connection as btConnection, socket as btSocket } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import rawPtp from 'libentry.so';
import { BleIdentityStore } from '../services/BleIdentityStore';
import { CameraService } from '../services/CameraService';

/**
 * 蓝牙经典 SPP 探针（仅调试包，2026-11-14）。
 *
 * 背景：官方 SnapBridge 的 2MP 自动传图不是走 BLE，而是
 * **Bluetooth Classic（BTC）+ SPP 上跑 PTP**（静态逆向见 SERVICES.md
 * 「2MP 自动传图走的是蓝牙经典」）。社区目前没有独立实现，也没有字节级
 * 协议文档；这个探针用来在真机上回答三个问题：
 *
 * 1. 相机的经典 SDP 里有没有标准 SPP（`00001101`）？没有的话试尼康
 *    128 位 UUID（`de00` / `de01` 同 BLE 服务那套基址）；
 * 2. 连上 SPP 后，把 PTP 命令按 **PTP/USB 容器**或 **PTP/IP 容器**发过去，
 *    相机回不回？
 * 3. 回的数据长什么样（原始 hex 落 AppLog，取回来再解）。
 *
 * 不写任何持久化、不改连接状态；跑完关 socket。触发方式（应用已在前台）：
 *
 *   hdc shell aa start -a EntryAbility -b <bundle> --ps spp usb
 *   hdc shell aa start -a EntryAbility -b <bundle> --ps spp ip
 *   hdc shell aa start -a EntryAbility -b <bundle> --ps spp usb-de00
 *
 * 参数格式 `[帧格式[-uuidKey]]`：帧格式 `usb`（默认）/ `ip` / `usb-noopen`；
 * uuidKey `1101`（默认）/ `de00` / `de01`。结果看应用日志 `[SPP]` 开头的行。
 */
export class BtSppProbe {
  /** 标准 SPP（RFCOMM）服务 UUID。 */
  private static readonly UUID_STANDARD = '00001101-0000-1000-8000-00805F9B34FB';
  /** 尼康 `de00` 族：与 BLE 服务同基址，经典 SDP 里可能也有同名记录。 */
  private static readonly UUID_DE00 = '0000de00-3dd4-4255-8d62-6dc7b9bd5561';
  private static readonly UUID_DE01 = '0000de01-3dd4-4255-8d62-6dc7b9bd5561';
  /**
   * SPP 单包上限：`0x2004` 尾部那个 4B 字段（本项目真机读到 492），
   * 官方 App 也按它切包（`L3` 从连接配置取 SPP 最大长度）。
   */
  private static readonly SPP_CHUNK = 492;
  private static readonly CONNECT_TIMEOUT_MS = 12000;

  private static log(msg: string): void {
    try {
      CameraService.getInstance().getLog().add(`[SPP] ${msg}`);
    } catch (_e) {
      // 日志不可用时探针照样跑
    }
  }

  /** 探针入口（EntryAbility.onNewWant 在调试包里调）。 */
  static run(arg: string): void {
    BtSppProbe.runInner(arg).catch((err: Error) => {
      BtSppProbe.log(`异常终止: ${err.message}`);
    });
  }

  private static async runInner(arg: string): Promise<void> {
    const parsed = BtSppProbe.parseArg(arg);
    BtSppProbe.log(`开始（frame=${parsed.frame} uuid=${parsed.uuidKey} chunk=${BtSppProbe.SPP_CHUNK}）`);
    const svc = CameraService.getInstance();
    BtSppProbe.log(`当前 BLE: connected=${svc.bleConnected} paired=${svc.bleSerial !== ''}`
      + ` mode=${svc.linkMode}`);
    const addr = BtSppProbe.findCamera();
    if (addr === '') {
      BtSppProbe.log('没找到相机的经典地址：先配对，且相机要醒着');
      return;
    }
    const uuid = BtSppProbe.uuidOf(parsed.uuidKey);
    BtSppProbe.log(`目标 ${addr}，UUID ${uuid}`);
    const socketId = await BtSppProbe.connect(addr, uuid);
    if (socketId < 0) {
      BtSppProbe.log('SPP 没连上，探针结束');
      return;
    }
    try {
      if (parsed.frame === 'ip') {
        await BtSppProbe.writeAll(socketId, BtSppProbe.ptpIpGetDeviceInfo());
        await BtSppProbe.readFor(socketId, 5000);
      } else if (parsed.frame === 'usb-noopen') {
        await BtSppProbe.writeAll(socketId, rawPtp.buildGetDeviceInfo());
        await BtSppProbe.readFor(socketId, 5000);
      } else {
        // 默认：先 OpenSession(1)，再 GetDeviceInfo（与 USB 会话顺序一致）。
        await BtSppProbe.writeAll(socketId, rawPtp.buildOpenSession(1));
        await BtSppProbe.sleep(400);
        await BtSppProbe.writeAll(socketId, rawPtp.buildGetDeviceInfo());
        await BtSppProbe.readFor(socketId, 6000);
      }
    } finally {
      try {
        btSocket.sppCloseClientSocket(socketId);
        BtSppProbe.log('socket 已关闭');
      } catch (err) {
        BtSppProbe.log(`关 socket 失败: ${(err as BusinessError).message}`);
      }
      BtSppProbe.log('结束');
    }
  }

  private static parseArg(arg: string): ProbeArg {
    const raw = arg.trim();
    const out: ProbeArg = { frame: 'usb', uuidKey: '1101' };
    if (raw === '') return out;
    const parts = raw.split('-');
    const frame = parts[0];
    if (frame === 'ip' || frame === 'usb-noopen' || frame === 'usb') out.frame = frame;
    if (parts.length > 1) out.uuidKey = parts[1];
    return out;
  }

  private static uuidOf(key: string): string {
    if (key === 'de00') return BtSppProbe.UUID_DE00;
    if (key === 'de01') return BtSppProbe.UUID_DE01;
    return BtSppProbe.UUID_STANDARD;
  }

  /**
   * 找相机的经典地址。
   *
   * 经典地址没有落盘（首配时只用它做一次 `pairDevice`），所以这里从系统
   * 已配对列表里按名字 / 序列号反查；只有一台已配对设备时直接用它。
   */
  private static findCamera(): string {
    const id = BleIdentityStore.getInstance();
    const wantName = id.cameraName;
    const wantSerial = id.serial;
    BtSppProbe.log(`身份: name=${wantName === '' ? '(空)' : wantName} serial=${wantSerial === '' ? '(空)' : wantSerial}`);
    let paired: string[] = [];
    try {
      paired = btConnection.getPairedDevices();
    } catch (err) {
      BtSppProbe.log(`getPairedDevices 失败: ${(err as BusinessError).message}`);
      return '';
    }
    BtSppProbe.log(`已配对 ${paired.length} 台`);
    let only = '';
    for (const addr of paired) {
      let name = '';
      try {
        name = btConnection.getRemoteDeviceName(addr, false);
      } catch (_e) {
        name = '(读不到名字)';
      }
      BtSppProbe.log(`  ${addr}  ${name}`);
      if (only === '') only = addr;
      const n = BtSppProbe.norm(name);
      if (wantSerial !== '' && n.includes(BtSppProbe.norm(wantSerial))) return addr;
      if (wantName !== '' && n.includes(BtSppProbe.norm(wantName))) return addr;
    }
    if (paired.length === 1) return only;
    return '';
  }

  private static norm(s: string): string {
    return s.replace(/[^a-zA-Z0-9]/g, '').toLowerCase();
  }

  private static connect(addr: string, uuid: string): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        BtSppProbe.log(`sppConnect 超时（${BtSppProbe.CONNECT_TIMEOUT_MS}ms）`);
        resolve(-1);
      }, BtSppProbe.CONNECT_TIMEOUT_MS);
      try {
        const options: btSocket.SppOptions = {
          uuid: uuid,
          secure: true,
          type: btSocket.SppType.SPP_RFCOMM
        };
        btSocket.sppConnect(addr, options, (err: BusinessError, socketId: number) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (err) {
            BtSppProbe.log(`sppConnect 失败 code=${err.code} msg=${err.message}`);
            resolve(-1);
            return;
          }
          BtSppProbe.log(`sppConnect 成功 socket=${socketId}`);
          resolve(socketId);
        });
      } catch (err) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        BtSppProbe.log(`sppConnect 异常: ${(err as BusinessError).message}`);
        resolve(-1);
      }
    });
  }

  /** 按 SPP_CHUNK 切片写出（RFCOMM 单包超过相机声明的大小时会被拒/截断）。 */
  private static async writeAll(socketId: number, bytes: Uint8Array): Promise<void> {
    if (bytes.length === 0) return;
    let sent = 0;
    for (let off = 0; off < bytes.length; off += BtSppProbe.SPP_CHUNK) {
      const end = Math.min(bytes.length, off + BtSppProbe.SPP_CHUNK);
      const slice = bytes.subarray(off, end);
      // ArkTS 下 `subarray().buffer.slice()` 的类型是 ArrayBufferLike，这里复制一份
      // 拿到干净的 ArrayBuffer（SPP 单包很小，复制开销可以忽略）。
      const copy = new Uint8Array(slice.length);
      copy.set(slice);
      await btSocket.sppWriteAsync(socketId, copy.buffer as ArrayBuffer);
      sent += slice.length;
      await BtSppProbe.sleep(30);
    }
    BtSppProbe.log(`→ ${sent}B ${BtSppProbe.hex(bytes)}`);
  }

  private static async readFor(socketId: number, ms: number): Promise<void> {
    const deadline = Date.now() + ms;
    let total = 0;
    while (Date.now() < deadline) {
      const data = await BtSppProbe.readOnce(socketId, 1200);
      if (data === null) continue;
      total += data.length;
      BtSppProbe.log(`← ${data.length}B ${BtSppProbe.hex(data)}`);
    }
    BtSppProbe.log(`读结束：共 ${total}B`);
  }

  /** 单次读：1.2 秒没有数据就返回 null，避免整个探针挂死。 */
  private static readOnce(socketId: number, ms: number): Promise<Uint8Array | null> {
    return new Promise<Uint8Array | null>((resolve: (v: Uint8Array | null) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        resolve(null);
      }, ms);
      btSocket.sppReadAsync(socketId).then((buf: ArrayBuffer) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(new Uint8Array(buf));
      }).catch((err: BusinessError) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        BtSppProbe.log(`读失败 code=${err.code} msg=${err.message}`);
        resolve(null);
      });
    });
  }

  /**
   * PTP/IP 的 OperationRequest（GetDeviceInfo，无参）。
   *
   * 小端：length(u32)=18 + type(u32)=6(OperationRequest) + dataPhase(u32)=1(NoData)
   * + code(u16)=0x1001 + transactionId(u32)=1。
   */
  private static ptpIpGetDeviceInfo(): Uint8Array {
    const bytes = new Uint8Array(18);
    const dv = new DataView(bytes.buffer);
    dv.setUint32(0, 18, true);
    dv.setUint32(4, 6, true);
    dv.setUint32(8, 1, true);
    dv.setUint16(12, 0x1001, true);
    dv.setUint32(14, 1, true);
    return bytes;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private static hex(bytes: Uint8Array): string {
    let out = '';
    for (let i = 0; i < bytes.length && i < 96; i++) {
      const h = bytes[i].toString(16);
      out += (h.length < 2 ? '0' : '') + h + ' ';
    }
    return out + (bytes.length > 96 ? `…(${bytes.length}B)` : '');
  }
}

/** 探针参数：帧格式 + UUID 键。 */
interface ProbeArg {
  frame: string;
  uuidKey: string;
}
