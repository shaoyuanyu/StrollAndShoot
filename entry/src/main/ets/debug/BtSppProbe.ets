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
    BtSppProbe.log(`开始（frame=${parsed.frame} uuid=${parsed.uuidKey}`
      + ` secure=${parsed.secure} chunk=${BtSppProbe.SPP_CHUNK}）`);
    const svc = CameraService.getInstance();
    BtSppProbe.log(`当前 BLE: connected=${svc.bleConnected} paired=${svc.bleSerial !== ''}`
      + ` mode=${svc.linkMode}`);
    if (parsed.establish !== 0) {
      // 先写 0x2005 的 BTC 位（0x02 只经典、0x03 经典+WiFi），再连 SPP：
      // 官方 SnapBridge 是「BLE 认证 → 经典绑定 → 建立 BTC」这条顺序。
      const ok = await svc.writeBleEstablishmentForProbe(parsed.establish);
      BtSppProbe.log(`触发 0x2005=0x${parsed.establish.toString(16)} ${ok ? '已写' : '没写成功'}`);
      await BtSppProbe.sleep(1200);
    }
    if (parsed.drop) {
      // 让出 BLE 但**不写 0x80**：官方在经典绑定后可能是「BLE 让位、经典起来」
      // 这个顺序；正常 disconnectBle() 会写 0x80 把 BTC 位抹掉，所以单独走这里。
      await svc.dropBleForProbe();
      await BtSppProbe.sleep(5000);
    }
    if (arg.trim().startsWith('listen')) {
      await BtSppProbe.runListen(arg.trim());
      return;
    }
    const addr = BtSppProbe.findCamera();
    if (addr === '') {
      BtSppProbe.log('没找到相机的经典地址：先配对，且相机要醒着');
      return;
    }
    const uuid = BtSppProbe.uuidOf(parsed.uuidKey);
    BtSppProbe.log(`目标 ${addr}，UUID ${uuid}`);
    const socketId = await BtSppProbe.connect(addr, uuid, parsed.secure);
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

  /**
   * 反过来等相机连进来（SnapBridge 在手机侧跑 SPP 服务端）。
   *
   * 依据：COOLPIX A1000 的实测记录里，经典绑定完成后相机会主动发起 RFCOMM，
   * 主机没有 SPP 服务端时相机会一直等（甚至冻结）——说明相机是 RFCOMM 客户端，
   * 手机（SnapBridge）应该 `sppListen` 等它连。参数 `listen-btc` / `listen-3`
   * 会先写 `0x2005 = 0x02 / 0x03`（官方建 BTC 通道时用的位）再开服务端。
   */
  private static async runListen(arg: string): Promise<void> {
    let establish = 0;
    if (arg.includes('btc')) establish = 0x02;
    if (arg.includes('3')) establish = 0x03;
    if (establish !== 0) {
      const ok = await CameraService.getInstance().writeBleEstablishmentForProbe(establish);
      BtSppProbe.log(`触发 0x2005=0x${establish.toString(16)} ${ok ? '已写' : '没写成功'}`);
      await BtSppProbe.sleep(1000);
    }
    const serverId = await BtSppProbe.startServer(BtSppProbe.UUID_STANDARD);
    if (serverId < 0) return;
    try {
      const clientId = await BtSppProbe.accept(serverId, 30000);
      if (clientId < 0) return;
      try {
        await BtSppProbe.writeAll(clientId, rawPtp.buildOpenSession(1));
        await BtSppProbe.sleep(400);
        await BtSppProbe.writeAll(clientId, rawPtp.buildGetDeviceInfo());
        await BtSppProbe.readFor(clientId, 6000);
      } finally {
        try {
          btSocket.sppCloseClientSocket(clientId);
          BtSppProbe.log('客户端 socket 已关闭');
        } catch (err) {
          BtSppProbe.log(`关客户端 socket 失败: ${(err as BusinessError).message}`);
        }
      }
    } finally {
      try {
        btSocket.sppCloseServerSocket(serverId);
        BtSppProbe.log('server 已关闭');
      } catch (err) {
        BtSppProbe.log(`关 server 失败: ${(err as BusinessError).message}`);
      }
      BtSppProbe.log('结束');
    }
  }

  private static startServer(uuid: string): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        BtSppProbe.log('sppListen 超时（8s）');
        resolve(-1);
      }, 8000);
      try {
        const options: btSocket.SppOptions = {
          uuid: uuid,
          secure: true,
          type: btSocket.SppType.SPP_RFCOMM
        };
        btSocket.sppListen('StrollAndShoot', options, (err: BusinessError, serverId: number) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (err) {
            BtSppProbe.log(`sppListen 失败 code=${err.code} msg=${err.message}`);
            resolve(-1);
            return;
          }
          BtSppProbe.log(`sppListen 成功 server=${serverId}（UUID ${uuid}），等相机连进来`);
          resolve(serverId);
        });
      } catch (err) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        BtSppProbe.log(`sppListen 异常: ${(err as BusinessError).message}`);
        resolve(-1);
      }
    });
  }

  private static accept(serverId: number, ms: number): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        BtSppProbe.log(`sppAccept 超时（${ms / 1000}s）：没有客户端连进来`);
        resolve(-1);
      }, ms);
      try {
        btSocket.sppAccept(serverId, (err: BusinessError, clientId: number) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (err) {
            BtSppProbe.log(`sppAccept 失败 code=${err.code} msg=${err.message}`);
            resolve(-1);
            return;
          }
          BtSppProbe.log(`相机连进来了 client=${clientId}`);
          resolve(clientId);
        });
      } catch (err) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        BtSppProbe.log(`sppAccept 异常: ${(err as BusinessError).message}`);
        resolve(-1);
      }
    });
  }

  private static parseArg(arg: string): ProbeArg {
    const raw = arg.trim();
    const out: ProbeArg = { frame: 'usb', uuidKey: '1101', secure: true, establish: 0, drop: false };
    if (raw === '') return out;
    const parts = raw.split('-');
    const frame = parts[0];
    if (frame === 'ip' || frame === 'usb-noopen' || frame === 'usb') out.frame = frame;
    for (const p of parts) {
      if (p === '1101' || p === 'de00' || p === 'de01') out.uuidKey = p;
      // 官方 SnapBridge 建立 RFCOMM 用的是 createInsecureRfcommSocket*（见
      // SERVICES.md 的 smali 证据），所以 insecure 是一个要单独试的分支。
      if (p === 'insecure') out.secure = false;
      if (p === 'btc') out.establish = 0x02;
      if (p === '3') out.establish = 0x03;
      if (p === 'drop') out.drop = true;
    }
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

  private static connect(addr: string, uuid: string, secure: boolean): Promise<number> {
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
          secure: secure,
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
  secure: boolean;
  /** 连接前先写的 0x2005 值：0 不写，0x02 经典，0x03 经典+WiFi。 */
  establish: number;
  /** 连接前先断开 BLE（不写 0x2005=0x80）。 */
  drop: boolean;
}
