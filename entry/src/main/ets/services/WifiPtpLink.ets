import { socket, connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * PTP/IP 传输层（ISO 15740 / CIPA DC-X005 的尼康方言）。
 *
 * 与 USB 那条链路（`PtpHost.PtpSession`）并列：这里只负责「把 PTP 事务
 * 装进 PTP/IP 帧、在两条 TCP 通道上收发」，不关心 GetObjectInfo 之类的
 * 语义。语义层见 `WifiPtpSession`。
 *
 * 协议要点（依据官方规范 + ZPill / N-Link / Camera_Bridge 的真机实证）：
 * - 包头 8 字节小端：`length u32`（含头）+ `type u32`；
 * - 命令通道先 `InitCommand`，**第二条 TCP 连接**发 `InitEvent`；
 * - 尼康方言：InitCommand 载荷是 `GUID(16B) + UTF-16LE 主机名(含 NUL) + 版本 u32`，
 *   **没有**标准 PTP/IP 的主机名长度前缀；
 * - CmdRequest 的 DataOut 字段恒为 1；
 * - 保活用 Ping(13)/Pong(14)。
 */

/** 单帧上限：防止长度字段被读错后一次性分配巨大缓冲。 */
const MAX_FRAME_BYTES = 64 * 1024 * 1024;

/** 建链超时。 */
const CONNECT_TIMEOUT_MS = 5000;
/** 单笔事务超时（含大数据阶段）。 */
const TRANSACTION_TIMEOUT_MS = 30000;
/** 保活间隔与连续失败上限。 */
const KEEPALIVE_INTERVAL_MS = 15000;
const KEEPALIVE_MAX_MISS = 3;

const PKT_INIT_COMMAND = 1;
const PKT_INIT_COMMAND_ACK = 2;
const PKT_INIT_EVENT = 3;
const PKT_INIT_EVENT_ACK = 4;
const PKT_INIT_FAIL = 5;
const PKT_CMD_REQUEST = 6;
const PKT_CMD_RESPONSE = 7;
const PKT_EVENT = 8;
const PKT_START_DATA = 9;
const PKT_DATA = 10;
const PKT_CANCEL = 11;
const PKT_END_DATA = 12;
const PKT_PING = 13;
const PKT_PONG = 14;

/** 尼康 Android 客户端的固定 GUID（SnapBridge / Camera_Bridge 同款）。 */
const NIKON_CLIENT_GUID: number[] = [
  0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
  0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
];
const PROTOCOL_VERSION = 0x00010000;
const HOST_NAME = 'HarmonyOS Device';

/** 一笔事务的结果：相机响应码、响应参数、数据段。 */
export interface PtpIpResult {
  code: number;
  params: number[];
  data: Uint8Array | null;
}

interface PendingTxn {
  transId: number;
  expectData: boolean;
  chunks: Uint8Array[];
  declared: number;
  resolve: (r: PtpIpResult) => void;
  reject: (e: Error) => void;
  timer: number;
}

interface InitWaiter {
  resolve: (ok: boolean) => void;
  reject: (e: Error) => void;
  timer: number;
}

function u16le(v: number): Uint8Array {
  const out = new Uint8Array(2);
  new DataView(out.buffer).setUint16(0, v & 0xFFFF, true);
  return out;
}

function u32le(v: number): Uint8Array {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, v >>> 0, true);
  return out;
}

function concat(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

/** UTF-16LE + NUL 结尾（尼康 InitCommand / 相机名）。 */
function utf16z(s: string): Uint8Array {
  const out = new Uint8Array((s.length + 1) * 2);
  const view = new DataView(out.buffer);
  for (let i = 0; i < s.length; i++) {
    view.setUint16(i * 2, s.charCodeAt(i), true);
  }
  view.setUint16(s.length * 2, 0, true);
  return out;
}

function readUtf16z(data: Uint8Array, offset: number): string {
  let s = '';
  for (let i = offset; i + 1 < data.length; i += 2) {
    const code = data[i] | (data[i + 1] << 8);
    if (code === 0) break;
    s += String.fromCharCode(code);
  }
  return s;
}

/** 一条连接要绑定的本地网络：地址用于 bind，句柄用于 bindSocket。 */
interface NetworkBinding {
  localAddress: string;
  net: connection.NetHandle;
}

function ipv4ToInt(ip: string): number {
  const parts = ip.split('.');
  if (parts.length !== 4) return -1;
  let v = 0;
  for (const part of parts) {
    const n = Number.parseInt(part, 10);
    if (!Number.isFinite(n) || n < 0 || n > 255) return -1;
    v = ((v << 8) | n) >>> 0;
  }
  return v >>> 0;
}

function sameSubnet(a: string, b: string, prefix: number): boolean {
  const ai = ipv4ToInt(a);
  const bi = ipv4ToInt(b);
  if (ai < 0 || bi < 0 || prefix < 0 || prefix > 32) return false;
  const mask = prefix === 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) >>> 0;
  return (ai & mask) === (bi & mask);
}

/**
 * 找到目标 IP 所属的那个本地网络。
 *
 * 手机同时挂办公网和相机热点时（本项目实测就是 wlan0 10.15.x + wlan1
 * 192.168.43.x），应用 socket 默认绑在系统默认网络上，往热点网段发的 SYN
 * 会从错误的网卡出去，表现是 `2301115 Operation in progress`（SYN 没回音）。
 * 这里按网段匹配，把 socket 绑到相机所在的那张网卡。
 */
async function resolveNetworkBinding(host: string): Promise<NetworkBinding | null> {
  try {
    const nets = await connection.getAllNets();
    for (const net of nets) {
      let props: connection.ConnectionProperties;
      try {
        props = await connection.getConnectionProperties(net);
      } catch (_e) {
        continue;
      }
      const links = props.linkAddresses;
      if (!links || links.length === 0) continue;
      for (const link of links) {
        const local = link.address.address;
        if (sameSubnet(local, host, link.prefixLength)) {
          return { localAddress: local, net: net };
        }
      }
    }
  } catch (_e) {
    // 查询失败就按默认网络走，不阻断连接
  }
  return null;
}

function buildFrame(type: number, payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(8 + payload.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, out.length, true);
  view.setUint32(4, type, true);
  out.set(payload, 8);
  return out;
}

/** 一条 TCP 通道：切帧 + 分发。 */
class PtpIpChannel {
  private tcp: socket.TCPSocket | null = null;
  private rx: Uint8Array = new Uint8Array(0);
  private closed: boolean = false;
  private readonly label: string;
  private readonly onFrame: (type: number, payload: Uint8Array) => void;
  private readonly onBroken: (reason: string) => void;
  private readonly binding: NetworkBinding | null;

  constructor(label: string,
              onFrame: (type: number, payload: Uint8Array) => void,
              onBroken: (reason: string) => void,
              binding: NetworkBinding | null) {
    this.label = label;
    this.onFrame = onFrame;
    this.onBroken = onBroken;
    this.binding = binding;
  }

  async open(host: string, port: number): Promise<boolean> {
    try {
      this.tcp = socket.constructTCPSocketInstance();
      this.tcp.on('message', (info: socket.SocketMessageInfo) => {
        this.feed(info.message);
      });
      this.tcp.on('close', () => {
        if (!this.closed) {
          this.closed = true;
          this.onBroken(`${this.label} closed`);
        }
      });
      this.tcp.on('error', (err: BusinessError) => {
        if (!this.closed) {
          this.closed = true;
          this.onBroken(`${this.label} error ${err.code}: ${err.message}`);
        }
      });
      if (this.binding !== null) {
        // 先 bind 本地地址、再把 socket 绑到对应网络，否则多网卡下会走默认网络。
        const local: socket.NetAddress = { address: this.binding.localAddress, port: 0 };
        await this.tcp.bind(local);
        await this.binding.net.bindSocket(this.tcp);
      }
      const addr: socket.NetAddress = { address: host, port: port };
      const options: socket.TCPConnectOptions = { address: addr, timeout: CONNECT_TIMEOUT_MS };
      await this.tcp.connect(options);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      this.onBroken(`${this.label} connect failed ${e.code}: ${e.message}`);
      return false;
    }
  }

  async send(type: number, payload: Uint8Array): Promise<void> {
    if (!this.tcp) throw new Error(`${this.label}: socket 未建立`);
    const frame = buildFrame(type, payload);
    const options: socket.TCPSendOptions = { data: frame.buffer as ArrayBuffer };
    await this.tcp.send(options);
  }

  async close(): Promise<void> {
    this.closed = true;
    const tcp = this.tcp;
    this.tcp = null;
    if (!tcp) return;
    try {
      await tcp.close();
    } catch (_e) {
      // 已经断开：关闭失败不影响上层清理
    }
  }

  private feed(chunk: ArrayBuffer): void {
    if (this.closed) return;
    const incoming = new Uint8Array(chunk);
    if (incoming.length === 0) return;
    if (this.rx.length === 0) {
      this.rx = incoming;
    } else {
      const merged = new Uint8Array(this.rx.length + incoming.length);
      merged.set(this.rx, 0);
      merged.set(incoming, this.rx.length);
      this.rx = merged;
    }
    while (this.rx.length >= 8) {
      const view = new DataView(this.rx.buffer, this.rx.byteOffset, this.rx.byteLength);
      const length = view.getUint32(0, true);
      if (length < 8 || length > MAX_FRAME_BYTES) {
        this.closed = true;
        this.onBroken(`${this.label} 帧长度异常: ${length}`);
        return;
      }
      if (this.rx.length < length) return;
      const type = view.getUint32(4, true);
      const payload = this.rx.slice(8, length);
      this.rx = this.rx.slice(length);
      this.onFrame(type, payload);
    }
  }
}

/**
 * PTP/IP 双通道连接。
 *
 * 生命周期：`connect()` → 若干 `transaction()` → `close()`。
 * 事务严格串行（`PtpScheduler` 已经在上层保证），所以这里只维护一个
 * pending，不做事务表。
 */
export class WifiPtpLink {
  private command: PtpIpChannel | null = null;
  private event: PtpIpChannel | null = null;
  private connectionId: number = 0;
  private transId: number = 0;
  private pending: PendingTxn | null = null;
  private initWaiter: InitWaiter | null = null;
  private eventWaiter: InitWaiter | null = null;
  private brokenHandler: (reason: string) => void = (_r: string) => {};

  /** 相机在 InitCommandAck 里自报的名字（可能为空）。 */
  cameraName: string = '';
  /** 相机 GUID（InitCommandAck）。 */
  cameraGuid: Uint8Array = new Uint8Array(16);
  /** 事件通道收到的相机事件（0x4002 等）。 */
  onEvent: (code: number, params: number[]) => void = (_c: number, _p: number[]) => {};
  /** 链路断开回调（心跳判死 / socket 关闭）。 */
  onBroken: (reason: string) => void = (_r: string) => {};
  private log: (msg: string) => void = (_m: string) => {};

  setLog(fn: (msg: string) => void): void {
    this.log = fn;
  }

  setBrokenHandler(fn: (reason: string) => void): void {
    this.brokenHandler = fn;
  }

  /**
   * 建立双通道并完成 PTP/IP 初始化握手。
   *
   * 命令通道先发 InitCommand；拿到 Ack 里的 connectionId 后，**再开第二条
   * TCP 连接**发 InitEvent。两条通道都必须成功，否则整个连接作废。
   */
  async connect(host: string, port: number): Promise<boolean> {
    await this.close();

    const binding = await resolveNetworkBinding(host);
    if (binding !== null) {
      this.log(`[PTP/IP] socket 绑定本地 ${binding.localAddress}（目标 ${host}）`);
    }
    const command = new PtpIpChannel('command', (type: number, payload: Uint8Array) => {
      this.handleCommandFrame(type, payload);
    }, (reason: string) => {
      this.failAll(reason);
    }, binding);
    this.command = command;
    this.log(`[PTP/IP] 连接 ${host}:${port} 命令通道`);
    if (!await command.open(host, port)) {
      await this.close();
      return false;
    }

    const initOk = await this.sendInitCommand();
    if (!initOk) {
      if (this.command) await this.command.close();
      this.command = null;
      return false;
    }

    const event = new PtpIpChannel('event', (type: number, payload: Uint8Array) => {
      this.handleEventFrame(type, payload);
    }, (reason: string) => {
      this.failAll(reason);
    }, binding);
    this.event = event;
    if (!await event.open(host, port)) {
      await this.close();
      return false;
    }
    const eventOk = await this.sendInitEvent();
    if (!eventOk) {
      await this.close();
      return false;
    }
    this.log(`[PTP/IP] 握手完成，connectionId=${this.connectionId}，相机="${this.cameraName}"`);
    return true;
  }

  async close(): Promise<void> {
    this.rejectPending('连接已关闭');
    const cmd = this.command;
    const evt = this.event;
    this.command = null;
    this.event = null;
    this.connectionId = 0;
    if (evt) await evt.close();
    if (cmd) await cmd.close();
  }

  /** 发一条 PTP 命令并等响应（可选数据段）。 */
  async transaction(opcode: number, params: number[], expectData: boolean): Promise<PtpIpResult> {
    const command = this.command;
    if (!command) throw new Error('PTP/IP 未连接');
    if (this.pending) throw new Error('PTP/IP 上一笔事务尚未结束');

    const transId = this.nextTransId();
    const parts: Uint8Array[] = [u32le(1), u16le(opcode), u32le(transId)];
    for (const p of params) parts.push(u32le(p));
    const payload = concat(parts);

    return new Promise<PtpIpResult>((resolve: (r: PtpIpResult) => void,
                                     reject: (e: Error) => void) => {
      const timer = setTimeout(() => {
        if (this.pending && this.pending.transId === transId) {
          this.pending = null;
          reject(new Error(`PTP/IP 事务超时 op=0x${opcode.toString(16)}`));
        }
      }, TRANSACTION_TIMEOUT_MS);
      this.pending = {
        transId: transId,
        expectData: expectData,
        chunks: [],
        declared: 0,
        resolve: resolve,
        reject: reject,
        timer: timer
      };
      command.send(PKT_CMD_REQUEST, payload).catch((err: Error) => {
        this.rejectPending(`发送失败: ${err.message}`);
      });
    });
  }

  private nextTransId(): number {
    this.transId = (this.transId + 1) >>> 0;
    if (this.transId === 0) this.transId = 1;
    return this.transId;
  }

  private sendInitCommand(): Promise<boolean> {
    const hostName = utf16z(HOST_NAME);
    const payload = concat([
      new Uint8Array(NIKON_CLIENT_GUID),
      hostName,
      u32le(PROTOCOL_VERSION)
    ]);
    return new Promise<boolean>((resolve: (v: boolean) => void, reject: (e: Error) => void) => {
      const timer = setTimeout(() => {
        this.initWaiter = null;
        reject(new Error('InitCommand 超时'));
      }, CONNECT_TIMEOUT_MS);
      this.initWaiter = { resolve: resolve, reject: reject, timer: timer };
      this.command?.send(PKT_INIT_COMMAND, payload).catch((err: Error) => {
        this.initWaiter = null;
        clearTimeout(timer);
        reject(err);
      });
    });
  }

  private sendInitEvent(): Promise<boolean> {
    const payload = u32le(this.connectionId);
    return new Promise<boolean>((resolve: (v: boolean) => void, reject: (e: Error) => void) => {
      const timer = setTimeout(() => {
        this.eventWaiter = null;
        reject(new Error('InitEvent 超时'));
      }, CONNECT_TIMEOUT_MS);
      this.eventWaiter = { resolve: resolve, reject: reject, timer: timer };
      this.event?.send(PKT_INIT_EVENT, payload).catch((err: Error) => {
        this.eventWaiter = null;
        clearTimeout(timer);
        reject(err);
      });
    });
  }

  private handleCommandFrame(type: number, payload: Uint8Array): void {
    switch (type) {
      case PKT_INIT_COMMAND_ACK: {
        const waiter = this.initWaiter;
        this.initWaiter = null;
        if (!waiter) return;
        clearTimeout(waiter.timer);
        if (payload.length < 20) {
          waiter.reject(new Error('InitCommandAck 载荷过短'));
          return;
        }
        const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
        this.connectionId = view.getUint32(0, true);
        this.cameraGuid = payload.slice(4, 20);
        this.cameraName = readUtf16z(payload, 20);
        waiter.resolve(true);
        return;
      }
      case PKT_INIT_FAIL: {
        const waiter = this.initWaiter;
        this.initWaiter = null;
        if (!waiter) return;
        clearTimeout(waiter.timer);
        const code = payload.length >= 4
          ? new DataView(payload.buffer, payload.byteOffset, payload.byteLength).getUint32(0, true)
          : 0;
        waiter.reject(new Error(`相机拒绝 Init（code=${code}）`));
        return;
      }
      case PKT_START_DATA: {
        const p = this.pending;
        if (!p || payload.length < 8) return;
        const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
        const tid = view.getUint32(0, true);
        if (tid !== p.transId) return;
        p.declared = view.getUint32(4, true);
        return;
      }
      case PKT_DATA:
      case PKT_END_DATA: {
        const p = this.pending;
        if (!p || payload.length < 4) return;
        const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
        const tid = view.getUint32(0, true);
        if (tid !== p.transId) return;
        p.chunks.push(payload.slice(4));
        if (type === PKT_END_DATA) {
          // EndData 之后紧跟 CmdResponse，这里只收数据
        }
        return;
      }
      case PKT_CMD_RESPONSE: {
        const p = this.pending;
        if (!p || payload.length < 6) return;
        const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
        const code = view.getUint16(0, true);
        const tid = view.getUint32(2, true);
        if (tid !== p.transId) return;
        const params: number[] = [];
        for (let off = 6; off + 4 <= payload.length; off += 4) {
          params.push(view.getUint32(off, true));
        }
        let data: Uint8Array | null = null;
        if (p.chunks.length > 0) {
          data = concat(p.chunks);
        }
        this.pending = null;
        clearTimeout(p.timer);
        p.resolve({ code: code, params: params, data: data });
        return;
      }
      case PKT_PING: {
        this.command?.send(PKT_PONG, new Uint8Array(0)).catch((_e: Error) => {});
        return;
      }
      default:
        return;
    }
  }

  private handleEventFrame(type: number, payload: Uint8Array): void {
    switch (type) {
      case PKT_INIT_EVENT_ACK: {
        const waiter = this.eventWaiter;
        this.eventWaiter = null;
        if (!waiter) return;
        clearTimeout(waiter.timer);
        waiter.resolve(true);
        return;
      }
      case PKT_INIT_FAIL: {
        const waiter = this.eventWaiter;
        this.eventWaiter = null;
        if (!waiter) return;
        clearTimeout(waiter.timer);
        waiter.reject(new Error('相机拒绝 InitEvent'));
        return;
      }
      case PKT_EVENT: {
        if (payload.length < 2) return;
        const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
        const code = view.getUint16(0, true);
        const params: number[] = [];
        for (let off = 2; off + 4 <= payload.length; off += 4) {
          params.push(view.getUint32(off, true));
        }
        this.onEvent(code, params);
        return;
      }
      case PKT_PING: {
        this.event?.send(PKT_PONG, new Uint8Array(0)).catch((_e: Error) => {});
        return;
      }
      default:
        return;
    }
  }

  private failAll(reason: string): void {
    this.log(`[PTP/IP] 链路中断: ${reason}`);
    this.rejectPending(reason);
    const waiter = this.initWaiter;
    this.initWaiter = null;
    if (waiter) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error(reason));
    }
    const eventWaiter = this.eventWaiter;
    this.eventWaiter = null;
    if (eventWaiter) {
      clearTimeout(eventWaiter.timer);
      eventWaiter.reject(new Error(reason));
    }
    this.brokenHandler(reason);
  }

  private rejectPending(reason: string): void {
    const p = this.pending;
    this.pending = null;
    if (!p) return;
    clearTimeout(p.timer);
    p.reject(new Error(reason));
  }
}
