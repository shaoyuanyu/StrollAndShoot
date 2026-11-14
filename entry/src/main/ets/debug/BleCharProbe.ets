import rawPtp from 'libentry.so';
import { BleCameraLink } from '../services/BleScanner';
import { CameraService } from '../services/CameraService';
import { BleIdentityStore } from '../services/BleIdentityStore';

/**
 * BLE 特征探测（仅调试包，2026-11-14）。
 *
 * 目的：Z50II 的 `de00` 服务里比 COOLPIX A1000 多出 `0x2020` / `0x2021` 两条
 * 特征（A1000 的公开特征表里没有），属性未知。如果它们是 PTP 的写入/通知对，
 * 那「蓝牙模式下看缩略图」就不必经过经典 SPP（SPP 已被鸿蒙的 SDP 限制挡住）。
 *
 * 流程：列服务表 → 逐个读候选特征（失败说明是只写/只通知）→ 能通知的开
 * notify → 往 `0x2021` / `0x2020` 写 PTP（OpenSession + GetDeviceInfo，USB 容器）
 * → 等各候选的通知，原始 hex 落 AppLog（`[BLECHAR]` 前缀）。
 *
 * 触发：`aa start ... --ps blechar`（仅调试包）。前提：相机醒着、App 的 BLE 已连。
 * 不写持久化；只写 `0x2020/0x2021` 两条未知特征，不碰配对/校时/位置那条链。
 */
export class BleCharProbe {
  private static readonly SERVICE = '0000de00-3dd4-4255-8d62-6dc7b9bd5561';
  /** 未知特征对：0x2021 可写、0x2020 只读+通知（2026-11-14 实测）。 */
  private static readonly CH_2020 = '00002020-3dd4-4255-8d62-6dc7b9bd5561';
  private static readonly CH_2021 = '00002021-3dd4-4255-8d62-6dc7b9bd5561';

  /** 候补特征（短名 → 完整 UUID）。 */
  private static readonly CANDIDATES: string[] = [
    '00002009-3dd4-4255-8d62-6dc7b9bd5561',
    '0000200a-3dd4-4255-8d62-6dc7b9bd5561',
    '00002020-3dd4-4255-8d62-6dc7b9bd5561',
    '00002021-3dd4-4255-8d62-6dc7b9bd5561',
    '00002080-3dd4-4255-8d62-6dc7b9bd5561',
    '00002082-3dd4-4255-8d62-6dc7b9bd5561',
    '00002083-3dd4-4255-8d62-6dc7b9bd5561',
    '00002084-3dd4-4255-8d62-6dc7b9bd5561',
    '00002086-3dd4-4255-8d62-6dc7b9bd5561',
    '00002087-3dd4-4255-8d62-6dc7b9bd5561'
  ];

  /** 可能只做通知的特征（读会失败，先试订阅）。 */
  private static readonly NOTIFY_CANDIDATES: string[] = [
    '0000200a-3dd4-4255-8d62-6dc7b9bd5561',
    '00002020-3dd4-4255-8d62-6dc7b9bd5561',
    '00002021-3dd4-4255-8d62-6dc7b9bd5561',
    '00002084-3dd4-4255-8d62-6dc7b9bd5561',
    '00002087-3dd4-4255-8d62-6dc7b9bd5561'
  ];

  private static log(msg: string): void {
    try {
      CameraService.getInstance().getLog().add(`[BLECHAR] ${msg}`);
    } catch (_e) {
      // 日志不可用不影响探针
    }
  }

  static run(arg: string): void {
    const mode = arg.trim();
    let task: Promise<void>;
    if (mode.startsWith('one')) {
      task = BleCharProbe.runOne(mode);
    } else if (mode === 'ptp') {
      task = BleCharProbe.runPtp();
    } else {
      task = BleCharProbe.runInner();
    }
    task.catch((err: Error) => {
      BleCharProbe.log(`异常终止: ${err.message}`);
    });
  }

  /**
   * 只写一种封装（不重连）：每次 App 冷启动后跑一次，保证是这条链路的第一笔写。
   *
   * 参数 `one` / `one-1` / `one-2`… 对应 `ptpVariants()` 的下标；第一笔写成功
   * 之后才谈得上「0x2020 会不会回通知」。
   */
  private static async runOne(mode: string): Promise<void> {
    const svc = CameraService.getInstance();
    const link = svc.getBleLinkForProbe();
    BleCharProbe.log(`单笔试验（BLE connected=${svc.bleConnected}，mode=${mode}）`);
    if (link === null || !svc.bleConnected) {
      BleCharProbe.log('BLE 没连上');
      return;
    }
    const parts = mode.split('-');
    const idx = parts.length > 1 ? Number(parts[1]) : 0;
    const variants = BleCharProbe.ptpVariants();
    if (!(idx >= 0 && idx < variants.length)) {
      BleCharProbe.log(`下标越界（共 ${variants.length} 种）`);
      return;
    }
    const v = variants[idx];
    try {
      await link.enableNotification(BleCharProbe.CH_2020);
      BleCharProbe.log('0x2020 notify 已开启');
    } catch (err) {
      BleCharProbe.log(`0x2020 notify 失败: ${(err as Error).message}`);
    }
    try {
      await link.enableNotification(BleCharProbe.CH_2021);
    } catch (_e) {
      // 可选
    }
    try {
      await link.writeCharacteristic(BleCharProbe.CH_2021, v.bytes);
      BleCharProbe.log(`写 0x2021 成功：${v.name}（${v.bytes.length}B）`
        + ` ${BleCameraLink.describeBytes(v.bytes)}`);
    } catch (err) {
      BleCharProbe.log(`写 0x2021 失败：${v.name} — ${(err as Error).message}`);
      return;
    }
    for (const uuid of [BleCharProbe.CH_2020, BleCharProbe.CH_2021]) {
      try {
        const r = await link.waitCharacteristic(uuid, 3000);
        BleCharProbe.log(`← ${BleCharProbe.short(uuid)} (${r.length}B) `
          + `${BleCameraLink.describeBytes(r)}`);
      } catch (_e) {
        BleCharProbe.log(`${BleCharProbe.short(uuid)} 无通知`);
      }
    }
    // 通知没有的话，再看一眼特征值本身有没有变成「回执」（有些通道是读回执）。
    for (const uuid of [BleCharProbe.CH_2020, BleCharProbe.CH_2021]) {
      try {
        const r = await link.readWithReason(uuid);
        BleCharProbe.log(`写完读 ${BleCharProbe.short(uuid)} = `
          + `${r.value !== null ? BleCameraLink.describeBytes(r.value) : '失败: ' + r.error}`);
      } catch (err) {
        BleCharProbe.log(`写完读 ${BleCharProbe.short(uuid)} 异常: ${(err as Error).message}`);
      }
    }
    BleCharProbe.log('单笔试验结束');
  }

  /**
   * PTP over BLE 试验：每换一种封装就重连一次 GATT（把 0x2021 的内部状态清掉），
   * 写一次 → 等 0x2020 的通知。命中就停。
   */
  private static async runPtp(): Promise<void> {
    const svc = CameraService.getInstance();
    BleCharProbe.log('PTP over BLE 试验开始');
    const variants = BleCharProbe.ptpVariants();
    for (const v of variants) {
      BleCharProbe.log(`--- ${v.name} (${v.bytes.length}B) ---`);
      if (!await BleCharProbe.reconnect(svc)) {
        BleCharProbe.log('重连失败，停止');
        return;
      }
      const link = svc.getBleLinkForProbe();
      if (link === null) return;
      try {
        await link.enableNotification(BleCharProbe.CH_2020);
        BleCharProbe.log('0x2020 notify 已开启');
      } catch (err) {
        BleCharProbe.log(`0x2020 notify 失败: ${(err as Error).message}`);
      }
      try {
        await link.enableNotification(BleCharProbe.CH_2021);
      } catch (_e) {
        // 0x2021 只做写入也行
      }
      try {
        await link.writeCharacteristic(BleCharProbe.CH_2021, v.bytes);
        BleCharProbe.log(`写 0x2021 成功（${v.name}）`);
      } catch (err) {
        BleCharProbe.log(`写 0x2021 失败（${v.name}）: ${(err as Error).message}`);
        continue;
      }
      let got = false;
      for (const uuid of [BleCharProbe.CH_2020, BleCharProbe.CH_2021]) {
        try {
          const r = await link.waitCharacteristic(uuid, 2500);
          got = true;
          BleCharProbe.log(`← ${BleCharProbe.short(uuid)} (${r.length}B) `
            + `${BleCameraLink.describeBytes(r)}`);
        } catch (_e) {
          // 这条没回
        }
      }
      if (got) {
        BleCharProbe.log(`命中：${v.name} 有回应，停止`);
        return;
      }
      BleCharProbe.log('两种通知都没回');
    }
    BleCharProbe.log('所有封装都没有回应');
  }

  private static async reconnect(svc: CameraService): Promise<boolean> {
    const id = BleIdentityStore.getInstance();
    if (!id.hasIdentity()) {
      BleCharProbe.log('没有 BLE 身份，无法重连');
      return false;
    }
    try {
      // 相机的 BLE 地址每轮广播都会换（RPA），不能用存档里的旧地址直连；
      // 先断开，再扫一轮拿当前地址。
      await svc.dropBleForProbe();
      await BleCharProbe.sleep(1500);
      await svc.scanBleCameras(5000);
      const cams = svc.bleCameras;
      if (cams.length === 0) {
        BleCharProbe.log('重连：扫描没找到相机');
        return false;
      }
      let target = cams[0];
      for (const c of cams) {
        if (c.name === id.cameraName || c.name.includes(id.cameraName)) {
          target = c;
          break;
        }
      }
      BleCharProbe.log(`重连：扫到 ${target.deviceId}（${target.name}）`);
      const ok = await svc.connectBle(target.deviceId, target.name, false);
      BleCharProbe.log(`BLE 重连${ok ? '成功' : '失败'}`);
      await BleCharProbe.sleep(800);
      return ok;
    } catch (err) {
      BleCharProbe.log(`重连异常: ${(err as Error).message}`);
      return false;
    }
  }

  private static ptpVariants(): PtpVariant[] {
    const dev = rawPtp.buildGetDeviceInfo();
    const open = rawPtp.buildOpenSession(1);
    const out: PtpVariant[] = [];
    out.push({ name: 'dev-usb', bytes: dev });
    out.push({ name: 'open-usb', bytes: open });
    out.push({ name: 'dev-2len', bytes: BleCharProbe.withLen(dev, 2) });
    out.push({ name: 'dev-4len', bytes: BleCharProbe.withLen(dev, 4) });
    out.push({ name: 'dev-ptpip', bytes: BleCharProbe.ptpIpDev() });
    out.push({ name: 'one-byte-01', bytes: new Uint8Array([0x01]) });
    out.push({ name: 'open-usb+dev-usb', bytes: BleCharProbe.concat(open, dev) });
    out.push({ name: 'open2len+dev2len', bytes: BleCharProbe.concat(
      BleCharProbe.withLen(open, 2), BleCharProbe.withLen(dev, 2)) });
    return out;
  }

  private static withLen(bytes: Uint8Array, width: number): Uint8Array {
    const out = new Uint8Array(bytes.length + width);
    const dv = new DataView(out.buffer);
    if (width === 2) {
      dv.setUint16(0, bytes.length, true);
    } else {
      dv.setUint32(0, bytes.length, true);
    }
    out.set(bytes, width);
    return out;
  }

  private static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  private static ptpIpDev(): Uint8Array {
    const bytes = new Uint8Array(18);
    const dv = new DataView(bytes.buffer);
    dv.setUint32(0, 18, true);
    dv.setUint32(4, 6, true);
    dv.setUint32(8, 1, true);
    dv.setUint16(12, 0x1001, true);
    dv.setUint32(14, 1, true);
    return bytes;
  }

  private static async runInner(): Promise<void> {
    const svc = CameraService.getInstance();
    const link = svc.getBleLinkForProbe();
    BleCharProbe.log(`开始（BLE connected=${svc.bleConnected}）`);
    if (link === null || !svc.bleConnected) {
      BleCharProbe.log('BLE 没连上：先在 App 里连上相机再跑探针');
      return;
    }

    // 1) 服务表（listServices 自己写日志）
    try {
      const lines = await link.listServices();
      for (const line of lines) {
        BleCharProbe.log(`服务表: ${line}`);
      }
    } catch (err) {
      BleCharProbe.log(`服务表失败: ${(err as Error).message}`);
    }

    // 2) 逐个读候选：读成功说明可读，失败通常意味着只写/只通知
    const readable: string[] = [];
    for (const uuid of BleCharProbe.CANDIDATES) {
      try {
        const r = await link.readWithReason(uuid);
        if (r.value !== null) {
          readable.push(uuid);
          BleCharProbe.log(`读 ${BleCharProbe.short(uuid)} = ${BleCameraLink.describeBytes(r.value)}`);
        } else {
          BleCharProbe.log(`读 ${BleCharProbe.short(uuid)} 失败: ${r.error}`);
        }
      } catch (err) {
        BleCharProbe.log(`读 ${BleCharProbe.short(uuid)} 异常: ${(err as Error).message}`);
      }
      await BleCharProbe.sleep(150);
    }

    // 3) 开通知：只对可能只通知的候选试
    const subscribed: string[] = [];
    for (const uuid of BleCharProbe.NOTIFY_CANDIDATES) {
      try {
        await link.enableNotification(uuid);
        subscribed.push(uuid);
        BleCharProbe.log(`notify 已开启 ${BleCharProbe.short(uuid)}`);
      } catch (err) {
        BleCharProbe.log(`notify 失败 ${BleCharProbe.short(uuid)}: ${(err as Error).message}`);
      }
      await BleCharProbe.sleep(150);
    }

    // 4) 往未知的写候选发 PTP：OpenSession(1) → GetDeviceInfo
    const open = rawPtp.buildOpenSession(1);
    const dev = rawPtp.buildGetDeviceInfo();
    for (const target of ['00002021-3dd4-4255-8d62-6dc7b9bd5561',
      '00002020-3dd4-4255-8d62-6dc7b9bd5561']) {
      BleCharProbe.log(`写 ${BleCharProbe.short(target)}：OpenSession(${open.length}B)`);
      try {
        await link.writeCharacteristic(target, open);
        await BleCharProbe.sleep(300);
        BleCharProbe.log(`写 ${BleCharProbe.short(target)}：GetDeviceInfo(${dev.length}B)`);
        await link.writeCharacteristic(target, dev);
      } catch (err) {
        BleCharProbe.log(`写 ${BleCharProbe.short(target)} 失败: ${(err as Error).message}`);
        continue;
      }
      // 等通知：逐个候选各等 900ms，谁先回就记谁
      for (const uuid of subscribed) {
        try {
          const v = await link.waitCharacteristic(uuid, 900);
          BleCharProbe.log(`← ${BleCharProbe.short(uuid)} (${v.length}B) ${BleCameraLink.describeBytes(v)}`);
        } catch (_e) {
          // 这条没回，继续等别的
        }
      }
    }

    BleCharProbe.log(`结束（可读 ${readable.length} 条，已订阅 ${subscribed.length} 条）`);
  }

  private static short(uuid: string): string {
    // 00002020-3dd4-... → 0x2020
    const head = uuid.substring(0, 8);
    return `0x${head.substring(4)}`;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }
}

/** 一次 PTP 封装试验。 */
interface PtpVariant {
  name: string;
  bytes: Uint8Array;
}
