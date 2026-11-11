import { NikonBlowfish } from './NikonBlowfish';

/**
 * 尼康智能设备模式的四步配对（stage1 → 2 → 3 → 4）。
 *
 * 帧固定 17 字节小端：`stage(u8) + timestamp(u64 LE) + device(u32 LE) + nonce(u32 LE)`。
 *
 * **ArkTS 的 number 只有 53 位精度**，不能像 Dart 那样直接存 u64 时间戳；
 * 这里把时间戳拆成 `tsLo`/`tsHi` 两个 u32，编码时按低 32 位在前写入。
 *
 * 协议来源：ZPill 在 Zf 上的真机实证（`pairing_engine.dart` / `pairing_message.dart`）。
 * salt 表是协议方言的固定常量，不能改。
 */

export interface PairingMessage {
  stage: number;
  /** 时间戳低 32 位。 */
  tsLo: number;
  /** 时间戳高 32 位。 */
  tsHi: number;
  device: number;
  nonce: number;
  raw: Uint8Array;
}

export interface Stage3Result {
  message: PairingMessage;
  saltIndex: number;
}

const FRAME_LEN = 17;

/** 8 组挑战 salt（协议方言定案）。 */
export const NIKON_SALTS: number[][] = [
  [0x704066e4, 0x0433d552],
  [0xed4b8fac, 0x15f7e47b],
  [0x24471f11, 0x8b5ea1fc],
  [0x05960c31, 0x2b8c7f41],
  [0xfda588c1, 0xeba8b1f3],
  [0x99166056, 0x1bd3d550],
  [0xcd32687f, 0xa9e28a30],
  [0x2a8fe834, 0xdec7ebf4]
];

function reverseU32(value: number): number {
  const v = value >>> 0;
  return (((v & 0x000000FF) << 24) |
    ((v & 0x0000FF00) << 8) |
    ((v & 0x00FF0000) >>> 8) |
    ((v & 0xFF000000) >>> 24)) >>> 0;
}

function randomU32(): number {
  return Math.floor(Math.random() * 0x100000000) >>> 0;
}

export function encodePairingMessage(stage: number, tsLo: number, tsHi: number,
                                     device: number, nonce: number): Uint8Array {
  const out = new Uint8Array(FRAME_LEN);
  const view = new DataView(out.buffer);
  view.setUint8(0, stage & 0xFF);
  view.setUint32(1, tsLo >>> 0, true);
  view.setUint32(5, tsHi >>> 0, true);
  view.setUint32(9, device >>> 0, true);
  view.setUint32(13, nonce >>> 0, true);
  return out;
}

export function decodePairingMessage(raw: Uint8Array): PairingMessage {
  if (raw.length !== FRAME_LEN) {
    throw new Error(`配对帧须为 ${FRAME_LEN} 字节，实得 ${raw.length}`);
  }
  const view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
  return {
    stage: view.getUint8(0),
    tsLo: view.getUint32(1, true),
    tsHi: view.getUint32(5, true),
    device: view.getUint32(9, true),
    nonce: view.getUint32(13, true),
    raw: raw.slice()
  };
}

export class NikonPairing {
  private readonly blowfish: NikonBlowfish;
  private readonly onLog: (msg: string) => void;

  constructor(blowfish: NikonBlowfish, onLog: (msg: string) => void) {
    this.blowfish = blowfish;
    this.onLog = onLog;
  }

  /** stage1：随机时间戳 + 新 deviceId（低位字节 0x01）+ 随机 nonce。 */
  createStage1(savedDevice?: number, savedNonce?: number): PairingMessage {
    const device = savedDevice !== undefined
      ? savedDevice
      : ((randomU32() & 0xFFFFFF00) | 0x01) >>> 0;
    const nonce = savedNonce !== undefined ? savedNonce : randomU32();
    const tsLo = randomU32();
    const tsHi = randomU32();
    const raw = encodePairingMessage(0x01, tsLo, tsHi, device, nonce);
    return { stage: 0x01, tsLo: tsLo, tsHi: tsHi, device: device, nonce: nonce, raw: raw };
  }

  /**
   * 用 stage2 的挑战帧找 salt 并构造 stage3。
   *
   * 校验式：`hash(salt ‖ camLo ‖ camHi ‖ ourLo ‖ ourHi)` 的两个字等于
   * `reverseU32(stage2.device/nonce)`。
   * stage3 的块序反过来（我方时间戳在前），结果再反转回小端。
   */
  async verifyStage2AndBuildStage3(stage1: PairingMessage,
                                   stage2: PairingMessage): Promise<Stage3Result | null> {
    const ourLo = reverseU32(stage1.tsLo);
    const ourHi = reverseU32(stage1.tsHi);
    const camLo = reverseU32(stage2.tsLo);
    const camHi = reverseU32(stage2.tsHi);
    const expectDevice = reverseU32(stage2.device);
    const expectNonce = reverseU32(stage2.nonce);

    for (let i = 0; i < NIKON_SALTS.length; i++) {
      const salt = NIKON_SALTS[i];
      const h = await this.blowfish.hash([salt[0], salt[1], camLo, camHi, ourLo, ourHi]);
      if (h[0] === expectDevice && h[1] === expectNonce) {
        const r = await this.blowfish.hash([salt[0], salt[1], ourLo, ourHi, camLo, camHi]);
        const device = reverseU32(r[0]);
        const nonce = reverseU32(r[1]);
        const raw = encodePairingMessage(0x03, stage1.tsLo, stage1.tsHi, device, nonce);
        this.onLog(`配对: 命中 salt #${i}`);
        return {
          message: { stage: 0x03, tsLo: stage1.tsLo, tsHi: stage1.tsHi,
            device: device, nonce: nonce, raw: raw },
          saltIndex: i
        };
      }
    }
    this.onLog('配对: 8 组 salt 均未命中');
    return null;
  }

  /** stage4 帧字节 9–16 = 相机序列号 ASCII（NUL 截止）。 */
  extractSerial(stage4: PairingMessage): string {
    let s = '';
    for (let i = 9; i < 17; i++) {
      const b = stage4.raw[i];
      if (b === 0) break;
      s += String.fromCharCode(b);
    }
    return s;
  }
}
